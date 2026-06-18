# nano_agent

An Elixir/OTP **orchestrator + ephemeral agent fleet** for executing goals with an
LLM. Give it a goal; it decomposes the goal into sub-plans, runs them across a
supervised, dependency-aware, concurrency-capped fleet of in-VM agent processes,
streams progress live, persists history, and reports back.

**Zero external dependencies** — built entirely on OTP (`:httpc`, `:json`, `:dets`,
`:gen_tcp`, `Registry`, supervisors). Runs anywhere Elixir/OTP 27+ runs.

```elixir
NanoAgent.run_goal("add a /health endpoint and a test for it")
#=> {:ok, %NanoAgent.GoalReport{status: :ok, outcomes: [...]}}
```

## Architecture

```
NanoAgent.Supervisor
├── Events            Registry-based pub/sub (zero-dep)
├── AgentRegistry     run_id -> agent pid (for cancellation)
├── Tracker           in-memory rollup for the dashboard
├── Store             durable run history (DETS) + crash-resume
├── Approvals         human-in-the-loop gate for flagged tools
├── AgentSupervisor   DynamicSupervisor — one ephemeral Agent per plan (globally capped)
├── TaskSupervisor    bounded fan-out for goal scheduling
├── Orchestrator      single-plan dispatch + monitoring
└── Web               live dashboard + JSON API (gen_tcp HTTP/SSE)

Supporting modules: Planner, Goal, Context (history compaction), Provider.* ,
Safety (sandbox + policy), Metrics, Export, Resume.

Goal flow:  Planner.decompose → Goal scheduler (deps + concurrency) → Agents → GoalReport
Agent loop: LLM.chat → tool calls (approval-gated, sandboxed) → checkpoint → repeat → Result
```

## Tools

Agents work through a tool loop. Built-in tools:

| Tool | Purpose |
|---|---|
| `read` / `write` | read or create/overwrite a file |
| `edit` / `multi_edit` | exact-string edit; `multi_edit` applies several atomically |
| `list` / `glob` / `grep` | explore the filesystem |
| `http_fetch` | TLS-verified HTTP(S) GET |
| `bash` | run a shell command (policy-gated) |
| `todo_write` | maintain a per-run progress checklist (shown on the dashboard) |
| `spawn_agent` | delegate a sub-task to a child agent (opt-in; see Reliability) |

Filesystem tools route through the sandbox; destructive ops can require approval.
Add your own by extending `NanoAgent.Tools.specs/0` and `execute/2`.

## Quick start

Needs Elixir/OTP 27+. No `mix deps.get` (zero deps).

```bash
cd nano_agent
export DEEPSEEK_API_KEY=sk-...          # default provider; or ANTHROPIC_API_KEY / OPENAI_API_KEY
# optional: export DEEPSEEK_MODEL=deepseek-v4-pro
iex -S mix
```

```elixir
# one plan
NanoAgent.run("List the files here and count them.")

# a goal — decomposed and fanned out
NanoAgent.run_goal("write a fizzbuzz script and run it")

# inspect history / resume / cancel / export
NanoAgent.history()
NanoAgent.resume()
NanoAgent.cancel(run_id)
NanoAgent.export(run_id, :markdown)
```

Open the live dashboard at **http://localhost:4000**.

## CLI

```bash
mix escript.build                       # produces ./nano_agent (single file)
export ANTHROPIC_API_KEY=sk-ant-...
./nano_agent --json "add a CHANGELOG"   # run a goal; NDJSON event stream + report
./nano_agent --plan --dir ./myproj "run the tests"
./nano_agent history [--json]           # list past runs
./nano_agent export <run-id> [--json]   # print a run as Markdown or JSON
```

Flags: `--plan` (single plan, skip decomposition), `--json` (NDJSON / JSON output),
`--dir DIR` (sandbox to DIR), `--model`, `--concurrency N`.

## HTTP API

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | live dashboard |
| GET | `/events` | SSE event stream |
| GET | `/api/events` | recent events (JSON) |
| GET | `/api/runs` | run history (JSON) |
| GET | `/api/approvals` | pending approval requests (JSON) |
| GET | `/api/metrics` | counts, tokens, duration p50/p95 (JSON) |
| GET | `/runs/:id` | one run (JSON) |
| GET | `/runs/:id/export.md` · `.json` | export a run transcript |
| POST | `/runs` | start: `{"plan": "..."}` or `{"goal": "..."}` |
| POST | `/runs/:id/cancel` | stop a running run |
| POST | `/approvals/:id` | decide: `{"decision": "approve"|"deny"}` |

The dashboard shows per-agent cards with live transcripts, todo checklists,
token/status/duration, a fleet stats strip, and **approve/deny buttons** for runs
paused on the approval gate (`:manual` mode).

```bash
curl -XPOST localhost:4000/runs -d '{"plan":"echo hi"}'
#=> {"run_id":"...","status":"running"}
```

## Providers

Pluggable via the `NanoAgent.Provider` behaviour. Select with
`config :nano_agent, provider: ...` or `NANO_PROVIDER`:

- `NanoAgent.Provider.DeepSeek` **(default)** — official DeepSeek API (OpenAI-compatible).
  Auth `DEEPSEEK_API_KEY`; model `DEEPSEEK_MODEL` (default `deepseek-v4-pro`).
- `NanoAgent.Provider.Anthropic` — Messages API, non-streaming (`ANTHROPIC_API_KEY`)
- `NanoAgent.Provider.AnthropicStream` — SSE streaming (live token deltas)
- `NanoAgent.Provider.OpenAI` — Chat Completions (`OPENAI_API_KEY`)
- `NanoAgent.Provider.Mock` — deterministic, for tests/offline

## Safety

```elixir
config :nano_agent,
  sandbox: [root: "/path/to/project", enforce: true],  # confine file tools
  bash_policy: [deny: [~r/rm\s+-rf/], allow: nil],      # command allow/deny
  approval_tools: ["write", "edit"],                    # require approval
  approvals: :manual                                    # :auto_approve | :auto_deny | :manual
```

Destructive bash (`rm -rf`, `mkfs`, …) is always flagged for approval. In `:manual`
mode, approve via `NanoAgent.Approvals.approve/1` (pending shown on the dashboard).

## Reliability & limits

```elixir
config :nano_agent,
  context_max_messages: 40,    # compact agent history past this (on tool-pair boundaries)
  context_keep_recent: 16,     # ...keeping the plan + this many recent messages
  max_concurrency: 5,          # concurrent agents per goal (greedy pipeline scheduler)
  max_agents: 200,             # global ceiling on live agents across all goals
  max_run_tokens: :infinity,   # per-run token budget; stops with status :budget when hit
  retry_base_ms: 500,          # exp backoff base; transient 5xx/429 retried, Retry-After honored
  subagents_enabled: false,    # give agents a spawn_agent tool to delegate sub-tasks
  max_subagent_depth: 2        # ...up to this many levels deep
```

With `subagents_enabled: true`, an agent gets a `spawn_agent` tool: it delegates a
self-contained sub-task to a fresh child agent (its own run, transcript, and
dashboard card), blocks on the result, and continues — bounded by depth. Each agent
runs its children under its own supervisor linked to itself, so terminating a parent
(cancel/timeout/crash) reaps the entire subtree recursively.

The goal scheduler is a greedy pipeline: each plan starts the instant its
dependencies clear, not at a wave boundary. Filesystem tools resolve symlinks
before the sandbox containment check. Store checkpoints are async (non-blocking).

## Configuration

App env (see `config/`), overridable at release runtime via env vars
(`config/runtime.exs`): `NANO_WEB_PORT`, `NANO_WEB_DISABLED`, `NANO_DATA_DIR`,
`NANO_PROVIDER`, `NANO_MAX_CONCURRENCY`. Model via `ANTHROPIC_MODEL` / `OPENAI_MODEL`.

## Deploy

```bash
MIX_ENV=prod mix release          # self-contained OTP release in _build/prod/rel
# or
docker build -t nano_agent .
docker run -e ANTHROPIC_API_KEY=sk-... -p 4000:4000 -v $PWD/data:/data nano_agent
```

## Test

```bash
mix test                 # 58 tests, fully offline (mock provider)
mix format --check-formatted
```

CI runs compile (`--warnings-as-errors`), format check, and tests on every push.

## Status

Feature-complete and hardened: goal decomposition, pipeline scheduling, subagents,
the full tool set, sandboxing + approval gates, persistence + crash-resume + run
cancellation, a live dashboard (metrics, todos, approvals), multi-provider, context
management, budgets/caps, session export, and a full CLI — all on **zero
dependencies** with **58 passing offline tests**.

**Caveat worth knowing:** the test suite uses the deterministic mock provider, so
the real LLM HTTP / streaming / OpenAI-translation paths are structurally complete
but not yet exercised end-to-end against a live API. Run `scripts/live_check.exs`
with a real key to validate them.
