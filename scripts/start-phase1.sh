#!/bin/bash
# scripts/start-phase1.sh
# Starts the full Phase 1 mesh on a single machine:
#   - Orchestrator on :8080
#   - Node A agent on :9001  →  Ollama on :11434
#   - Node B agent on :9002  →  Ollama on :11435
#
# Prerequisites:
#   1. Go 1.22+  (https://go.dev/dl/)
#   2. Ollama    (https://ollama.com)
#   3. mistral model pulled: ollama pull mistral
#
# Usage:
#   chmod +x scripts/start-phase1.sh
#   ./scripts/start-phase1.sh

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGS="$ROOT/logs"
mkdir -p "$LOGS"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║     ECHO-SYSTEM  Phase 1 Startup     ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ─── Check prerequisites ──────────────────────────────────────────────────────

check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "❌  $1 is not installed. See prerequisites above."
    exit 1
  fi
}
check_cmd go
check_cmd ollama

echo "✅  Go:     $(go version)"
echo "✅  Ollama: found"
echo ""

# ─── Build binaries ───────────────────────────────────────────────────────────

echo "🔨 Building binaries..."
cd "$ROOT"
mkdir -p bin
go mod tidy
go build -o bin/orchestrator.exe ./orchestrator
go build -o bin/node-agent.exe   ./node-agent/main.go ./node-agent/discovery.go
echo "✅  Binaries built → bin/"
echo ""

# ─── Helper: check if a port is in use ───────────────────────────────────────
port_in_use() {
  netstat -ano 2>/dev/null | grep -q ":$1 " || \
  netstat -ano 2>/dev/null | grep -q ":$1$"
}

# ─── Start Ollama instances ───────────────────────────────────────────────────

echo "🦙 Starting Ollama instances..."

# Instance A — default port
if port_in_use 11434; then
  echo "   Ollama A already running on :11434"
else
  OLLAMA_HOST=127.0.0.1:11434 ollama serve > "$LOGS/ollama-a.log" 2>&1 &
  echo "   Started Ollama A on :11434 (pid $!)"
fi

# Instance B — second port
if port_in_use 11435; then
  echo "   Ollama B already running on :11435"
else
  OLLAMA_HOST=127.0.0.1:11435 ollama serve > "$LOGS/ollama-b.log" 2>&1 &
  echo "   Started Ollama B on :11435 (pid $!)"
  sleep 3
  # Pull the model into instance B (runs in background)
  OLLAMA_HOST=127.0.0.1:11435 ollama pull mistral >> "$LOGS/ollama-b.log" 2>&1 &
fi

echo ""
sleep 3

# ─── Start orchestrator ───────────────────────────────────────────────────────

echo "🧠 Starting Orchestrator on :8080..."
"$ROOT/bin/orchestrator.exe" > "$LOGS/orchestrator.log" 2>&1 &
ORCH_PID=$!
echo "   pid $ORCH_PID — logs: logs/orchestrator.log"
sleep 1

# ─── Start node agents ────────────────────────────────────────────────────────

echo "🤖 Starting Node Agent A (port :9001, ollama :11434)..."
"$ROOT/bin/node-agent.exe" \
  -id node-a \
  -port 9001 \
  -ollama-port 11434 \
  -models mistral \
  -capabilities mistral:text,summarize \
  -orchestrator http://localhost:8080 \
  > "$LOGS/agent-a.log" 2>&1 &
echo "   pid $! — logs: logs/agent-a.log"

# Node B removed — replaced by Ubuntu VM node (ubuntu-node-1)
# Start it on your Ubuntu VM with:
#   ./bin/node-agent -id ubuntu-node-1 -port 9003 -ollama-port 11434 \
#     -orchestrator http://192.168.1.7:8080 -models mistral \
#     -capabilities "mistral:code,text"

echo ""
sleep 2

# ─── Verify ───────────────────────────────────────────────────────────────────

echo "🔍 Checking mesh status..."
# On MSYS/Git Bash/WSL, the bundled curl can't reach Windows-bound localhost.
if command -v curl.exe &>/dev/null; then
  CURL="curl.exe"
else
  CURL="curl"
fi
STATUS=$($CURL -s http://localhost:8080/status 2>/dev/null)
if [ -z "$STATUS" ]; then
  echo "⚠️  Orchestrator not responding yet. Check logs/orchestrator.log"
else
  echo "✅  Mesh is up:"
  echo "$STATUS" | python3 -m json.tool 2>/dev/null || echo "$STATUS"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    Mesh is running!                      ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Orchestrator:     http://localhost:8080                 ║"
echo "║  Node A (local):   http://localhost:9001                 ║"
echo "║  Ubuntu VM node:   http://192.168.1.9:9003  (manual)    ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Test it:                                                ║"
echo "║  ./scripts/test-task.sh                                  ║"
echo "║                                                          ║"
echo "║  Watch logs:                                             ║"
echo "║  tail -f logs/orchestrator.log logs/agent-a.log          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""