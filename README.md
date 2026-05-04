# 🌌 Echo-System — Decentralized Local AI Mesh

[![Go](https://img.shields.io/badge/Go-1.22+-00ADD8?style=for-the-badge&logo=go&logoColor=white)](https://go.dev/)
[![Ollama](https://img.shields.io/badge/Ollama-Local_AI-000000?style=for-the-badge&logo=ollama&logoColor=white)](https://ollama.com/)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

**Echo-System** is a decentralized, local AI mesh network. It allows multiple Ollama instances running across different machines (or locally for testing) to communicate seamlessly through a central Orchestrator. 

This project aims to distribute AI workloads intelligently, load balancing tasks across available nodes based on their capabilities, available memory, and current queue.

---

## 📑 Table of Contents
- [Architecture](#-architecture)
- [How it Works](#-how-it-works)
- [Getting Started](#-getting-started)
  - [Prerequisites](#prerequisites)
  - [Quick Start](#quick-start)
- [Manual Testing & Usage](#-manual-testing--usage)
- [API Reference](#-api-reference)
- [Project Structure](#-project-structure)
- [Phase Roadmap](#-phase-roadmap)

---

## 🏗️ Architecture

```text
Your Laptop / Network
│
├── Ollama A  :11434  ←──  Node Agent A  :9001
│                                             ↑
├── Ollama B  :11435  ←──  Node Agent B  :9002   ← Orchestrator :8080  ← Client
│                                             ↑
└── (future: local LAN nodes)            routes to least-busy node
```

Echo-System is built with a dual-layer approach:
1. **Node Agents (Go):** Run alongside Ollama instances, reporting hardware capabilities and handling inference workloads.
2. **Orchestrator (Go):** The brain of the mesh. It tracks alive nodes, handles incoming tasks, and routes them based on a load-balancing strategy (e.g., lowest active tasks).

---

## ⚙️ How it Works

1. **Client Request:** The user submits a prompt via the REST/gRPC API.
2. **Routing:** The Orchestrator queries its internal `NodeRegistry` to find the most capable, lowest-load node.
3. **Execution:** The Orchestrator forwards the task to the selected Node Agent via a gRPC stream.
4. **Inference:** The Node Agent proxies the request to the local Ollama API and streams the tokens back.
5. **Delivery:** The Orchestrator relays the streamed response back to the client in real-time.

---

## 🚀 Getting Started

### Prerequisites

| Tool | Version | Installation |
|------|---------|--------------|
| **Go** | 1.22+ | [Download Go](https://go.dev/dl/) |
| **Ollama** | Latest | [Download Ollama](https://ollama.com) |
| **Model** | Mistral | Run `ollama pull mistral` |

### Quick Start

We've provided a set of scripts to spin up Phase 1 (two local agents + orchestrator) effortlessly.

```bash
# 1. Pull the default model (only needed once)
ollama pull mistral

# 2. Start the full stack (Orchestrator + Agent A + Agent B)
chmod +x scripts/*.sh
./scripts/start-phase1.sh

# 3. Run the automated test suite
./scripts/test-task.sh

# 4. Gracefully stop all services when done
./scripts/stop.sh
```

---

## 🧪 Manual Testing & Usage

You can interact with the mesh network via standard HTTP calls.

**Send a standard task (non-streaming):**
```bash
curl -X POST http://localhost:8080/task \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is 2 + 2?"}'
```

**Send a streaming task (Server-Sent Events):**
```bash
curl -N -X POST http://localhost:8080/task/stream \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Write a haiku about distributed systems."}'
```

**Check the health and status of the mesh:**
```bash
curl http://localhost:8080/status | python3 -m json.tool
```

**Monitor logs in real-time:**
```bash
tail -f logs/orchestrator.log logs/agent-a.log logs/agent-b.log
```

---

## 📡 API Reference

### `POST /task`
Submit a task and wait for the complete response.
**Request:**
```json
{
  "prompt": "Explain gravity.",
  "model_hint": "mistral" 
}
```
**Response:**
```json
{
  "task_id": "uuid",
  "content": "Gravity is...",
  "routed_to": "node-a",
  "latency_ms": 1234,
  "success": true
}
```

### `POST /task/stream`
Submit a task and get the response streamed back token by token (SSE).
**Response (Stream):**
```text
data: {"task_id":"...","token":"Hello","done":false,"routed_to":"node-a"}
data: {"task_id":"...","token":" world","done":false,"routed_to":"node-a"}
data: {"task_id":"...","token":"","done":true,"latency_ms":890}
```

### `GET /status`
Retrieve the current topology of the mesh, including connected nodes, their hardware capabilities, and current load.

---

## 📂 Project Structure

```text
echo-system/
├── shared/
│   └── types.go          # Common types (TaskRequest, NodeInfo, etc.)
├── orchestrator/
│   ├── main.go           # HTTP server, request handlers, forwarding logic
│   └── registry.go       # Node tracking, routing, heartbeat eviction
├── node-agent/
│   ├── main.go           # Agent server, heartbeat loop, Ollama integration
│   └── ...
├── dashboard/            # React-based real-time topology UI
├── proto/                # Shared protobuf definitions
├── scripts/
│   ├── start-phase1.sh   # Spin up local cluster
│   ├── test-task.sh      # Trigger mock tasks
│   └── stop.sh           # Tear down services
├── docker/               # Dockerfiles and compose setups
└── logs/                 # Runtime application logs
```

---

## 🗺️ Phase Roadmap

| Phase | Goal | Deliverable | Status |
|-------|------|-------------|--------|
| **1** | Foundational Mesh | Two nodes, one task type routed locally. | ✅ |
| **2** | Auto-Discovery | Nodes discover orchestrator via **mDNS**. Failover logic and active task mutexes. | 🚧 |
| **3** | Pipeline Chaining | Chain tasks across nodes (e.g., Vision analysis → Text summarization). | ⏳ |
| **4** | UI Dashboard | React dashboard for live mesh topology and task feed. | ⏳ |
| **5** | Local LAN Mesh | True decentralized operation across physical machines via Docker. | ⏳ |

*For more details on the planned architecture and routing strategies, see [ARCHITECTURE.md](ARCHITECTURE.md).*
