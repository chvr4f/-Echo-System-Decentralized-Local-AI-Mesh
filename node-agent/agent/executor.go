// node-agent/agent/executor.go
// Receives tasks from the orchestrator and calls the local Ollama API.
// Streams tokens back via gRPC.

package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	pb "echo-system/proto"
)

const ollamaBaseURL = "http://localhost:11434"

type Executor struct {
	httpClient *http.Client
}

func NewExecutor() *Executor {
	return &Executor{
		httpClient: &http.Client{Timeout: 120 * time.Second},
	}
}

// ─────────────────────────────────────────────
// EXECUTE (non-streaming)
// ─────────────────────────────────────────────

func (e *Executor) Execute(ctx context.Context, task *pb.TaskRequest) (*pb.TaskResult, error) {
	model := e.resolveModel(task)

	body, err := json.Marshal(map[string]interface{}{
		"model":  model,
		"prompt": task.Prompt,
		"stream": false,
		"options": map[string]interface{}{
			"temperature": task.Options.GetTemperature(),
			"num_predict": task.Options.GetMaxTokens(),
		},
	})
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", ollamaBaseURL+"/api/generate", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := e.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ollama request failed: %w", err)
	}
	defer resp.Body.Close()

	var result struct {
		Response string `json:"response"`
		Done     bool   `json:"done"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("failed to decode ollama response: %w", err)
	}

	return &pb.TaskResult{
		TaskId:  task.TaskId,
		Content: result.Response,
		Success: true,
	}, nil
}

// ─────────────────────────────────────────────
// EXECUTE STREAM
// ─────────────────────────────────────────────

// ExecuteStream calls Ollama with stream:true and sends each token
// back through the gRPC stream as a TaskChunk.
func (e *Executor) ExecuteStream(ctx context.Context, task *pb.TaskRequest, stream pb.NodeAgent_ExecuteTaskStreamServer) error {
	model := e.resolveModel(task)

	body, err := json.Marshal(map[string]interface{}{
		"model":  model,
		"prompt": task.Prompt,
		"stream": true,
	})
	if err != nil {
		return fmt.Errorf("marshal error: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "POST", ollamaBaseURL+"/api/generate", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := e.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("ollama stream request failed: %w", err)
	}
	defer resp.Body.Close()

	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		// Check if context was cancelled (orchestrator disconnected)
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var chunk struct {
			Response string `json:"response"`
			Done     bool   `json:"done"`
		}
		if err := json.Unmarshal(line, &chunk); err != nil {
			continue // skip malformed lines
		}

		if err := stream.Send(&pb.TaskChunk{
			TaskId: task.TaskId,
			Token:  chunk.Response,
			Done:   chunk.Done,
		}); err != nil {
			return fmt.Errorf("stream send error: %w", err)
		}

		if chunk.Done {
			break
		}
	}

	return scanner.Err()
}

// ─────────────────────────────────────────────
// CAPABILITIES
// ─────────────────────────────────────────────

// GetLoadedModels queries Ollama to see what models are currently loaded
func (e *Executor) GetLoadedModels(ctx context.Context) ([]string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", ollamaBaseURL+"/api/tags", nil)
	if err != nil {
		return nil, err
	}

	resp, err := e.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}

	body, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}

	names := make([]string, len(result.Models))
	for i, m := range result.Models {
		names[i] = m.Name
	}
	return names, nil
}

// resolveModel picks the right local model for the task type
// Falls back to "mistral" as a general-purpose model
func (e *Executor) resolveModel(task *pb.TaskRequest) string {
	if task.ModelHint != "" {
		return task.ModelHint
	}

	switch task.Type {
	case pb.TaskType_CODE:
		return "codellama"
	case pb.TaskType_VISION:
		return "llava"
	case pb.TaskType_SUMMARIZE:
		return "mistral"
	case pb.TaskType_EMBED:
		return "nomic-embed-text"
	default:
		return "mistral"
	}
}
