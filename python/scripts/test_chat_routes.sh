#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PY_BIN=".venv/bin/python"
if [[ ! -x "$PY_BIN" ]]; then
  echo "Missing virtualenv python at $PY_BIN"
  exit 1
fi

echo "[1/5] Legacy chat routing tests (AI_ROUTER_V2_ENABLED=0)"
AI_ROUTER_V2_ENABLED=0 "$PY_BIN" -m unittest tests.test_chat_service -q

echo "[2/5] V2 chat routing regression tests (AI_ROUTER_V2_ENABLED=1)"
AI_ROUTER_V2_ENABLED=1 "$PY_BIN" -m unittest tests.test_chat_service_v2_regression -q

echo "[3/5] V2 chat routing regression tests batch-2 (AI_ROUTER_V2_ENABLED=1)"
AI_ROUTER_V2_ENABLED=1 "$PY_BIN" -m unittest tests.test_chat_service_v2_regression_batch2 -q

echo "[4/5] V2 paraphrase regression tests (AI_ROUTER_V2_ENABLED=1)"
AI_ROUTER_V2_ENABLED=1 "$PY_BIN" -m unittest tests.test_chat_service_v2_paraphrase_regression -q

echo "[5/5] English routing benchmark with thresholds (AI_ROUTER_V2_ENABLED=1)"
BENCH_OUT="${ROOT_DIR}/.artifacts/chat_route_benchmark_latest.json"
BENCH_HISTORY="${ROOT_DIR}/.artifacts/chat_route_benchmark_history.jsonl"
mkdir -p "${ROOT_DIR}/.artifacts"
PYTHONPATH=. AI_ROUTER_V2_ENABLED=1 "$PY_BIN" scripts/chat_route_benchmark.py --router-v2 1 --min-intent-accuracy 0.95 --min-answer-source-accuracy 0.95 --output-json "$BENCH_OUT" --append-jsonl "$BENCH_HISTORY"
echo "Benchmark report saved to: $BENCH_OUT"
echo "Benchmark history appended to: $BENCH_HISTORY"
PYTHONPATH=. "$PY_BIN" scripts/chat_route_benchmark_trend.py --history-jsonl "$BENCH_HISTORY" --tail 10

echo "Chat routing test tracks passed."
