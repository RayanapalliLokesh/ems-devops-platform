"""
Observability (Phase 24): request IDs, one JSON log line per request, Prometheus metrics, optional tracing

  logs     every response carries X-Request-ID (taken from nginx, or generated); the request log line holds
           request_id, trace_id, method, path, status and duration
  metrics  GET /metrics in the Prometheus text format. Under gunicorn (several worker processes) the values
           of all workers are merged through PROMETHEUS_MULTIPROC_DIR
  traces   OpenTelemetry spans per request and per SQL query, sent over OTLP/HTTP when
           OTEL_EXPORTER_OTLP_ENDPOINT is set (Jaeger in docker-compose.monitoring.yml)
"""
import json
import logging
import os
import time
import uuid

from flask import Response, g, request
from prometheus_client import (
    CONTENT_TYPE_LATEST, REGISTRY, CollectorRegistry, Counter, Gauge, Histogram, generate_latest,
)

REQUESTS = Counter('ems_http_requests_total', 'HTTP requests handled', ['method', 'endpoint', 'status'])
LATENCY = Histogram('ems_http_request_duration_seconds', 'HTTP request duration in seconds',
                    ['method', 'endpoint'],
                    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10))
DB_UP = Gauge('ems_db_up', '1 when the last database check succeeded', multiprocess_mode='mostrecent')
EMPLOYEES = Gauge('ems_employees_total', 'Employees in the database', multiprocess_mode='mostrecent')

# Endpoints that would drown the request log; they are still counted in the metrics
QUIET_PATHS = {'/metrics', '/livez'}
REQUEST_ID_HEADER = 'X-Request-ID'


class JsonFormatter(logging.Formatter):
    """One JSON object per line: what a log pipeline (CloudWatch, Loki, kubectl logs | jq) can parse"""
    FIELDS = ('request_id', 'trace_id', 'method', 'path', 'status', 'duration_ms', 'remote_addr')

    def format(self, record):
        entry = {
            'ts': self.formatTime(record, '%Y-%m-%dT%H:%M:%S'),
            'level': record.levelname,
            'logger': record.module,
            'message': record.getMessage(),
        }
        for field in self.FIELDS:
            if hasattr(record, field):
                entry[field] = getattr(record, field)
        if record.exc_info:
            entry['exception'] = self.formatException(record.exc_info)
        return json.dumps(entry)


def current_trace_id():
    """Hex trace id of the active span, or None when tracing is off"""
    try:
        from opentelemetry import trace
    except ImportError:                                   # pragma: no cover - tracing is an optional extra
        return None
    context = trace.get_current_span().get_span_context()
    return format(context.trace_id, '032x') if context.is_valid else None


def check_database(db):
    """Run SELECT 1, update ems_db_up, and return (healthy, detail)"""
    try:
        db.session.execute(db.text('SELECT 1'))
        DB_UP.set(1)
        return True, 'healthy'
    except Exception as e:                                 # any driver error means "not reachable"
        db.session.rollback()
        DB_UP.set(0)
        return False, f'unhealthy: {e}'


def _metrics_registry():
    if os.getenv('PROMETHEUS_MULTIPROC_DIR'):
        from prometheus_client import multiprocess
        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
        return registry
    return REGISTRY


def init_tracing(app, db):
    """Send spans to an OTLP collector (Jaeger). No endpoint configured = no tracing, no overhead"""
    endpoint = app.config.get('OTEL_EXPORTER_OTLP_ENDPOINT')
    if not endpoint:
        return False
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.flask import FlaskInstrumentor
    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    provider = TracerProvider(resource=Resource.create({
        'service.name': app.config['OTEL_SERVICE_NAME'],
        'service.version': app.config['APP_VERSION'],
    }))
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint.rstrip('/') + '/v1/traces')))
    trace.set_tracer_provider(provider)
    FlaskInstrumentor().instrument_app(app, excluded_urls='metrics,livez')
    with app.app_context():
        SQLAlchemyInstrumentor().instrument(engine=db.engine)
    app.logger.info('Tracing enabled: %s', endpoint)
    return True


def init_observability(app, db):
    """Request ID + request log + metrics hooks, and the /metrics and /livez endpoints"""

    @app.before_request
    def start_request():
        incoming = request.headers.get(REQUEST_ID_HEADER, '')
        # accept the proxy's id if it looks sane, otherwise make one: the id ends up in logs and headers
        g.request_id = incoming if 0 < len(incoming) <= 128 and incoming.isprintable() else uuid.uuid4().hex
        g.start_time = time.perf_counter()

    @app.after_request
    def finish_request(response):
        duration = time.perf_counter() - g.get('start_time', time.perf_counter())
        endpoint = request.url_rule.rule if request.url_rule else 'unmatched'   # bounded label values
        REQUESTS.labels(request.method, endpoint, str(response.status_code)).inc()
        LATENCY.labels(request.method, endpoint).observe(duration)
        response.headers[REQUEST_ID_HEADER] = g.get('request_id', '')

        if request.path not in QUIET_PATHS:
            level = logging.ERROR if response.status_code >= 500 else logging.INFO
            app.logger.log(level, '%s %s %s', request.method, request.path, response.status_code, extra={
                'request_id': g.get('request_id'),
                'trace_id': current_trace_id(),
                'method': request.method,
                'path': request.path,
                'status': response.status_code,
                'duration_ms': round(duration * 1000, 2),
                'remote_addr': request.remote_addr,
            })
        return response

    @app.route('/livez')
    def livez():
        """Liveness: the process answers. Never touches the database (see docs/kubernetes)"""
        return {'status': 'alive'}, 200

    @app.route('/metrics')
    def metrics():
        healthy, _ = check_database(db)
        if healthy:
            from app.models import Employee
            EMPLOYEES.set(Employee.query.count())
        return Response(generate_latest(_metrics_registry()), mimetype=CONTENT_TYPE_LATEST)
