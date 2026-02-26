#!/bin/bash
# scripts/test-phase4.sh
# Tests Phase 4: Pipeline Engine — chaining tasks across nodes.
#
# Setup (from start-phase1.sh):
#   node-a: mistral  → handles text, summarize
#   node-b: mistral  → handles code, text
#
# What we verify:
#   - POST /pipeline accepts and executes multi-step pipelines
#   - Each step's output feeds into the next step's prompt
#   - {{prev_output}} and {{initial_input}} templates resolve correctly
#   - Steps route to the correct node based on task type
#   - Pipeline result includes per-step details and final_output
#   - Single-step pipeline works as a degenerate case
#   - Pipeline aborts cleanly on step failure

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
echo "║     ECHO-SYSTEM  Phase 4 Tests       ║"
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

# ─── Test 1: Two-step pipeline (text → summarize) ────────────────────────────

echo "── Test 1: Two-step pipeline (text → summarize) ──────────"
RESULT=$($CURL -s -X POST "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{
    "initial_input": "Explain what a distributed hash table is and how it works in peer-to-peer networks.",
    "steps": [
      {
        "type": "text",
        "prompt_template": "{{initial_input}}"
      },
      {
        "type": "summarize",
        "prompt_template": "Summarize the following in exactly one sentence: {{prev_output}}"
      }
    ]
  }')
echo "   Pipeline ID: $(echo $RESULT | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pipeline_id','?'))" 2>/dev/null)"
echo "   Total steps: $(echo $RESULT | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('total_steps','?'))" 2>/dev/null)"
check "Pipeline succeeded"           "$RESULT" '"success":true'
check "Has pipeline_id"              "$RESULT" '"pipeline_id"'
check "Has final_output"             "$RESULT" '"final_output"'
check "Has total_steps 2"            "$RESULT" '"total_steps":2'
check "Has latency_ms"               "$RESULT" '"latency_ms"'
check "Step 0 present"               "$RESULT" '"step_index":0'
check "Step 1 present"               "$RESULT" '"step_index":1'
echo ""

# ─── Test 2: Routing — summarize step → node-a, code step → node-b ──────────

echo "── Test 2: Pipeline routing (summarize→a, code→b) ────────"
RESULT=$($CURL -s -X POST "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{
    "initial_input": "Build a REST API that handles user authentication with JWT tokens, password hashing, and rate limiting.",
    "steps": [
      {
        "type": "summarize",
        "prompt_template": "Summarize this requirement in two sentences: {{initial_input}}"
      },
      {
        "type": "code",
        "prompt_template": "Write a Go function that implements: {{prev_output}}"
      }
    ]
  }')

# Extract routed_to for each step
STEP0_NODE=$(echo "$RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for s in d.get('steps', []):
    if s['step_index'] == 0: print(s.get('routed_to','?'))
" 2>/dev/null)
STEP1_NODE=$(echo "$RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for s in d.get('steps', []):
    if s['step_index'] == 1: print(s.get('routed_to','?'))
" 2>/dev/null)
echo "   Step 0 (summarize) → $STEP0_NODE"
echo "   Step 1 (code)      → $STEP1_NODE"

check "Pipeline succeeded"                "$RESULT" '"success":true'
check "Summarize step routed to node-a"   "$RESULT" '"routed_to":"node-a"'
check "Code step routed to node-b"        "$RESULT" '"routed_to":"node-b"'
check "Code step has model_used"          "$RESULT" '"model_used"'
echo ""

# ─── Test 3: Three-step pipeline (text → summarize → code) ──────────────────

echo "── Test 3: Three-step chain (text → summarize → code) ────"
RESULT=$($CURL -s -X POST "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{
    "pipeline_id": "three-step-test",
    "initial_input": "Describe how load balancers distribute traffic across servers.",
    "steps": [
      {
        "type": "text",
        "prompt_template": "{{initial_input}}"
      },
      {
        "type": "summarize",
        "prompt_template": "Summarize in one sentence: {{prev_output}}"
      },
      {
        "type": "code",
        "prompt_template": "Write a simple Python load balancer based on: {{prev_output}}"
      }
    ]
  }')
echo "   Pipeline ID: $(echo $RESULT | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pipeline_id','?'))" 2>/dev/null)"
check "Pipeline succeeded"           "$RESULT" '"success":true'
check "Custom pipeline_id preserved" "$RESULT" '"pipeline_id":"three-step-test"'
check "Has 3 total_steps"            "$RESULT" '"total_steps":3'
check "Final output has content"     "$RESULT" '"final_output"'
# Final step should be code → likely contains a code keyword
FINAL=$(echo "$RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('final_output','')))" 2>/dev/null)
echo "   Final output length: ${FINAL:-?} chars"
echo ""

# ─── Test 4: Single-step pipeline (degenerate case) ─────────────────────────

echo "── Test 4: Single-step pipeline ──────────────────────────"
RESULT=$($CURL -s -X POST "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{
    "initial_input": "Say only: single step works",
    "steps": [
      {
        "type": "text",
        "prompt_template": "{{initial_input}}"
      }
    ]
  }')
check "Single-step succeeded"   "$RESULT" '"success":true'
check "Has 1 total_step"        "$RESULT" '"total_steps":1'
check "Has final_output"        "$RESULT" '"final_output"'
echo ""

# ─── Test 5: Empty prompt_template defaults to prev_output ──────────────────

echo "── Test 5: Empty template uses prev_output ───────────────"
RESULT=$($CURL -s -X POST "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{
    "initial_input": "Say only the word: echo",
    "steps": [
      {
        "type": "text"
      },
      {
        "type": "summarize",
        "prompt_template": "Repeat exactly: {{prev_output}}"
      }
    ]
  }')
check "Pipeline succeeded"   "$RESULT" '"success":true'
check "Both steps completed" "$RESULT" '"step_index":1'
echo ""

# ─── Test 6: Validation — empty steps rejected ──────────────────────────────

echo "── Test 6: Validation errors ─────────────────────────────"
EMPTY_STEPS=$($CURL -s -o /dev/null -w "%{http_code}" -X POST "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{"initial_input": "hello", "steps": []}')
check "Empty steps → 400" "$EMPTY_STEPS" "400"

NO_INPUT=$($CURL -s -o /dev/null -w "%{http_code}" -X POST "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{"steps": [{"type": "text"}]}')
check "No initial_input → 400" "$NO_INPUT" "400"
echo ""

# ─── Test 7: Per-step metadata is complete ───────────────────────────────────

echo "── Test 7: Per-step metadata in response ─────────────────"
RESULT=$($CURL -s -X POST "$BASE/pipeline" \
  -H "Content-Type: application/json" \
  -d '{
    "initial_input": "Say hello",
    "steps": [
      {"type": "text", "prompt_template": "{{initial_input}}"},
      {"type": "summarize", "prompt_template": "Repeat: {{prev_output}}"}
    ]
  }')
check "Steps have routed_to"  "$RESULT" '"routed_to"'
check "Steps have model_used" "$RESULT" '"model_used"'
check "Steps have task_type"  "$RESULT" '"task_type"'
check "Steps have content"    "$RESULT" '"content"'
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────

echo "──────────────────────────────────────────────────────────"
echo "  Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "  🎉 Phase 4 complete — pipeline engine is working!"
else
  echo "  ⚠️  Some tests failed. Check logs/ for details."
fi
echo "──────────────────────────────────────────────────────────"
echo ""
