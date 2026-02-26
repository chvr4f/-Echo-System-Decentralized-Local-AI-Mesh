// orchestrator/pipeline.go
// Phase 4: Pipeline Engine — chains tasks across nodes.
//
// A pipeline is a sequence of steps where each step's output feeds into the
// next step's prompt. The engine resolves {{prev_output}} and {{initial_input}}
// template variables, routes each step to the best node via the registry, and
// collects all results.
//
// Example: vision → summarize → code
//   Step 1 (vision):    describe an image      → node with llava
//   Step 2 (summarize): condense description   → node with mistral
//   Step 3 (code):      generate code from it  → node with codellama

package main

import (
	"context"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/google/uuid"

	"echo-system/shared"
)

// ─── Pipeline Engine ──────────────────────────────────────────────────────────

// ExecutePipeline runs a multi-step pipeline, routing each step to the best
// available node and threading outputs through prompt templates.
func ExecutePipeline(ctx context.Context, req shared.PipelineRequest) *shared.PipelineResult {
	if req.PipelineID == "" {
		req.PipelineID = uuid.New().String()
	}

	totalStart := time.Now()
	log.Printf("[Pipeline] Starting %s (%d steps)", req.PipelineID, len(req.Steps))

	results := make([]shared.PipelineStepResult, 0, len(req.Steps))
	prevOutput := req.InitialInput

	for i, step := range req.Steps {
		// Resolve template variables
		prompt := resolveTemplate(step.PromptTemplate, prevOutput, req.InitialInput, i)

		taskID := fmt.Sprintf("%s_step_%d", req.PipelineID, i)
		log.Printf("[Pipeline] Step %d/%d — type=%q model=%q",
			i+1, len(req.Steps), step.Type, step.ModelHint)

		// Build a normal TaskRequest and route it through the existing failover logic
		taskReq := shared.TaskRequest{
			TaskID:    taskID,
			Prompt:    prompt,
			Type:      step.Type,
			ModelHint: step.ModelHint,
		}

		stepStart := time.Now()
		taskResult, err := routeWithFailover(ctx, taskReq, nil)

		stepResult := shared.PipelineStepResult{
			StepIndex: i,
			TaskID:    taskID,
			Type:      step.Type,
		}

		if err != nil {
			// Step failed — abort the pipeline
			stepResult.Success = false
			stepResult.Error = err.Error()
			stepResult.LatencyMs = time.Since(stepStart).Milliseconds()
			results = append(results, stepResult)

			log.Printf("[Pipeline] Step %d failed: %v — aborting pipeline", i+1, err)
			return &shared.PipelineResult{
				PipelineID:  req.PipelineID,
				Steps:       results,
				FinalOutput: "",
				TotalSteps:  len(req.Steps),
				LatencyMs:   time.Since(totalStart).Milliseconds(),
				Success:     false,
				Error:       fmt.Sprintf("step %d failed: %v", i+1, err),
			}
		}

		stepResult.RoutedTo = taskResult.RoutedTo
		stepResult.ModelUsed = taskResult.ModelUsed
		stepResult.Content = taskResult.Content
		stepResult.LatencyMs = taskResult.LatencyMs
		stepResult.Success = true
		results = append(results, stepResult)

		// Thread this step's output into the next step
		prevOutput = taskResult.Content

		log.Printf("[Pipeline] Step %d done → %s (%dms, %d chars)",
			i+1, taskResult.RoutedTo, taskResult.LatencyMs, len(taskResult.Content))
	}

	log.Printf("[Pipeline] Completed %s (%d steps, %dms total)",
		req.PipelineID, len(req.Steps), time.Since(totalStart).Milliseconds())

	return &shared.PipelineResult{
		PipelineID:  req.PipelineID,
		Steps:       results,
		FinalOutput: prevOutput,
		TotalSteps:  len(req.Steps),
		LatencyMs:   time.Since(totalStart).Milliseconds(),
		Success:     true,
	}
}

// ─── Template Resolution ──────────────────────────────────────────────────────

// resolveTemplate replaces {{prev_output}}, {{initial_input}}, and
// {{step_index}} in a prompt template string.
//
// If the template is empty, the previous step's output is used as-is.
func resolveTemplate(tmpl, prevOutput, initialInput string, stepIndex int) string {
	if tmpl == "" {
		return prevOutput
	}

	r := strings.NewReplacer(
		"{{prev_output}}", prevOutput,
		"{{initial_input}}", initialInput,
		"{{step_index}}", fmt.Sprintf("%d", stepIndex),
	)
	return r.Replace(tmpl)
}
