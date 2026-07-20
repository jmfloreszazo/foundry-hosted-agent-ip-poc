# Multi-stage image for the Python variant of the Foundry Hosted Agent.
# Mirrors the discipline of src/Agent/Dockerfile: small runtime, non-root user,
# pinned base tag, no source shipped in a shared layer. Uses the same base
# image and CMD pattern as the Microsoft bring-your-own Python Responses
# hosted-agent sample (python:3.12-slim + `python main.py`).

FROM python:3.12-slim AS build
WORKDIR /src
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

# Install deps into a self-contained prefix so we can COPY only what we need
# into the runtime stage (keeps the surface smaller / more auditable).
COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

# --- runtime -----------------------------------------------------------------
FROM python:3.12-slim
WORKDIR /app

# Non-root user, matches the C# Dockerfile posture (stricter than the MS
# sample, which runs as root).
RUN useradd --create-home --shell /usr/sbin/nologin appuser

# Bring in the pre-installed dependencies.
COPY --from=build /install /usr/local

# Ship the app as an importable package (``agentpython.main``).
COPY --chown=appuser:appuser guardrails.py opacity.py key_vault_prompt_store.py \
     protected_response_handler.py main.py __init__.py /app/agentpython/

USER appuser
ENV PYTHONUNBUFFERED=1
# The azure-ai-agentserver-responses SDK binds to port 8088 by default (same
# port the Foundry runtime proxies to). No $PORT expansion needed -- the SDK
# reads it internally when the runtime overrides it.
EXPOSE 8088
CMD ["python", "-m", "agentpython.main"]
