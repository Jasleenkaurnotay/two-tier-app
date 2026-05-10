FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt requirements.txt

RUN pip install --no-cache-dir -r requirements.txt

COPY entrypoint.sh entrypoint.sh

RUN chmod +x entrypoint.sh

COPY app/ app/

COPY config.py config.py

COPY run.py run.py

EXPOSE 8000

ENTRYPOINT ["./entrypoint.sh"]