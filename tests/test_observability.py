"""Phases 13, 22 and 24 - proxy trust, liveness, request IDs, metrics, JSON logs and the alert webhook"""
import json
import logging

from app import create_app
from app.observability import JsonFormatter


def test_livez_never_touches_the_database(client, app):
    from app.models import db
    db.drop_all()                                   # /health would now fail; /livez must not care
    assert client.get('/livez').json == {'status': 'alive'}


def test_every_response_carries_a_request_id(client):
    generated = client.get('/health').headers['X-Request-ID']
    assert len(generated) == 32
    assert client.get('/health', headers={'X-Request-ID': 'abc-123'}).headers['X-Request-ID'] == 'abc-123'


def test_metrics_exposes_red_metrics_and_db_up(client, seeded):
    client.get('/api/employees')
    body = client.get('/metrics').get_data(as_text=True)
    assert 'ems_http_requests_total{endpoint="/api/employees",method="GET",status="200"}' in body
    assert 'ems_http_request_duration_seconds_bucket' in body
    assert 'ems_db_up 1.0' in body
    assert 'ems_employees_total 4.0' in body


def test_unknown_paths_share_one_metric_label(client):
    client.get('/no/such/path/1')
    client.get('/no/such/path/2')
    body = client.get('/metrics').get_data(as_text=True)
    assert 'endpoint="unmatched"' in body and '/no/such/path' not in body


def test_trusted_proxies_set_the_client_address(monkeypatch):
    from config import TestingConfig
    monkeypatch.setattr(TestingConfig, 'TRUSTED_PROXIES', 2)
    app = create_app('testing')

    @app.route('/whoami')
    def whoami():
        from flask import request
        return {'ip': request.remote_addr}

    client = app.test_client()
    # ALB appends the client, nginx appends the ALB: with 2 trusted hops the client is the real address
    r = client.get('/whoami', headers={'X-Forwarded-For': '6.6.6.6, 203.0.113.9, 10.0.1.5'})
    assert r.json['ip'] == '203.0.113.9'


def test_json_log_line_has_the_request_fields():
    record = logging.LogRecord('ems', logging.INFO, __file__, 1, 'GET / 200', None, None)
    record.request_id, record.status, record.duration_ms = 'abc', 200, 1.5
    line = json.loads(JsonFormatter().format(record))
    assert line['request_id'] == 'abc' and line['status'] == 200 and line['level'] == 'INFO'


def test_alertmanager_webhook_stores_history(client):
    payload = {'alerts': [
        {'status': 'firing', 'startsAt': '2026-10-09T10:00:00Z',
         'labels': {'alertname': 'EMSHighErrorRate', 'severity': 'page'},
         'annotations': {'summary': 'errors', 'runbook_url': 'docs/runbooks/EMSHighErrorRate.md'}},
        'not-an-alert',
    ]}
    r = client.post('/api/alerts', json=payload)
    assert r.status_code == 202 and r.json['received'] == 1
    history = client.get('/api/alerts?status=firing').json
    assert history['count'] == 1 and history['alerts'][0]['alertname'] == 'EMSHighErrorRate'
    assert client.post('/api/alerts', json={'alerts': 'x'}).status_code == 400
    assert client.get('/api/alerts?limit=0').status_code == 400
