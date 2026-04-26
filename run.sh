# in path day2/app

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export DB_LINK='postgresql://postgres:app-db1!@app-db.cshaymiem82x.us-east-1.rds.amazonaws.com:5432/mydb'
gunicorn run:app --bind 0.0.0.0:8000 &



