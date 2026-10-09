from datetime import date

from app.models import db, Employee, Attendance


def test_employee_to_dict_and_str(app):
    e = Employee("Alice Johnson", 28, "Engineering", "alice@company.com", 75000)
    db.session.add(e)
    db.session.commit()
    d = e.to_dict()
    assert d['id'] == 1 and d['name'] == "Alice Johnson" and d['active'] is True
    assert str(e) == "Alice Johnson - Engineering"
    assert "Alice Johnson" in repr(e)


def test_static_validators():
    assert Employee.validate_age(30) and not Employee.validate_age(17) and not Employee.validate_age(66)
    assert Employee.validate_salary(30000) and not Employee.validate_salary(29999)


def test_attendance_relationship_and_cascade(app):
    e = Employee("Bob Smith", 35, "Marketing", "bob@company.com", 65000)
    db.session.add(e)
    db.session.commit()
    db.session.add(Attendance(e.id, date(2026, 4, 21), "Present"))
    db.session.commit()
    assert e.attendance_records.count() == 1
    db.session.delete(e)
    db.session.commit()
    assert Attendance.query.count() == 0       # cascade delete
    assert Attendance.get_status_options() == ['Present', 'Absent', 'Leave', 'Holiday']
