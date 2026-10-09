from datetime import date

from app.services import (create_employee_db, update_employee_db, delete_employee_db,
                          mark_attendance_db, get_salary_statistics_numpy,
                          generate_department_report_pandas, get_top_earners)


def test_create_validation_and_duplicate(app):
    assert create_employee_db("A", 30, "IT", "a@x.com", 50000)[0] is None
    assert "Age" in create_employee_db("Alice", 17, "IT", "a@x.com", 50000)[1]
    assert "Salary" in create_employee_db("Alice", 30, "IT", "a@x.com", 100)[1]
    assert "email" in create_employee_db("Alice", 30, "IT", "bad", 50000)[1].lower()
    emp, _ = create_employee_db("Alice", 30, "IT", "a@x.com", 50000)
    assert emp.id == 1
    assert "already exists" in create_employee_db("Alice2", 30, "IT", "a@x.com", 50000)[1]


def test_update_and_delete(app, seeded):
    emp, _ = update_employee_db(1, salary=99000)
    assert emp.salary == 99000
    assert update_employee_db(999, salary=50000)[1] == "Employee not found"
    assert delete_employee_db(1) == (True, "Employee deleted successfully")
    assert delete_employee_db(1)[0] is False


def test_attendance_rules(app, seeded):
    assert mark_attendance_db(1, date(2026, 4, 21), "Present")[0] is not None
    assert "already marked" in mark_attendance_db(1, date(2026, 4, 21), "Present")[1]
    assert "Invalid status" in mark_attendance_db(1, date(2026, 4, 22), "Napping")[1]
    assert mark_attendance_db(99, date(2026, 4, 22), "Present")[1] == "Employee not found"


def test_analytics(app, seeded):
    stats = get_salary_statistics_numpy()
    assert stats['mean'] == 76250.0 and stats['median'] == 72500.0 and stats['count'] == 4
    report = generate_department_report_pandas()
    assert report['departments']['Engineering']['avg_salary'] == 85000.0
    assert [e['name'] for e in get_top_earners(2)] == ["Charlie Brown", "Alice Johnson"]


def test_analytics_empty_db(app):
    assert 'error' in get_salary_statistics_numpy()
    assert get_top_earners(3) == []
