// orchestrator/main.go
// The orchestrator is the brain of the mesh.
// It exposes an HTTP API that clients use to submit tasks,
// and forwards those tasks to the best available node-agent.

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/google/uuid"

	"echo-system/shared"
)

var registry = NewRegistry()

// taskTimeout is how long we wait for a node to respond before giving up
// and trying a failover node. Ollama on CPU can be slow, so 3 minutes.
const taskTimeout = 3 * time.Minute

func main() {
	mux := http.NewServeMux()

	// ── Client-facing endpoints ──────────────────────────────────────────────
	mux.HandleFunc("POST /task", handleTask)              // non-streaming
	mux.HandleFunc("POST /task/stream", handleTaskStream) // streaming SSE
	mux.HandleFunc("POST /pipeline", handlePipeline)      // Phase 4: multi-step pipeline

	// ── Node-agent endpoints ─────────────────────────────────────────────────
	mux.HandleFunc("POST /register", handleRegister)
	mux.HandleFunc("POST /heartbeat", handleHeartbeat)

	// ── Debug / status ───────────────────────────────────────────────────────
	mux.HandleFunc("GET /status", handleStatus)
	mux.HandleFunc("GET /debug/routing", handleDebugRouting)

	addr := ":8080"
	log.Printf("[Orchestrator] Listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

// ─── Client: POST /task ───────────────────────────────────────────────────────
// Collects the full response and returns it as JSON.

func handleTask(w http.ResponseWriter, r *http.Request) {
	var req shared.TaskRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.TaskID == "" {
		req.TaskID = uuid.New().String()
	}
	if req.Prompt == "" {
		http.Error(w, "prompt is required", http.StatusBadRequest)
		return
	}

	startedAt := time.Now()

	// Wrap with a timeout so a hung node doesn't block forever
	ctx, cancel := context.WithTimeout(r.Context(), taskTimeout)
	defer cancel()

	result, err := routeWithFailover(ctx, req, nil)
	if err != nil {
		http.Error(w, fmt.Sprintf("all nodes failed: %v", err), http.StatusServiceUnavailable)
		return
	}

	result.LatencyMs = time.Since(startedAt).Milliseconds()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

// routeWithFailover tries to execute a task, and if the chosen node fails,
// automatically retries on the next best available node.
func routeWithFailover(ctx context.Context, req shared.TaskRequest, tried map[string]bool) (*shared.TaskResult, error) {
	if tried == nil {
		tried = make(map[string]bool)
	}

	node, err := registry.FindBestNodeExcluding(req.Type, req.ModelHint, tried)
	if err != nil {
		return nil, fmt.Errorf("no more nodes to try (tried %d): %w", len(tried), err)
	}

	log.Printf("[Orchestrator] Task %s type=%q → node %s (attempt %d)",
		req.TaskID, req.Type, node.NodeID, len(tried)+1)
	registry.IncrementLoad(node.NodeID)
	defer registry.DecrementLoad(node.NodeID)

	result, err := forwardTask(ctx, node, req)
	if err != nil {
		tried[node.NodeID] = true
		log.Printf("[Orchestrator] Node %s failed (%v) — trying failover", node.NodeID, err)
		registry.MarkSuspect(node.NodeID)
		return routeWithFailover(ctx, req, tried)
	}

	result.RoutedTo = node.NodeID
	result.TaskType = req.Type
	result.Success = true
	return result, nil
}

// ─── Client: POST /task/stream ────────────────────────────────────────────────
// Streams tokens back as Server-Sent Events (SSE).
// Each event is a JSON-encoded TaskChunk.

func handleTaskStream(w http.ResponseWriter, r *http.Request) {
	var req shared.TaskRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.TaskID == "" {
		req.TaskID = uuid.New().String()
	}

	node, err := registry.FindBestNode(req.Type, req.ModelHint)
	if err != nil {
		http.Error(w, fmt.Sprintf("no available nodes: %v", err), http.StatusServiceUnavailable)
		return
	}

	log.Printf("[Orchestrator] Stream task %s type=%q → node %s", req.TaskID, req.Type, node.NodeID)
	startedAt := time.Now()
	registry.IncrementLoad(node.NodeID)
	defer registry.DecrementLoad(node.NodeID)

	// Set SSE headers
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	// Forward to node-agent and pipe the stream back
	err = forwardTaskStream(r.Context(), node, req, func(chunk shared.TaskChunk) {
		if chunk.Done {
			chunk.LatencyMs = time.Since(startedAt).Milliseconds()
		}
		chunk.RoutedTo = node.NodeID

		data, _ := json.Marshal(chunk)
		fmt.Fprintf(w, "data: %s\n\n", data)
		flusher.Flush()
	})

	if err != nil {
		log.Printf("[Orchestrator] Stream error for task %s: %v", req.TaskID, err)
	}
}

// ─── Node agent: POST /register ───────────────────────────────────────────────

func handleRegister(w http.ResponseWriter, r *http.Request) {
	var req shared.RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	if req.NodeID == "" {
		http.Error(w, "node_id is required", http.StatusBadRequest)
		return
	}
	registry.Register(req)
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "registered"})
}

// ─── Node agent: POST /heartbeat ──────────────────────────────────────────────

func handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	var req shared.HeartbeatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	if !registry.Heartbeat(req) {
		// Node isn't registered — tell it to re-register
		http.Error(w, "unknown node, please re-register", http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// ─── Debug: GET /status ───────────────────────────────────────────────────────

func handleStatus(w http.ResponseWriter, r *http.Request) {
	nodes := registry.AllNodes()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"nodes":       nodes,
		"node_count":  len(nodes),
		"server_time": time.Now().UnixMilli(),
	})
}

// handleDebugRouting shows exactly how the next task of each type would be routed.
// GET /debug/routing
func handleDebugRouting(w http.ResponseWriter, r *http.Request) {
	types := []shared.TaskType{
		shared.TaskTypeText,
		shared.TaskTypeCode,
		shared.TaskTypeSummarize,
		shared.TaskTypeAny,
	}
	routing := make(map[string]string)
	for _, t := range types {
		node, err := registry.FindBestNode(t, "")
		if err != nil {
			routing[string(t)] = "no node available"
		} else {
			model := shared.BestModelForType(node.Capabilities, t)
			routing[string(t)] = fmt.Sprintf("%s (model: %s)", node.NodeID, model)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"routing": routing,
		"nodes":   registry.AllNodes(),
	})
}

// ─── Client: POST /pipeline ───────────────────────────────────────────────────
// Executes a multi-step pipeline, chaining outputs across nodes.

func handlePipeline(w http.ResponseWriter, r *http.Request) {
	var req shared.PipelineRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if len(req.Steps) == 0 {
		http.Error(w, "pipeline must have at least one step", http.StatusBadRequest)
		return
	}
	if req.InitialInput == "" {
		http.Error(w, "initial_input is required", http.StatusBadRequest)
		return
	}

	// Use the per-request context with pipeline-level timeout
	// (each step already gets the task timeout via routeWithFailover)
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(len(req.Steps))*taskTimeout)
	defer cancel()

	result := ExecutePipeline(ctx, req)

	w.Header().Set("Content-Type", "application/json")
	if !result.Success {
		w.WriteHeader(http.StatusInternalServerError)
	}
	json.NewEncoder(w).Encode(result)
}

// ─── Forwarding helpers ───────────────────────────────────────────────────────

// forwardTask sends a task to a node-agent and waits for the full response.
func forwardTask(ctx context.Context, node *shared.NodeInfo, req shared.TaskRequest) (*shared.TaskResult, error) {
	body, _ := json.Marshal(req)
	url := fmt.Sprintf("http://localhost:%d/execute", node.AgentPort)

	httpReq, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("agent unreachable: %w", err)
	}
	defer resp.Body.Close()

	var result shared.TaskResult
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode agent response: %w", err)
	}
	return &result, nil
}

// forwardTaskStream sends a task to a node-agent and streams chunks back,
// calling onChunk for each received TaskChunk.
func forwardTaskStream(ctx context.Context, node *shared.NodeInfo, req shared.TaskRequest, onChunk func(shared.TaskChunk)) error {
	body, _ := json.Marshal(req)
	url := fmt.Sprintf("http://localhost:%d/execute/stream", node.AgentPort)

	httpReq, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		return fmt.Errorf("agent stream unreachable: %w", err)
	}
	defer resp.Body.Close()

	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var chunk shared.TaskChunk
		if err := json.Unmarshal(line, &chunk); err != nil {
			continue
		}
		onChunk(chunk)
		if chunk.Done {
			break
		}
	}
	return scanner.Err()
}
