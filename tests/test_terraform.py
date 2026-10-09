"""Phases 20-23 - the Terraform code keeps the playground rules and the dev/prod/eks promises.

The policy check and the structure tests need only Python. The `terraform test` suites (mock providers, no AWS
account) run when the terraform binary is on PATH and are skipped otherwise; they take a few seconds each.
"""
import os
import re
import shutil
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TF = os.path.join(ROOT, 'terraform')
CHECK = os.path.join(TF, 'tf_static_check.py')
MODULES = os.path.join(TF, 'modules')
MODULE_NAMES = ['network', 'security_groups', 'backup_bucket', 'host_role', 'host', 'load_balancer']
TERRAFORM = shutil.which('terraform')
COPY_IGNORE = shutil.ignore_patterns('.terraform', '*.tfstate', '*.tfstate.*', 'tfplan', '*.tfplan', 'terraform.tfvars')


def read(*parts):
    with open(os.path.join(TF, *parts)) as f:
        return f.read()


def tf_files():
    for dirpath, dirnames, filenames in os.walk(TF):
        dirnames[:] = [d for d in dirnames if d != '.terraform']
        for name in filenames:
            if name.endswith('.tf'):
                yield os.path.join(dirpath, name)


def run_check(root=None):
    cmd = [sys.executable, CHECK] + ([root] if root else [])
    return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, timeout=60)


def modules_used(env):
    """{module name: source} of an environment's main.tf"""
    text = read('envs', env, 'main.tf')
    found = {}
    for m in re.finditer(r'^module\s+"([^"]+)"\s*\{(.*?)^\}', text, re.M | re.S):
        source = re.search(r'^\s*source\s*=\s*"([^"]+)"', m.group(2), re.M)
        found[m.group(1)] = source.group(1) if source else None
    return found


def module_block(env, name):
    text = read('envs', env, 'main.tf')
    m = re.search(r'^module\s+"' + name + r'"\s*\{(.*?)^\}', text, re.M | re.S)
    assert m, f'module "{name}" not found in envs/{env}'
    return m.group(1)


# ---- tf_static_check.py -------------------------------------------------------------------------------

def test_static_check_passes_on_the_tree():
    result = run_check()
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'PASS playground policy check' in result.stdout
    assert 'FAIL' not in result.stdout


@pytest.fixture()
def tree_copy(tmp_path):
    dest = tmp_path / 'terraform'
    shutil.copytree(TF, dest, ignore=COPY_IGNORE)
    return dest


def replace_in(path, old, new):
    text = path.read_text()
    assert old in text, f'{old!r} not in {path}'
    path.write_text(text.replace(old, new, 1))


VIOLATIONS = {
    'unlimited credits': ('modules/host/main.tf', 'cpu_credits = "standard"', 'cpu_credits = "unlimited"',
                          'cpu_credits = "unlimited"'),
    'large instance': ('envs/dev/variables.tf', 'default     = "t3.medium"', 'default     = "t3.large"', 't3.large'),
    'nat in dev': ('envs/dev/main.tf', 'nat_gateways         = 0', 'nat_gateways         = 1', 'nat_gateways = 1'),
    'big volume': ('envs/dev/main.tf', 'volume_size_gb        = 20', 'volume_size_gb        = 40', 'volume_size_gb = 40'),
    'region': ('registry/main.tf', 'default = "us-east-1"', 'default = "eu-west-1"', 'eu-west-1'),
    'eks nodes': ('eks/variables.tf', 'default     = 3', 'default     = 5', 'node_max_size'),
}


@pytest.mark.parametrize('name', sorted(VIOLATIONS))
def test_static_check_fails_on_an_injected_violation(tree_copy, name):
    rel, old, new, expected = VIOLATIONS[name]
    replace_in(tree_copy / rel, old, new)
    result = run_check(str(tree_copy))
    assert result.returncode == 1, result.stdout
    assert 'FAIL' in result.stdout and expected in result.stdout, result.stdout


def test_static_check_fails_on_inline_policy_and_missing_credit_spec(tree_copy):
    with open(tree_copy / 'registry' / 'main.tf', 'a') as f:
        f.write('\nresource "aws_iam_role_policy" "inline" {\n  role   = "x"\n  policy = "{}"\n}\n')
    replace_in(tree_copy / 'eks' / 'nodes.tf', 'cpu_credits = "standard"', 'cpu_credits = var.credits')
    result = run_check(str(tree_copy))
    assert result.returncode == 1
    assert 'aws_iam_role_policy.inline' in result.stdout
    assert 'aws_launch_template.node has no credit_specification' in result.stdout


def test_static_check_allows_nat_in_prod_only(tree_copy):
    # prod already has nat_gateways = 2 and the tree passes; the same value in eks must fail
    assert 'nat_gateways         = 2' in (tree_copy / 'envs' / 'prod' / 'main.tf').read_text()
    replace_in(tree_copy / 'eks' / 'main.tf', 'nat_gateways         = 0', 'nat_gateways         = 2')
    result = run_check(str(tree_copy))
    fails = [line for line in result.stdout.splitlines() if line.startswith('FAIL')]
    assert result.returncode == 1
    assert fails and all(line.startswith('FAIL eks/main.tf') for line in fails), fails


def test_static_check_ignores_comments_and_heredocs(tree_copy):
    with open(tree_copy / 'registry' / 'main.tf', 'a') as f:
        f.write('\n# instance_type = "m5.large" in eu-west-1 is only a comment\n'
                'locals {\n  note = <<-EOT\n    cpu_credits = "unlimited"\n  EOT\n}\n')
    assert run_check(str(tree_copy)).returncode == 0


# ---- structure ----------------------------------------------------------------------------------------

@pytest.mark.parametrize('module', MODULE_NAMES)
def test_module_has_the_standard_files(module):
    for name in ('main.tf', 'variables.tf', 'outputs.tf', 'versions.tf'):
        assert os.path.isfile(os.path.join(MODULES, module, name)), f'modules/{module}/{name} missing'


def test_there_are_exactly_six_modules():
    found = sorted(d for d in os.listdir(MODULES) if os.path.isdir(os.path.join(MODULES, d)))
    assert found == sorted(MODULE_NAMES)


def test_dev_and_prod_use_the_same_modules():
    dev, prod = modules_used('dev'), modules_used('prod')
    assert dev == prod
    assert sorted(dev) == sorted(MODULE_NAMES)
    assert all(source == f'../../modules/{name}' for name, source in dev.items())


def test_prod_has_nat_per_zone_private_host_and_no_ssh():
    assert re.search(r'^\s*nat_gateways\s*=\s*2\s*$', module_block('prod', 'network'), re.M)
    assert re.search(r'^\s*ssh_cidrs\s*=\s*\[\]\s*$', module_block('prod', 'security_groups'), re.M)
    host = module_block('prod', 'host')
    assert 'private_subnet_ids' in host and re.search(r'public_ip\s*=\s*false', host)


def test_dev_has_no_nat_and_a_public_host():
    assert re.search(r'^\s*nat_gateways\s*=\s*0\s*$', module_block('dev', 'network'), re.M)
    host = module_block('dev', 'host')
    assert 'public_subnet_ids' in host and re.search(r'public_ip\s*=\s*true', host)


def test_no_inline_iam_policies_anywhere():
    offenders = []
    for path in tf_files():
        with open(path) as f:
            if re.search(r'resource\s+"aws_iam_(role|user|group)_policy"\s', f.read()):
                offenders.append(os.path.relpath(path, ROOT))
    assert not offenders, f'inline IAM policies are denied in the playground: {offenders}'


def test_eks_role_names_and_managed_policies():
    text = read('eks', 'main.tf')
    assert re.search(r'resource "aws_iam_role" "cluster" \{[^}]*name\s*=\s*"eksClusterRole"', text)
    assert re.search(r'resource "aws_iam_role" "node" \{[^}]*name\s*=\s*"AmazonEKSNodeRole"', text)
    for policy in ('AmazonEKSClusterPolicy', 'AmazonEKSWorkerNodePolicy', 'AmazonEKS_CNI_Policy',
                   'AmazonEC2ContainerRegistryReadOnly'):
        assert f'arn:aws:iam::aws:policy/{policy}' in text
    assert 'resource "aws_iam_policy"' not in text


def test_eks_reuses_the_network_module_without_nat():
    block = re.search(r'^module "network" \{(.*?)^\}', read('eks', 'main.tf'), re.M | re.S).group(1)
    assert '"../modules/network"' in block
    assert re.search(r'nat_gateways\s*=\s*0', block)


def test_eks_nodes_and_backend():
    nodes = read('eks', 'nodes.tf')
    assert '/amazon-linux-2023/x86_64/standard/recommended/image_id' in nodes
    assert 'kind: NodeConfig' in nodes and 'application/node.eks.aws' in nodes
    assert 'http_put_response_hop_limit = 2' in nodes
    versions = read('eks', 'versions.tf')
    assert re.search(r'backend "s3" \{\s*key\s*=\s*"eks/terraform.tfstate"\s*\}', versions)
    assert 'update_kubeconfig_command' in read('eks', 'outputs.tf')


# ---- terraform test (mock providers) ------------------------------------------------------------------

def terraform(args, cwd, timeout=600):
    env = dict(os.environ, TF_IN_AUTOMATION='1', CHECKPOINT_DISABLE='1')
    if 'TF_PLUGIN_CACHE_DIR' not in env:
        # download the ~700 MB AWS provider once, not once per configuration
        env['TF_PLUGIN_CACHE_DIR'] = os.path.expanduser('~/.terraform.d/plugin-cache')
        os.makedirs(env['TF_PLUGIN_CACHE_DIR'], exist_ok=True)
    return subprocess.run(['terraform', f'-chdir={cwd}'] + args, capture_output=True, text=True, env=env, timeout=timeout)


def init_and_test(directory):
    init = terraform(['init', '-backend=false', '-input=false', '-no-color'], directory)
    assert init.returncode == 0, init.stdout + init.stderr
    result = terraform(['test', '-no-color'], directory)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'Success!' in result.stdout and '0 failed' in result.stdout
    return result.stdout


SUITES = ['modules/network', 'modules/security_groups', 'modules/host', 'modules/host_role', 'eks']


@pytest.mark.skipif(TERRAFORM is None, reason='terraform is not installed')
@pytest.mark.parametrize('suite', SUITES)
def test_terraform_test_suite(suite):
    assert os.path.isdir(os.path.join(TF, suite, 'tests')), f'{suite}/tests missing'
    init_and_test(os.path.join(TF, suite))


@pytest.mark.skipif(TERRAFORM is None, reason='terraform is not installed')
def test_terraform_test_dev_environment(tmp_path):
    # a copy: the real envs/dev folder is initialised against the live remote backend and must not be touched
    copy = tmp_path / 'repo'
    shutil.copytree(os.path.join(TF, 'envs', 'dev'), copy / 'terraform' / 'envs' / 'dev', ignore=COPY_IGNORE)
    shutil.copytree(MODULES, copy / 'terraform' / 'modules', ignore=COPY_IGNORE)
    shutil.copytree(os.path.join(ROOT, 'deploy', 'aws'), copy / 'deploy' / 'aws')
    init_and_test(str(copy / 'terraform' / 'envs' / 'dev'))
    assert not (copy / 'ansible').exists(), 'the mock local provider must not write the inventory'


@pytest.mark.skipif(TERRAFORM is None, reason='terraform is not installed')
def test_terraform_fmt():
    result = subprocess.run(['terraform', 'fmt', '-check', '-recursive', TF], capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, f'unformatted files:\n{result.stdout}'
