# AI Router V2 Go-Live Checklist

## Goal
Run backend chat routing with V2 by default, while keeping fast rollback.

## Pre-deploy
- Ensure env has `AI_ROUTER_V2_ENABLED=1` (or omit it; default is now on).
- Run:
  - `cd python`
  - `./scripts/test_chat_routes.sh`
- Confirm benchmark thresholds pass:
  - `intent_accuracy >= 0.95`
  - `answer_source_accuracy >= 0.95`

## Deploy
- Deploy backend normally.
- Verify health endpoint and one smoke prompt:
  - `why did my spending increase last month`
- Confirm route logs show expected intent and deterministic answer source for core prompts.

## Post-deploy monitoring (daily)
- Run route script and check:
  - `.artifacts/chat_route_benchmark_latest.json`
  - `.artifacts/chat_route_benchmark_history.jsonl`
- Watch trend output deltas:
  - `intent_accuracy`
  - `answer_source_accuracy`
  - `clarification_rate`

## Rollback
- Set `AI_ROUTER_V2_ENABLED=0`.
- Restart backend.
- Re-run smoke prompts to confirm legacy behavior.

## Exit criteria to remove legacy path
- Stable benchmark for 1-2 weeks (no threshold failures).
- No critical routing incidents from production prompts.
- Then remove legacy branches in a dedicated cleanup PR.
