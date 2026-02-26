// orchestrator/websocket.go
// Phase 5: WebSocket hub for real-time dashboard events.
//
// Manages connected dashboard clients and broadcasts mesh events
// (task routing, completions, node status changes, pipeline progress).

package main

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"echo-system/shared"
)

// ─── Global event hub ─────────────────────────────────────────────────────────

var hub = NewEventHub()

// ─── Counters for dashboard stats ─────────────────────────────────────────────

var (
	startTime      = time.Now()
	totalTasks     int64
	totalPipelines int64
	latencySum     int64 // cumulative latency in ms
	latencyCount   int64 // number of completed tasks
)

// ─── WebSocket upgrader ───────────────────────────────────────────────────────

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true }, // allow any origin
}

// ─── EventHub ─────────────────────────────────────────────────────────────────

// EventHub manages WebSocket clients and broadcasts events.
type EventHub struct {
	mu      sync.RWMutex
	clients map[*wsClient]bool
}

type wsClient struct {
	conn *websocket.Conn
	send chan []byte
}

func NewEventHub() *EventHub {
	return &EventHub{
		clients: make(map[*wsClient]bool),
	}
}

// Broadcast sends a MeshEvent to all connected dashboard clients.
func (h *EventHub) Broadcast(event shared.MeshEvent) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}

	h.mu.RLock()
	defer h.mu.RUnlock()

	for client := range h.clients {
		select {
		case client.send <- data:
		default:
			// Client buffer full — drop the message
		}
	}
}

// register adds a new client to the hub.
func (h *EventHub) register(client *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[client] = true
	log.Printf("[WS] Dashboard client connected (%d total)", len(h.clients))
}

// unregister removes a client from the hub and closes its connection.
func (h *EventHub) unregister(client *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.clients[client]; ok {
		delete(h.clients, client)
		close(client.send)
		client.conn.Close()
		log.Printf("[WS] Dashboard client disconnected (%d remaining)", len(h.clients))
	}
}

// ClientCount returns number of connected dashboard clients.
func (h *EventHub) ClientCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}

// ─── WebSocket HTTP handler ───────────────────────────────────────────────────

// handleWS upgrades an HTTP connection to a WebSocket and starts read/write pumps.
func handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[WS] Upgrade error: %v", err)
		return
	}

	client := &wsClient{
		conn: conn,
		send: make(chan []byte, 64),
	}
	hub.register(client)

	// Send initial snapshot: full mesh status + stats
	sendInitialState(client)

	// Start I/O pumps
	go client.writePump()
	go client.readPump()
}

// sendInitialState pushes the full mesh state to a newly connected client.
func sendInitialState(client *wsClient) {
	// Send all nodes
	nodes := registry.AllNodes()
	for _, node := range nodes {
		evt := shared.MeshEvent{
			Type:      "node_registered",
			Timestamp: time.Now().UnixMilli(),
			Data: shared.NodeEvent{
				NodeID:       node.NodeID,
				AgentPort:    node.AgentPort,
				Status:       node.Status,
				ActiveTasks:  node.ActiveTasks,
				Models:       node.Models,
				Capabilities: node.Capabilities,
			},
		}
		data, _ := json.Marshal(evt)
		select {
		case client.send <- data:
		default:
		}
	}

	// Send current stats
	avgLat := float64(0)
	if cnt := atomic.LoadInt64(&latencyCount); cnt > 0 {
		avgLat = float64(atomic.LoadInt64(&latencySum)) / float64(cnt)
	}
	statsEvt := shared.MeshEvent{
		Type:      "stats",
		Timestamp: time.Now().UnixMilli(),
		Data: shared.DashboardStats{
			TotalTasks:     atomic.LoadInt64(&totalTasks),
			TotalPipelines: atomic.LoadInt64(&totalPipelines),
			AvgLatencyMs:   avgLat,
			UptimeSecs:     int64(time.Since(startTime).Seconds()),
		},
	}
	data, _ := json.Marshal(statsEvt)
	select {
	case client.send <- data:
	default:
	}
}

// ─── Read/Write pumps ─────────────────────────────────────────────────────────

// readPump drains incoming messages (we don't expect any, but must read to
// detect disconnects and handle pongs).
func (c *wsClient) readPump() {
	defer hub.unregister(c)
	c.conn.SetReadLimit(4096)
	c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})
	for {
		_, _, err := c.conn.ReadMessage()
		if err != nil {
			break
		}
	}
}

// writePump sends messages from the send channel to the WebSocket.
func (c *wsClient) writePump() {
	ticker := time.NewTicker(30 * time.Second)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case msg, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// ─── Event emitters — called from task/pipeline handlers ──────────────────────

// EmitTaskRouted broadcasts that a task has been routed to a node.
func EmitTaskRouted(taskID string, taskType shared.TaskType, routedTo string, prompt string) {
	atomic.AddInt64(&totalTasks, 1)
	if len(prompt) > 120 {
		prompt = prompt[:120] + "…"
	}
	hub.Broadcast(shared.MeshEvent{
		Type:      "task_routed",
		Timestamp: time.Now().UnixMilli(),
		Data: shared.TaskEvent{
			TaskID:   taskID,
			TaskType: taskType,
			RoutedTo: routedTo,
			Prompt:   prompt,
		},
	})
}

// EmitTaskDone broadcasts that a task has completed.
func EmitTaskDone(result *shared.TaskResult) {
	atomic.AddInt64(&latencySum, result.LatencyMs)
	atomic.AddInt64(&latencyCount, 1)

	content := result.Content
	if len(content) > 200 {
		content = content[:200] + "…"
	}
	hub.Broadcast(shared.MeshEvent{
		Type:      "task_done",
		Timestamp: time.Now().UnixMilli(),
		Data: shared.TaskEvent{
			TaskID:    result.TaskID,
			TaskType:  result.TaskType,
			RoutedTo:  result.RoutedTo,
			ModelUsed: result.ModelUsed,
			Content:   content,
			LatencyMs: result.LatencyMs,
			Success:   result.Success,
			Error:     result.Error,
		},
	})
}

// EmitNodeRegistered broadcasts that a node has registered.
func EmitNodeRegistered(req shared.RegisterRequest) {
	hub.Broadcast(shared.MeshEvent{
		Type:      "node_registered",
		Timestamp: time.Now().UnixMilli(),
		Data: shared.NodeEvent{
			NodeID:       req.NodeID,
			AgentPort:    req.AgentPort,
			Status:       shared.StatusIdle,
			Models:       req.Models,
			Capabilities: req.Capabilities,
		},
	})
}

// EmitNodeStatus broadcasts a node status update (from heartbeat).
func EmitNodeStatus(nodeID string, status shared.NodeStatus, activeTasks int) {
	hub.Broadcast(shared.MeshEvent{
		Type:      "node_status",
		Timestamp: time.Now().UnixMilli(),
		Data: shared.NodeEvent{
			NodeID:      nodeID,
			Status:      status,
			ActiveTasks: activeTasks,
		},
	})
}

// EmitPipelineStarted broadcasts that a pipeline has started.
func EmitPipelineStarted(pipelineID string, totalSteps int) {
	atomic.AddInt64(&totalPipelines, 1)
	hub.Broadcast(shared.MeshEvent{
		Type:      "pipeline_started",
		Timestamp: time.Now().UnixMilli(),
		Data: shared.PipelineEvent{
			PipelineID: pipelineID,
			TotalSteps: totalSteps,
		},
	})
}

// EmitPipelineDone broadcasts that a pipeline has completed.
func EmitPipelineDone(result *shared.PipelineResult) {
	hub.Broadcast(shared.MeshEvent{
		Type:      "pipeline_done",
		Timestamp: time.Now().UnixMilli(),
		Data: shared.PipelineEvent{
			PipelineID: result.PipelineID,
			TotalSteps: result.TotalSteps,
			LatencyMs:  result.LatencyMs,
			Success:    result.Success,
			Error:      result.Error,
		},
	})
}

// EmitStats broadcasts updated dashboard stats (called periodically).
func EmitStats() {
	avgLat := float64(0)
	if cnt := atomic.LoadInt64(&latencyCount); cnt > 0 {
		avgLat = float64(atomic.LoadInt64(&latencySum)) / float64(cnt)
	}
	hub.Broadcast(shared.MeshEvent{
		Type:      "stats",
		Timestamp: time.Now().UnixMilli(),
		Data: shared.DashboardStats{
			TotalTasks:     atomic.LoadInt64(&totalTasks),
			TotalPipelines: atomic.LoadInt64(&totalPipelines),
			AvgLatencyMs:   avgLat,
			UptimeSecs:     int64(time.Since(startTime).Seconds()),
		},
	})
}

// StartStatsBroadcast starts a goroutine that sends stats every 3 seconds.
func StartStatsBroadcast() {
	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			if hub.ClientCount() > 0 {
				EmitStats()
			}
		}
	}()
}
