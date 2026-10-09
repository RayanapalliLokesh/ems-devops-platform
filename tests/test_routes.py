import json


def post(client, url, payload):
    return client.post(url, data=json.dumps(payload), content_type='application/json')


def test_health_and_home(client):
    r = client.get('/health')
    assert r.status_code == 200 and r.json['database'] == 'healthy'
    assert client.get('/').json['message']


def test_unknown_route_returns_json_404(client):
    r = client.get('/nope')
    assert r.status_code == 404 and r.json == {'error': 'Resource not found'}


def test_crud_flow(client):
    payload = {"name": "Eve Martinez", "age": 29, "department": "IT",
               "email": "eve@company.com", "salary": 80000}
    r = post(client, '/api/employees', payload)
    assert r.status_code == 201
    emp_id = r.json['employee']['id']

    assert client.get(f'/api/employees/{emp_id}').json['employee']['name'] == "Eve Martinez"
    r = client.put(f'/api/employees/{emp_id}', json={"salary": 85000})
    assert r.status_code == 200 and r.json['employee']['salary'] == 85000
    assert client.delete(f'/api/employees/{emp_id}').status_code == 200
    assert client.get(f'/api/employees/{emp_id}').status_code == 404


def test_create_errors(client):
    assert post(client, '/api/employees', {"name": "X"}).status_code == 400
    assert client.post('/api/employees', data='not json', content_type='application/json').status_code == 400
    bad_age = {"name": "Eve", "age": 12, "department": "IT", "email": "e@x.com", "salary": 80000}
    assert post(client, '/api/employees', bad_age).status_code == 400


def test_search_and_departments(client, seeded):
    assert client.get('/api/employees/search?department=eng').json['count'] == 2
    assert client.get('/api/employees/search?min_salary=70000').json['count'] == 3
    assert client.get('/api/departments').json['departments'] == ['Engineering', 'HR', 'Marketing']
    assert client.get('/api/departments/stats').json['departments']['Engineering'] == 2


def test_attendance_endpoints(client, seeded):
    r = post(client, '/api/attendance', {"employee_id": 1, "date": "2026-04-21", "status": "Present"})
    assert r.status_code == 201
    assert post(client, '/api/attendance', {"employee_id": 1, "date": "2026-04-21", "status": "Present"}).status_code == 400
    assert post(client, '/api/attendance', {"employee_id": 1, "date": "21/04/2026", "status": "Present"}).status_code == 400
    assert post(client, '/api/attendance', {"employee_id": 99, "date": "2026-04-22", "status": "Present"}).status_code == 404
    assert client.get('/api/attendance/employee/1').json['count'] == 1
    assert client.get('/api/attendance/employee/1/statistics').json['statistics']['attendance_percentage'] == 100.0


def test_validation_endpoints(client):
    assert post(client, '/api/validation/email', {"email": "a@b.co"}).json['valid'] is True
    assert post(client, '/api/validation/phone', {"phone": "+91-9876543210", "country": "IN"}).json['valid'] is True
    assert post(client, '/api/validation/phone', {"phone": "1", "country": "XX"}).status_code == 400
    assert post(client, '/api/validation/password', {"password": "Strong@123"}).json['strength'] == 'Strong'
    # a body that is not a JSON object, or a value of the wrong type, is a bad request: never a 500
    for path in ('/api/validation/email', '/api/validation/phone', '/api/validation/password'):
        for body in ('text', 5, [1], {"email": 5, "phone": 5, "password": 5}):
            assert post(client, path, body).status_code == 200, (path, body)
    assert post(client, '/api/validation/password', {"password": 12345678}).json['strength'] == 'Weak'


def test_analytics_endpoints(client, seeded):
    assert client.get('/api/analytics/salary/statistics').json['mean'] == 76250.0
    assert client.get('/api/analytics/salary/distribution').json['distribution']['70k-90k'] == 2
    assert client.get('/api/analytics/employees/top-earners?limit=1').json['top_earners'][0]['name'] == "Charlie Brown"
    assert client.get('/api/analytics/employees/top-earners?limit=0').status_code == 400
    assert client.get('/api/analytics/demographics/age').json['mean_age'] == 34.0
    assert client.get('/api/analytics/attendance/summary').status_code == 404   # no records yet


def test_analytics_empty_database(client):
    assert client.get('/api/analytics/salary/statistics').status_code == 404
    assert client.get('/api/employees/export/csv').status_code == 404        # nothing to export is not a server error
