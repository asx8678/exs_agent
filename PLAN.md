# nano_agent — Plan to Completion

> **Status: M1–M7 all implemented and tested (30 tests, 0 failures).** This plan is
> the build log; each milestone below shipped with its acceptance test. See README.md.


From the working Model A skeleton (orchestrator + in-VM agent processes, zero
deps) to a finished, usable application. Milestones are ordered by dependency and
value: each one ends with something you can actually run and demo.

**Definition of "complete":** a person can give the system a high-level goal, it
plans and executes that goal across a supervised fleet of agents using a real tool
set, you can watch it happen live, results and history are persisted, it's safe to
run on a real working directory, it's reachable via CLI / HTTP / UI, and it's
tested, packaged, and documented.

Legend — effort: S (≤½ day), M (1–2 days), L (3–5 days).

---

## Milestone 1 — Make a single agent genuinely useful
*Goal: one agent can reliably carry out a non-trivial plan against a real repo.*

- [ ] **1.1 Complete the tool set** (M) — add to `Tools`:
  - `write` (create/overwrite file), `edit` (exact string replace, must-be-unique),
    `list`/`glob` (directory + pattern), `grep` (ripgrep-style search).
  - Each: spec in `specs/0` + clause in `execute/2`. Keep returning strings.
- [ ] **1.2 Tool result robustness** (S) — truncate huge outputs (cap bytes + note),
  normalize newlines, never raise out of `execute/2` (wrap in try/rescue → error string).
- [ ] **1.3 Loop robustness** (M) — in `Agent`/`LLM`:
  - Retry transient API failures (HTTP 429/500/502/503, timeouts) with exponential
    backoff + jitter; honor `retry-after`.
  - On `@max_iterations`, return a *partial* summary instead of crashing.
  - Track token usage from the API response; expose it in the final result.
- [ ] **1.4 Result shape** (S) — replace the bare summary string with a struct:
  `%Result{summary, status, iterations, tokens, tool_calls, error}`.

**Acceptance:** `NanoAgent.run("refactor X, run the tests, report")` completes a
multi-step task end-to-end, survives a simulated 429, and returns a structured result.

---

## Milestone 2 — Make the orchestrator smart
*Goal: give a goal, not a plan. The orchestrator decomposes and coordinates.*

- [ ] **2.1 Planning step** (L) — `Orchestrator.run_goal/1`: an LLM call that
  decomposes a goal into N plans with metadata (`depends_on`, `parallelizable`).
  Reuse `LLM` with a planning system prompt + a structured-output tool.
- [ ] **2.2 Dependency execution** (M) — topologically order plans; run independent
  ones concurrently, dependent ones in sequence; thread upstream results into
  downstream plans' context.
- [ ] **2.3 Aggregation + re-planning** (M) — collect agent results; on `{:failed,_}`
  decide retry / re-plan / abort; produce a final goal-level report.
- [ ] **2.4 Concurrency control** (M) — cap in-flight agents via
  `Task.Supervisor.async_stream` (or a pool); queue the rest; per-agent timeout.

**Acceptance:** `NanoAgent.run_goal("add a /health endpoint with a test")` fans out
into ordered sub-plans, runs them with a concurrency cap, and returns one report.

---

## Milestone 3 — Make it observable
*Goal: watch the fleet live; this is the Elixir/Phoenix payoff.*

- [ ] **3.1 Event bus** (S) — agents broadcast lifecycle + tool events over
  `Phoenix.PubSub` (`:started, :tool_call, :tool_result, :iteration, :done, :failed`).
- [ ] **3.2 Streaming LLM** (M) — add SSE streaming to `LLM` (accumulate
  `*_delta` events); emit partial text/tool-arg events for live rendering.
- [ ] **3.3 Phoenix + LiveView dashboard** (L) — add Phoenix; a LiveView showing the
  live fleet (agents, current step, tokens, status) and a drill-down per-agent
  transcript. Subscribe to the PubSub topics from 3.1.
- [ ] **3.4 Telemetry** (S) — `:telemetry` spans for agent lifetime, LLM latency,
  tool duration; a simple metrics view.

**Acceptance:** start a goal, open the dashboard, and watch agents spawn, call tools,
and finish in real time.

---

## Milestone 4 — Make it durable
*Goal: nothing is lost; runs can be inspected and resumed.*

- [ ] **4.1 Persistence layer** (M) — store runs/plans/transcripts/results. Start
  simple (SQLite via Ecto, or DETS/JSON files) — schema: `runs`, `agents`, `events`.
- [ ] **4.2 Session/run history** (M) — list past runs, view a full transcript, export.
- [ ] **4.3 Resumability** (M) — persist agent message history; on crash/restart,
  resume an interrupted plan from its last good state instead of restarting.

**Acceptance:** kill the VM mid-run, restart, and the orchestrator resumes (or
cleanly reports) every in-flight agent; past runs are browsable.

---

## Milestone 5 — Make it usable by others
*Goal: drive it without an IEx shell; support more than one provider.*

- [ ] **5.1 CLI** (M) — an escript / Mix task: `nano_agent run "goal" --dir . --json`
  for headless single-shot use; stream events to stdout (NDJSON).
- [ ] **5.2 HTTP/JSON API** (M) — Phoenix endpoints: `POST /runs` (dispatch a goal),
  `GET /runs/:id` (status + result), SSE `GET /runs/:id/events` (live stream).
- [ ] **5.3 Provider abstraction** (L) — a `Provider` behaviour; keep Anthropic,
  add OpenAI (and a stub mock provider for tests). Config-select per run.
- [ ] **5.4 Config** (S) — `Config`/`Application` env for model, provider, limits,
  system prompt, working dir, concurrency cap; document every knob.

**Acceptance:** dispatch the same goal via CLI, via `curl` to the HTTP API, and via
the dashboard — all three work; switch provider with one config change.

---

## Milestone 6 — Make it safe
*Goal: safe to point at a real repo / machine.*

- [ ] **6.1 Path sandboxing** (M) — confine `read`/`write`/`edit` to an allowlisted
  root; reject traversal/symlink escapes.
- [ ] **6.2 Command policy** (M) — `bash` allow/deny patterns; opt-in approval gate
  for destructive commands; hard timeouts + process-tree kill (already partial).
- [ ] **6.3 Approval hooks** (M) — orchestrator can require human approval for flagged
  tool calls (surfaced in dashboard/CLI), agent blocks until approved/denied.
- [ ] **6.4 Optional containerization** (S, docs) — document running agents inside a
  container/sandbox for hard isolation.

**Acceptance:** an agent told to `rm -rf /` or write outside the root is blocked and
reports the refusal; destructive ops pause for approval.

---

## Milestone 7 — Make it shippable
*Goal: tested, packaged, documented.*

- [ ] **7.1 Tests** (L) — unit (tools, parsing, retry/backoff), integration with the
  mock provider (full loop, no network), supervision/crash tests (assert isolation +
  `{:failed,_}`), planning decomposition tests. Target the critical paths.
- [ ] **7.2 CI** (S) — GitHub Actions: `mix compile --warnings-as-errors`, `mix test`,
  `mix format --check-formatted`, Credo/Dialyzer.
- [ ] **7.3 Release & packaging** (M) — `mix release`; optional Burrito single-binary;
  Dockerfile; env-based runtime config.
- [ ] **7.4 Docs** (M) — finish README, architecture doc, tool-authoring guide,
  config reference, deployment guide.

**Acceptance:** clean clone → `mix test` green → `mix release` boots → documented
quickstart works for someone new.

---

## Cross-cutting / optional

- [ ] **X.1 Hot-loadable extensions** (M) — let users drop Elixir tool/extension
  modules that register at runtime via BEAM hot code loading (the analogue of pi's
  jiti-loaded TS extensions). No JS engine needed.
- [ ] **X.2 Subagents** (M) — allow an agent to spawn child agents (a `spawn_agent`
  tool) through the same orchestrator, with depth/budget limits.
- [ ] **X.3 Cost/budget guard** (S) — per-run token/cost ceiling; abort when exceeded.

---

## Suggested order & rough total

1 → 2 → 3 → (4 ‖ 5) → 6 → 7, with cross-cutting items slotted in opportunistically.
Ballpark: **~4–6 focused weeks** for a solid, demoable, safe v1 (M1–M3 + M5 CLI + M6
basics + M7 tests). Everything else hardens it toward production.

## Done? Definition-of-done checklist

- [x] Goal → plan → supervised fleet → aggregated report works headlessly
- [x] Full tool set (read/write/edit/list/glob/grep/bash), sandboxed, with approval gates
- [x] Retries/backpressure/limits make long runs reliable
- [x] Live dashboard + persisted, browsable, resumable run history
- [x] CLI + HTTP API drive it (LiveView swap-in noted; zero-dep dashboard shipped)
- [x] Multi-provider via config (Anthropic, Anthropic-stream, OpenAI, Mock)
- [x] Tests green (30/30); release + Docker build; docs complete
