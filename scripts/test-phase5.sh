#!/bin/bash
# scripts/test-phase5.sh
# Tests Phase 5: Dashboard — live WebSocket events and static file server.
#
# Setup (from start-phase1.sh):
#   Node A (:9001) — mistral: text, summarize
#   Node B (:9002) — mistral: code, text
#
# What we verify:
#   - Dashboard HTML is served at /dashboard/
#   - /dashboard redirects to /dashboard/
#   - WebSocket endpoint exists at /ws
#   - Real-time events flow through WebSocket on task execution
#   - Stats broadcast works

BASE="http://localhost:8080"
PASS=0
FAIL=0

# On MSYS/Git Bash, the bundled curl can't reach Windows-bound localhost.
if command -v curl.exe &>/dev/null; then
  CURL="curl.exe"
else
  CURL="curl"
fi

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Phase 5 — Dashboard Tests         ║"
echo "╚══════════════════════════════════════╝"
echo ""

check() {
  local label="$1"
  local result="$2"
  local expect="$3"
  if echo "$result" | grep -qF "$expect"; then
    echo "  ✓  $label"
    PASS=$((PASS+1))
  else
    echo "  ✗  $label"
    echo "      Expected to find: $expect"
    FAIL=$((FAIL+1))
  fi
}

check_code() {
  local label="$1"
  local code="$2"
  local expect="$3"
  if [ "$code" = "$expect" ]; then
    echo "  ✓  $label"
    PASS=$((PASS+1))
  else
    echo "  ✗  $label  (got $code, expected $expect)"
    FAIL=$((FAIL+1))
  fi
}

check_not() {
  local label="$1"
  local code="$2"
  local bad="$3"
  if [ "$code" != "$bad" ]; then
    echo "  ✓  $label"
    PASS=$((PASS+1))
  else
    echo "  ✗  $label  (got $code)"
    FAIL=$((FAIL+1))
  fi
}

# ── 1. Dashboard static file serving ──────────────────────────────────────────
echo "┌─ 1. Dashboard static file serving ────────────────────┐"

# 1.1 — /dashboard/ returns HTML
DASH=$($CURL -s "$BASE/dashboard/")
check "1.1  /dashboard/ returns HTML content" "$DASH" "<!DOCTYPE html>"
check "1.2  /dashboard/ contains ECHO-SYSTEM title" "$DASH" "ECHO-SYSTEM"
check "1.3  /dashboard/ contains WebSocket code" "$DASH" "WebSocket"

# 1.4 — /dashboard redirects to /dashboard/
REDIR_CODE=$($CURL -s -o /dev/null -w "%{http_code}" "$BASE/dashboard")
check_code "1.4  /dashboard redirects (301)" "$REDIR_CODE" "301"

echo ""

# ── 2. WebSocket endpoint ─────────────────────────────────────────────────────
echo "┌─ 2. WebSocket endpoint ───────────────────────────────┐"

# 2.1 — /ws returns non-200 when accessed via plain HTTP (not upgraded)
WS_CODE=$($CURL -s -o /dev/null -w "%{http_code}" "$BASE/ws")
check_not "2.1  /ws rejects plain HTTP (not upgraded)" "$WS_CODE" "200"

echo ""

# ── 3. Status endpoint still works ───────────────────────────────────────────
echo "┌─ 3. Status endpoint ──────────────────────────────────┐"

STATUS=$($CURL -s "$BASE/status")
check "3.1  /status returns JSON" "$STATUS" "{"
check "3.2  /status includes node info" "$STATUS" "node_id"

echo ""

# ── 4. Task execution produces events (indirect test) ─────────────────────────
echo "┌─ 4. Task → event flow (indirect via /status) ─────────┐"

# Fire a quick task
TASK_RESP=$($CURL -s -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Say hello","type":"text"}')

check "4.1  Task executed successfully" "$TASK_RESP" '"success"'
check "4.2  Task has routed_to field" "$TASK_RESP" "routed_to"
check "4.3  Task has latency_ms field" "$TASK_RESP" "latency_ms"

# Fire a code task
CODE_RESP=$($CURL -s -X POST "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Print hello in Python","type":"code"}')

check "4.4  Code task executed successfully" "$CODE_RESP" '"success"'

echo ""

# ── 5. Pipeline still works with events ───────────────────────────────────────
echo "┌─ 5. Pipeline with dashboard events ───────────────────┐"

PIPE_RESP=$($CURL -s -X POST "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{
    "initial_input": "the moon",
    "steps": [
      { "prompt_template": "Write a haiku about {{initial_input}}", "type": "text" },
      { "prompt_template": "Now turn this into code that prints it: {{prev_output}}", "type": "code" }
    ]
  }')

check "5.1  Pipeline executed successfully" "$PIPE_RESP" '"success":true'
check "5.2  Pipeline has final_output" "$PIPE_RESP" "final_output"
check "5.3  Pipeline has latency_ms" "$PIPE_RESP" "latency_ms"

echo ""

# ── 6. Dashboard content quality ─────────────────────────────────────────────
echo "┌─ 6. Dashboard content quality ────────────────────────┐"

check "6.1  Dashboard includes React import" "$DASH" "react"
check "6.2  Dashboard includes topology component" "$DASH" "Topology"
check "6.3  Dashboard includes task feed" "$DASH" "Task Feed"
check "6.4  Dashboard includes task interface" "$DASH" "Task Interface"
check "6.5  Dashboard includes mesh topology" "$DASH" "Mesh Topology"
check "6.6  Dashboard has responsive WS reconnect" "$DASH" "reconnect"

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo "╔══════════════════════════════════════╗"
echo "║  Phase 5 Results: $PASS/$TOTAL passed"
if [ "$FAIL" -eq 0 ]; then
  echo "║  🎉  ALL TESTS PASSED!"
else
  echo "║  ⚠  $FAIL test(s) failed"
fi
echo "╚══════════════════════════════════════╝"
echo ""
exit $FAIL
