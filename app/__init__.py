"""
Application Factory with logging, error handlers, request logging, metrics and tracing
"""
import logging
import os
from logging.handlers import RotatingFileHandler

from flask import Flask, request
from sqlalchemy.engine import make_url
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from werkzeug.middleware.proxy_fix import ProxyFix

from app.models import db
from app.observability import JsonFormatter, check_database, init_observability, init_tracing
from config import config_by_name

SEED_EMPLOYEES = [
    ("Alice Johnson", 28, "Engineering", "alice@company.com", 75000),
    ("Bob Smith", 35, "Marketing", "bob@company.com", 65000),
    ("Charlie Brown", 42, "Engineering", "charlie@company.com", 95000),
    ("Diana Prince", 31, "HR", "diana@company.com", 70000),
]


def _ensure_sqlite_directory(uri):
    url = make_url(uri)
    if url.drivername.startswith('sqlite') and url.database and url.database != ':memory:':
        folder = os.path.dirname(url.database)
        if folder:
            os.makedirs(folder, exist_ok=True)


def configure_logging(app):
    """Console handler (the terminal now, the service log later) + rotating file handler"""
    level = getattr(logging, str(app.config.get('LOG_LEVEL', 'INFO')).upper(), logging.INFO)
    if app.config.get('LOG_FORMAT') == 'json':
        formatter = JsonFormatter()
    else:
        formatter = logging.Formatter('[%(asctime)s] %(levelname)s in %(module)s: %(message)s')

    # Avoid duplicate handlers when create_app() is called more than once (tests)
    app.logger.handlers.clear()

    console = logging.StreamHandler()
    console.setFormatter(formatter)
    console.setLevel(level)
    app.logger.addHandler(console)

    log_file = app.config.get('LOG_FILE')
    if log_file:
        os.makedirs(os.path.dirname(os.path.abspath(log_file)), exist_ok=True)
        file_handler = RotatingFileHandler(log_file, maxBytes=10 * 1024 * 1024, backupCount=10)
        file_handler.setFormatter(formatter)
        file_handler.setLevel(level)
        app.logger.addHandler(file_handler)

    app.logger.setLevel(level)
    app.logger.propagate = False


def create_app(config_name=None):
    """Application factory - config_name: development | production | testing"""
    app = Flask(__name__)
    app.json.sort_keys = False      # keep dict order in JSON (Flask 3 setting)

    if config_name is None:
        config_name = os.getenv('FLASK_ENV', 'development')
    config_class = config_by_name.get(config_name, config_by_name['default'])
    if config_name == 'production':
        config_class.validate()
    app.config.from_object(config_class)

    configure_logging(app)
    if app.config.get('TRUSTED_PROXIES'):
        # trust exactly N proxies for X-Forwarded-For/Proto: nginx (1), or the ALB and nginx (2)
        hops = app.config['TRUSTED_PROXIES']
        app.wsgi_app = ProxyFix(app.wsgi_app, x_for=hops, x_proto=hops, x_host=0)
    app.logger.info('=' * 60)
    app.logger.info('%s starting (env=%s, debug=%s)', app.config['APP_NAME'],
                    config_name, app.config.get('DEBUG', False))

    # ---- Database ----------------------------------------------------------
    db.init_app(app)
    _ensure_sqlite_directory(app.config['SQLALCHEMY_DATABASE_URI'])

    with app.app_context():
        from app.models import Employee
        try:
            db.create_all()
        except SQLAlchemyError as e:            # two workers started at once on an empty database
            db.session.rollback()
            if 'already exists' not in str(e) and 'duplicate key' not in str(e):
                raise
        if app.config.get('SEED_DEMO_DATA') and Employee.query.count() == 0:
            try:
                for name, age, dept, email, salary in SEED_EMPLOYEES:
                    db.session.add(Employee(name, age, dept, email, salary))
                db.session.commit()
                app.logger.info('Seeded %d demo employees', len(SEED_EMPLOYEES))
            except IntegrityError:               # another worker seeded first - that is fine
                db.session.rollback()
    app.logger.info('Database initialised')

    # ---- Blueprints ----------------------------------------------------------
    from app.routes import api
    app.register_blueprint(api, url_prefix='/api')

    # ---- Error handlers ------------------------------------------------------
    @app.errorhandler(404)
    def not_found_error(error):
        app.logger.warning('404 error: %s %s', request.method, request.path)
        return {'error': 'Resource not found'}, 404

    @app.errorhandler(405)
    def method_not_allowed(error):
        app.logger.warning('405 error: %s %s', request.method, request.path)
        return {'error': 'Method not allowed'}, 405

    @app.errorhandler(500)
    def internal_error(error):
        app.logger.error('500 error: %s', error)
        db.session.rollback()
        return {'error': 'Internal server error'}, 500

    # ---- Request ID, request log, /metrics, /livez, tracing ----------------------
    init_observability(app, db)
    init_tracing(app, db)

    # ---- Home & health ---------------------------------------------------------
    @app.route('/')
    def home():
        return {
            'message': app.config['APP_NAME'],
            'version': app.config['APP_VERSION'],
            'database': 'Connected',
            'endpoints': {
                'employees': '/api/employees',
                'attendance': '/api/attendance',
                'analytics': '/api/analytics/salary/statistics',
                'departments': '/api/departments',
                'health': '/health',
                'liveness': '/livez',
                'metrics': '/metrics',
                'alerts': '/api/alerts',
            },
        }

    @app.route('/health')
    def health():
        healthy, db_status = check_database(db)
        if not healthy:
            app.logger.error('Health check failed: %s', db_status)
        return {
            'status': 'healthy' if db_status == 'healthy' else 'degraded',
            'database': db_status,
            'version': app.config['APP_VERSION'],
        }, (200 if db_status == 'healthy' else 503)

    return app
