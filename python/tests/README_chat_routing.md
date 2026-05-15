## Chat Routing Test Tracks

Run both routing tracks with:

```bash
cd python
./scripts/test_chat_routes.sh
```

Tracks:

1. Legacy routing contract (`AI_ROUTER_V2_ENABLED=0`)
   - `tests.test_chat_service`
2. V2 routing regression (`AI_ROUTER_V2_ENABLED=1`)
   - `tests.test_chat_service_v2_regression`
3. V2 routing regression batch-2 (`AI_ROUTER_V2_ENABLED=1`)
   - `tests.test_chat_service_v2_regression_batch2`
4. V2 paraphrase regression (`AI_ROUTER_V2_ENABLED=1`)
   - `tests.test_chat_service_v2_paraphrase_regression`
5. English routing benchmark + thresholds (`AI_ROUTER_V2_ENABLED=1`)
   - `scripts/chat_route_benchmark.py`
   - Dataset:
     - `tests/data/chat_route_benchmark_en.json`
   - Default thresholds in route script:
     - `intent_accuracy >= 0.95`
     - `answer_source_accuracy >= 0.95`
   - Latest report output:
     - `.artifacts/chat_route_benchmark_latest.json`
   - Historical trend output (one record per run):
     - `.artifacts/chat_route_benchmark_history.jsonl`
   - Trend summary helper:
     - `scripts/chat_route_benchmark_trend.py`
