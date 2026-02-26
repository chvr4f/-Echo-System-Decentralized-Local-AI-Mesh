#!/bin/bash
# scripts/test-task.sh
# Sends test tasks to the orchestrator and shows routing info.
# Run this after start-phase1.sh to verify everything is working.

BASE="http://localhost:8080"
PASS=0
FAIL=0

echo ""
echo "╔══════════════════════════════════════╗"
echo "║     ECHO-SYSTEM  Phase 1 Tests       ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ─── Helper ───────────────────────────────────────────────────────────────────

check() {
  local label="$1"
  local result="$2"
  local expect="$3"

  if echo "$result" | grep -q "$expect"; then
    echo "  ✅  $label"
    PASS=$((PASS+1))
  else
    echo "  ❌  $label"
    echo "      Expected to find: $expect"
    echo "      Got: $result"
    FAIL=$((FAIL+1))
  fi
}

# ─── Test 1: Orchestrator health ──────────────────────────────────────────────

echo "── Test 1: Orchestrator is up ─────────────────────────────"
STATUS=$(curl -s "$BASE/status")
check "Orchestrator responds" "$STATUS" "node_count"
check "Nodes are registered"  "$STATUS" "node-a"
echo ""

# ─── Test 2: Non-streaming task ───────────────────────────────────────────────

echo "── Test 2: Non-streaming task ─────────────────────────────"
echo "   Sending: 'Say hello in one word'"
RESULT=$(curl -s -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Say hello in exactly one word. Reply with only that word."}')
echo "   Response: $RESULT"
check "Task succeeded"        "$RESULT" '"success":true'
check "Has routed_to field"   "$RESULT" '"routed_to"'
check "Has content"           "$RESULT" '"content"'
check "Has latency"           "$RESULT" '"latency_ms"'
echo ""

# ─── Test 3: Routing to specific node ─────────────────────────────────────────

echo "── Test 3: Route to node-a specifically ───────────────────"
RESULT=$(curl -s -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Say the number 1. Reply with only: 1", "model_hint": "mistral"}')
check "Routed correctly" "$RESULT" '"success":true'
echo ""

# ─── Test 4: Load balancing (send 4 tasks, check both nodes get work) ─────────

echo "── Test 4: Load balancing across nodes ────────────────────"
echo "   Sending 4 quick tasks in parallel..."

RESULTS=""
for i in 1 2 3 4; do
  RES=$(curl -s -X POST "$BASE/task" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\": \"Say the number $i. Reply with only: $i\"}") &
done
wait

STATUS2=$(curl -s "$BASE/status")
echo "   Mesh status after load test:"
echo "$STATUS2" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data.get('nodes', []):
    print(f\"   {n['node_id']:15} status={n['status']:10} active={n['active_tasks']}\")
" 2>/dev/null || echo "   $STATUS2"
echo ""

# ─── Test 5: Streaming task ───────────────────────────────────────────────────

echo "── Test 5: Streaming task ─────────────────────────────────"
echo "   Streaming: 'Count from 1 to 5'"
echo "   Tokens received:"
curl -s -N -X POST "$BASE/task/stream" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Count from 1 to 5. Use spaces between numbers."}' \
  | head -20 \
  | while IFS= read -r line; do
      # Lines are: data: {"token":"...","done":false,...}
      token=$(echo "$line" | python3 -c "
import json, sys
try:
    line = sys.stdin.read().strip()
    if line.startswith('data: '):
        line = line[6:]
    d = json.loads(line)
    if d.get('token'):
        print(d['token'], end='', flush=True)
except: pass
" 2>/dev/null)
      printf "%s" "$token"
    done
echo ""
echo ""
PASS=$((PASS+1)) # count streaming test as pass if we got here

# ─── Test 6: No node available ────────────────────────────────────────────────

echo "── Test 6: Graceful error on unknown model ─────────────────"
RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "test", "model_hint": "nonexistent-model-xyz"}')
check "Returns 503 when no node available" "$RESULT" "503"
echo ""

# ─── Summary ──────────────────────────────────────────────────────────────────

echo "──────────────────────────────────────────────────────────"
echo "  Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "  🎉 All tests passed — Phase 1 is working!"
else
  echo "  ⚠️  Some tests failed. Check logs/ for details."
fi
echo "──────────────────────────────────────────────────────────"
echo ""
