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
├── Tracker           in-memory rollup for the dashboard
├── Store             durable run history (DETS) + crash-resume
├── Approvals         human-in-the-loop gate for flagged tools
├── AgentSupervisor   DynamicSupervisor — one ephemeral Agent per plan
├── TaskSupervisor    bounded fan-out for goal scheduling
├── Orchestrator      single-plan dispatch + monitoring
└── Web               live dashboard + JSON API (gen_tcp HTTP/SSE)

Goal flow:  Planner.decompose → Goal scheduler (deps + concurrency) → Agents → GoalReport
Agent loop: LLM.chat → tool calls (approval-gated, sandboxed) → checkpoint → repeat → Result
```

## Quick start

Needs Elixir/OTP 27+. No `mix deps.get` (zero deps).

```bash
cd nano_agent
export ANTHROPIC_API_KEY=sk-ant-...
iex -S mix
```

```elixir
# one plan
NanoAgent.run("List the files here and count them.")

# a goal — decomposed and fanned out
NanoAgent.run_goal("write a fizzbuzz script and run it")

# inspect history / resume interrupted runs
NanoAgent.history()
NanoAgent.resume()
```

Open the live dashboard at **http://localhost:4000**.

## CLI

```bash
mix escript.build                       # produces ./nano_agent (single file)
export ANTHROPIC_API_KEY=sk-ant-...
./nano_agent --json "add a CHANGELOG"   # NDJSON event stream + final report
./nano_agent --plan --dir ./myproj "run the tests"
```

Flags: `--plan` (single plan, skip decomposition), `--json` (NDJSON), `--dir DIR`
(sandbox to DIR), `--model`, `--concurrency N`.

## HTTP API

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | live dashboard |
| GET | `/events` | SSE event stream |
| GET | `/api/events` | recent events (JSON) |
| GET | `/api/runs` | run history (JSON) |
| GET | `/runs/:id` | one run (JSON) |
| POST | `/runs` | start: `{"plan": "..."}` or `{"goal": "..."}` |

```bash
curl -XPOST localhost:4000/runs -d '{"plan":"echo hi"}'
#=> {"run_id":"...","status":"running"}
```

## Providers

Pluggable via the `NanoAgent.Provider` behaviour. Select with
`config :nano_agent, provider: ...` or `NANO_PROVIDER`:

- `NanoAgent.Provider.Anthropic` (default) — Messages API, non-streaming
- `NanoAgent.Provider.AnthropicStream` — SSE streaming (live token deltas)
- `NanoAgent.Provider.OpenAI` — Chat Completions (translates wire format)
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
mix test                 # 30 tests, fully offline (mock provider)
mix format --check-formatted
```

CI runs compile (`--warnings-as-errors`), format check, and tests on every push.

## Status

All milestones M1–M7 implemented (see `PLAN.md`). The streaming provider's live
HTTP path is exercised against the real API; everything else is covered by the
offline test suite.
