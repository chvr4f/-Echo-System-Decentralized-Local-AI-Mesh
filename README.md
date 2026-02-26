# Echo-System — Phase 1: Foundation

A decentralized local AI mesh. Phase 1 gets two Ollama instances talking
through a central orchestrator on a single machine.

## Architecture

```
Your Laptop
│
├── Ollama A  :11434  ←──  Node Agent A  :9001
│                                             ↑
├── Ollama B  :11435  ←──  Node Agent B  :9002   ← Orchestrator :8080  ← Client
│                                             ↑
└── (future: real devices over LAN)      routes to least-busy node
```

## Prerequisites

| Tool   | Install |
|--------|---------|
| Go 1.22+ | https://go.dev/dl/ |
| Ollama   | https://ollama.com |
| mistral  | `ollama pull mistral` |

## Quick Start

```bash
# 1. Pull the model (only needed once)
ollama pull mistral

# 2. Start the full stack
chmod +x scripts/*.sh
./scripts/start-phase1.sh

# 3. Run the test suite
./scripts/test-task.sh

# 4. When done
./scripts/stop.sh
```

## Manual Testing

```bash
# Send a task (non-streaming)
curl -X POST http://localhost:8080/task \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is 2 + 2?"}'

# Send a streaming task
curl -N -X POST http://localhost:8080/task/stream \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Write a haiku about distributed systems."}'

# Check mesh status
curl http://localhost:8080/status | python3 -m json.tool

# Watch logs live
tail -f logs/orchestrator.log logs/agent-a.log logs/agent-b.log
```

## API Reference

### POST /task
Submit a task, get the full response.

```json
// Request
{ "prompt": "...", "model_hint": "mistral" }

// Response
{
  "task_id": "uuid",
  "content": "...",
  "routed_to": "node-a",
  "latency_ms": 1234,
  "success": true
}
```

### POST /task/stream
Submit a task, get tokens streamed as SSE.

```
data: {"task_id":"...","token":"Hello","done":false,"routed_to":"node-a"}
data: {"task_id":"...","token":" world","done":false,"routed_to":"node-a"}
data: {"task_id":"...","token":"","done":true,"latency_ms":890}
```

### GET /status
See all connected nodes and their current state.

## Project Structure

```
echo-system/
├── shared/
│   └── types.go          # Common types (TaskRequest, NodeInfo, etc.)
├── orchestrator/
│   ├── main.go           # HTTP server, request handlers, forwarding logic
│   └── registry.go       # Node tracking, routing, heartbeat eviction
├── node-agent/
│   └── main.go           # Agent server, heartbeat loop, Ollama integration
├── scripts/
│   ├── start-phase1.sh   # One-command startup
│   ├── test-task.sh      # Test suite
│   └── stop.sh           # Clean shutdown
└── logs/                 # Created at runtime
```

## What's Next — Phase 2

Phase 2 adds:
- Nodes auto-discover the orchestrator via **mDNS** (no hardcoded IP)
- **Active task count** tracked accurately with a mutex in the agent
- **Failover**: if node-a dies mid-task, orchestrator retries on node-b
- **Reconnect logic**: agent detects orchestrator restart and re-registers
