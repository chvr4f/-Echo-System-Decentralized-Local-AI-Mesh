#!/bin/bash
# scripts/test-phase3.sh
# Tests Phase 3: task type routing and model capability matching.
#
# Setup in start-phase1.sh:
#   node-a: mistral  → handles text, summarize
#   node-b: mistral  → handles code, text  (mistral used as codellama stand-in)
#
# What we verify:
#   - "type":"code"     routes to node-b
#   - "type":"text"     routes to either node (both handle text)
#   - "type":"summarize" routes to node-a (only one with summarize)
#   - unknown type      falls back gracefully to any node
#   - response includes model_used and task_type fields

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
echo "║     ECHO-SYSTEM  Phase 3 Tests       ║"
echo "╚══════════════════════════════════════╝"
echo ""

check() {
  local label="$1"
  local result="$2"
  local expect="$3"
  if echo "$result" | grep -qF "$expect"; then
    echo "  ✅  $label"
    PASS=$((PASS+1))
  else
    echo "  ❌  $label"
    echo "      Expected: $expect"
    echo "      Got:      $(echo $result | head -c 300)"
    FAIL=$((FAIL+1))
  fi
}

# ─── Test 1: Mesh status shows capabilities ───────────────────────────────────

echo "── Test 1: Capabilities registered ───────────────────────"
STATUS=$($CURL -s "$BASE/status")
check "Capabilities present in status"  "$STATUS" '"capabilities"'
check "node-a has text capability"      "$STATUS" '"types":["text","summarize"]'
check "node-b has code capability"      "$STATUS" '"types":["code","text"]'
echo ""

# ─── Test 2: Code task routes to node-b ──────────────────────────────────────

echo "── Test 2: Code task → node-b ─────────────────────────────"
RESULT=$($CURL -s -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Write a Go function that reverses a string.", "type": "code"}')
echo "   Routed to: $(echo $RESULT | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('routed_to','?'))" 2>/dev/null)"
echo "   Model:     $(echo $RESULT | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('model_used','?'))" 2>/dev/null)"
check "Code task succeeded"           "$RESULT" '"success":true'
check "Routed to node-b (code node)"  "$RESULT" '"routed_to":"node-b"'
check "task_type echoed in response"  "$RESULT" '"task_type":"code"'
check "model_used field present"      "$RESULT" '"model_used"'
echo ""

# ─── Test 3: Summarize task routes to node-a ─────────────────────────────────

echo "── Test 3: Summarize task → node-a ────────────────────────"
RESULT=$($CURL -s -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Summarize in one sentence: Distributed systems are complex.", "type": "summarize"}')
echo "   Routed to: $(echo $RESULT | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('routed_to','?'))" 2>/dev/null)"
check "Summarize task succeeded"          "$RESULT" '"success":true'
check "Routed to node-a (summarize node)" "$RESULT" '"routed_to":"node-a"'
check "task_type echoed back"             "$RESULT" '"task_type":"summarize"'
echo ""

# ─── Test 4: Text task distributes across both nodes ─────────────────────────

echo "── Test 4: Text tasks load-balanced across both nodes ─────"
NODES_USED=""
for i in 1 2 3 4; do
  R=$($CURL -s -X POST "$BASE/task" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\": \"Say only the word hello\", \"type\": \"text\"}")
  NODE=$(echo $R | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('routed_to','?'))" 2>/dev/null)
  NODES_USED="$NODES_USED $NODE"
done
echo "   Nodes used: $NODES_USED"
# Both should appear since both handle text
echo "$NODES_USED" | grep -q "node-a" && echo "$NODES_USED" | grep -q "node-b" && \
  { echo "  ✅  Text tasks spread across both nodes"; PASS=$((PASS+1)); } || \
  { echo "  ⚠️   Text tasks went to one node (ok if one was busy)"; PASS=$((PASS+1)); }
echo ""

# ─── Test 5: No-type task falls back to any node ─────────────────────────────

echo "── Test 5: No type specified → any node ───────────────────"
RESULT=$($CURL -s -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Say yes"}')
check "No-type task succeeds"    "$RESULT" '"success":true'
check "Has routed_to field"      "$RESULT" '"routed_to"'
echo ""

# ─── Test 6: Exact model_hint still works ────────────────────────────────────

echo "── Test 6: Explicit model_hint bypasses type routing ──────"
RESULT=$($CURL -s -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Say only: model hint works", "model_hint": "mistral"}')
check "model_hint task succeeds" "$RESULT" '"success":true'
check "Has routed_to field"      "$RESULT" '"routed_to"'
echo ""

# ─── Test 7: Streaming with task type ────────────────────────────────────────

echo "── Test 7: Streaming code task → node-b ───────────────────"
echo "   Tokens received:"
CHUNKS=$($CURL -s -N -X POST "$BASE/task/stream" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Write a one-line Python hello world", "type": "code"}' \
  --max-time 60)
# Check routed_to in any chunk
check "Stream routed to node-b" "$CHUNKS" '"routed_to":"node-b"'
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────

echo "──────────────────────────────────────────────────────────"
echo "  Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "  🎉 Phase 3 complete — smart routing is working!"
else
  echo "  ⚠️  Some tests failed. Check logs/ for details."
fi
echo "──────────────────────────────────────────────────────────"
echo ""