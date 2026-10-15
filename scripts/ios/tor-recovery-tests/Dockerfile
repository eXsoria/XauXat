FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends tor python3 && rm -rf /var/lib/apt/lists/*
ENV PYTHONDONTWRITEBYTECODE=1
