FROM python:3.12-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        texlive-latex-base \
        texlive-latex-recommended \
        texlive-latex-extra \
        texlive-fonts-recommended \
        texlive-bibtex-extra \
    && rm -rf /var/lib/apt/lists/*

COPY . /app/github_bootstrap_service

ENV PYTHONUNBUFFERED=1
ENV PORT=8787

EXPOSE 8787

CMD ["python3", "-m", "github_bootstrap_service.bootstrap_service.server"]
