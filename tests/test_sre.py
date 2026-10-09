"""Phase 25 - SRE practice: every alert has a severity and a runbook, the SLO document matches the rules,
every chaos script has a safe dry run and a game-day scenario, and the alert rules pass `promtool test rules`"""
import glob
import os
import re
import shutil
import stat
import subprocess

import pytest
import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMETHEUS_DIR = os.path.join(ROOT, 'monitoring', 'prometheus')
RUNBOOK_DIR = os.path.join(ROOT, 'docs', 'runbooks')
CHAOS_DIR = os.path.join(ROOT, 'scripts', 'chaos')
REQUIRED_HEADINGS = ('## Meaning', '## Diagnosis', '## Mitigation')
EXPECTED_SCENARIOS = {'high-cpu', 'db-timeout', 'dns-failure', 'image-pull-failure', 'lb-health-check-failure',
                      'terraform-drift'}
PROMETHEUS_IMAGE = 'prom/prometheus:v2.55.1'


def read(*parts):
    with open(os.path.join(ROOT, *parts)) as f:
        return f.read()


def alert_rules():
    """Every `alert:` rule of ems-alerts.yml, in file order"""
    with open(os.path.join(PROMETHEUS_DIR, 'rules', 'ems-alerts.yml')) as f:
        groups = yaml.safe_load(f)['groups']
    return [rule for group in groups for rule in group['rules'] if 'alert' in rule]


def runbook_files():
    return {os.path.splitext(os.path.basename(p))[0]
            for p in glob.glob(os.path.join(RUNBOOK_DIR, '*.md')) if os.path.basename(p) != 'README.md'}


def chaos_scripts():
    return sorted(glob.glob(os.path.join(CHAOS_DIR, '*.sh')))


# ---- alerts and runbooks --------------------------------------------------------------------------------

def test_there_are_fifteen_uniquely_named_alerts():
    names = [rule['alert'] for rule in alert_rules()]
    assert len(names) == 15
    assert len(set(names)) == len(names)


@pytest.mark.parametrize('rule', alert_rules(), ids=lambda rule: rule['alert'])
def test_every_alert_has_a_severity_and_a_runbook_with_the_required_sections(rule):
    name = rule['alert']
    assert rule['labels']['severity'] in {'page', 'ticket'}, name
    for annotation in ('summary', 'description', 'runbook_url'):
        assert rule['annotations'].get(annotation), f'{name} has no {annotation}'

    url = rule['annotations']['runbook_url']
    assert url.endswith(f'/docs/runbooks/{name}.md'), url
    path = os.path.join(RUNBOOK_DIR, f'{name}.md')
    assert os.path.isfile(path), f'{name}: {path} is missing'

    text = read('docs', 'runbooks', f'{name}.md')
    assert text.startswith(f'# {name}\n'), f'{name}.md must start with "# {name}"'
    for heading in REQUIRED_HEADINGS:
        assert re.search(rf'^{heading}\s*$', text, re.MULTILINE), f'{name}.md has no "{heading}" section'
    assert re.search(r'^Related:', text, re.MULTILINE), f'{name}.md has no "Related:" line'


def test_every_runbook_belongs_to_an_alert():
    orphans = runbook_files() - {rule['alert'] for rule in alert_rules()}
    assert not orphans, f'runbooks without an alert: {sorted(orphans)}'


def test_the_runbook_index_lists_every_alert_with_its_severity():
    index = read('docs', 'runbooks', 'README.md')
    rows = {}
    for line in index.splitlines():
        cells = [cell.strip() for cell in line.strip().strip('|').split('|')]
        if line.startswith('|') and len(cells) == 3 and cells[2].endswith('.md)'):
            rows[cells[0]] = cells
    for rule in alert_rules():
        name = rule['alert']
        assert name in rows, f'{name} is missing from docs/runbooks/README.md'
        assert rows[name][1] == rule['labels']['severity'], f'{name}: wrong severity in the index'
        assert rows[name][2] == f'[{name}.md]({name}.md)'
    assert set(rows) == {rule['alert'] for rule in alert_rules()}


# ---- SLOs -----------------------------------------------------------------------------------------------

def test_the_slo_document_matches_the_thresholds_in_the_rules():
    slo = read('docs', 'sre', 'slo.md')
    availability = re.search(r'\*\*([\d.]+)%\*\* of requests answer without a 5xx', slo)
    latency = re.search(r'\*\*([\d.]+)%\*\* of requests answer in under \*\*(\d+) ms\*\*', slo)
    assert availability and latency, 'docs/sre/slo.md must state both SLOs in its table'
    assert float(availability.group(1)) == 99.5
    assert int(latency.group(2)) == 500

    error_budget = f'{round(1 - float(availability.group(1)) / 100, 6):g}'        # 99.5 % -> 0.005
    latency_budget = f'{round(1 - float(latency.group(1)) / 100, 6):g}'           # 95 %   -> 0.05
    threshold = f'{int(latency.group(2)) / 1000:g}'                                # 500 ms -> 0.5
    assert (error_budget, latency_budget, threshold) == ('0.005', '0.05', '0.5')

    recording = read('monitoring', 'prometheus', 'rules', 'ems-slo.yml')
    assert recording.count(f'le="{threshold}"') == 4, 'every latency SLI window must use the 500 ms bucket'
    alerts = read('monitoring', 'prometheus', 'rules', 'ems-alerts.yml')
    for factor in ('14.4', '6'):
        assert f'({factor} * {error_budget})' in alerts
        assert f'({factor} * {latency_budget})' in alerts


def test_the_sre_documents_exist():
    for name in ('slo.md', 'error-budget-policy.md', 'alerting.md', 'incident-template.md', 'postmortem-template.md',
                 'game-days.md', 'oncall.md', os.path.join('postmortems', '2026-10-example-db-timeout.md')):
        assert os.path.isfile(os.path.join(ROOT, 'docs', 'sre', name)), name
    assert 'game-day exercise' in read('docs', 'sre', 'postmortems', '2026-10-example-db-timeout.md').lower()
    for name in ('metrics.md', 'logs.md', 'traces.md', 'alerting-flow.md', 'dashboards.md', 'cloudwatch.md'):
        assert os.path.isfile(os.path.join(ROOT, 'docs', 'observability', name)), name


# ---- chaos scripts and game days ------------------------------------------------------------------------

def test_there_is_one_chaos_script_per_scenario():
    assert {os.path.basename(p)[:-3] for p in chaos_scripts()} == EXPECTED_SCENARIOS


@pytest.fixture
def fake_tools(tmp_path):
    """docker/kubectl/aws/terraform shims first on PATH: a dry run that calls one of them leaves a trace"""
    calls = tmp_path / 'calls.log'
    for tool in ('docker', 'kubectl', 'aws', 'terraform'):
        shim = tmp_path / tool
        shim.write_text(f'#!/bin/sh\necho "{tool} $*" >> "{calls}"\nexit 99\n')
        shim.chmod(shim.stat().st_mode | stat.S_IEXEC)
    env = dict(os.environ, PATH=f'{tmp_path}{os.pathsep}{os.environ.get("PATH", "")}')
    return env, calls


@pytest.mark.parametrize('script', chaos_scripts(), ids=os.path.basename)
def test_every_chaos_script_is_strict_and_its_dry_run_only_prints(script, fake_tools):
    env, calls = fake_tools
    text = open(script).read()
    assert text.startswith('#!/usr/bin/env bash\n')
    assert 'set -euo pipefail' in text
    assert '--revert' in text and '--inject' in text

    for args in (['--dry-run'], ['--inject', '--dry-run'], ['--revert', '--dry-run']):
        result = subprocess.run(['bash', script, *args], capture_output=True, text=True, env=env, timeout=30)
        assert result.returncode == 0, f'{args}: {result.stderr}'
        assert result.stdout.strip(), f'{args}: a dry run must print the commands'
    assert not calls.exists(), f'a dry run executed: {calls.read_text() if calls.exists() else ""}'

    help_result = subprocess.run(['bash', script, '--help'], capture_output=True, text=True, timeout=30)
    assert help_result.returncode == 0 and 'Usage' in help_result.stdout
    bare = subprocess.run(['bash', script], capture_output=True, text=True, env=env, timeout=30)
    assert bare.returncode != 0, 'without arguments a chaos script must only print its usage'
    assert not calls.exists()


def test_every_game_day_scenario_references_an_existing_chaos_script():
    text = read('docs', 'sre', 'game-days.md')
    scenarios = {}
    for section in re.split(r'^## ', text, flags=re.MULTILINE)[1:]:
        heading, _, body = section.partition('\n')
        script = re.search(r'^\*\*Script:\*\* `(scripts/chaos/[\w-]+\.sh)`', body, re.MULTILINE)
        if script:
            scenarios[heading.strip()] = script.group(1)
    assert set(scenarios) == EXPECTED_SCENARIOS
    for name, script in scenarios.items():
        assert script == f'scripts/chaos/{name}.sh'
        assert os.path.isfile(os.path.join(ROOT, script)), script
        assert re.search(rf'^\| [\d-]* *\| {re.escape(name)} \|', text, re.MULTILINE), f'{name}: no row in the results table'


# ---- promtool -------------------------------------------------------------------------------------------

def docker_available():
    if not shutil.which('docker'):
        return False
    try:
        return subprocess.run(['docker', 'info'], capture_output=True, timeout=20).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def test_the_alert_rules_pass_promtool_unit_tests():
    if not docker_available():
        pytest.skip('docker is not available')
    result = subprocess.run(
        ['docker', 'run', '--rm', '-v', f'{PROMETHEUS_DIR}:/p:ro', '-w', '/p/tests', '--entrypoint', 'promtool',
         PROMETHEUS_IMAGE, 'test', 'rules', 'ems-alerts-test.yml'],
        capture_output=True, text=True, timeout=300)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'SUCCESS' in result.stdout + result.stderr
