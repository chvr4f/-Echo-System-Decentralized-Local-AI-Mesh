// node-agent/main.go
// The node-agent runs on each device (or each Ollama instance in Phase 1).
// It:
//   1. Registers itself with the orchestrator on startup
//   2. Sends a heartbeat every 3 seconds
//   3. Listens for task execution requests from the orchestrator
//   4. Calls its local Ollama instance and streams tokens back

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"echo-system/shared"
)

// activeTasks is an atomic counter — incremented when a task starts,
// decremented when it finishes. Read by the heartbeat loop so the
// orchestrator always knows the true load on this node.
var activeTasks int64

// ─── Config ───────────────────────────────────────────────────────────────────

type Config struct {
	NodeID          string
	AgentHost       string // hostname/IP this agent is reachable at
	AgentPort       int    // this agent's HTTP server port
	OllamaHost      string // Ollama hostname (default: localhost)
	OllamaPort      int    // local Ollama port
	OrchestratorURL string
	Models          []string
	Capabilities    []shared.ModelCapability // which task types each model handles
}

func main() {
	// Flags — makes it easy to run two instances with different ports
	nodeID := flag.String("id", "", "Unique node ID (e.g. node-a)")
	agentPort := flag.Int("port", 9001, "Port this agent listens on")
	ollamaPort := flag.Int("ollama-port", 11434, "Local Ollama port")
	orchURL := flag.String("orchestrator", "auto", "Orchestrator URL ('auto' = mDNS discovery)")
	agentHost := flag.String("host", "", "Hostname/IP this agent is reachable at (default: auto-detect)")
	ollamaHost := flag.String("ollama-host", "localhost", "Ollama hostname (for Docker: service name)")
	modelsFlag := flag.String("models", "mistral", "Comma-separated model names")
	// capabilities format: "mistral:text,summarize;codellama:code"
	// Each entry is "modelname:type1,type2" separated by semicolons.
	capsFlag := flag.String("capabilities", "", "Model capabilities, e.g. mistral:text,summarize;codellama:code")
	flag.Parse()

	if *nodeID == "" {
		hostname, _ := os.Hostname()
		*nodeID = fmt.Sprintf("%s-%d", hostname, *agentPort)
	}

	models := strings.Split(*modelsFlag, ",")
	caps := parseCapabilities(*capsFlag, models)
	log.Printf("[Agent] capabilities flag raw value: %q", *capsFlag)
	for _, c := range caps {
		log.Printf("[Agent] capability: model=%s types=%v", c.Name, c.Types)
	}

	// Phase 6: mDNS auto-discovery
	orchestratorURL := *orchURL
	if orchestratorURL == "auto" || orchestratorURL == "" {
		log.Println("[Agent] No orchestrator URL specified — using mDNS discovery")
		orchestratorURL = discoverOrchestratorWithRetry()
	}

	// Determine the host this agent is reachable at
	resolvedHost := *agentHost
	if resolvedHost == "" {
		resolvedHost = getPreferredOutboundIP()
	}

	cfg := Config{
		NodeID:          *nodeID,
		AgentHost:       resolvedHost,
		AgentPort:       *agentPort,
		OllamaHost:      *ollamaHost,
		OllamaPort:      *ollamaPort,
		OrchestratorURL: orchestratorURL,
		Models:          models,
		Capabilities:    caps,
	}

	log.Printf("[Agent:%s] Starting (agent :%d, ollama :%d)", cfg.NodeID, cfg.AgentPort, cfg.OllamaPort)

	// Register with orchestrator (retry until it's up)
	registerWithRetry(cfg)

	// Start heartbeat in background
	go heartbeatLoop(cfg)

	// Start HTTP server
	runServer(cfg)
}

// ─── Registration ─────────────────────────────────────────────────────────────

func registerWithRetry(cfg Config) {
	req := shared.RegisterRequest{
		NodeID:       cfg.NodeID,
		AgentHost:    cfg.AgentHost,
		AgentPort:    cfg.AgentPort,
		OllamaPort:   cfg.OllamaPort,
		Models:       cfg.Models,
		Capabilities: cfg.Capabilities,
		Status:       shared.StatusIdle,
	}

	for {
		err := postJSON(cfg.OrchestratorURL+"/register", req, nil)
		if err == nil {
			log.Printf("[Agent:%s] Registered with orchestrator", cfg.NodeID)
			return
		}
		log.Printf("[Agent:%s] Orchestrator not ready, retrying in 3s: %v", cfg.NodeID, err)
		time.Sleep(3 * time.Second)
	}
}

// ─── Heartbeat ────────────────────────────────────────────────────────────────

func heartbeatLoop(cfg Config) {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		count := int(atomic.LoadInt64(&activeTasks))
		status := shared.StatusIdle
		if count >= 5 {
			status = shared.StatusBusy
		}

		hb := shared.HeartbeatRequest{
			NodeID:      cfg.NodeID,
			Status:      status,
			ActiveTasks: count,
		}
		err := postJSON(cfg.OrchestratorURL+"/heartbeat", hb, nil)
		if err != nil {
			// Any failure (network blip or 404 = orchestrator restarted) triggers re-register
			log.Printf("[Agent:%s] Heartbeat failed (%v) — re-registering", cfg.NodeID, err)
			registerWithRetry(cfg)
		}
	}
}

// ─── HTTP Server ──────────────────────────────────────────────────────────────

func runServer(cfg Config) {
	mux := http.NewServeMux()

	// Orchestrator calls these to execute tasks
	mux.HandleFunc("POST /execute", makeExecuteHandler(cfg))
	mux.HandleFunc("POST /execute/stream", makeExecuteStreamHandler(cfg))

	// Health check
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	addr := fmt.Sprintf(":%d", cfg.AgentPort)
	log.Printf("[Agent:%s] HTTP server on %s", cfg.NodeID, addr)

	// Graceful shutdown
	srv := &http.Server{Addr: addr, Handler: mux}
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[Agent:%s] Server error: %v", cfg.NodeID, err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Printf("[Agent:%s] Shutting down...", cfg.NodeID)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(ctx)
}

// ─── Execute (non-streaming) ──────────────────────────────────────────────────

func makeExecuteHandler(cfg Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req shared.TaskRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}

		log.Printf("[Agent:%s] Executing task %s", cfg.NodeID, req.TaskID)
		startedAt := time.Now()
		atomic.AddInt64(&activeTasks, 1)
		defer atomic.AddInt64(&activeTasks, -1)

		model := resolveModel(cfg, req.ModelHint, req.Type)
		content, err := callOllama(r.Context(), cfg.OllamaHost, cfg.OllamaPort, model, req.Prompt, false)
		if err != nil {
			result := shared.TaskResult{
				TaskID:  req.TaskID,
				Success: false,
				Error:   err.Error(),
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(result)
			return
		}

		result := shared.TaskResult{
			TaskID:    req.TaskID,
			Content:   content,
			ModelUsed: model,
			TaskType:  req.Type,
			LatencyMs: time.Since(startedAt).Milliseconds(),
			Success:   true,
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(result)
	}
}

// ─── Execute (streaming) ──────────────────────────────────────────────────────

func makeExecuteStreamHandler(cfg Config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req shared.TaskRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}

		log.Printf("[Agent:%s] Streaming task %s", cfg.NodeID, req.TaskID)
		atomic.AddInt64(&activeTasks, 1)
		defer atomic.AddInt64(&activeTasks, -1)
		model := resolveModel(cfg, req.ModelHint, req.Type)

		w.Header().Set("Content-Type", "application/x-ndjson")
		w.Header().Set("Transfer-Encoding", "chunked")
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming not supported", 500)
			return
		}

		err := streamOllama(r.Context(), cfg.OllamaHost, cfg.OllamaPort, model, req.Prompt, func(token string, done bool) {
			chunk := shared.TaskChunk{
				TaskID: req.TaskID,
				Token:  token,
				Done:   done,
			}
			data, _ := json.Marshal(chunk)
			fmt.Fprintf(w, "%s\n", data)
			flusher.Flush()
		})

		if err != nil {
			log.Printf("[Agent:%s] Stream error: %v", cfg.NodeID, err)
		}
	}
}

// ─── Ollama integration ───────────────────────────────────────────────────────

type ollamaRequest struct {
	Model  string `json:"model"`
	Prompt string `json:"prompt"`
	Stream bool   `json:"stream"`
}

type ollamaChunk struct {
	Response string `json:"response"`
	Done     bool   `json:"done"`
}

// callOllama sends a prompt to Ollama and returns the full response.
func callOllama(ctx context.Context, host string, port int, model, prompt string, stream bool) (string, error) {
	body, _ := json.Marshal(ollamaRequest{Model: model, Prompt: prompt, Stream: false})
	url := fmt.Sprintf("http://%s:%d/api/generate", host, port)

	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("ollama unreachable on :%d — is it running? (%w)", port, err)
	}
	defer resp.Body.Close()

	var result ollamaChunk
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return "", fmt.Errorf("failed to parse ollama response: %w", err)
	}
	return result.Response, nil
}

// streamOllama sends a prompt to Ollama and calls onToken for each streamed token.
func streamOllama(ctx context.Context, host string, port int, model, prompt string, onToken func(token string, done bool)) error {
	body, _ := json.Marshal(ollamaRequest{Model: model, Prompt: prompt, Stream: true})
	url := fmt.Sprintf("http://%s:%d/api/generate", host, port)

	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("ollama unreachable on :%d (%w)", port, err)
	}
	defer resp.Body.Close()

	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var chunk ollamaChunk
		if err := json.Unmarshal(line, &chunk); err != nil {
			continue
		}
		onToken(chunk.Response, chunk.Done)
		if chunk.Done {
			break
		}
	}
	return scanner.Err()
}

// resolveModel picks the right model for this task.
// Priority: explicit model_hint > task type match via capabilities > first model
func resolveModel(cfg Config, hint string, taskType shared.TaskType) string {
	if hint != "" {
		return hint
	}
	// Use capabilities to find the best model for the task type
	if taskType != shared.TaskTypeAny {
		if m := shared.BestModelForType(cfg.Capabilities, taskType); m != "" {
			return m
		}
	}
	if len(cfg.Models) > 0 {
		return cfg.Models[0]
	}
	return "mistral"
}

// parseCapabilities parses the -capabilities flag value.
// Format: "mistral:text,summarize;codellama:code"
// If the flag is empty, falls back to registering all models as "text" capable.
func parseCapabilities(flag string, models []string) []shared.ModelCapability {
	if flag == "" {
		// Default: register every model as handling text and summarize
		caps := make([]shared.ModelCapability, 0, len(models))
		for _, m := range models {
			m = strings.TrimSpace(m)
			if m == "" {
				continue
			}
			caps = append(caps, shared.ModelCapability{
				Name:  m,
				Types: []shared.TaskType{shared.TaskTypeText, shared.TaskTypeSummarize},
			})
		}
		return caps
	}

	// Normalise separator — accept both ; and | since ; can be
	// swallowed by some shells (Git Bash on Windows in particular)
	separator := ";"
	if !strings.Contains(flag, ";") && strings.Contains(flag, "|") {
		separator = "|"
	}

	var caps []shared.ModelCapability
	for _, entry := range strings.Split(flag, separator) {
		parts := strings.SplitN(strings.TrimSpace(entry), ":", 2)
		if len(parts) != 2 {
			continue
		}
		modelName := strings.TrimSpace(parts[0])
		var types []shared.TaskType
		for _, t := range strings.Split(parts[1], ",") {
			types = append(types, shared.TaskType(strings.TrimSpace(t)))
		}
		caps = append(caps, shared.ModelCapability{Name: modelName, Types: types})
	}
	return caps
}

// ─── HTTP helper ─────────────────────────────────────────────────────────────

func postJSON(url string, payload any, out any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(raw))
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}
