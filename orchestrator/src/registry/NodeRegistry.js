// orchestrator/src/registry/NodeRegistry.js
// Tracks all live nodes, their capabilities, and current load

class NodeRegistry {
  constructor() {
    // Map<node_id, NodeEntry>
    this.nodes = new Map();

    // Cleanup dead nodes every 10 seconds
    this._cleanupInterval = setInterval(() => this._evictDeadNodes(), 10_000);
  }

  // ─────────────────────────────────────────────
  // REGISTRATION
  // ─────────────────────────────────────────────

  register(capabilities) {
    const { node_id, host, port, models, hardware } = capabilities;

    const entry = {
      node_id,
      host,
      port,
      models,       // [{ name, type, size_gb, is_loaded }]
      hardware,     // { ram_total_gb, ram_free_gb, has_gpu, ... }
      status: 'idle',
      active_tasks: 0,
      registered_at: Date.now(),
      last_heartbeat: Date.now(),
    };

    this.nodes.set(node_id, entry);
    console.log(`[Registry] Node registered: ${node_id} @ ${host}:${port}`);
    console.log(`[Registry] Models: ${models.map(m => m.name).join(', ')}`);

    return entry;
  }

  unregister(node_id) {
    if (this.nodes.has(node_id)) {
      this.nodes.delete(node_id);
      console.log(`[Registry] Node unregistered: ${node_id}`);
    }
  }

  // ─────────────────────────────────────────────
  // HEARTBEAT
  // ─────────────────────────────────────────────

  heartbeat(node_id, { status, active_tasks, ram_free_gb }) {
    const node = this.nodes.get(node_id);
    if (!node) return false;

    node.last_heartbeat = Date.now();
    node.status = status;
    node.active_tasks = active_tasks;
    node.hardware.ram_free_gb = ram_free_gb;

    return true;
  }

  // ─────────────────────────────────────────────
  // QUERYING
  // ─────────────────────────────────────────────

  /**
   * Find the best node for a given task.
   *
   * Priority order:
   *  1. Exact model match (if model_hint provided)
   *  2. Task type match (node has a model of that type)
   *  3. Lowest active_tasks (load balancing)
   *  4. Highest ram_free_gb (tiebreaker)
   *
   * Returns null if no suitable node is available.
   */
  findBestNode(task_type, model_hint = null) {
    const candidates = [...this.nodes.values()].filter(node =>
      node.status !== 'offline' &&
      node.status !== 'overloaded' &&
      this._isAlive(node) &&
      this._canHandle(node, task_type, model_hint)
    );

    if (candidates.length === 0) return null;

    // Sort by: active_tasks ASC, then ram_free_gb DESC
    candidates.sort((a, b) => {
      if (a.active_tasks !== b.active_tasks) {
        return a.active_tasks - b.active_tasks;
      }
      return b.hardware.ram_free_gb - a.hardware.ram_free_gb;
    });

    return candidates[0];
  }

  getNode(node_id) {
    return this.nodes.get(node_id) || null;
  }

  getAllNodes() {
    return [...this.nodes.values()];
  }

  getLiveNodes() {
    return [...this.nodes.values()].filter(n => this._isAlive(n));
  }

  // ─────────────────────────────────────────────
  // TASK TRACKING
  // ─────────────────────────────────────────────

  incrementLoad(node_id) {
    const node = this.nodes.get(node_id);
    if (node) {
      node.active_tasks++;
      if (node.active_tasks >= 5) node.status = 'busy';
    }
  }

  decrementLoad(node_id) {
    const node = this.nodes.get(node_id);
    if (node) {
      node.active_tasks = Math.max(0, node.active_tasks - 1);
      if (node.active_tasks < 5) node.status = 'idle';
    }
  }

  // ─────────────────────────────────────────────
  // INTERNALS
  // ─────────────────────────────────────────────

  _isAlive(node) {
    // Node is considered dead if no heartbeat in 15 seconds
    return (Date.now() - node.last_heartbeat) < 15_000;
  }

  _canHandle(node, task_type, model_hint) {
    if (model_hint) {
      // Exact model requested — does this node have it loaded?
      return node.models.some(m => m.name === model_hint && m.is_loaded);
    }

    // Task type match — does any loaded model handle this type?
    // task_type comes in as a string: 'code', 'text', 'vision', etc.
    return node.models.some(m => m.type === task_type && m.is_loaded);
  }

  _evictDeadNodes() {
    for (const [id, node] of this.nodes.entries()) {
      if (!this._isAlive(node)) {
        node.status = 'offline';
        console.warn(`[Registry] Node went offline: ${id}`);
        // Don't delete — keep in registry so dashboard can show it as offline
      }
    }
  }

  destroy() {
    clearInterval(this._cleanupInterval);
  }
}

module.exports = { NodeRegistry };
