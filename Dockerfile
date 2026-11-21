# Official Python image (slim variant keeps the image small)
FROM python:3.12-slim

LABEL org.opencontainers.image.title="dice-devops-finalproject-client" \
      org.opencontainers.image.description="Receives a file from the server and verifies its SHA-256 checksum"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/clientdata

# Packages needed by the app: the app itself only uses the Python standard library,
# tini is installed as a minimal init so signals (docker stop) are handled cleanly.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*

# Run as a non-root user; pre-create the data dir so the named volume
# inherits the correct ownership on first mount.
RUN useradd --create-home --uid 10001 appuser \
    && mkdir -p /clientdata \
    && chown appuser:appuser /clientdata

WORKDIR /app
COPY app/ /app/

USER appuser

VOLUME ["/clientdata"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "/app/client.py"]
