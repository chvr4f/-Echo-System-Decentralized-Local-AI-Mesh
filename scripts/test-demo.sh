#!/bin/bash
# scripts/test-demo.sh
# Comprehensive demo tests for screenshot documentation.
#
# Current mesh topology:
#   windows-11      (192.168.1.7:9001)  → mistral   [text, summarize]
#   windows-code    (192.168.1.7:9002)  → mistral   [code]
#   ubuntu-vision   (192.168.1.11:9004) → moondream [vision, text]
#
# Tests cover:
#   1. Mesh status & node discovery
#   2. Routing table & capability matching
#   3. Text tasks → windows-11
#   4. Code tasks → ubuntu-code
#   5. Summarize tasks → windows-11
#   6. Vision tasks → ubuntu-vision
#   7. Streaming responses
#   8. Pipeline (multi-step chaining)
#   9. Load balancing / failover
#  10. Health checks
#  11. Dashboard availability

BASE="http://localhost:8080"
PASS=0
FAIL=0
TOTAL=0

# Use curl.exe on MSYS/Git Bash to reach Windows-bound localhost
if command -v curl.exe &>/dev/null; then
  CURL="curl.exe"
else
  CURL="curl"
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

check() {
  local label="$1"
  local result="$2"
  local expect="$3"
  TOTAL=$((TOTAL+1))
  if echo "$result" | grep -qiF "$expect"; then
    echo "  ✅  $label"
    PASS=$((PASS+1))
  else
    echo "  ❌  $label"
    echo "      Expected: $expect"
    echo "      Got:      $(echo "$result" | head -c 300)"
    FAIL=$((FAIL+1))
  fi
}

check_regex() {
  local label="$1"
  local result="$2"
  local pattern="$3"
  TOTAL=$((TOTAL+1))
  if echo "$result" | grep -qiE "$pattern"; then
    echo "  ✅  $label"
    PASS=$((PASS+1))
  else
    echo "  ❌  $label"
    echo "      Pattern: $pattern"
    echo "      Got:     $(echo "$result" | head -c 300)"
    FAIL=$((FAIL+1))
  fi
}

check_not() {
  local label="$1"
  local result="$2"
  local reject="$3"
  TOTAL=$((TOTAL+1))
  if echo "$result" | grep -qiF "$reject"; then
    echo "  ❌  $label"
    echo "      Should NOT contain: $reject"
    echo "      Got:      $(echo "$result" | head -c 300)"
    FAIL=$((FAIL+1))
  else
    echo "  ✅  $label"
    PASS=$((PASS+1))
  fi
}

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        ECHO-SYSTEM  Comprehensive Demo Tests            ║"
echo "║        3-Node Distributed AI Mesh                       ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  windows-11    │ mistral   │ text, summarize            ║"
echo "║  windows-code  │ mistral   │ code                       ║"
echo "║  ubuntu-vision │ moondream │ vision, text               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 1: MESH STATUS & NODE DISCOVERY
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 1: Mesh Status & Node Discovery"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

STATUS=$($CURL -s "$BASE/status")

check "1.1  Orchestrator responds" "$STATUS" "node_count"
check "1.2  Three nodes registered" "$STATUS" '"node_count":3'
check "1.3  windows-11 is present" "$STATUS" "windows-11"
check "1.4  windows-code is present" "$STATUS" "windows-code"
check "1.5  ubuntu-vision is present" "$STATUS" "ubuntu-vision"
check "1.6  windows-11 is idle" "$STATUS" '"node_id":"windows-11"'
check "1.7  All nodes have heartbeats" "$STATUS" "last_heartbeat"
check "1.8  server_time is present" "$STATUS" "server_time"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 2: ROUTING TABLE & CAPABILITY MATCHING
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 2: Routing Table & Capability Matching"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ROUTING=$($CURL -s "$BASE/debug/routing")

check "2.1  Routing endpoint responds" "$ROUTING" "routing"
check "2.2  Code routes to windows-code" "$ROUTING" '"code":"windows-code'
check "2.3  Summarize routes to windows-11" "$ROUTING" '"summarize":"windows-11'
check "2.4  Text routing available" "$ROUTING" '"text":'

# Capabilities checks
check "2.5  windows-11 has mistral model" "$STATUS" '"node_id":"windows-11"'
check "2.6  windows-code has code capability" "$ROUTING" '"code":"windows-code'
check "2.7  ubuntu-vision has moondream" "$STATUS" '"models":["moondream"]'
check "2.8  ubuntu-vision has vision type" "$STATUS" '"types":["vision","text"]'

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3: TEXT TASK → windows-11
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 3: Text Task Routing (any text-capable node)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  ⏳ Sending text task (may take 30-120s on VM)..."
TEXT_RESULT=$($CURL -s -m 300 "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"What is artificial intelligence? Answer in 2 sentences.","type":"text"}')

check "3.1  Text task succeeded" "$TEXT_RESULT" '"success":true'
check_regex "3.2  Routed to a text node" "$TEXT_RESULT" '"routed_to":"(windows-11|ubuntu-code|ubuntu-vision)"'
check "3.3  Task type echoed back" "$TEXT_RESULT" '"task_type":"text"'
check "3.4  Has content" "$TEXT_RESULT" '"content":'
check "3.5  Has latency_ms" "$TEXT_RESULT" '"latency_ms":'
check "3.6  Has task_id" "$TEXT_RESULT" '"task_id":'
check "3.7  Response is non-empty" "$TEXT_RESULT" '"success":true'

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 4: CODE TASK → ubuntu-code
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 4: Code Task Routing → windows-code"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  ⏳ Sending code task (VM may take 2-4 min)..."
CODE_RESULT=$($CURL -s -m 300 "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Write a Python hello world one-liner","type":"code"}')

check "4.1  Code task succeeded" "$CODE_RESULT" '"success":true'
check_regex "4.2  Routed to code-capable node" "$CODE_RESULT" '"routed_to":"(windows-code|windows-11)"'
check "4.3  Task type is code" "$CODE_RESULT" '"task_type":"code"'
check "4.4  Has model_used" "$CODE_RESULT" '"model_used":'
check "4.5  Has content" "$CODE_RESULT" '"content":'
check_regex "4.6  Content has code" "$CODE_RESULT" "(print|hello|def |function )"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 5: SUMMARIZE TASK → windows-11
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 5: Summarize Task Routing → windows-11"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  ⏳ Sending summarize task (may take 30-120s)..."
SUMM_RESULT=$($CURL -s -m 300 "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Summarize in one sentence: Machine learning lets computers learn from data.","type":"summarize"}')

check "5.1  Summarize task succeeded" "$SUMM_RESULT" '"success":true'
check "5.2  Routed to windows-11" "$SUMM_RESULT" '"routed_to":"windows-11"'
check "5.3  Task type is summarize" "$SUMM_RESULT" '"task_type":"summarize"'
check "5.4  Has content" "$SUMM_RESULT" '"content":'

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 6: VISION TASK → ubuntu-vision
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 6: Vision Task Routing → ubuntu-vision"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  ⏳ Sending vision task (VM may take 2-4 min)..."
VISION_RESULT=$($CURL -s -m 300 "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Describe a sunset briefly.","type":"vision"}')

check "6.1  Vision task succeeded" "$VISION_RESULT" '"success":true'
check_regex "6.2  Routed to vision node" "$VISION_RESULT" '"routed_to":"(ubuntu-vision|windows-11)"'
check "6.3  Task type is vision" "$VISION_RESULT" '"task_type":"vision"'
check "6.4  Has content" "$VISION_RESULT" '"content":'
check "6.5  Has model_used" "$VISION_RESULT" '"model_used":'

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 7: STREAMING RESPONSE
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 7: Streaming Response (SSE)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  ⏳ Sending streaming task (may take 30-120s)..."
STREAM_RESULT=$($CURL -s -m 300 "$BASE/task/stream" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Say hello","type":"text"}')

check "7.1  Stream returns data" "$STREAM_RESULT" "data:"
check "7.2  Stream has tokens" "$STREAM_RESULT" '"token":'
check "7.3  Stream has task_id" "$STREAM_RESULT" '"task_id":'
check "7.4  Stream ends with done" "$STREAM_RESULT" '"done":true'
check "7.5  Stream routed to a node" "$STREAM_RESULT" '"routed_to":'

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 8: PIPELINE (Multi-step Chaining)
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 8: Pipeline (Multi-step Task Chaining)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  ⏳ Sending 2-step pipeline (text → summarize, may take 3-6 min)..."
PIPE_RESULT=$($CURL -s -m 600 "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{
    "initial_input": "What is AI?",
    "steps": [
      {"type": "text", "prompt_template": "{{initial_input}}"},
      {"type": "summarize", "prompt_template": "Summarize: {{prev_output}}"}
    ]
  }')

check "8.1  Pipeline succeeded" "$PIPE_RESULT" '"success":true'
check "8.2  Has pipeline_id" "$PIPE_RESULT" '"pipeline_id":'
check "8.3  Two steps completed" "$PIPE_RESULT" '"total_steps":2'
check "8.4  Has final_output" "$PIPE_RESULT" '"final_output":'
check_regex "8.5  Steps routed to nodes" "$PIPE_RESULT" '"routed_to":"(windows-code|ubuntu-vision|windows-11)"'
check "8.6  Has latency_ms" "$PIPE_RESULT" '"latency_ms":'

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 9: EDGE CASES & ERROR HANDLING
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 9: Edge Cases & Error Handling"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Empty prompt
EMPTY=$($CURL -s -o /dev/null -w "%{http_code}" "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt":""}')
check "9.1  Empty prompt returns 400" "$EMPTY" "400"

# Invalid JSON
INVALID=$($CURL -s -o /dev/null -w "%{http_code}" "$BASE/task" \
  -H "Content-Type: application/json" \
  -d 'not json')
check "9.2  Invalid JSON returns 400" "$INVALID" "400"

# No type (should still route)
echo "  ⏳ Sending task with no type (any routing)..."
NOTYPE=$($CURL -s -m 300 "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"What is 2+2?"}')
check "9.3  No-type task still succeeds" "$NOTYPE" '"success":true'
check "9.4  No-type task has routed_to" "$NOTYPE" '"routed_to":'

# Explicit model hint
echo "  ⏳ Sending task with model_hint..."
HINT_RESULT=$($CURL -s -m 300 "$BASE/task" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Say hi","type":"text","model_hint":"mistral"}')
check "9.5  Model hint task succeeded" "$HINT_RESULT" '"success":true'
check "9.6  Model hint used correctly" "$HINT_RESULT" '"model_used":"mistral"'

# Pipeline with empty steps
EMPTY_PIPE=$($CURL -s -o /dev/null -w "%{http_code}" "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{"initial_input":"test","steps":[]}')
check "9.7  Empty pipeline returns 400" "$EMPTY_PIPE" "400"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 10: HEALTH CHECKS
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 10: Health Checks"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Orchestrator status endpoint
ORCH_HTTP=$($CURL -s -o /dev/null -w "%{http_code}" "$BASE/status")
check "10.1 Orchestrator HTTP 200" "$ORCH_HTTP" "200"

# Node-agent health (windows-11 is local)
AGENT_HEALTH=$($CURL -s "http://localhost:9001/health")
check "10.2 windows-11 agent health OK" "$AGENT_HEALTH" "ok"

# Routing endpoint
ROUTE_HTTP=$($CURL -s -o /dev/null -w "%{http_code}" "$BASE/debug/routing")
check "10.3 Routing endpoint HTTP 200" "$ROUTE_HTTP" "200"

# All nodes are idle (post-tasks)
STATUS_POST=$($CURL -s "$BASE/status")
check_regex "10.4 Nodes returned to idle" "$STATUS_POST" '"status":"idle"'

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 11: DASHBOARD
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 11: Dashboard Availability"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

DASH_HTTP=$($CURL -s -o /dev/null -w "%{http_code}" "$BASE/dashboard/")
check "11.1 Dashboard serves HTML (200)" "$DASH_HTTP" "200"

DASH_CONTENT=$($CURL -s "$BASE/dashboard/")
check "11.2 Dashboard has HTML content" "$DASH_CONTENT" "<html"
check "11.3 Dashboard has React" "$DASH_CONTENT" "react"

# Dashboard redirect
DASH_REDIR=$($CURL -s -o /dev/null -w "%{http_code}" "$BASE/dashboard")
check_regex "11.4 /dashboard redirects" "$DASH_REDIR" "30[12]"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 12: MULTI-NODE STATUS DETAILS
# ═══════════════════════════════════════════════════════════════════════════════

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SECTION 12: Multi-Node Infrastructure Details"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

FINAL_STATUS=$($CURL -s "$BASE/status")

# Windows node
check "12.1 windows-11 host is 192.168.1.7" "$FINAL_STATUS" '"agent_host":"192.168.1.7"'
check "12.2 windows-11 on port 9001" "$FINAL_STATUS" '"agent_port":9001'

# Windows code node
check "12.3 windows-code on port 9002" "$FINAL_STATUS" '"agent_port":9002'
# Ubuntu vision node
check "12.4 ubuntu-vision on port 9004" "$FINAL_STATUS" '"agent_port":9004'

# Models
check "12.5 mistral model present" "$FINAL_STATUS" '"models":["mistral"]'
check "12.6 moondream model present" "$FINAL_STATUS" '"models":["moondream"]'

# Registered timestamps
check "12.7 Nodes have registered_at" "$FINAL_STATUS" '"registered_at":'

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    TEST RESULTS                         ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  Total:  %-3d                                           ║\n" $TOTAL
printf "║  Passed: %-3d  ✅                                       ║\n" $PASS
printf "║  Failed: %-3d  ❌                                       ║\n" $FAIL
echo "╠══════════════════════════════════════════════════════════╣"

if [ $FAIL -eq 0 ]; then
  echo "║          🎉  ALL TESTS PASSED!  🎉                     ║"
else
  echo "║          ⚠️   SOME TESTS FAILED                        ║"
fi

echo "╚══════════════════════════════════════════════════════════╝"
echo ""

exit $FAIL
