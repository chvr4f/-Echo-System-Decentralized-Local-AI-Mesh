// shared/types.go
// Common types used by both the orchestrator and node-agent.

package shared

// ─── Task Types ───────────────────────────────────────────────────────────────

// TaskType tells the orchestrator what kind of work this task requires.
type TaskType string

const (
	TaskTypeText      TaskType = "text"
	TaskTypeCode      TaskType = "code"
	TaskTypeVision    TaskType = "vision"
	TaskTypeSummarize TaskType = "summarize"
	TaskTypeEmbed     TaskType = "embed"
	TaskTypeAny       TaskType = "" // no preference — pick least busy
)

// ─── Task ─────────────────────────────────────────────────────────────────────

// TaskRequest is what a client sends to the orchestrator.
type TaskRequest struct {
	TaskID    string   `json:"task_id"`
	Prompt    string   `json:"prompt"`
	Type      TaskType `json:"type,omitempty"`       // routing hint: code/text/vision/summarize
	ModelHint string   `json:"model_hint,omitempty"` // optional: request a specific model by name
}

// TaskChunk is one streamed token from a node back to the client.
type TaskChunk struct {
	TaskID    string `json:"task_id"`
	Token     string `json:"token"`
	Done      bool   `json:"done"`
	RoutedTo  string `json:"routed_to"`
	LatencyMs int64  `json:"latency_ms,omitempty"`
}

// TaskResult is the full response for non-streamed tasks.
type TaskResult struct {
	TaskID    string   `json:"task_id"`
	Content   string   `json:"content"`
	RoutedTo  string   `json:"routed_to"`
	ModelUsed string   `json:"model_used"` // which model actually ran this
	TaskType  TaskType `json:"task_type"`  // echoed back so client knows how it was routed
	LatencyMs int64    `json:"latency_ms"`
	Success   bool     `json:"success"`
	Error     string   `json:"error,omitempty"`
}

// ─── Node ─────────────────────────────────────────────────────────────────────

type NodeStatus string

const (
	StatusIdle       NodeStatus = "idle"
	StatusBusy       NodeStatus = "busy"
	StatusOverloaded NodeStatus = "overloaded"
	StatusOffline    NodeStatus = "offline"
)

// ModelCapability describes a single model and what task types it handles.
//
//	{"name":"codellama", "types":["code"]}
//	{"name":"mistral",   "types":["text","summarize"]}
type ModelCapability struct {
	Name  string     `json:"name"`
	Types []TaskType `json:"types"`
}

// RegisterRequest is sent by a node-agent to the orchestrator on startup.
type RegisterRequest struct {
	NodeID       string            `json:"node_id"`
	AgentPort    int               `json:"agent_port"`
	OllamaPort   int               `json:"ollama_port"`
	Models       []string          `json:"models"`       // kept for backwards compat
	Capabilities []ModelCapability `json:"capabilities"` // rich map used in Phase 3+
	Status       NodeStatus        `json:"status"`
}

// HeartbeatRequest is sent every 3 seconds from node to orchestrator.
type HeartbeatRequest struct {
	NodeID      string     `json:"node_id"`
	Status      NodeStatus `json:"status"`
	ActiveTasks int        `json:"active_tasks"`
}

// NodeInfo is how the orchestrator stores a connected node internally.
type NodeInfo struct {
	NodeID        string            `json:"node_id"`
	AgentPort     int               `json:"agent_port"`
	OllamaPort    int               `json:"ollama_port"`
	Models        []string          `json:"models"`
	Capabilities  []ModelCapability `json:"capabilities"`
	Status        NodeStatus        `json:"status"`
	ActiveTasks   int               `json:"active_tasks"`
	LastHeartbeat int64             `json:"last_heartbeat"`
	RegisteredAt  int64             `json:"registered_at"`
}

// ─── Capability helpers ───────────────────────────────────────────────────────

// BestModelForType returns the first model on this node that handles
// the requested task type, or "" if none match.
func BestModelForType(caps []ModelCapability, t TaskType) string {
	if t == TaskTypeAny {
		if len(caps) > 0 {
			return caps[0].Name
		}
		return ""
	}
	for _, c := range caps {
		for _, ct := range c.Types {
			if ct == t {
				return c.Name
			}
		}
	}
	return ""
}

// CanHandle returns true if this node has any model that handles task type t.
func CanHandle(caps []ModelCapability, t TaskType) bool {
	return BestModelForType(caps, t) != ""
}

// ─── Pipeline Types ───────────────────────────────────────────────────────────
// Used by the Phase 4 pipeline engine to chain tasks across nodes.

// PipelineStep describes one step in a multi-step pipeline.
// The prompt_template can include {{prev_output}} and {{initial_input}}.
type PipelineStep struct {
	Type           TaskType `json:"type"`                      // routing hint for this step
	ModelHint      string   `json:"model_hint,omitempty"`      // optional: force a specific model
	PromptTemplate string   `json:"prompt_template,omitempty"` // template with {{prev_output}}, {{initial_input}}
}

// PipelineRequest is what a client sends to POST /pipeline.
type PipelineRequest struct {
	PipelineID   string         `json:"pipeline_id,omitempty"`
	Steps        []PipelineStep `json:"steps"`
	InitialInput string         `json:"initial_input"` // seed text / first prompt
}

// PipelineStepResult captures the outcome of a single pipeline step.
type PipelineStepResult struct {
	StepIndex int      `json:"step_index"`
	TaskID    string   `json:"task_id"`
	Type      TaskType `json:"task_type"`
	RoutedTo  string   `json:"routed_to"`
	ModelUsed string   `json:"model_used"`
	Content   string   `json:"content"`
	LatencyMs int64    `json:"latency_ms"`
	Success   bool     `json:"success"`
	Error     string   `json:"error,omitempty"`
}

// PipelineResult is the full response returned by POST /pipeline.
type PipelineResult struct {
	PipelineID  string               `json:"pipeline_id"`
	Steps       []PipelineStepResult `json:"steps"`
	FinalOutput string               `json:"final_output"`
	TotalSteps  int                  `json:"total_steps"`
	LatencyMs   int64                `json:"latency_ms"`
	Success     bool                 `json:"success"`
	Error       string               `json:"error,omitempty"`
}
