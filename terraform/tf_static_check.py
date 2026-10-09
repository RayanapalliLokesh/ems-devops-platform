#!/usr/bin/env python3
"""Phase 20 - playground policy check for every Terraform file (stdlib only, no terraform binary needed).

Usage: python3 terraform/tf_static_check.py [TERRAFORM_ROOT]     (default: the folder this script is in)

Scans **/*.tf and **/*.tfvars* (skipping .terraform folders) and fails (exit 1) on anything the KodeKloud
playground forbids or that would cost money there:
  - an instance type outside t2/t3 nano-medium (instance_type values, *instance_type* variable defaults)
  - cpu_credits other than "standard", or an aws_instance / aws_launch_template without
    credit_specification { cpu_credits = "standard" } (unlimited credits suspend the session)
  - nat_gateways > 0 anywhere except envs/prod (prod is planned only, never applied)
  - EBS volume sizes above 30 GB
  - AWS regions outside us-east-1, us-west-2, us-east-2
  - aws_iam_role_policy resources (iam:PutRolePolicy is denied: use aws_iam_policy + an attachment)
  - aws_iam_policy without provider = aws.untagged (iam:TagPolicy is denied, default_tags would add tags)
  - Auto Scaling / node group sizes above 3 nodes
"""
import os
import re
import sys

ALLOWED_INSTANCE_TYPES = {f'{family}.{size}' for family in ('t2', 't3') for size in ('nano', 'micro', 'small', 'medium')}
ALLOWED_REGIONS = {'us-east-1', 'us-west-2', 'us-east-2'}
MAX_VOLUME_GB = 30
MAX_NODES = 3
NAT_ALLOWED_DIRS = ('envs/prod',)

REGION_RE = re.compile(
    r'\b((?:us|eu|ap|sa|ca|me|af|il|mx|cn)(?:-gov|-iso[a-z]?)?-'
    r'(?:east|west|north|south|central|northeast|northwest|southeast|southwest)-\d+)[a-z]?\b')
NOT_EQ = r'=(?![=~>])'


def lex(text):
    """Return (clean, masked), both as long as `text`, newlines kept.

    clean:  comments and heredoc bodies blanked out (strings kept)
    masked: like clean, but string contents blanked too (safe for brace matching)
    """
    clean = list(text)
    masked = list(text)
    n = len(text)
    i = 0
    stack = ['code']        # 'code' | 'string' | ('interp', depth)

    def blank(start, end, both=True):
        for k in range(start, end):
            if text[k] != '\n':
                masked[k] = ' '
                if both:
                    clean[k] = ' '

    while i < n:
        mode = stack[-1]
        ch = text[i]
        if mode == 'string':
            if ch == '\\':
                blank(i, min(i + 2, n), both=False)
                i += 2
                continue
            if ch in '$%' and text[i + 1:i + 2] == '{':
                if text[i + 2:i + 3] == ch:   # $${ / %%{ is an escaped literal
                    blank(i, i + 3, both=False)
                    i += 3
                    continue
                blank(i, i + 2, both=False)
                stack.append(['interp', 0])
                i += 2
                continue
            if ch == '"':
                stack.pop()
                i += 1
                continue
            blank(i, i + 1, both=False)
            i += 1
            continue
        # code or interpolation
        if ch == '#' or text.startswith('//', i):
            end = text.find('\n', i)
            end = n if end == -1 else end
            blank(i, end)
            i = end
            continue
        if text.startswith('/*', i):
            end = text.find('*/', i + 2)
            end = n if end == -1 else end + 2
            blank(i, end)
            i = end
            continue
        if ch == '"':
            stack.append('string')
            i += 1
            continue
        heredoc = re.match(r'<<-?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\n', text[i:])
        if heredoc:
            marker = heredoc.group(1)
            body_start = i + heredoc.end()
            end_match = re.compile(r'^[ \t]*' + re.escape(marker) + r'[ \t]*$', re.M).search(text, body_start)
            end = end_match.start() if end_match else n
            blank(body_start, end)
            i = end_match.end() if end_match else n
            continue
        if isinstance(mode, list):
            if ch == '{':
                mode[1] += 1
            elif ch == '}':
                if mode[1] == 0:
                    blank(i, i + 1, both=False)
                    stack.pop()
                    i += 1
                    continue
                mode[1] -= 1
            blank(i, i + 1, both=False)   # interpolation belongs to the string in `masked`
        i += 1
    return ''.join(clean), ''.join(masked)


def block_end(masked, open_brace):
    """Index just past the brace that closes the block opened at `open_brace`."""
    depth = 0
    for k in range(open_brace, len(masked)):
        if masked[k] == '{':
            depth += 1
        elif masked[k] == '}':
            depth -= 1
            if depth == 0:
                return k + 1
    return len(masked)


def blocks(clean, masked, header_re):
    """Yield (match, body_start, body_end) for each block whose header matches header_re (ends with '{')."""
    for m in re.finditer(header_re, clean):
        if masked[m.end() - 1] != '{':
            continue
        yield m, m.end(), block_end(masked, m.end() - 1)


class Checker:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.errors = []
        self.files = []
        self.counts = {}

    def rel(self, path):
        return os.path.relpath(path, self.root).replace(os.sep, '/')

    def find_files(self):
        for dirpath, dirnames, filenames in os.walk(self.root):
            dirnames[:] = sorted(d for d in dirnames if d != '.terraform')
            for name in sorted(filenames):
                if name.endswith('.tf') or '.tfvars' in name:
                    self.files.append(os.path.join(dirpath, name))

    def fail(self, path, text, offset, message):
        line = text.count('\n', 0, offset) + 1
        self.errors.append(f'FAIL {self.rel(path)}:{line}: {message}')

    def count(self, rule):
        self.counts[rule] = self.counts.get(rule, 0) + 1

    def variable_defaults(self, clean, masked, name_re):
        """(name, raw default, offset) for every variable block whose name matches name_re."""
        for m, start, end in blocks(clean, masked, r'variable\s+"([^"]+)"\s*\{'):
            if not re.search(name_re, m.group(1)):
                continue
            d = re.search(r'^\s*default\s*' + NOT_EQ + r'\s*(\[[^\]]*\]|.+)$', clean[start:end], re.M)
            if d:
                yield m.group(1), d.group(1).strip(), start + d.start(1)

    def check_file(self, path):
        with open(path, encoding='utf-8') as f:
            text = f.read()
        clean, masked = lex(text)
        rel = self.rel(path)

        # 1. instance types: attributes and variable defaults
        for m in re.finditer(r'\binstance_types?\s*' + NOT_EQ + r'\s*(\[[^\]]*\]|"[^"]*")', clean):
            for value in re.findall(r'"([^"]*)"', m.group(1)):
                self.count('instance types')
                if '${' not in value and value not in ALLOWED_INSTANCE_TYPES:
                    self.fail(path, text, m.start(), f'instance type "{value}" is not allowed '
                              f'(playground: {", ".join(sorted(ALLOWED_INSTANCE_TYPES))})')
        for name, raw, off in self.variable_defaults(clean, masked, r'instance_type'):
            for value in re.findall(r'"([^"]*)"', raw):
                self.count('instance types')
                if value not in ALLOWED_INSTANCE_TYPES:
                    self.fail(path, text, off,
                              f'variable "{name}" defaults to instance type "{value}" (not allowed in the playground)')

        # 2. CPU credits
        for m in re.finditer(r'\bcpu_credits\s*' + NOT_EQ + r'\s*"([^"]*)"', clean):
            self.count('cpu credits')
            if m.group(1) != 'standard':
                self.fail(path, text, m.start(),
                          f'cpu_credits = "{m.group(1)}" (only "standard": unlimited suspends the session)')
        for m, start, end in blocks(clean, masked, r'resource\s+"(aws_instance|aws_launch_template)"\s+"([^"]+)"\s*\{'):
            self.count('credit specification')
            body = clean[start:end]
            spec = re.search(r'\bcredit_specification\s*\{[^}]*\bcpu_credits\s*' + NOT_EQ + r'\s*"standard"', body)
            if not spec:
                self.fail(path, text, m.start(),
                          f'{m.group(1)}.{m.group(2)} has no credit_specification {{ cpu_credits = "standard" }} '
                          '(t2/t3 default to unlimited in some accounts)')

        # 3. NAT gateways (prod is plan-only)
        nat_allowed = any(rel == d or rel.startswith(d + '/') for d in NAT_ALLOWED_DIRS)
        for m in re.finditer(r'\bnat_gateways\s*' + NOT_EQ + r'\s*(\d+)', clean):
            self.count('nat gateways')
            if int(m.group(1)) > 0 and not nat_allowed:
                self.fail(path, text, m.start(), f'nat_gateways = {m.group(1)} (NAT gateways cost money; '
                          'only envs/prod, which is never applied, may have them)')
        for name, raw, off in self.variable_defaults(clean, masked, r'^nat_gateways$'):
            self.count('nat gateways')
            if raw.isdigit() and int(raw) > 0:
                self.fail(path, text, off, f'variable "{name}" defaults to {raw} NAT gateways (must default to 0)')

        # 4. volume sizes
        size_attr = r'\b(volume_size|volume_size_gb|root_volume_size|disk_size)\s*' + NOT_EQ + r'\s*(\d+)'
        for m in re.finditer(size_attr, clean):
            self.count('volume sizes')
            if int(m.group(2)) > MAX_VOLUME_GB:
                self.fail(path, text, m.start(), f'{m.group(1)} = {m.group(2)} (playground max {MAX_VOLUME_GB} GB)')
        for name, raw, off in self.variable_defaults(clean, masked, r'volume_size|disk_size'):
            self.count('volume sizes')
            if raw.isdigit() and int(raw) > MAX_VOLUME_GB:
                self.fail(path, text, off, f'variable "{name}" defaults to {raw} GB (playground max {MAX_VOLUME_GB} GB)')

        # 5. regions (any region or zone name outside comments and heredocs)
        for m in REGION_RE.finditer(clean):
            self.count('regions')
            if m.group(1) not in ALLOWED_REGIONS:
                allowed = ', '.join(sorted(ALLOWED_REGIONS))
                self.fail(path, text, m.start(), f'region "{m.group(1)}" is outside the playground ({allowed})')

        # 6. IAM: no inline role policies; customer-managed policies without tags
        for m in re.finditer(r'\bresource\s+"(aws_iam_role_policy|aws_iam_user_policy|aws_iam_group_policy)"\s+"([^"]+)"', clean):
            self.fail(path, text, m.start(), f'{m.group(1)}.{m.group(2)}: inline policies are denied in the playground '
                      '(use aws_iam_policy + aws_iam_role_policy_attachment)')
        for m, start, end in blocks(clean, masked, r'resource\s+"aws_iam_policy"\s+"([^"]+)"\s*\{'):
            self.count('iam policies')
            if not re.search(r'^\s*provider\s*=\s*aws\.untagged\b', clean[start:end], re.M):
                self.fail(path, text, m.start(), f'aws_iam_policy.{m.group(1)} must use provider = aws.untagged '
                          '(iam:TagPolicy is denied; default_tags would tag it)')

        # 7. node counts
        for m in re.finditer(r'\b(max_size|desired_size|desired_capacity)\s*' + NOT_EQ + r'\s*(\d+)', clean):
            self.count('node counts')
            if int(m.group(2)) > MAX_NODES:
                self.fail(path, text, m.start(), f'{m.group(1)} = {m.group(2)} (playground max {MAX_NODES} nodes per group)')
        for name, raw, off in self.variable_defaults(clean, masked, r'max_size|desired|max_nodes'):
            self.count('node counts')
            if raw.isdigit() and int(raw) > MAX_NODES:
                self.fail(path, text, off, f'variable "{name}" defaults to {raw} nodes (playground max {MAX_NODES})')

    def run(self):
        if not os.path.isdir(self.root):
            print(f'FAIL {self.root} is not a directory')
            return 1
        self.find_files()
        if not self.files:
            print(f'FAIL no Terraform files under {self.root}')
            return 1
        for path in self.files:
            self.check_file(path)
        if self.errors:
            for error in self.errors:
                print(error)
            print(f'\n{len(self.errors)} playground policy violation(s) in {len(self.files)} files')
            return 1
        print(f'PASS scanned {len(self.files)} Terraform files under {self.root}')
        for rule in ('instance types', 'cpu credits', 'credit specification', 'nat gateways', 'volume sizes',
                     'regions', 'iam policies', 'node counts'):
            print(f'PASS {rule}: {self.counts.get(rule, 0)} checked')
        print('PASS no inline IAM policies (aws_iam_role_policy)')
        print('PASS playground policy check')
        return 0


def main(argv):
    if len(argv) > 2 or (len(argv) == 2 and argv[1] in ('-h', '--help')):
        print(__doc__)
        return 0 if len(argv) == 2 else 2
    root = argv[1] if len(argv) == 2 else os.path.dirname(os.path.abspath(__file__))
    return Checker(root).run()


if __name__ == '__main__':
    sys.exit(main(sys.argv))
