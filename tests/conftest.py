import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import create_app          # noqa: E402
from app.models import db, Employee  # noqa: E402


@pytest.fixture()
def app():
    """Fresh app + empty in-memory database for every test"""
    app = create_app('testing')
    with app.app_context():
        db.create_all()
        yield app
        db.session.remove()
        db.drop_all()


@pytest.fixture()
def client(app):
    return app.test_client()


@pytest.fixture()
def seeded(app):
    """Four demo employees"""
    rows = [
        ("Alice Johnson", 28, "Engineering", "alice@company.com", 75000),
        ("Bob Smith", 35, "Marketing", "bob@company.com", 65000),
        ("Charlie Brown", 42, "Engineering", "charlie@company.com", 95000),
        ("Diana Prince", 31, "HR", "diana@company.com", 70000),
    ]
    for r in rows:
        db.session.add(Employee(*r))
    db.session.commit()
    return rows
