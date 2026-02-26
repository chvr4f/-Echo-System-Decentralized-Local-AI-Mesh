// orchestrator/src/pipeline/PipelineEngine.js
// Executes multi-step AI pipelines, routing each step to the right node.
//
// Example pipeline:
//   Step 1: llava (vision) — describe an image
//   Step 2: mistral (text) — summarize the description
//   Step 3: codellama (code) — generate code based on the summary
//
// Each step can reference the previous step's output via {{prev_output}}

const { v4: uuidv4 } = require('uuid');

class PipelineEngine {
  /**
   * @param {TaskRouter} router
   * @param {EventEmitter} eventBus
   */
  constructor(router, eventBus) {
    this.router = router;
    this.eventBus = eventBus;
  }

  /**
   * Execute a full pipeline.
   *
   * @param {Object} pipelineRequest
   * @param {string} pipelineRequest.pipeline_id
   * @param {Array}  pipelineRequest.steps          — array of PipelineStep
   * @param {string} pipelineRequest.initial_input  — first prompt / text input
   * @param {Buffer} pipelineRequest.initial_image  — optional image for first step
   *
   * @returns {PipelineResult}
   */
  async execute({ pipeline_id, steps, initial_input, initial_image }) {
    pipeline_id = pipeline_id || uuidv4();

    console.log(`[Pipeline] Starting pipeline ${pipeline_id} (${steps.length} steps)`);
    this._emitEvent('pipeline_started', { pipeline_id, total_steps: steps.length });

    const results = [];
    let prev_output = initial_input;
    let prev_image  = initial_image;

    for (let i = 0; i < steps.length; i++) {
      const step = steps[i];

      // Inject previous step's output into the prompt template
      const prompt = this._resolveTemplate(step.prompt_template, {
        prev_output,
        initial_input,
        step_index: i,
      });

      console.log(`[Pipeline] Step ${i + 1}/${steps.length} — type: ${step.type}, model: ${step.model_hint || 'auto'}`);
      this._emitEvent('pipeline_step_started', {
        pipeline_id,
        step_index: i,
        type: step.type,
        model_hint: step.model_hint,
      });

      const task = {
        task_id: `${pipeline_id}_step_${i}`,
        type: step.type,
        prompt,
        image_data: i === 0 ? prev_image : null,  // only pass image on first step
        model_hint: step.model_hint || null,
        options: step.options || {},
      };

      let result;
      try {
        result = await this.router.route(task);
      } catch (err) {
        // Step failed — abort the pipeline
        console.error(`[Pipeline] Step ${i + 1} failed: ${err.message}`);
        this._emitEvent('pipeline_failed', { pipeline_id, step_index: i, error: err.message });

        return {
          pipeline_id,
          steps: results,
          final_output: null,
          success: false,
          error: `Step ${i + 1} failed: ${err.message}`,
        };
      }

      results.push(result);
      prev_output = result.content;  // pass this step's output to the next step

      this._emitEvent('pipeline_step_done', {
        pipeline_id,
        step_index: i,
        routed_to: result.routed_to,
        latency_ms: result.latency_ms,
      });
    }

    console.log(`[Pipeline] Completed pipeline ${pipeline_id}`);
    this._emitEvent('pipeline_done', { pipeline_id, total_steps: steps.length });

    return {
      pipeline_id,
      steps: results,
      final_output: prev_output,
      success: true,
      error: null,
    };
  }

  // ─────────────────────────────────────────────
  // TEMPLATE RESOLUTION
  // ─────────────────────────────────────────────

  /**
   * Resolve template variables in a prompt string.
   *
   * Supported variables:
   *   {{prev_output}}   — output from the previous step
   *   {{initial_input}} — the very first input to the pipeline
   *   {{step_index}}    — current step index (0-based)
   *
   * Example:
   *   template: "Summarize the following in one sentence: {{prev_output}}"
   *   prev_output: "A long description..."
   *   → "Summarize the following in one sentence: A long description..."
   */
  _resolveTemplate(template, vars) {
    if (!template) return vars.prev_output || '';

    return template.replace(/\{\{(\w+)\}\}/g, (match, key) => {
      return vars[key] !== undefined ? String(vars[key]) : match;
    });
  }

  _emitEvent(type, data) {
    this.eventBus.emit('mesh_event', { type, data, timestamp: Date.now() });
  }
}

// ─────────────────────────────────────────────
// EXAMPLE USAGE
// ─────────────────────────────────────────────

/*
const pipeline = {
  pipeline_id: "vision-to-code",
  initial_image: fs.readFileSync("./screenshot.png"),
  initial_input: "What do you see in this image?",
  steps: [
    {
      // Step 1: Vision node describes the image
      type: "vision",
      model_hint: "llava",
      prompt_template: "{{initial_input}}",
    },
    {
      // Step 2: Text node summarizes the description
      type: "summarize",
      model_hint: "mistral",
      prompt_template: "Summarize this in two sentences: {{prev_output}}",
    },
    {
      // Step 3: Code node generates code based on the summary
      type: "code",
      model_hint: "codellama",
      prompt_template: "Write a Python function that implements: {{prev_output}}",
    },
  ],
};

const result = await engine.execute(pipeline);
console.log(result.final_output); // the generated Python code
*/

module.exports = { PipelineEngine };
