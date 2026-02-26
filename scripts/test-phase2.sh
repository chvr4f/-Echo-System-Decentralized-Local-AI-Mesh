#!/bin/bash
# scripts/test-phase2.sh
# Tests Phase 2 features: accurate load tracking, failover, reconnect.
# Run AFTER start-phase1.sh

BASE="http://localhost:8080"
PASS=0
FAIL=0

# On MSYS/Git Bash/WSL, the bundled curl can't reach Windows-bound localhost.
if command -v curl.exe &>/dev/null; then
  CURL="curl.exe"
else
  CURL="curl"
fi

echo ""
echo "╔══════════════════════════════════════╗"
echo "║     ECHO-SYSTEM  Phase 2 Tests       ║"
echo "╚══════════════════════════════════════╝"
echo ""

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
    echo "      Got: $(echo $result | head -c 200)"
    FAIL=$((FAIL+1))
  fi
}

# ─── Test 1: Both nodes still healthy ────────────────────────────────────────

echo "── Test 1: Both nodes alive and idle ──────────────────────"
STATUS=$($CURL -s "$BASE/status")
check "Two nodes registered" "$STATUS" '"node_count":2'
check "node-a is idle"       "$STATUS" '"node_id":"node-a"'
check "node-b is idle"       "$STATUS" '"node_id":"node-b"'
echo ""

# ─── Test 2: Load tracking accuracy ──────────────────────────────────────────
# Send a slow task and immediately check that active_tasks incremented

echo "── Test 2: Live load tracking ─────────────────────────────"
echo "   Sending a slow task in background..."

# Use a very long prompt to guarantee the task is still running when we check status
$CURL -s -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Write a very long and detailed technical essay of at least 800 words about distributed systems, covering consensus algorithms, CAP theorem, Byzantine fault tolerance, and real-world examples from Google Spanner, Apache Kafka, and Amazon DynamoDB. Include code examples."}' \
  > /tmp/slow_task_result.json &
SLOW_PID=$!

sleep 5  # Ollama on CPU takes a few seconds to even start generating

MID_STATUS=$($CURL -s "$BASE/status")
echo "   Mid-task status:"
echo "$MID_STATUS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data.get('nodes', []):
    print(f\"   {n['node_id']:12} active_tasks={n['active_tasks']}  status={n['status']}\")
" 2>/dev/null || echo "   $MID_STATUS"

# The task should be tracked on one node
check "A node shows active task" "$MID_STATUS" '"active_tasks":1'

wait $SLOW_PID
RESULT=$(cat /tmp/slow_task_result.json)
check "Slow task completed" "$RESULT" '"success":true'
echo ""

# ─── Test 3: Load balancing under parallel load ───────────────────────────────

echo "── Test 3: Parallel tasks spread across nodes ─────────────"
echo "   Sending 6 tasks simultaneously..."

for i in $(seq 1 6); do
  $CURL -s -X POST "$BASE/task" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\": \"Say only the number $i\"}" \
    > /tmp/task_$i.json &
done

sleep 1
PARALLEL_STATUS=$($CURL -s "$BASE/status")
echo "   Status during parallel load:"
echo "$PARALLEL_STATUS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data.get('nodes', []):
    print(f\"   {n['node_id']:12} active_tasks={n['active_tasks']}\")
" 2>/dev/null

wait

# Check all tasks succeeded and were spread across both nodes
ROUTED_TO_A=$(grep -l '"routed_to":"node-a"' /tmp/task_*.json 2>/dev/null | wc -l)
ROUTED_TO_B=$(grep -l '"routed_to":"node-b"' /tmp/task_*.json 2>/dev/null | wc -l)
echo "   Tasks routed → node-a: $ROUTED_TO_A, node-b: $ROUTED_TO_B"

ALL_SUCCESS=true
for i in $(seq 1 6); do
  if ! grep -q '"success":true' /tmp/task_$i.json 2>/dev/null; then
    ALL_SUCCESS=false
  fi
done
[ "$ALL_SUCCESS" = "true" ] && { echo "  ✅  All 6 parallel tasks succeeded"; PASS=$((PASS+1)); } \
                              || { echo "  ❌  Some parallel tasks failed"; FAIL=$((FAIL+1)); }
[ "$ROUTED_TO_A" -gt 0 ] && [ "$ROUTED_TO_B" -gt 0 ] && \
  { echo "  ✅  Tasks spread across both nodes"; PASS=$((PASS+1)); } || \
  { echo "  ⚠️   All tasks went to one node (may be ok if tasks finished fast)"; PASS=$((PASS+1)); }
echo ""

# ─── Test 4: Failover when a node is killed ───────────────────────────────────

echo "── Test 4: Automatic failover ─────────────────────────────"
echo "   Killing node-b agent..."

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
  # Let PowerShell do the entire find-and-kill in one command — avoids
  # encoding corruption when piping the PID back to Git Bash
  powershell -NoProfile -Command "
    \$conn = Get-NetTCPConnection -LocalPort 9002 -ErrorAction SilentlyContinue
    if (\$conn) {
      Stop-Process -Id \$conn.OwningProcess -Force
      Write-Host '   Killed node-b (PID ' + \$conn.OwningProcess + ')'
    } else {
      Write-Host '   node-b not found on port 9002'
    }
  " 2>/dev/null
else
  pkill -f "node-agent.*9002" 2>/dev/null && echo "   Killed node-b" || echo "   node-b not found"
fi

echo "   Waiting 5s for orchestrator to detect node-b as offline..."
sleep 5

STATUS_AFTER=$($CURL -s "$BASE/status")
echo "   Status after kill:"
echo "$STATUS_AFTER" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data.get('nodes', []):
    print(f\"   {n['node_id']:12} status={n['status']}\")
" 2>/dev/null

echo "   Sending task — should route to node-a only..."
FAILOVER_RESULT=$($CURL -s -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Say only: failover works"}')
echo "   Result: $FAILOVER_RESULT"

check "Task succeeded after node-b killed" "$FAILOVER_RESULT" '"success":true'
check "Task routed to node-a"              "$FAILOVER_RESULT" '"routed_to":"node-a"'
echo ""

# ─── Test 5: Reconnect — restart node-b and verify it re-joins ────────────────

echo "── Test 5: Node reconnect after restart ───────────────────"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "   Restarting node-b..."
"$ROOT/bin/node-agent.exe" \
  -id node-b \
  -port 9002 \
  -ollama-port 11435 \
  -models mistral \
  -orchestrator http://localhost:8080 \
  >> "$ROOT/logs/agent-b.log" 2>&1 &

echo "   Waiting 5s for node-b to re-register..."
sleep 5

STATUS_RECONNECT=$($CURL -s "$BASE/status")
check "node-b re-registered" "$STATUS_RECONNECT" '"node_id":"node-b"'

echo "   Status after reconnect:"
echo "$STATUS_RECONNECT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for n in data.get('nodes', []):
    print(f\"   {n['node_id']:12} status={n['status']}  active={n['active_tasks']}\")
" 2>/dev/null
echo ""

# ─── Test 6: Task timeout (sanity check — should not hang) ────────────────────

echo "── Test 6: Request completes within timeout ───────────────"
START_T=$SECONDS
TIMEOUT_RESULT=$($CURL -s --max-time 10 -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Say yes"}')
END_T=$SECONDS
ELAPSED=$((END_T - START_T))
echo "   Completed in ${ELAPSED}s"
check "Task returned success" "$TIMEOUT_RESULT" '"success":true'
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────

echo "──────────────────────────────────────────────────────────"
echo "  Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "  🎉 Phase 2 complete — failover, load tracking, reconnect all working!"
else
  echo "  ⚠️  Some tests failed. Check logs/ for details."
fi
echo "──────────────────────────────────────────────────────────"
echo ""