FROM denoland/deno:bin-2.9.2@sha256:a479d91f958895f3b9804ab4dd074b596a497fe0d4af198bfd2f688e61297c39 AS deno

FROM python:3.12.11-slim-bookworm@sha256:519591d6871b7bc437060736b9f7456b8731f1499a57e22e6c285135ae657bf7

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    MEDIA_HARBOR_HOST=0.0.0.0 \
    MEDIA_HARBOR_DOWNLOAD_DIR=/data/downloads

RUN sed -i \
      -e 's|http://deb.debian.org/debian-security|https://snapshot.debian.org/archive/debian-security/20260701T000000Z|g' \
      -e 's|http://deb.debian.org/debian|https://snapshot.debian.org/archive/debian/20260701T000000Z|g' \
      /etc/apt/sources.list.d/debian.sources \
    && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99snapshot \
    && apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg aria2 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=deno /deno /usr/local/bin/deno

WORKDIR /app
COPY requirements.txt requirements.lock ./
RUN pip install --disable-pip-version-check --require-hashes -r requirements.lock
COPY app ./app

RUN useradd --create-home --uid 10001 langbai \
    && mkdir -p /data/downloads \
    && chown -R langbai:langbai /data /app
USER langbai

EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import os,urllib.request; r=urllib.request.Request('http://127.0.0.1:8787/api/v1/health',headers={'X-Langbai-Instance-Token':os.getenv('MEDIA_HARBOR_INSTANCE_TOKEN','')}); urllib.request.urlopen(r,timeout=3).read()"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8787", "--workers", "1"]
