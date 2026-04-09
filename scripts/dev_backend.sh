#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY_DIR="$ROOT_DIR/python"
PY_BIN="$PY_DIR/.venv/bin/python"

if [[ ! -x "$PY_BIN" ]]; then
  echo "Missing Python venv at $PY_BIN"
  echo "Create it under $PY_DIR/.venv and install dependencies."
  exit 1
fi

cd "$PY_DIR"

# Fail fast if critical deps are missing (prevents silently running the wrong python).
"$PY_BIN" -c "import dotenv, flask" >/dev/null 2>&1 || {
  echo "Missing dependencies in python/.venv."
  echo "Run: cd $PY_DIR && .venv/bin/pip install -r requirements.txt"
  exit 1
}

if command -v lsof >/dev/null 2>&1; then
  PIDS="$(lsof -ti :8000 2>/dev/null || true)"
  if [[ -n "$PIDS" ]]; then
    echo "Stopping existing process(es) on :8000: $PIDS"
    kill -9 $PIDS || true
  fi
fi

echo "Starting backend on http://127.0.0.1:8000 using $PY_BIN"
exec "$PY_BIN" server.py

