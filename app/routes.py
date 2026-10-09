"""
API Routes (Controllers)
Thin HTTP layer: parse request -> call service -> format JSON response
"""
from datetime import datetime

from flask import Blueprint, current_app, jsonify, request

from app.services import (
    create_employee_db, get_all_employees_db, get_employee_by_id_db,
    update_employee_db, delete_employee_db, search_employees_db,
    get_unique_departments_db, get_employee_count_by_department_db,
    mark_attendance_db, get_attendance_by_employee_db, get_attendance_statistics_db,
    export_employees_csv, export_employees_json,
)
from app.utils import (
    validate_email, validate_indian_phone, validate_uk_phone,
    validate_password_strength, extract_domain_from_email,
)

api = Blueprint('api', __name__)


def _json_object():
    """The JSON body as a dict. No body, broken JSON, a list, a string or a number all count as an empty object,
    so the validation of each route answers 400: a malformed request must never end in a 500."""
    data = request.get_json(silent=True)
    return data if isinstance(data, dict) else {}


def _parse_date(value):
    """'2026-04-21' -> date, or None if missing. Raises ValueError if malformed"""
    return datetime.strptime(value, '%Y-%m-%d').date() if value else None


# ===========================================================================
# EMPLOYEES
# ===========================================================================
@api.route('/employees', methods=['GET'])
def list_employees():
    """GET /api/employees?active_only=true"""
    active_only = request.args.get('active_only', 'false').lower() == 'true'
    employees = get_all_employees_db(active_only)
    return jsonify({'employees': employees, 'count': len(employees)}), 200


@api.route('/employees/<int:emp_id>', methods=['GET'])
def get_employee(emp_id):
    employee = get_employee_by_id_db(emp_id)
    if employee:
        return jsonify({'employee': employee.to_dict()}), 200
    return jsonify({'error': 'Employee not found'}), 404


@api.route('/employees', methods=['POST'])
def add_employee():
    """Body: name, age, department, email, salary (active optional)"""
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({'error': 'Request body must be valid JSON'}), 400

    required = ['name', 'age', 'department', 'email', 'salary']
    missing = [f for f in required if f not in data]
    if missing:
        return jsonify({'error': f"Missing required field(s): {', '.join(missing)}"}), 400

    current_app.logger.debug('Creating employee: %s', data.get('email'))
    employee, message = create_employee_db(
        data['name'], data['age'], data['department'], data['email'],
        data['salary'], data.get('active', True))

    if employee:
        current_app.logger.info('Employee created: ID %s', employee.id)
        return jsonify({'employee': employee.to_dict(), 'message': message}), 201
    current_app.logger.warning('Employee creation failed: %s', message)
    return jsonify({'error': message}), 400


@api.route('/employees/<int:emp_id>', methods=['PUT'])
def modify_employee(emp_id):
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({'error': 'Request body must be valid JSON'}), 400

    employee, message = update_employee_db(emp_id, **data)
    if employee:
        return jsonify({'employee': employee.to_dict(), 'message': message}), 200
    return jsonify({'error': message}), 404 if message == 'Employee not found' else 400


@api.route('/employees/<int:emp_id>', methods=['DELETE'])
def remove_employee(emp_id):
    success, message = delete_employee_db(emp_id)
    if success:
        current_app.logger.info('Employee deleted: ID %s', emp_id)
        return jsonify({'message': message, 'deleted_id': emp_id}), 200
    return jsonify({'error': message}), 404


@api.route('/employees/search', methods=['GET'])
def search_employees():
    """GET /api/employees/search?department=Eng&min_age=30&min_salary=70000&active=true"""
    department = request.args.get('department')
    min_age = request.args.get('min_age', type=int)
    max_age = request.args.get('max_age', type=int)
    min_salary = request.args.get('min_salary', type=float)
    active = request.args.get('active')
    active = None if active is None else active.lower() == 'true'

    results = search_employees_db(department, min_age, max_age, min_salary, active)
    return jsonify({'results': results, 'count': len(results)}), 200


# ===========================================================================
# DEPARTMENTS
# ===========================================================================
@api.route('/departments', methods=['GET'])
def list_departments():
    departments = get_unique_departments_db()
    return jsonify({'departments': departments, 'count': len(departments)}), 200


@api.route('/departments/stats', methods=['GET'])
def department_stats():
    stats = get_employee_count_by_department_db()
    return jsonify({'departments': stats, 'total_departments': len(stats)}), 200


# ===========================================================================
# ATTENDANCE
# ===========================================================================
@api.route('/attendance', methods=['POST'])
def mark_attendance():
    """Body: {"employee_id": 1, "date": "2026-04-21", "status": "Present", "notes": "..."}"""
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({'error': 'Request body must be valid JSON'}), 400

    for field in ('employee_id', 'date', 'status'):
        if field not in data:
            return jsonify({'error': f'{field} is required'}), 400

    try:
        attendance_date = _parse_date(data['date'])
    except (ValueError, TypeError):
        return jsonify({'error': 'Invalid date format. Use YYYY-MM-DD'}), 400

    record, message = mark_attendance_db(
        data['employee_id'], attendance_date, data['status'], data.get('notes'))

    if record:
        return jsonify({'attendance': record.to_dict(), 'message': message}), 201
    return jsonify({'error': message}), 404 if message == 'Employee not found' else 400


@api.route('/attendance/employee/<int:emp_id>', methods=['GET'])
def get_employee_attendance(emp_id):
    """GET ...?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD"""
    try:
        start_date = _parse_date(request.args.get('start_date'))
        end_date = _parse_date(request.args.get('end_date'))
    except ValueError:
        return jsonify({'error': 'Invalid date format. Use YYYY-MM-DD'}), 400

    if not get_employee_by_id_db(emp_id):
        return jsonify({'error': 'Employee not found'}), 404

    records = get_attendance_by_employee_db(emp_id, start_date, end_date)
    return jsonify({'employee_id': emp_id, 'records': records, 'count': len(records)}), 200


@api.route('/attendance/employee/<int:emp_id>/statistics', methods=['GET'])
def get_employee_attendance_stats(emp_id):
    stats = get_attendance_statistics_db(emp_id)
    if stats:
        return jsonify({'employee_id': emp_id, 'statistics': stats}), 200
    return jsonify({'error': 'No attendance records found'}), 404


# ===========================================================================
# VALIDATION UTILITIES (regex - Phase 6)
# ===========================================================================
@api.route('/validation/email', methods=['POST'])
def validate_email_endpoint():
    email = _json_object().get('email', '')
    valid = validate_email(email)
    return jsonify({'email': email, 'valid': valid,
                    'domain': extract_domain_from_email(email) if valid else None}), 200


@api.route('/validation/phone', methods=['POST'])
def validate_phone_endpoint():
    data = _json_object()
    phone, country = data.get('phone', ''), str(data.get('country', 'IN')).upper()
    if country == 'IN':
        valid = validate_indian_phone(phone)
    elif country == 'UK':
        valid = validate_uk_phone(phone)
    else:
        return jsonify({'error': 'Unsupported country code'}), 400
    return jsonify({'phone': phone, 'country': country, 'valid': valid}), 200


@api.route('/validation/password', methods=['POST'])
def validate_password_endpoint():
    valid, errors = validate_password_strength(_json_object().get('password', ''))
    return jsonify({'valid': valid, 'errors': errors,
                    'strength': 'Strong' if valid else 'Weak'}), 200


# ===========================================================================
# FILE EXPORT (Phase 7)
# ===========================================================================
@api.route('/employees/export/csv', methods=['GET'])
def export_csv():
    success, message = export_employees_csv()
    if success:
        return jsonify({'success': True, 'message': message}), 200
    # nothing to export is the caller's situation (404); only a failed write is a server error (500)
    return jsonify({'success': False, 'error': message}), 404 if message == 'No employees to export' else 500


@api.route('/employees/export/json', methods=['GET'])
def export_json():
    success, message = export_employees_json()
    return (jsonify({'success': True, 'message': message}), 200) if success \
        else (jsonify({'success': False, 'error': message}), 500)


# ===========================================================================
# PHASE 9 - ANALYTICS (NumPy + Pandas)
# ===========================================================================
from app.services import (   # noqa: E402
    get_salary_statistics_numpy, get_salary_distribution,
    generate_department_report_pandas, get_top_earners, get_salary_comparison,
    generate_age_demographics, get_attendance_summary_pandas,
    get_department_attendance_stats,
)


def _analytics_response(result, key=None):
    """Service functions return {"error": ...} on failure -> map to 404/500"""
    if isinstance(result, dict) and 'error' in result:
        status = 404 if 'No ' in result['error'] else 500
        return jsonify(result), status
    return jsonify({key: result} if key else result), 200


@api.route('/analytics/salary/statistics', methods=['GET'])
def salary_statistics():
    """Mean / median / std / percentiles (NumPy)"""
    return _analytics_response(get_salary_statistics_numpy())


@api.route('/analytics/salary/distribution', methods=['GET'])
def salary_distribution():
    """Employees per salary band (NumPy masks)"""
    return _analytics_response(get_salary_distribution(), 'distribution')


@api.route('/analytics/departments/report', methods=['GET'])
def department_report():
    """Department report (Pandas groupby)"""
    return _analytics_response(generate_department_report_pandas())


@api.route('/analytics/employees/top-earners', methods=['GET'])
def top_earners():
    """GET ...?limit=3"""
    limit = request.args.get('limit', default=10, type=int)
    if limit < 1 or limit > 100:
        return jsonify({'error': 'limit must be between 1 and 100'}), 400
    result = get_top_earners(limit)
    if isinstance(result, dict):
        return _analytics_response(result)
    return jsonify({'top_earners': result, 'count': len(result)}), 200


@api.route('/analytics/salary/comparison', methods=['GET'])
def salary_comparison():
    return _analytics_response(get_salary_comparison())


@api.route('/analytics/demographics/age', methods=['GET'])
def age_demographics():
    return _analytics_response(generate_age_demographics())


@api.route('/analytics/attendance/summary', methods=['GET'])
def attendance_summary():
    """GET ...?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD"""
    try:
        start_date = _parse_date(request.args.get('start_date'))
        end_date = _parse_date(request.args.get('end_date'))
    except ValueError:
        return jsonify({'error': 'Invalid date format. Use YYYY-MM-DD'}), 400
    return _analytics_response(get_attendance_summary_pandas(start_date, end_date))


@api.route('/analytics/attendance/departments', methods=['GET'])
def department_attendance():
    return _analytics_response(get_department_attendance_stats(), 'departments')
