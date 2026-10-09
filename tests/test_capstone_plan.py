"""Phase 11 - the capstone plan is complete, and the repository matches it in every later phase"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(*parts):
    with open(os.path.join(ROOT, *parts)) as f:
        return f.read()


def table_rows(text, header):
    """Cells of every data row of the Markdown table that starts with `header`"""
    lines = text[text.index(header):].splitlines()[2:]
    rows = []
    for line in lines:
        if not line.startswith('|'):
            break
        rows.append([cell.strip() for cell in line.strip('|').split('|')])
    return rows


def current_phase():
    """The newest entry of the changelog names the phase this working tree is at"""
    return int(re.search(r'^## Phase (\d+)', read('CHANGELOG.md'), re.MULTILINE).group(1))


def test_the_plan_documents_exist_and_the_milestones_cover_every_phase():
    for name in ('target-role.md', 'scope.md', 'architecture.md', 'repo-structure.md', 'milestones.md'):
        assert len(read('docs', 'capstone', name)) > 800, name
    rows = table_rows(read('docs', 'capstone', 'milestones.md'), '| # | Focus |')
    assert [row[0] for row in rows] == [f'M{n}' for n in range(1, 13)]
    covered = []
    for row in rows:
        first, _, last = row[2].partition('-')
        covered += range(int(first), int(last or first) + 1)
    assert covered == list(range(0, 31))                         # no phase missing, none planned twice
    assert len(table_rows(read('docs', 'capstone', 'target-role.md'), '| # | Skill')) == 12


def test_the_repository_contains_what_the_plan_says_and_nothing_early():
    phase = current_phase()
    for paths, _, arrives in table_rows(read('docs', 'capstone', 'repo-structure.md'), '| Path | Content |'):
        first = int(re.search(r'\d+', arrives).group())
        for path in re.findall(r'`([^`]+)`', paths):
            exists = os.path.exists(os.path.join(ROOT, path))
            if first <= phase:
                assert exists, f'{path} is planned for Phase {first} and missing in Phase {phase}'
            elif first > 10:
                assert not exists, f'{path} belongs to Phase {first}, but exists in Phase {phase}'


def test_no_environment_file_is_committed_and_every_decision_is_indexed():
    assert not os.path.exists(os.path.join(ROOT, '.env')) and os.path.exists(os.path.join(ROOT, '.env.example'))
    assert re.search(r'^\.env$', read('.gitignore'), re.MULTILINE)
    index = read('docs', 'adr', 'README.md')
    records = sorted(name for name in os.listdir(os.path.join(ROOT, 'docs', 'adr')) if re.match(r'\d{4}-', name))
    assert len(records) >= 2
    for name in records:
        assert f'| {name[:4]} |' in index, f'{name} is not listed in docs/adr/README.md'
        assert '- Status: ' in read('docs', 'adr', name)
    for template in ('.github/ISSUE_TEMPLATE/phase.md', '.github/pull_request_template.md', 'docs/learning-log/README.md'):
        assert os.path.exists(os.path.join(ROOT, template)), template
