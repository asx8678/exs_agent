import Config

config :logger, level: :info

# Default LLM provider. Override with NanoAgent.Provider.Mock in tests/offline.
config :nano_agent, provider: NanoAgent.Provider.Anthropic

# Sandbox (M6). Permissive until enforce: true with a root is set.
config :nano_agent, sandbox: []

# Live dashboard (M3).
config :nano_agent, web_enabled: true, web_port: 4000

# Durable run history (M4).
config :nano_agent, data_dir: "data"

# Default fan-out concurrency cap for goals (M5).
config :nano_agent, max_concurrency: 5

# Base unit (ms) for exponential retry backoff on transient LLM errors.
config :nano_agent, retry_base_ms: 500

# Safety (M6). Permissive defaults; tighten per deployment.
config :nano_agent,
  approvals: :auto_approve,
  approval_tools: [],
  approval_timeout_ms: 300_000,
  bash_policy: []

import_config "#{config_env()}.exs"
