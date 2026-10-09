"""
Business Logic Layer
CRUD operations using the SQLAlchemy ORM (Employee / Attendance models)
Every function returns (result, message) so routes stay thin.
"""
import csv
import json
import os
from datetime import date

import numpy as np
import pandas as pd
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from app.models import db, Employee, Attendance
from app.utils import validate_email


# ===========================================================================
# EMPLOYEE CRUD
# ===========================================================================
def create_employee_db(name, age, department, email, salary, active=True):
    """Create an employee. Returns: (Employee | None, message)"""
    if not isinstance(name, str) or len(name.strip()) < 2:
        return None, "Name must be at least 2 characters"
    if not Employee.validate_age(age):
        return None, "Age must be between 18 and 65"
    if not Employee.validate_salary(salary):
        return None, "Salary must be at least 30,000"
    if not validate_email(email):
        return None, "Invalid email format"
    if not department or not isinstance(department, str):
        return None, "Department is required"

    try:
        employee = Employee(name.strip(), age, department.strip(), email.lower(), salary, active)
        db.session.add(employee)
        db.session.commit()
        return employee, "Employee created successfully"
    except IntegrityError:
        db.session.rollback()
        return None, f"Email {email} already exists"
    except SQLAlchemyError as e:
        db.session.rollback()
        return None, f"Database error: {str(e)}"


def get_all_employees_db(active_only=False):
    """All employees as dictionaries"""
    query = Employee.query
    if active_only:
        query = query.filter_by(active=True)
    return [emp.to_dict() for emp in query.order_by(Employee.id).all()]


def get_employee_by_id_db(emp_id):
    """Employee object or None"""
    return db.session.get(Employee, emp_id)


def update_employee_db(emp_id, **kwargs):
    """Partial update. Returns: (Employee | None, message)"""
    employee = get_employee_by_id_db(emp_id)
    if not employee:
        return None, "Employee not found"

    if 'name' in kwargs and (not isinstance(kwargs['name'], str) or len(kwargs['name'].strip()) < 2):
        return None, "Name must be at least 2 characters"
    if 'age' in kwargs and not Employee.validate_age(kwargs['age']):
        return None, "Age must be between 18 and 65"
    if 'salary' in kwargs and not Employee.validate_salary(kwargs['salary']):
        return None, "Salary must be at least 30,000"
    if 'email' in kwargs:
        if not validate_email(kwargs['email']):
            return None, "Invalid email format"
        kwargs['email'] = kwargs['email'].lower()

    try:
        employee.update_from_dict(kwargs)
        db.session.commit()
        return employee, "Employee updated successfully"
    except IntegrityError:
        db.session.rollback()
        return None, "Email already exists"
    except SQLAlchemyError as e:
        db.session.rollback()
        return None, f"Database error: {str(e)}"


def delete_employee_db(emp_id):
    """Delete employee (and attendance via cascade). Returns: (bool, message)"""
    employee = get_employee_by_id_db(emp_id)
    if not employee:
        return False, "Employee not found"
    try:
        db.session.delete(employee)
        db.session.commit()
        return True, "Employee deleted successfully"
    except SQLAlchemyError as e:
        db.session.rollback()
        return False, f"Database error: {str(e)}"


def search_employees_db(department=None, min_age=None, max_age=None, min_salary=None, active=None):
    """Chainable query filters"""
    query = Employee.query
    if department:
        query = query.filter(Employee.department.ilike(f"%{department}%"))
    if min_age is not None:
        query = query.filter(Employee.age >= min_age)
    if max_age is not None:
        query = query.filter(Employee.age <= max_age)
    if min_salary is not None:
        query = query.filter(Employee.salary >= min_salary)
    if active is not None:
        query = query.filter(Employee.active == active)
    return [emp.to_dict() for emp in query.order_by(Employee.id).all()]


def get_unique_departments_db():
    rows = db.session.query(Employee.department).distinct().order_by(Employee.department).all()
    return [row[0] for row in rows]


def get_employee_count_by_department_db():
    rows = (db.session.query(Employee.department, func.count(Employee.id))
            .group_by(Employee.department).order_by(Employee.department).all())
    return {dept: count for dept, count in rows}


# ===========================================================================
# ATTENDANCE
# ===========================================================================
def mark_attendance_db(employee_id, attendance_date, status, notes=None):
    """Mark attendance. Returns: (Attendance | None, message)"""
    employee = get_employee_by_id_db(employee_id)
    if not employee:
        return None, "Employee not found"
    if status not in Attendance.get_status_options():
        return None, f"Invalid status. Must be one of: {', '.join(Attendance.get_status_options())}"

    existing = Attendance.query.filter_by(employee_id=employee_id, date=attendance_date).first()
    if existing:
        return None, f"Attendance already marked for {attendance_date.isoformat()}"

    try:
        record = Attendance(employee_id, attendance_date, status, notes)
        db.session.add(record)
        db.session.commit()
        return record, "Attendance marked successfully"
    except SQLAlchemyError as e:
        db.session.rollback()
        return None, f"Database error: {str(e)}"


def get_attendance_by_employee_db(employee_id, start_date=None, end_date=None):
    query = Attendance.query.filter_by(employee_id=employee_id)
    if start_date:
        query = query.filter(Attendance.date >= start_date)
    if end_date:
        query = query.filter(Attendance.date <= end_date)
    return [r.to_dict() for r in query.order_by(Attendance.date.desc()).all()]


def get_attendance_statistics_db(employee_id):
    """Count of each status + attendance percentage"""
    rows = (db.session.query(Attendance.status, func.count(Attendance.id))
            .filter_by(employee_id=employee_id).group_by(Attendance.status).all())
    if not rows:
        return None
    counts = {status: count for status, count in rows}
    total = sum(counts.values())
    return {
        "total_records": total,
        "status_counts": counts,
        "attendance_percentage": round(counts.get('Present', 0) / total * 100, 2),
    }


# ===========================================================================
# FILE EXPORT (Phase 7 skills, now fed from the database)
# ===========================================================================
EXPORT_DIR = os.getenv('EXPORT_DIR', 'data')


def export_employees_csv():
    """Write all employees to <EXPORT_DIR>/employees.csv. Returns: (success, message)"""
    try:
        employees = get_all_employees_db()
        if not employees:
            return False, "No employees to export"
        os.makedirs(EXPORT_DIR, exist_ok=True)
        path = os.path.join(EXPORT_DIR, 'employees.csv')
        fields = ['id', 'name', 'age', 'department', 'email', 'salary', 'active']
        with open(path, 'w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=fields)
            writer.writeheader()
            for emp in employees:
                writer.writerow({k: emp[k] for k in fields})
        return True, f"Exported {len(employees)} employees to {path}"
    except OSError as e:
        return False, f"File error: {str(e)}"


def export_employees_json():
    """Write all employees to <EXPORT_DIR>/employees.json. Returns: (success, message)"""
    try:
        employees = get_all_employees_db()
        os.makedirs(EXPORT_DIR, exist_ok=True)
        path = os.path.join(EXPORT_DIR, 'employees.json')
        with open(path, 'w') as f:
            json.dump(employees, f, indent=2)
        return True, f"Exported {len(employees)} employees to {path}"
    except OSError as e:
        return False, f"File error: {str(e)}"


# ===========================================================================
# PHASE 9 - DATA ANALYSIS WITH NUMPY AND PANDAS
# ===========================================================================
def _native(value):
    """Convert NumPy / Pandas scalars (int64, float64, NaN) to JSON-safe Python types"""
    if isinstance(value, (np.integer,)):
        return int(value)
    if isinstance(value, (np.floating, float)):
        return None if np.isnan(value) else float(value)
    return value


def _active_employees_df():
    """DataFrame of active employees (empty DataFrame if none)"""
    employees = Employee.query.filter_by(active=True).all()
    return pd.DataFrame([emp.to_dict() for emp in employees])


# ---------------------------- NumPy: salary statistics ----------------------
def get_salary_statistics_numpy():
    """Salary statistics from a NumPy array"""
    try:
        df = _active_employees_df()
        if df.empty:
            return {"error": "No active employees found"}

        salaries = df['salary'].to_numpy(dtype=float)
        total = float(np.sum(salaries))
        return {
            "count": int(len(salaries)),
            "mean": round(float(np.mean(salaries)), 2),
            "median": float(np.median(salaries)),
            "std_deviation": round(float(np.std(salaries)), 2),
            "variance": round(float(np.var(salaries)), 2),
            "min": float(np.min(salaries)),
            "max": float(np.max(salaries)),
            "range": float(np.max(salaries) - np.min(salaries)),
            "percentile_25": float(np.percentile(salaries, 25)),
            "percentile_50": float(np.percentile(salaries, 50)),
            "percentile_75": float(np.percentile(salaries, 75)),
            "annual_payroll": total,
            "monthly_payroll": round(total / 12, 2),
        }
    except Exception as e:
        return {"error": f"Calculation error: {str(e)}"}


def get_salary_distribution():
    """Employee count per salary band using NumPy boolean masks"""
    try:
        df = _active_employees_df()
        if df.empty:
            return {"error": "No active employees found"}

        salaries = df['salary'].to_numpy(dtype=float)
        ranges = [
            (0, 50000, "<50k"),
            (50000, 70000, "50k-70k"),
            (70000, 90000, "70k-90k"),
            (90000, 110000, "90k-110k"),
            (110000, float('inf'), "110k+"),
        ]
        return {label: int(np.sum((salaries >= lo) & (salaries < hi)))
                for lo, hi, label in ranges}
    except Exception as e:
        return {"error": f"Distribution error: {str(e)}"}


# ---------------------------- Pandas: reports -------------------------------
def generate_department_report_pandas():
    """Department-wise report with groupby + agg"""
    try:
        df = _active_employees_df()
        if df.empty:
            return {"error": "No active employees found"}

        grouped = df.groupby('department')
        report = {}
        for dept, g in grouped:
            std = g['salary'].std()
            report[dept] = {
                "employee_count": int(len(g)),
                "avg_salary": round(float(g['salary'].mean()), 2),
                "median_salary": float(g['salary'].median()),
                "min_salary": float(g['salary'].min()),
                "max_salary": float(g['salary'].max()),
                "total_salary_cost": float(g['salary'].sum()),
                "salary_std_dev": 0 if pd.isna(std) else round(float(std), 2),
                "avg_age": round(float(g['age'].mean()), 2),
                "min_age": int(g['age'].min()),
                "max_age": int(g['age'].max()),
            }
        return {"departments": report, "total_departments": len(report),
                "total_employees": int(len(df))}
    except Exception as e:
        return {"error": f"Report generation error: {str(e)}"}


def get_top_earners(limit=10):
    """Top N highest-paid active employees"""
    try:
        df = _active_employees_df()
        if df.empty:
            return []
        top = df.nlargest(limit, 'salary').copy()
        top['rank'] = range(1, len(top) + 1)
        result = top[['rank', 'name', 'department', 'salary', 'age']]
        return [{k: _native(v) for k, v in row.items()} for row in result.to_dict('records')]
    except Exception as e:
        return {"error": f"Top earners error: {str(e)}"}


def get_salary_comparison():
    """Each department vs the company average"""
    try:
        df = _active_employees_df()
        if df.empty:
            return {"error": "No active employees found"}

        overall_avg = df['salary'].mean()
        overall_median = df['salary'].median()

        comparison = []
        for dept in df['department'].unique():
            dept_df = df[df['department'] == dept]
            dept_avg = dept_df['salary'].mean()
            comparison.append({
                "department": dept,
                "avg_salary": round(float(dept_avg), 2),
                "vs_company_avg": round(float((dept_avg / overall_avg - 1) * 100), 2),
                "employee_count": int(len(dept_df)),
                "percentage_of_workforce": round(len(dept_df) / len(df) * 100, 2),
            })
        comparison.sort(key=lambda x: x['avg_salary'], reverse=True)

        return {"company_avg_salary": round(float(overall_avg), 2),
                "company_median_salary": round(float(overall_median), 2),
                "department_comparison": comparison}
    except Exception as e:
        return {"error": f"Comparison error: {str(e)}"}


def generate_age_demographics():
    """Age groups with pd.cut + stats"""
    try:
        df = _active_employees_df()
        if df.empty:
            return {"error": "No active employees found"}

        bins = [0, 25, 30, 35, 40, 45, 50, 100]
        labels = ['<25', '25-29', '30-34', '35-39', '40-44', '45-49', '50+']
        df['age_group'] = pd.cut(df['age'], bins=bins, labels=labels, right=False)

        distribution = {str(k): int(v) for k, v in df['age_group'].value_counts(sort=False).items()}
        return {
            "mean_age": round(float(df['age'].mean()), 1),
            "median_age": float(df['age'].median()),
            "min_age": int(df['age'].min()),
            "max_age": int(df['age'].max()),
            "age_distribution": distribution,
            "avg_age_by_department": {d: round(float(v), 1)
                                      for d, v in df.groupby('department')['age'].mean().items()},
        }
    except Exception as e:
        return {"error": f"Demographics error: {str(e)}"}


# ---------------------------- Pandas: attendance ----------------------------
def get_attendance_summary_pandas(start_date=None, end_date=None):
    """Overall + per-employee attendance summary"""
    try:
        query = Attendance.query
        if start_date:
            query = query.filter(Attendance.date >= start_date)
        if end_date:
            query = query.filter(Attendance.date <= end_date)

        records = query.all()
        if not records:
            return {"error": "No attendance records found"}

        df = pd.DataFrame([r.to_dict() for r in records])
        total_records = len(df)
        status_counts = {k: int(v) for k, v in df['status'].value_counts().items()}
        status_percentages = {k: round(v / total_records * 100, 2) for k, v in status_counts.items()}

        by_employee = {}
        for (emp_id, name), g in df.groupby(['employee_id', 'employee_name']):
            present = int((g['status'] == 'Present').sum())
            total = int(len(g))
            by_employee[name] = {
                "employee_id": int(emp_id),
                "total_days": total,
                "present_days": present,
                "attendance_percentage": round(present / total * 100, 2),
            }

        return {
            "period": {"start_date": start_date.isoformat() if start_date else None,
                       "end_date": end_date.isoformat() if end_date else None},
            "overall": {"total_records": total_records,
                        "status_counts": status_counts,
                        "status_percentages": status_percentages},
            "by_employee": by_employee,
        }
    except Exception as e:
        return {"error": f"Attendance summary error: {str(e)}"}


def get_department_attendance_stats():
    """Attendance rate per department"""
    try:
        rows = (db.session.query(Attendance.status, Employee.department)
                .join(Employee, Attendance.employee_id == Employee.id)
                .filter(Employee.active.is_(True)).all())
        if not rows:
            return {"error": "No attendance records found"}

        df = pd.DataFrame(rows, columns=['status', 'department'])
        table = df.groupby(['department', 'status']).size().unstack(fill_value=0)
        table['Total'] = table.sum(axis=1)
        present = table['Present'] if 'Present' in table.columns else 0
        table['Attendance_Rate'] = (present / table['Total'] * 100).round(2)

        return {dept: {str(col): _native(val) for col, val in row.items()}
                for dept, row in table.to_dict('index').items()}
    except Exception as e:
        return {"error": f"Department attendance error: {str(e)}"}
