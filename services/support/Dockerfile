FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.lock .
RUN pip install --no-cache-dir --require-hashes -r requirements.lock && useradd --uid 10001 --no-create-home support
COPY support.py supportctl.py ./
COPY public ./public
USER 10001:10001
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", "--timeout", "20", "--limit-request-line", "2048", "--limit-request-fields", "30", "--limit-request-field_size", "2048", "--max-requests", "1000", "--max-requests-jitter", "100", "support:application"]
