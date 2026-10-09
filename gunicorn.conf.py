"""
gunicorn settings (Phase 12). Every value can be overridden with an environment variable, so the same file
serves the systemd unit (127.0.0.1), the container (0.0.0.0) and Kubernetes.
"""
import os

bind = os.getenv('GUNICORN_BIND', '127.0.0.1:5000')
workers = int(os.getenv('GUNICORN_WORKERS', '2'))
threads = int(os.getenv('GUNICORN_THREADS', '2'))
timeout = int(os.getenv('GUNICORN_TIMEOUT', '30'))
graceful_timeout = 20
keepalive = 5
max_requests = 1000                 # recycle workers now and then: protects against slow memory leaks
max_requests_jitter = 100
accesslog = None                    # the app writes one structured line per request instead
errorlog = '-'
loglevel = os.getenv('LOG_LEVEL', 'info').lower()
worker_tmp_dir = os.getenv('GUNICORN_WORKER_TMP_DIR', None)   # /dev/shm in containers
forwarded_allow_ips = os.getenv('FORWARDED_ALLOW_IPS', '127.0.0.1')


def on_starting(server):
    """Prometheus multi-process mode needs an empty directory at every start"""
    folder = os.getenv('PROMETHEUS_MULTIPROC_DIR')
    if folder:
        os.makedirs(folder, exist_ok=True)
        for name in os.listdir(folder):
            os.remove(os.path.join(folder, name))


def child_exit(server, worker):
    """Drop the live gauges of a worker that has exited"""
    if os.getenv('PROMETHEUS_MULTIPROC_DIR'):
        from prometheus_client import multiprocess
        multiprocess.mark_process_dead(worker.pid)
