"""
Database Models
SQLAlchemy ORM classes representing database tables

OOP concepts shown here:
  - Classes & objects     (Employee, Attendance)
  - Inheritance           (class Employee(db.Model))
  - Encapsulation         (data + methods together)
  - Magic methods         (__init__, __repr__, __str__)
  - Static / class methods
"""
from datetime import datetime, date

from flask_sqlalchemy import SQLAlchemy

# Create SQLAlchemy instance
db = SQLAlchemy()


class Employee(db.Model):
    """Employee model - represents the `employees` table"""
    __tablename__ = 'employees'

    # Columns (class attributes)
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    name = db.Column(db.String(100), nullable=False, index=True)
    age = db.Column(db.Integer, nullable=False)
    department = db.Column(db.String(50), nullable=False, index=True)
    email = db.Column(db.String(120), unique=True, nullable=False, index=True)
    salary = db.Column(db.Float, nullable=False)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    # One-to-many relationship: one employee has many attendance records
    attendance_records = db.relationship(
        'Attendance', backref='employee', lazy='dynamic', cascade='all, delete-orphan')

    def __init__(self, name, age, department, email, salary, active=True):
        """Constructor - called when creating a new Employee object"""
        self.name = name
        self.age = age
        self.department = department
        self.email = email
        self.salary = salary
        self.active = active

    def to_dict(self):
        """Convert object to a JSON-friendly dictionary"""
        return {
            'id': self.id,
            'name': self.name,
            'age': self.age,
            'department': self.department,
            'email': self.email,
            'salary': self.salary,
            'active': self.active,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        }

    UPDATABLE_FIELDS = ('name', 'age', 'department', 'email', 'salary', 'active')

    def update_from_dict(self, data):
        """Update attributes from a dictionary (whitelisted fields only)"""
        for key, value in data.items():
            if key in self.UPDATABLE_FIELDS:
                setattr(self, key, value)
        self.updated_at = datetime.utcnow()

    def __repr__(self):
        """Developer-friendly representation (debugging)"""
        return f"<Employee {self.id}: {self.name} ({self.department})>"

    def __str__(self):
        """User-friendly representation"""
        return f"{self.name} - {self.department}"

    @staticmethod
    def validate_age(age):
        return isinstance(age, int) and not isinstance(age, bool) and 18 <= age <= 65

    @staticmethod
    def validate_salary(salary):
        return isinstance(salary, (int, float)) and not isinstance(salary, bool) and salary >= 30000


class Attendance(db.Model):
    """Attendance model - one record per employee per date"""
    __tablename__ = 'attendance'

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    employee_id = db.Column(db.Integer, db.ForeignKey('employees.id'), nullable=False)
    date = db.Column(db.Date, nullable=False)
    status = db.Column(db.String(20), nullable=False)   # Present, Absent, Leave, Holiday
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    # Composite unique constraint
    __table_args__ = (
        db.UniqueConstraint('employee_id', 'date', name='unique_employee_date'),
    )

    VALID_STATUSES = ['Present', 'Absent', 'Leave', 'Holiday']

    def __init__(self, employee_id, date, status, notes=None):
        self.employee_id = employee_id
        self.date = date
        self.status = status
        self.notes = notes

    def to_dict(self):
        return {
            'id': self.id,
            'employee_id': self.employee_id,
            'employee_name': self.employee.name if self.employee else None,
            'date': self.date.isoformat(),
            'status': self.status,
            'notes': self.notes,
            'created_at': self.created_at.isoformat() if self.created_at else None,
        }

    def __repr__(self):
        return f"<Attendance {self.employee_id} on {self.date}: {self.status}>"

    @classmethod
    def get_status_options(cls):
        """Class method: valid status values"""
        return cls.VALID_STATUSES
