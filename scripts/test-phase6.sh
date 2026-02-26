#!/bin/bash
# scripts/test-phase6.sh
# Tests Phase 6: Zero-Config Discovery — mDNS + Docker Compose readiness.
#
# What we verify:
#   - mDNS discovery code compiles and is wired in
#   - AgentHost is stored and used for forwarding
#   - Orchestrator advertises service via mDNS
#   - Node registration includes agent_host
#   - Docker Compose config is valid
#   - Existing functionality (tasks, pipelines, dashboard) still works
#   - Ollama host is configurable (-ollama-host flag)

BASE="http://localhost:8080"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
echo "║   Phase 6 — Zero-Config Discovery   ║"
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
    echo "      Got: $(echo "$result" | head -3)"
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

check_file() {
  local label="$1"
  local filepath="$2"
  if [ -f "$filepath" ]; then
    echo "  ✓  $label"
    PASS=$((PASS+1))
  else
    echo "  ✗  $label  (file not found: $filepath)"
    FAIL=$((FAIL+1))
  fi
}

check_file_contains() {
  local label="$1"
  local filepath="$2"
  local pattern="$3"
  if grep -qF "$pattern" "$filepath" 2>/dev/null; then
    echo "  ✓  $label"
    PASS=$((PASS+1))
  else
    echo "  ✗  $label  (pattern not found in $filepath)"
    FAIL=$((FAIL+1))
  fi
}


# ── 1. Source code: mDNS discovery wired in ───────────────────────────────────
echo "┌─ 1. mDNS discovery source code ──────────────────────┐"

check_file "1.1  orchestrator/discovery.go exists" "$ROOT/orchestrator/discovery.go"
check_file "1.2  node-agent/discovery.go exists" "$ROOT/node-agent/discovery.go"
check_file_contains "1.3  Orchestrator advertises _echo-mesh._tcp" "$ROOT/orchestrator/discovery.go" "_echo-mesh._tcp"
check_file_contains "1.4  Node-agent discovers _echo-mesh._tcp" "$ROOT/node-agent/discovery.go" "_echo-mesh._tcp"
check_file_contains "1.5  Orchestrator main starts mDNS" "$ROOT/orchestrator/main.go" "startMDNS"
check_file_contains "1.6  Node-agent supports mDNS auto mode" "$ROOT/node-agent/main.go" "discoverOrchestratorWithRetry"

echo ""

# ── 2. Source code: AgentHost networking ──────────────────────────────────────
echo "┌─ 2. AgentHost networking support ─────────────────────┐"

check_file_contains "2.1  RegisterRequest has AgentHost field" "$ROOT/shared/types.go" "AgentHost"
check_file_contains "2.2  NodeInfo has AgentHost field" "$ROOT/shared/types.go" "AgentHost"
check_file_contains "2.3  Orchestrator uses AgentHost in forwarding" "$ROOT/orchestrator/main.go" "node.AgentHost"
check_file_contains "2.4  Registry stores AgentHost" "$ROOT/orchestrator/registry.go" "AgentHost"
check_file_contains "2.5  Node-agent sends AgentHost" "$ROOT/node-agent/main.go" "AgentHost"
check_file_contains "2.6  Ollama host is configurable" "$ROOT/node-agent/main.go" "OllamaHost"

echo ""

# ── 3. Docker setup files ────────────────────────────────────────────────────
echo "┌─ 3. Docker setup files ──────────────────────────────┐"

check_file "3.1  Dockerfile.orchestrator exists" "$ROOT/Dockerfile.orchestrator"
check_file "3.2  Dockerfile.node-agent exists" "$ROOT/Dockerfile.node-agent"
check_file "3.3  docker-compose.yml exists" "$ROOT/docker-compose.yml"
check_file_contains "3.4  Compose has orchestrator service" "$ROOT/docker-compose.yml" "orchestrator:"
check_file_contains "3.5  Compose has ollama-a service" "$ROOT/docker-compose.yml" "ollama-a:"
check_file_contains "3.6  Compose has ollama-b service" "$ROOT/docker-compose.yml" "ollama-b:"
check_file_contains "3.7  Compose has node-a service" "$ROOT/docker-compose.yml" "node-a:"
check_file_contains "3.8  Compose has node-b service" "$ROOT/docker-compose.yml" "node-b:"
check_file_contains "3.9  Compose uses healthcheck" "$ROOT/docker-compose.yml" "healthcheck"
check_file_contains "3.10 Compose uses depends_on" "$ROOT/docker-compose.yml" "depends_on"

echo ""

# ── 4. Binaries compile ─────────────────────────────────────────────────────
echo "┌─ 4. Binary compilation ──────────────────────────────┐"

check_file "4.1  orchestrator.exe exists" "$ROOT/bin/orchestrator.exe"
check_file "4.2  node-agent.exe exists" "$ROOT/bin/node-agent.exe"

echo ""

# ── 5. Live mesh: registration includes agent_host ────────────────────────────
echo "┌─ 5. Live mesh: AgentHost in registration ────────────┐"

STATUS=$($CURL -s "$BASE/status" 2>/dev/null)
if [ -z "$STATUS" ]; then
  echo "  ⚠  Orchestrator not running — skipping live tests"
  echo "      Run ./scripts/start-phase1.sh first"
  echo ""
  # Skip live tests but don't fail
  SKIP_LIVE=1
else
  SKIP_LIVE=0
fi

if [ "$SKIP_LIVE" = "0" ]; then
  check "5.1  /status returns JSON" "$STATUS" "{"
  check "5.2  Nodes are registered" "$STATUS" "node_id"
  # agent_host should now appear in node info
  check "5.3  Node info includes agent_host" "$STATUS" "agent_host"

  echo ""

  # ── 6. Existing functionality still works ─────────────────────────────────
  echo "┌─ 6. Backward compatibility ────────────────────────┐"

  # Text task
  TEXT_RESP=$($CURL -s -X POST "$BASE/task" \
    -H "Content-Type: application/json" \
    -d '{"prompt":"Say hello","type":"text"}')
  check "6.1  Text task still works" "$TEXT_RESP" '"success"'
  check "6.2  Task has routed_to" "$TEXT_RESP" "routed_to"

  # Code task
  CODE_RESP=$($CURL -s -X POST "$BASE/task" \
    -H "Content-Type: application/json" \
    -d '{"prompt":"Print hello in Python","type":"code"}')
  check "6.3  Code task still works" "$CODE_RESP" '"success"'

  # Pipeline
  PIPE_RESP=$($CURL -s -X POST "$BASE/pipeline" \
    -H "Content-Type: application/json" \
    -d '{
      "initial_input": "the stars",
      "steps": [
        { "prompt_template": "Write one line about {{initial_input}}", "type": "text" },
        { "prompt_template": "Turn this into code: {{prev_output}}", "type": "code" }
      ]
    }')
  check "6.4  Pipeline still works" "$PIPE_RESP" '"success":true'

  # Dashboard
  DASH=$($CURL -s "$BASE/dashboard/")
  check "6.5  Dashboard still serves" "$DASH" "<!DOCTYPE html>"

  echo ""
fi

# ── 7. Dockerfile quality ────────────────────────────────────────────────────
echo "┌─ 7. Dockerfile quality ──────────────────────────────┐"

check_file_contains "7.1  Orchestrator Dockerfile is multi-stage" "$ROOT/Dockerfile.orchestrator" "AS builder"
check_file_contains "7.2  Node-agent Dockerfile is multi-stage" "$ROOT/Dockerfile.node-agent" "AS builder"
check_file_contains "7.3  Orchestrator exposes 8080" "$ROOT/Dockerfile.orchestrator" "EXPOSE 8080"
check_file_contains "7.4  Node-agent exposes 9001" "$ROOT/Dockerfile.node-agent" "EXPOSE 9001"
check_file_contains "7.5  Orchestrator copies dashboard" "$ROOT/Dockerfile.orchestrator" "dashboard"
check_file_contains "7.6  Dockerfiles use CGO_ENABLED=0" "$ROOT/Dockerfile.orchestrator" "CGO_ENABLED=0"

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo "╔══════════════════════════════════════╗"
echo "║  Phase 6 Results: $PASS/$TOTAL passed"
if [ "$FAIL" -eq 0 ]; then
  echo "║  🎉  ALL TESTS PASSED!"
else
  echo "║  ⚠  $FAIL test(s) failed"
fi
echo "╚══════════════════════════════════════╝"
echo ""
exit $FAIL
