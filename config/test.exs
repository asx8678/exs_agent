import Config

# Tests never hit the network — use the deterministic mock provider.
config :nano_agent, provider: NanoAgent.Provider.Mock
config :logger, level: :warning

# Don't auto-bind the dashboard port during tests; tests start Web explicitly.
config :nano_agent, web_enabled: false

# Isolate persisted run history under a temp dir for tests.
config :nano_agent, data_dir: Path.join(System.tmp_dir!(), "nano_agent_test")

# Make retry backoff effectively instant in tests.
config :nano_agent, retry_base_ms: 1
