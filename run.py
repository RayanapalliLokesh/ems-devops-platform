"""
Application Entry Point
  Development : python run.py
  Production  : gunicorn --bind 0.0.0.0:5000 run:app
"""
import os

from app import create_app

app = create_app()

if __name__ == '__main__':
    app.logger.info('Server: http://127.0.0.1:5000  (API: /api/employees)')
    app.run(debug=app.config.get('DEBUG', False), port=int(os.getenv('PORT', 5000)), host='0.0.0.0')
