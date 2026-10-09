"""
Application Configuration
All settings come from environment variables (12-factor style) with safe defaults.
"""
import os
from dotenv import load_dotenv

# Load environment variables from .env file (no effect if the file is absent)
load_dotenv()

BASE_DIR = os.path.abspath(os.path.dirname(__file__))
DEFAULT_DB = 'sqlite:///' + os.path.join(BASE_DIR, 'data', 'employees.db')
INSECURE_KEYS = {None, '', 'dev-secret-key-change-in-production',
                 'change-this-to-a-random-string'}


class Config:
    """Base configuration - settings common to all environments"""
    SECRET_KEY = os.getenv('SECRET_KEY', 'dev-secret-key-change-in-production')

    # Database
    SQLALCHEMY_DATABASE_URI = os.getenv('DATABASE_URL', DEFAULT_DB)
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    SQLALCHEMY_ECHO = os.getenv('SQLALCHEMY_ECHO', 'False').lower() == 'true'

    # Application
    APP_NAME = os.getenv('APP_NAME', 'Employee Management System')
    APP_VERSION = os.getenv('APP_VERSION', '1.0.0')

    # Logging
    LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO').upper()
    LOG_FILE = os.getenv('LOG_FILE', os.path.join(BASE_DIR, 'logs', 'app.log'))

    # API
    MAX_CONTENT_LENGTH = int(os.getenv('MAX_CONTENT_LENGTH', 16 * 1024 * 1024))  # 16 MB

    SEED_DEMO_DATA = os.getenv('SEED_DEMO_DATA', 'true').lower() == 'true'


class DevelopmentConfig(Config):
    DEBUG = True
    LOG_LEVEL = os.getenv('LOG_LEVEL', 'DEBUG').upper()


class ProductionConfig(Config):
    DEBUG = False
    SQLALCHEMY_ECHO = False

    @classmethod
    def validate(cls):
        """Fail fast when production is started with an insecure secret"""
        if cls.SECRET_KEY in INSECURE_KEYS:
            raise ValueError("SECRET_KEY must be set to a strong random value in production")


class TestingConfig(Config):
    TESTING = True
    SQLALCHEMY_DATABASE_URI = 'sqlite:///:memory:'    # in-memory database
    SEED_DEMO_DATA = False
    LOG_FILE = None                                    # no log file during tests


config_by_name = {
    'development': DevelopmentConfig,
    'production': ProductionConfig,
    'testing': TestingConfig,
    'default': DevelopmentConfig,
}
