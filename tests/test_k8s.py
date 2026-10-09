"""Phases 22-23 - the Kubernetes manifests, overlays, broken samples and scripts keep their promises"""
import os
import re
import shutil
import subprocess

import pytest
import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
K8S = os.path.join(ROOT, 'k8s')
BASE = os.path.join(K8S, 'base')
PLAYGROUND = os.path.join(K8S, 'overlays', 'playground')
SAMPLES = os.path.join(ROOT, 'k8s_samples')
SCRIPTS = os.path.join(ROOT, 'scripts', 'k8s')

# playground limits
MAX_PODS_PER_NAMESPACE = 3
MAX_CPU_MILLI = 256
MAX_MEMORY_MI = 512


def load(path):
    with open(path) as f:
        return [doc for doc in yaml.safe_load_all(f) if doc]


def load_dir(folder):
    docs = []
    for name in sorted(os.listdir(folder)):
        if name.endswith(('.yaml', '.yml')) and name != 'kustomization.yaml':
            docs.extend(load(os.path.join(folder, name)))
    return docs


def find(docs, kind, name):
    matches = [d for d in docs if d['kind'] == kind and d['metadata']['name'] == name]
    assert matches, f'{kind}/{name} not found'
    return matches[0]


def cpu_milli(value):
    value = str(value)
    return int(value[:-1]) if value.endswith('m') else int(float(value) * 1000)


def memory_mi(value):
    value = str(value)
    units = {'Mi': 1, 'Gi': 1024, 'Ki': 1 / 1024}
    for unit, factor in units.items():
        if value.endswith(unit):
            return float(value[:-len(unit)]) * factor
    return int(value) / (1024 * 1024)


def merged_containers(base_spec, patch_spec):
    """Strategic-merge the containers of a patch into the base pod spec by container name"""
    containers = {c['name']: dict(c) for c in base_spec.get('containers', [])}
    for patch in (patch_spec or {}).get('containers', []):
        merged = containers.setdefault(patch['name'], {})
        for key, value in patch.items():
            merged[key] = value
    return list(containers.values()) + list(base_spec.get('initContainers', []))


@pytest.fixture(scope='module')
def base_docs():
    return load_dir(BASE)


@pytest.fixture(scope='module')
def app(base_docs):
    return find(base_docs, 'Deployment', 'ems-app')


def app_container(deployment):
    return next(c for c in deployment['spec']['template']['spec']['containers'] if c['name'] == 'app')


# ---- base ---------------------------------------------------------------------------------------------

def test_base_kustomization_lists_every_manifest_and_generates_config_and_secret():
    kustomization = load(os.path.join(BASE, 'kustomization.yaml'))[0]
    assert kustomization['namespace'] == 'ems'
    for resource in kustomization['resources']:
        assert os.path.exists(os.path.join(BASE, resource)), resource
    assert kustomization['configMapGenerator'][0]['envs'] == ['config.env']
    assert kustomization['secretGenerator'][0]['envs'] == ['secret.env']
    assert os.path.exists(os.path.join(BASE, 'config.env'))
    assert os.path.exists(os.path.join(BASE, 'secret.env.example'))


def test_secret_env_is_gitignored_and_config_env_holds_no_secrets():
    with open(os.path.join(K8S, '.gitignore')) as f:
        assert 'secret.env' in f.read()
    with open(os.path.join(BASE, 'config.env')) as f:
        config = f.read()
    assert 'SECRET_KEY' not in config and 'PASSWORD' not in config


def test_app_probes_livez_for_liveness_and_health_for_readiness(app):
    container = app_container(app)
    assert container['livenessProbe']['httpGet']['path'] == '/livez'
    assert container['startupProbe']['httpGet']['path'] == '/livez'
    assert container['readinessProbe']['httpGet']['path'] == '/health'


def test_app_runs_as_non_root_with_a_read_only_root_filesystem(app):
    pod = app['spec']['template']['spec']
    assert pod['securityContext']['runAsNonRoot'] is True
    assert pod['securityContext']['runAsUser'] == 10001
    container = app_container(app)
    assert container['securityContext']['readOnlyRootFilesystem'] is True
    assert container['securityContext']['allowPrivilegeEscalation'] is False
    mounts = {m['mountPath'] for m in container['volumeMounts']}
    assert {'/tmp', '/app/data'} <= mounts           # PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus, SQLite dir


def test_app_has_two_replicas_service_and_prometheus_annotations(base_docs, app):
    assert app['spec']['replicas'] == 2
    annotations = app['spec']['template']['metadata']['annotations']
    assert annotations['prometheus.io/scrape'] == 'true'
    assert annotations['prometheus.io/port'] == '5000'
    service = find(base_docs, 'Service', 'ems-app')
    assert service['spec']['ports'][0]['port'] == 80
    assert app_container(app)['ports'][0]['containerPort'] == 5000
    pod_labels = app['spec']['template']['metadata']['labels']
    assert service['spec']['selector'].items() <= pod_labels.items()     # the Service finds the pods


def test_database_url_is_built_from_the_secret(app):
    env = {e['name']: e for e in app_container(app)['env']}
    assert env['SECRET_KEY']['valueFrom']['secretKeyRef']['name'] == 'ems-secret'
    assert env['POSTGRES_PASSWORD']['valueFrom']['secretKeyRef']['name'] == 'ems-secret'
    assert env['DATABASE_URL']['value'].startswith('postgresql+psycopg://')
    assert '$(POSTGRES_PASSWORD)' in env['DATABASE_URL']['value']


def test_postgres_is_a_statefulset_with_headless_service_and_pvc(base_docs):
    statefulset = find(base_docs, 'StatefulSet', 'postgres')
    assert statefulset['spec']['template']['spec']['containers'][0]['image'] == 'postgres:16.4-alpine'
    assert statefulset['spec']['volumeClaimTemplates']
    service = find(base_docs, 'Service', 'postgres')
    assert service['spec']['clusterIP'] == 'None'


def test_networkpolicy_lets_only_app_pods_reach_postgres(base_docs):
    policies = [d for d in base_docs if d['kind'] == 'NetworkPolicy']
    policy = next(p for p in policies
                  if p['spec']['podSelector']['matchLabels'].get('app.kubernetes.io/name') == 'postgres')
    rule = policy['spec']['ingress'][0]
    assert rule['from'] == [{'podSelector': {'matchLabels': {'app.kubernetes.io/name': 'ems-app'}}}]
    assert rule['ports'][0]['port'] == 5432


def test_ingress_and_hpa(base_docs):
    ingress = find(base_docs, 'Ingress', 'ems')
    assert ingress['spec']['ingressClassName'] == 'nginx'
    hpa = find(base_docs, 'HorizontalPodAutoscaler', 'ems-app')
    assert (hpa['spec']['minReplicas'], hpa['spec']['maxReplicas']) == (2, 4)
    assert hpa['spec']['metrics'][0]['resource']['target']['averageUtilization'] == 70


# ---- overlays -----------------------------------------------------------------------------------------

def test_local_overlay_uses_the_local_image_and_nodeport_30080():
    kustomization = load(os.path.join(K8S, 'overlays', 'local', 'kustomization.yaml'))[0]
    assert kustomization['images'] == [{'name': 'ems-app', 'newName': 'ems-app', 'newTag': 'local'}]
    service = load(os.path.join(K8S, 'overlays', 'local', 'service-nodeport.yaml'))[0]
    assert service['spec']['type'] == 'NodePort'
    assert service['spec']['ports'][0]['nodePort'] == 30080


def test_kind_config_maps_host_8081_to_the_nodeport_and_leaves_8080_and_80_free():
    config = load(os.path.join(K8S, 'kind-config.yaml'))[0]
    assert config['name'] == 'ems'
    mappings = {m['containerPort']: m['hostPort'] for m in config['nodes'][0]['extraPortMappings']}
    assert mappings[30080] == 8081
    assert not {80, 443, 8080} & set(mappings.values())


def test_playground_overlay_pulls_from_ecr():
    kustomization = load(os.path.join(PLAYGROUND, 'kustomization.yaml'))[0]
    image = kustomization['images'][0]
    assert image['name'] == 'ems-app'
    assert re.fullmatch(r'ACCOUNT_ID\.dkr\.ecr\.us-east-1\.amazonaws\.com/ems-app', image['newName'])


def test_playground_fits_three_pods_per_namespace(base_docs):
    patches = load_dir(PLAYGROUND)
    deployment = find(patches, 'Deployment', 'ems-app')
    hpa = find(patches, 'HorizontalPodAutoscaler', 'ems-app')
    postgres = find(base_docs, 'StatefulSet', 'postgres')
    replicas = deployment['spec']['replicas']
    assert 1 <= replicas <= 2
    assert hpa['spec']['maxReplicas'] + postgres['spec']['replicas'] <= MAX_PODS_PER_NAMESPACE
    assert deployment['spec']['strategy']['rollingUpdate']['maxSurge'] == 0   # no 4th pod during a rollout


def test_playground_resources_are_within_the_per_pod_limits(base_docs):
    patches = load_dir(PLAYGROUND)
    for kind, name in (('Deployment', 'ems-app'), ('StatefulSet', 'postgres')):
        base_spec = find(base_docs, kind, name)['spec']['template']['spec']
        patch_spec = find(patches, kind, name)['spec']['template']['spec']
        for container in merged_containers(base_spec, patch_spec):
            limits = container['resources']['limits']
            assert cpu_milli(limits['cpu']) <= MAX_CPU_MILLI, (name, container['name'])
            assert memory_mi(limits['memory']) <= MAX_MEMORY_MI, (name, container['name'])


# ---- broken samples -----------------------------------------------------------------------------------

SAMPLE_NAMES = ['01-image-pull-backoff', '02-crashloop', '03-oom-killed', '04-failing-readiness',
                '05-pending-unschedulable', '06-service-selector-mismatch', '07-missing-configmap',
                '08-networkpolicy-blocks-db']


def test_there_are_eight_samples_each_documented_in_the_readme():
    files = sorted(name[:-5] for name in os.listdir(SAMPLES) if re.match(r'\d\d-.*\.yaml$', name))
    assert files == SAMPLE_NAMES
    with open(os.path.join(SAMPLES, 'README.md')) as f:
        readme = f.read()
    for name in files:
        assert f'`{name}`' in readme, f'{name} missing from k8s_samples/README.md'
    kustomization = load(os.path.join(SAMPLES, 'kustomization.yaml'))[0]
    assert sorted(r[:-5] for r in kustomization['resources'] if r[0].isdigit()) == files


def test_samples_use_their_own_namespace():
    for name in SAMPLE_NAMES:
        for doc in load(os.path.join(SAMPLES, name + '.yaml')):
            assert doc['metadata']['namespace'] == 'ems-samples', (name, doc['kind'])


# ---- scripts ------------------------------------------------------------------------------------------

SCRIPT_ARGS = {
    'k8s-up.sh': [],
    'k8s-rollout.sh': ['--tag', 'test-tag'],
    'k8s-triage.sh': [],
    'k8s-monitoring.sh': [],
    'k8s-playground.sh': ['--tag', 'test-tag', '--account', '123456789012'],
}


@pytest.mark.parametrize('script', sorted(SCRIPT_ARGS))
def test_scripts_are_strict_and_support_help_and_dry_run(script):
    path = os.path.join(SCRIPTS, script)
    with open(path) as f:
        assert 'set -euo pipefail' in f.read()
    assert os.access(path, os.X_OK)
    help_run = subprocess.run([path, '--help'], capture_output=True, text=True, timeout=30)
    assert help_run.returncode == 0 and '--dry-run' in help_run.stdout
    dry = subprocess.run([path, '--dry-run', *SCRIPT_ARGS[script]], capture_output=True, text=True, timeout=30)
    assert dry.returncode == 0, dry.stderr
    assert '+ kubectl' in dry.stdout


def test_rollout_script_undoes_a_failed_rollout():
    dry = subprocess.run([os.path.join(SCRIPTS, 'k8s-rollout.sh'), '--dry-run', '--tag', 'bad'],
                         capture_output=True, text=True, timeout=30)
    assert 'rollout status' in dry.stdout and 'rollout undo' in dry.stdout


@pytest.mark.skipif(not shutil.which('shellcheck'), reason='shellcheck not installed')
def test_scripts_pass_shellcheck():
    scripts = [os.path.join(SCRIPTS, name) for name in sorted(SCRIPT_ARGS)]
    result = subprocess.run(['shellcheck', *scripts], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout


# ---- render with kustomize (optional) -----------------------------------------------------------------

@pytest.mark.skipif(not shutil.which('kubectl'), reason='kubectl not installed')
@pytest.mark.parametrize('overlay', ['local', 'playground'])
def test_overlays_render(tmp_path, overlay):
    """Render a copy of k8s/ with secret.env taken from the example, so the real secret is never needed"""
    copy = tmp_path / 'k8s'
    shutil.copytree(K8S, copy, ignore=shutil.ignore_patterns('secret.env'))
    shutil.copy(copy / 'base' / 'secret.env.example', copy / 'base' / 'secret.env')
    result = subprocess.run(['kubectl', 'kustomize', str(copy / 'overlays' / overlay)],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    docs = [d for d in yaml.safe_load_all(result.stdout) if d]
    kinds = {d['kind'] for d in docs}
    assert {'Namespace', 'Deployment', 'StatefulSet', 'Service', 'ConfigMap', 'Secret', 'NetworkPolicy',
            'Ingress', 'HorizontalPodAutoscaler'} <= kinds
    assert all(d['metadata'].get('namespace') == 'ems' for d in docs if d['kind'] != 'Namespace')
    deployment = find(docs, 'Deployment', 'ems-app')
    env_from = app_container(deployment)['envFrom'][0]['configMapRef']['name']
    assert env_from.startswith('ems-config-')             # the generated name with its content hash
    image = app_container(deployment)['image']
    if overlay == 'local':
        assert image == 'ems-app:local'
    else:
        assert image == 'ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/ems-app:IMAGE_TAG'
        resources = app_container(deployment)['resources']['limits']
        assert cpu_milli(resources['cpu']) <= MAX_CPU_MILLI
        assert memory_mi(resources['memory']) <= MAX_MEMORY_MI


@pytest.mark.skipif(not shutil.which('kubectl'), reason='kubectl not installed')
def test_monitoring_renders_and_keeps_the_ems_app_job_name():
    result = subprocess.run(['kubectl', 'kustomize', os.path.join(K8S, 'monitoring')],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    with open(os.path.join(K8S, 'monitoring', 'prometheus.yml')) as f:
        config = yaml.safe_load(f)
    relabels = config['scrape_configs'][0]['relabel_configs']
    assert any(r.get('target_label') == 'job' for r in relabels)


def test_metrics_is_blocked_on_the_ingress():
    docs = [d for d in yaml.safe_load_all(open(os.path.join(ROOT, 'k8s', 'base', 'ingress.yaml'))) if d]
    block = next(d for d in docs if d['metadata']['name'] == 'ems-metrics-block')
    assert block['metadata']['annotations']['nginx.ingress.kubernetes.io/denylist-source-range'].startswith('0.0.0.0/0')
    path = block['spec']['rules'][0]['http']['paths'][0]
    assert path['path'] == '/metrics' and path['pathType'] == 'Exact'
