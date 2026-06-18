# Changelog

## [0.1.0] — unreleased

Initial build of nano_agent: a zero-dependency Elixir/OTP orchestrator + ephemeral
agent fleet for executing goals with an LLM.

### Core
- Goal decomposition (`run_goal`) → dependency-aware, concurrency-capped **pipeline
  scheduler** → supervised fleet of in-VM agents → aggregated `GoalReport`.
- Agent tool-use loop with **context-window compaction** (drops whole tool pairs).
- Tools: `read`, `write`, `edit`, `multi_edit`, `list`, `glob`, `grep`, `http_fetch`,
  `bash`, plus `todo_write` (progress checklist) and `spawn_agent` (subagents).
- **Subagents** run under a per-agent supervisor, so terminating a parent reaps the
  whole subtree.

### Providers
- Pluggable `Provider` behaviour: **DeepSeek** (default), Anthropic, AnthropicStream
  (SSE), OpenAI, and a deterministic Mock for tests. Retries with backoff (honors
  `Retry-After`).

### Persistence & control
- Durable run history (DETS) with retention, crash-resume, run cancellation.
- `NanoAgent.export/2` (Markdown/JSON), history/metrics.

### Interfaces
- Live zero-dep dashboard (gen_tcp HTTP/SSE): per-agent cards, transcripts, todos,
  metrics strip, approve/deny buttons.
- JSON API + CLI/escript (`run`, `history`, `export`, `doctor`).

### Safety & hardening
- Sandbox (symlink-resolving path confinement), bash policy, human approval gates.
- Per-run token budget, global agent cap.
- `http_fetch` SSRF guard (private/loopback/redirect) + size cap.
- UTF-8 scrubbing of tool output; bounded `grep`.
- **API binds to loopback by default**; optional bearer token for network exposure.
- Config validation at boot.

### Tooling
- 92 offline tests (+ gated `:live` real-provider smoke tests), CI, `mix release`,
  Docker.
