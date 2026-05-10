#!/bin/bash
set -e
python -c "from run import init_db; init_db()"
exec gunicorn run:app --bind 0.0.0.0:8000