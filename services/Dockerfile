# One image runs all four resort services and the load generator.
# Kubernetes picks which one with the APP_MODULE variable.
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY skiapp ./skiapp

ENV APP_MODULE=skiapp.lift_tickets:app \
    PYTHONUNBUFFERED=1
EXPOSE 8000
CMD ["sh", "-c", "uvicorn $APP_MODULE --host 0.0.0.0 --port 8000 --no-access-log"]
