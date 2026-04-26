#!/bin/bash
exec > /var/log/userdata.log 2>&1

# Install dependencies
sudo yum install git -y

# Clone into ec2-user's home
git clone https://username:apppassword@github.com/Jasleenkaurnotay/two-tier-app.git /home/ec2-user/two-tier-app

cd /home/ec2-user/two-tier-app

python3 -m venv .venv
source .venv/bin/activate

pip install -r requirements.txt

export DB_LINK='postgresql://{user-name}:{rds-endpoint-name}:5432/{db-name}'

gunicorn run:app --bind 0.0.0.0:8000 &
