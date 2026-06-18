import Config

config :logger, level: :info

# Default LLM provider. Override with NanoAgent.Provider.Mock in tests/offline.
# DeepSeek is OpenAI-compatible; set DEEPSEEK_API_KEY and (optionally) DEEPSEEK_MODEL.
config :nano_agent, provider: NanoAgent.Provider.DeepSeek

# Sandbox (M6). Permissive until enforce: true with a root is set.
config :nano_agent, sandbox: []

# Live dashboard (M3). Binds to loopback by default — the API can run bash on the
# host, so only expose it on a network behind a token. Set web_bind: "0.0.0.0" and
# web_token: "secret" to expose it; clients then pass `Authorization: Bearer secret`
# or `?token=secret`.
config :nano_agent,
  web_enabled: true,
  web_port: 4000,
  web_bind: "127.0.0.1",
  web_token: nil

# Durable run history (M4).
config :nano_agent, data_dir: "data"

# Default fan-out concurrency cap for goals (M5).
config :nano_agent, max_concurrency: 5

# Global ceiling on simultaneously-live agents (safety valve across all goals).
config :nano_agent, max_agents: 200

# Per-run token budget guard. :infinity = unlimited; an integer caps total tokens.
config :nano_agent, max_run_tokens: :infinity

# Base unit (ms) for exponential retry backoff on transient LLM errors.
config :nano_agent, retry_base_ms: 500

# Context-window management: compact agent history past max_messages, keeping
# the plan + the most recent keep_recent messages (kept on tool-pair boundaries).
config :nano_agent, context_max_messages: 40, context_keep_recent: 16

# Subagents: when enabled, agents get a spawn_agent tool to delegate sub-tasks to
# supervised child agents, up to max_subagent_depth levels deep.
config :nano_agent, subagents_enabled: false, max_subagent_depth: 2

# http_fetch tool: blocks private/loopback/link-local hosts (SSRF guard) and caps
# the download size. Set allow_private: true only in trusted/local setups.
config :nano_agent,
  http_fetch_enabled: true,
  http_fetch_max_bytes: 200_000,
  http_fetch_allow_private: false

# Run retention: keep at most this many runs in the durable store (0 = unlimited).
config :nano_agent, max_stored_runs: 1000

# How long to wait on a child/subagent before timing it out.
config :nano_agent, agent_timeout_ms: 180_000

# Safety (M6). Permissive defaults; tighten per deployment.
config :nano_agent,
  approvals: :auto_approve,
  approval_tools: [],
  approval_timeout_ms: 300_000,
  bash_policy: []

import_config "#{config_env()}.exs"
