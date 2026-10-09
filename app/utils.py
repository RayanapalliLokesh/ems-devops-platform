"""
Utility Functions
Validation helpers (regular expressions) and small formatters
"""
import re

EMAIL_PATTERN = re.compile(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')
INDIAN_PHONE_PATTERN = re.compile(r'^(\+91-?)?[6-9]\d{9}$')
UK_PHONE_PATTERN = re.compile(r'^(\+44\s?|0)(\d\s?){9,10}$')
EMPLOYEE_CODE_PATTERN = re.compile(r'EMP-(\d{3})')


def validate_email(email):
    """Validate email format using regex. Returns: bool"""
    if not email or not isinstance(email, str):
        return False
    return bool(EMAIL_PATTERN.match(email))


def validate_indian_phone(phone):
    """Indian mobile: optional +91 prefix, 10 digits starting with 6-9"""
    if not phone or not isinstance(phone, str):
        return False
    return bool(INDIAN_PHONE_PATTERN.match(phone.strip()))


def validate_uk_phone(phone):
    """UK phone: +44 or leading 0, then 9-10 digits"""
    if not phone or not isinstance(phone, str):
        return False
    return bool(UK_PHONE_PATTERN.match(phone.strip()))


def validate_password_strength(password):
    """
    Check password strength.
    Returns: (is_valid: bool, errors: list[str])
    """
    errors = []
    password = password if isinstance(password, str) else ""

    if len(password) < 8:
        errors.append("Password must be at least 8 characters")
    if not re.search(r'[A-Z]', password):
        errors.append("Password must contain uppercase letter")
    if not re.search(r'[a-z]', password):
        errors.append("Password must contain lowercase letter")
    if not re.search(r'\d', password):
        errors.append("Password must contain digit")
    if not re.search(r'[!@#$%^&*(),.?":{}|<>_\-]', password):
        errors.append("Password must contain special character")

    return len(errors) == 0, errors


def extract_domain_from_email(email):
    """'alice@company.com' -> 'company.com' (regex capture group)"""
    match = re.search(r'@([\w.-]+)', email or "")
    return match.group(1) if match else None


def extract_employee_code_number(text):
    """Find 'EMP-123' inside free text and return 123 (or None)"""
    match = EMPLOYEE_CODE_PATTERN.search(text or "")
    return int(match.group(1)) if match else None
