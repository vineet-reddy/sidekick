FROM python:3.12-slim

WORKDIR /app

COPY . /app/github_bootstrap_service

ENV PYTHONUNBUFFERED=1
ENV PORT=8787

EXPOSE 8787

CMD ["python3", "-m", "github_bootstrap_service.bootstrap_service.server"]
