FROM python:3.12-slim

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# Baked in at build time so the running container can report which image it
# came from -- GET /version. scripts/build.sh passes --build-arg APP_VERSION=$TAG,
# so the reported version always matches the image tag.
#
# This is what makes per-environment image pinning demonstrable: build the same
# source twice at two tags, and `kubectl exec ... curl /version` proves which one
# a Pod is actually running. See k8s/overlays/prod (pins pricing to 0.2.0).
ARG APP_VERSION=0.1.0
ENV APP_VERSION=${APP_VERSION}

USER appuser

EXPOSE 8000

ENTRYPOINT ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
