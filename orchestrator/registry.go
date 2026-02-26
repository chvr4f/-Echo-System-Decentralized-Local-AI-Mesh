// orchestrator/registry.go
// Keeps track of all connected node-agents.
// Thread-safe — multiple HTTP handlers read/write concurrently.

package main

import (
	"fmt"
	"log"
	"sync"
	"time"

	"echo-system/shared"
)

// Registry holds all known nodes and provides routing decisions.
type Registry struct {
	mu    sync.RWMutex
	nodes map[string]*shared.NodeInfo // keyed by node_id
}

func NewRegistry() *Registry {
	r := &Registry{
		nodes: make(map[string]*shared.NodeInfo),
	}
	// Start background goroutine that marks stale nodes as offline
	go r.evictLoop()
	return r
}

// ─── Registration ─────────────────────────────────────────────────────────────

func (r *Registry) Register(req shared.RegisterRequest) {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now().UnixMilli()
	r.nodes[req.NodeID] = &shared.NodeInfo{
		NodeID:        req.NodeID,
		AgentPort:     req.AgentPort,
		OllamaPort:    req.OllamaPort,
		Models:        req.Models,
		Capabilities:  req.Capabilities,
		Status:        shared.StatusIdle,
		ActiveTasks:   0,
		LastHeartbeat: now,
		RegisteredAt:  now,
	}
	log.Printf("[Registry] Node registered: %s (agent :%d, ollama :%d, models: %v)",
		req.NodeID, req.AgentPort, req.OllamaPort, req.Models)
	for _, cap := range req.Capabilities {
		log.Printf("[Registry]   %s handles: %v", cap.Name, cap.Types)
	}
}

// ─── Heartbeat ────────────────────────────────────────────────────────────────

// Heartbeat updates a node's last-seen time and load metrics.
// Returns false if the node isn't registered.
func (r *Registry) Heartbeat(req shared.HeartbeatRequest) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	node, ok := r.nodes[req.NodeID]
	if !ok {
		return false
	}
	node.LastHeartbeat = time.Now().UnixMilli()
	node.Status = req.Status
	node.ActiveTasks = req.ActiveTasks
	return true
}

// ─── Routing ──────────────────────────────────────────────────────────────────

// FindBestNode returns the most suitable live node for a task.
//
// Phase 3 routing priority:
//   1. Exact model match   (model_hint specified by client)
//   2. Task type match     (node has a model that handles this task type)
//   3. Any available node  (fallback if no type was specified)
//   4. Fewest active tasks (tiebreaker at each level)
func (r *Registry) FindBestNode(taskType shared.TaskType, modelHint string) (*shared.NodeInfo, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	return r.findBest(taskType, modelHint, nil)
}

// ─── Load tracking ────────────────────────────────────────────────────────────

func (r *Registry) IncrementLoad(nodeID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if node, ok := r.nodes[nodeID]; ok {
		node.ActiveTasks++
		if node.ActiveTasks >= 5 {
			node.Status = shared.StatusBusy
		}
	}
}

func (r *Registry) DecrementLoad(nodeID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if node, ok := r.nodes[nodeID]; ok {
		if node.ActiveTasks > 0 {
			node.ActiveTasks--
		}
		if node.ActiveTasks < 5 {
			node.Status = shared.StatusIdle
		}
	}
}

// ─── Status ───────────────────────────────────────────────────────────────────

func (r *Registry) AllNodes() []*shared.NodeInfo {
	r.mu.RLock()
	defer r.mu.RUnlock()
	list := make([]*shared.NodeInfo, 0, len(r.nodes))
	for _, n := range r.nodes {
		copy := *n // return a copy so callers can't mutate registry state
		list = append(list, &copy)
	}
	return list
}

// ─── Eviction loop ────────────────────────────────────────────────────────────

// evictLoop runs every 5 seconds and marks nodes as offline
// if they haven't sent a heartbeat in 15 seconds.
func (r *Registry) evictLoop() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		r.mu.Lock()
		for id, node := range r.nodes {
			if node.Status != shared.StatusOffline && !r.isAlive(node) {
				node.Status = shared.StatusOffline
				log.Printf("[Registry] Node went offline: %s (no heartbeat for 15s)", id)
			}
		}
		r.mu.Unlock()
	}
}

// isAlive checks if the node sent a heartbeat recently.
// Must be called with at least a read lock held.
func (r *Registry) isAlive(node *shared.NodeInfo) bool {
	return time.Now().UnixMilli()-node.LastHeartbeat < 15_000
}

func containsModel(models []string, target string) bool {
	for _, m := range models {
		if m == target {
			return true
		}
	}
	return false
}

// FindBestNodeExcluding is like FindBestNode but skips nodes in the
// already-tried set. Used by the failover router.
func (r *Registry) FindBestNodeExcluding(taskType shared.TaskType, modelHint string, exclude map[string]bool) (*shared.NodeInfo, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	return r.findBest(taskType, modelHint, exclude)
}

// findBest is the shared routing logic used by both FindBestNode and
// FindBestNodeExcluding. Must be called with at least a read lock held.
//
// Routing tiers (tried in order, picks lowest active_tasks within each tier):
//   Tier 1: exact model name match (model_hint)
//   Tier 2: task type match via capabilities
//   Tier 3: any live node (fallback when type is TaskTypeAny)
func (r *Registry) findBest(taskType shared.TaskType, modelHint string, exclude map[string]bool) (*shared.NodeInfo, error) {
	isCandidate := func(node *shared.NodeInfo) bool {
		if exclude != nil && exclude[node.NodeID] {
			return false
		}
		if !r.isAlive(node) {
			return false
		}
		if node.Status == shared.StatusOverloaded || node.Status == shared.StatusOffline {
			return false
		}
		return true
	}

	pickBetter := func(current, candidate *shared.NodeInfo) *shared.NodeInfo {
		if current == nil || candidate.ActiveTasks < current.ActiveTasks {
			return candidate
		}
		return current
	}

	var tier1, tier2, tier3 *shared.NodeInfo

	for _, node := range r.nodes {
		if !isCandidate(node) {
			continue
		}

		// Tier 1: exact model name requested
		if modelHint != "" && containsModel(node.Models, modelHint) {
			tier1 = pickBetter(tier1, node)
			continue
		}

		// Tier 2: node has a model that handles this task type
		if taskType != shared.TaskTypeAny && shared.CanHandle(node.Capabilities, taskType) {
			tier2 = pickBetter(tier2, node)
			continue
		}

		// Tier 3: no type preference — any live node works
		tier3 = pickBetter(tier3, node)
	}

	// Return highest-priority tier that found a node
	if tier1 != nil {
		log.Printf("[Registry] Routing via tier1 (exact model: %s)", modelHint)
		return tier1, nil
	}
	if tier2 != nil {
		log.Printf("[Registry] Routing via tier2 (task type: %s)", taskType)
		return tier2, nil
	}
	if tier3 != nil {
		log.Printf("[Registry] Routing via tier3 (any node — no type specified)")
		return tier3, nil
	}

	return nil, fmt.Errorf("no node available for type=%q model=%q (registered: %d)", taskType, modelHint, len(r.nodes))
}

// MarkSuspect temporarily marks a node as overloaded after a task failure.
// It will recover automatically on the next successful heartbeat.
func (r *Registry) MarkSuspect(nodeID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if node, ok := r.nodes[nodeID]; ok {
		node.Status = shared.StatusOverloaded
		log.Printf("[Registry] Node %s marked suspect after failure", nodeID)
	}
}