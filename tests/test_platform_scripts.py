"""Phase 12, 13 and 17 support material: the operations scripts and the port map.

The scripts are run only with --help and --dry-run, so these tests never touch Docker, the network or AWS.
"""
import os
import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = sorted(
    list((ROOT / 'scripts' / 'linux').glob('*.sh'))
    + list((ROOT / 'scripts' / 'net').glob('*.sh'))
    + [ROOT / 'scripts' / 'image-report.sh']
)
EXPECTED = {'triage.sh', 'backup-db.sh', 'break-fix.sh', 'netcheck.sh', 'image-report.sh'}
PORT_MAP = ROOT / 'docs' / 'networking' / 'port-map.md'
COMPOSE_FILES = [ROOT / 'docker-compose.yml', ROOT / 'docker-compose.monitoring.yml']
VAR_DEFAULT = re.compile(r'\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}')


def run(script, *args):
    return subprocess.run(['bash', str(script), *args], capture_output=True, text=True, timeout=30,
                          cwd=ROOT, env={**os.environ, 'NO_COLOR': '1'})


def test_all_expected_scripts_exist():
    assert EXPECTED <= {s.name for s in SCRIPTS}


@pytest.mark.parametrize('script', SCRIPTS, ids=lambda p: p.name)
def test_script_is_strict_and_executable(script):
    text = script.read_text()
    assert text.startswith('#!/usr/bin/env bash')
    assert re.search(r'^set -euo pipefail$', text, re.M), f'{script.name} needs set -euo pipefail'
    assert os.access(script, os.X_OK), f'{script.name} is not executable'


@pytest.mark.parametrize('script', SCRIPTS, ids=lambda p: p.name)
def test_help(script):
    result = run(script, '--help')
    assert result.returncode == 0, result.stderr
    assert 'Usage' in result.stdout
    assert '--dry-run' in result.stdout


@pytest.mark.parametrize('script', SCRIPTS, ids=lambda p: p.name)
def test_dry_run(script):
    result = run(script, '--dry-run')
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip(), f'{script.name} --dry-run printed nothing'


def test_netcheck_dry_run_covers_all_five_layers():
    out = run(ROOT / 'scripts' / 'net' / 'netcheck.sh', '--dry-run', '--host', 'example.test',
              '--port', '8080').stdout
    layers = [line.split()[1] for line in out.splitlines() if line.startswith('DRY')]
    assert set(layers) >= {'name', 'tcp', 'http', 'application', 'exposure'}
    for port in ('5000', '5432'):
        assert f'/dev/tcp/example.test/{port}' in out


def test_netcheck_probes_have_short_timeouts():
    text = (ROOT / 'scripts' / 'net' / 'netcheck.sh').read_text()
    timeout = int(re.search(r'^TIMEOUT=(\d+)$', text, re.M).group(1))
    assert timeout <= 3
    assert '--max-time "$TIMEOUT"' in text


def test_backup_dry_run_uses_container_and_s3_without_keys():
    out = run(ROOT / 'scripts' / 'linux' / 'backup-db.sh', '--dry-run', '--s3-bucket', 'demo').stdout
    assert 'docker compose -p ems exec -T db' in out
    assert 'pg_dump' in out and 'gzip' in out
    assert 'aws s3 cp' in out and 's3://demo/backups/' in out
    assert 'AWS_SECRET_ACCESS_KEY' not in (ROOT / 'scripts' / 'linux' / 'backup-db.sh').read_text()


def test_break_fix_lists_five_scenarios():
    out = run(ROOT / 'scripts' / 'linux' / 'break-fix.sh', 'list').stdout
    assert [line.split()[0] for line in out.splitlines() if line.strip()] == ['1', '2', '3', '4', '5']


# ---- port map -------------------------------------------------------------------------------------------
def _resolve(value):
    """'${EMS_HTTP_PORT:-80}' -> '80'"""
    return VAR_DEFAULT.sub(lambda m: m.group(1), str(value))


def _split_mapping(entry):
    """'127.0.0.1:9090:9090' / '${EMS_HTTP_PORT:-80}:80' / '5000' -> (host port or None, container port)"""
    if isinstance(entry, dict):         # long syntax
        return entry.get('published') and _resolve(entry['published']), str(entry['target'])
    parts = _resolve(entry).split('/')[0].split(':')
    if len(parts) == 1:
        return None, parts[0]
    return parts[-2], parts[-1]


def compose_ports():
    host, container = set(), set()
    for path in COMPOSE_FILES:
        services = yaml.safe_load(path.read_text()).get('services', {})
        for service in services.values():
            for entry in service.get('ports', []) or []:
                h, c = _split_mapping(entry)
                if h:
                    host.add(int(h))
                container.add(int(c))
    return host, container


def port_map_ports():
    rows = [line for line in PORT_MAP.read_text().splitlines() if re.match(r'^\|\s*\d+\s*\|', line)]
    return {int(row.split('|')[1]) for row in rows}


def test_port_map_has_the_required_columns():
    assert '| Port | Listener | Bound to | Reachable from |' in PORT_MAP.read_text()


def test_compose_port_parsing():
    assert _split_mapping('${EMS_HTTP_PORT:-80}:80') == ('80', '80')
    assert _split_mapping('127.0.0.1:9090:9090') == ('9090', '9090')
    host, _ = compose_ports()
    assert {80, 9090, 9093, 3000, 16686} <= host


def test_port_map_lists_every_published_host_port():
    host, container = compose_ports()
    missing = (host | container) - port_map_ports()
    assert not missing, f'port-map.md is missing {sorted(missing)}'


def test_port_map_lists_internal_listeners_ssh_and_alb():
    listed = port_map_ports()
    nginx_listen = {int(p) for p in re.findall(r'^\s*listen\s+(\d+)', (ROOT / 'nginx' / 'default.conf').read_text(),
                                               re.M)}
    gunicorn = {int(re.search(r'GUNICORN_BIND=[\d.]+:(\d+)', (ROOT / 'Dockerfile').read_text()).group(1))}
    assert nginx_listen and gunicorn == {5000}
    assert nginx_listen | gunicorn | {5432, 22, 80} <= listed
    text = PORT_MAP.read_text()
    assert 'ALB' in text and 'sshd' in text
