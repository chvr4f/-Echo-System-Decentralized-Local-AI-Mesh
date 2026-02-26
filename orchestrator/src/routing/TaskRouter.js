// orchestrator/src/routing/TaskRouter.js
// Decides which node handles each task and manages the execution

const { v4: uuidv4 } = require('uuid');

class TaskRouter {
  /**
   * @param {NodeRegistry} registry
   * @param {EventEmitter} eventBus  — emits events to dashboard WebSocket
   */
  constructor(registry, eventBus) {
    this.registry = registry;
    this.eventBus = eventBus;

    // Queue for tasks that had no available node
    // Map<task_id, { task, resolve, reject, queued_at }>
    this.queue = new Map();

    // Retry queued tasks every 5 seconds
    this._retryInterval = setInterval(() => this._retryQueue(), 5_000);
  }

  // ─────────────────────────────────────────────
  // PUBLIC API
  // ─────────────────────────────────────────────

  /**
   * Route a task to the best available node.
   * Returns the full result (non-streaming).
   */
  async route(task) {
    task.task_id = task.task_id || uuidv4();
    const started_at = Date.now();

    const node = this.registry.findBestNode(task.type, task.model_hint);

    if (!node) {
      // No node available right now — queue it
      console.warn(`[Router] No node available for task ${task.task_id} (type: ${task.type}). Queuing...`);
      this._emitEvent('task_queued', { task_id: task.task_id, type: task.type });

      return this._enqueue(task);
    }

    return this._execute(node, task, started_at);
  }

  /**
   * Route a task and stream tokens back via an async generator.
   * Usage:
   *   for await (const chunk of router.routeStream(task)) { ... }
   */
  async *routeStream(task) {
    task.task_id = task.task_id || uuidv4();
    const started_at = Date.now();

    const node = this.registry.findBestNode(task.type, task.model_hint);

    if (!node) {
      throw new Error(`No node available for task type: ${task.type}`);
    }

    this.registry.incrementLoad(node.node_id);
    this._emitEvent('task_started', {
      task_id: task.task_id,
      type: task.type,
      routed_to: node.node_id,
    });

    try {
      // Call the node agent's ExecuteTaskStream gRPC method
      const stream = node.grpcClient.executeTaskStream(task);

      let first_token = true;
      for await (const chunk of stream) {
        if (first_token) {
          chunk.latency_ms = Date.now() - started_at;
          first_token = false;
        }
        chunk.routed_to = node.node_id;
        yield chunk;
      }
    } finally {
      this.registry.decrementLoad(node.node_id);
      this._emitEvent('task_done', {
        task_id: task.task_id,
        routed_to: node.node_id,
        latency_ms: Date.now() - started_at,
      });
    }
  }

  // ─────────────────────────────────────────────
  // INTERNALS
  // ─────────────────────────────────────────────

  async _execute(node, task, started_at) {
    this.registry.incrementLoad(node.node_id);

    this._emitEvent('task_started', {
      task_id: task.task_id,
      type: task.type,
      routed_to: node.node_id,
    });

    try {
      // Call the node agent's ExecuteTask gRPC method
      const result = await node.grpcClient.executeTask(task);

      result.routed_to = node.node_id;
      result.latency_ms = Date.now() - started_at;
      result.success = true;

      this._emitEvent('task_done', {
        task_id: task.task_id,
        routed_to: node.node_id,
        latency_ms: result.latency_ms,
      });

      return result;

    } catch (err) {
      console.error(`[Router] Task ${task.task_id} failed on node ${node.node_id}:`, err.message);

      this._emitEvent('task_failed', {
        task_id: task.task_id,
        routed_to: node.node_id,
        error: err.message,
      });

      // Try to failover to another node
      const fallback = this.registry.findBestNode(task.type, null); // drop model hint
      if (fallback && fallback.node_id !== node.node_id) {
        console.log(`[Router] Failing over task ${task.task_id} to ${fallback.node_id}`);
        return this._execute(fallback, task, started_at);
      }

      return { success: false, error: err.message, task_id: task.task_id };

    } finally {
      this.registry.decrementLoad(node.node_id);
    }
  }

  _enqueue(task) {
    return new Promise((resolve, reject) => {
      const TTL = 30_000; // 30 seconds

      const timer = setTimeout(() => {
        this.queue.delete(task.task_id);
        reject(new Error(`Task ${task.task_id} timed out in queue after 30s`));
      }, TTL);

      this.queue.set(task.task_id, {
        task,
        resolve,
        reject,
        queued_at: Date.now(),
        timer,
      });
    });
  }

  async _retryQueue() {
    if (this.queue.size === 0) return;

    for (const [task_id, entry] of this.queue.entries()) {
      const node = this.registry.findBestNode(entry.task.type, entry.task.model_hint);

      if (node) {
        this.queue.delete(task_id);
        clearTimeout(entry.timer);

        console.log(`[Router] Dequeuing task ${task_id} → ${node.node_id}`);
        this._emitEvent('task_dequeued', { task_id, routed_to: node.node_id });

        const started_at = entry.queued_at;
        this._execute(node, entry.task, started_at)
          .then(entry.resolve)
          .catch(entry.reject);
      }
    }
  }

  _emitEvent(type, data) {
    this.eventBus.emit('mesh_event', { type, data, timestamp: Date.now() });
  }

  destroy() {
    clearInterval(this._retryInterval);
  }
}

module.exports = { TaskRouter };
