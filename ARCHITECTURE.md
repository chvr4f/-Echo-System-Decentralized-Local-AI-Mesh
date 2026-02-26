# Echo-System — Decentralized Local AI Mesh

## Project Structure

```
echo-system/
│
├── orchestrator/               # Node.js — the brain
│   ├── src/
│   │   ├── registry/
│   │   │   ├── NodeRegistry.js       # Tracks alive nodes + capabilities
│   │   │   └── HealthMonitor.js      # Heartbeat checker (ping every 3s)
│   │   ├── routing/
│   │   │   ├── TaskRouter.js         # Decides which node handles a task
│   │   │   └── LoadBalancer.js       # Round-robin + least-load strategy
│   │   ├── pipeline/
│   │   │   └── PipelineEngine.js     # Chains tasks across multiple nodes
│   │   ├── server/
│   │   │   ├── grpc-server.js        # gRPC server (accepts tasks from clients)
│   │   │   └── ws-server.js          # WebSocket server (dashboard real-time feed)
│   │   └── index.js
│   ├── proto/
│   │   ├── mesh.proto                # gRPC service definitions
│   │   └── node.proto                # Node capability definitions
│   └── package.json
│
├── node-agent/                 # Go — runs on EACH device
│   ├── main.go
│   ├── agent/
│   │   ├── advertiser.go       # mDNS broadcast (announces this node to the mesh)
│   │   ├── executor.go         # Calls local Ollama API, streams response back
│   │   ├── heartbeat.go        # Pings orchestrator every 3s
│   │   └── capabilities.go     # Reports what models this node has loaded
│   ├── grpc/
│   │   └── client.go           # Connects to orchestrator via gRPC
│   └── go.mod
│
├── proto/                      # Shared protobuf definitions
│   ├── mesh.proto
│   └── node.proto
│
├── dashboard/                  # React — mesh topology UI
│   ├── src/
│   │   ├── components/
│   │   │   ├── MeshMap.jsx           # Live node graph visualization
│   │   │   ├── NodeCard.jsx          # Per-node status card
│   │   │   ├── TaskFeed.jsx          # Real-time task routing log
│   │   │   └── ChatInterface.jsx     # Send tasks, see routed results
│   │   └── App.jsx
│   └── package.json
│
├── docker/
│   ├── orchestrator.Dockerfile
│   ├── node-agent.Dockerfile
│   └── docker-compose.yml      # Spin up full local mesh for testing
│
└── README.md
```

---

## Data Flow (Single Task)

```
Client sends task
      │
      ▼
[Orchestrator — gRPC]
  1. Receive task + type (code/vision/summarize)
  2. Query NodeRegistry → find capable, lowest-load node
  3. Forward task to Node Agent via gRPC stream
      │
      ▼
[Node Agent — Go]
  4. Call local Ollama REST API
  5. Stream tokens back to Orchestrator
      │
      ▼
[Orchestrator]
  6. Forward stream to original client
  7. Update load metrics in registry
  8. Emit event to dashboard via WebSocket
```

---

## Data Flow (Pipeline Task — chained across nodes)

```
Task: "Describe this image, then summarize the description"

Step 1: Route image → Node A (has llava vision model)
         → returns: "A cityscape at night with..."

Step 2: Route text → Node B (has mistral for summarization)
         → returns: "Urban nighttime scene."

PipelineEngine manages step sequencing and passes
output of step N as input to step N+1.
```

---

## Node Capability Schema

Each node agent reports this on connection and on model load/unload:

```json
{
  "node_id": "macbook-pro-charaf",
  "host": "192.168.1.10",
  "port": 50052,
  "models": [
    { "name": "codellama", "type": "code", "size_gb": 4.1 },
    { "name": "mistral",   "type": "text", "size_gb": 4.0 }
  ],
  "hardware": {
    "ram_total_gb": 16,
    "ram_free_gb": 6.2,
    "has_gpu": true,
    "gpu_vram_gb": 8
  },
  "status": "idle",
  "active_tasks": 0
}
```

---

## Routing Strategy

```
Priority Order:
1. Model specialization match  (exact model requested?)
2. Task type match             (node has a model of this type?)
3. Lowest active_tasks count   (load balancing)
4. Highest free RAM            (fallback tiebreaker)

If NO node is available:
→ Queue task with TTL (30s default)
→ Return 503 with estimated wait
→ Notify dashboard
```

---

## Phase Roadmap

| Phase | Goal | Deliverable |
|-------|------|-------------|
| 1 | Two nodes, one task type, working E2E | Text task routed between laptop + Pi |
| 2 | Capability registry + health checks | Auto-failover when a node dies |
| 3 | Pipeline chaining | Vision → text chain across nodes |
| 4 | Dashboard | Live mesh topology + task feed |
| 5 | mDNS auto-discovery | Zero-config node joining |
| 6 | Docker Compose | One-command local mesh setup |
