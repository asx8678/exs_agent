import Config

# Runtime (release) configuration, read from the environment at boot.
# Provider API keys (ANTHROPIC_API_KEY / OPENAI_API_KEY) are read on each call.

if port = System.get_env("NANO_WEB_PORT") do
  config :nano_agent, web_port: String.to_integer(port)
end

if System.get_env("NANO_WEB_DISABLED") in ~w(1 true yes) do
  config :nano_agent, web_enabled: false
end

if bind = System.get_env("NANO_WEB_BIND") do
  config :nano_agent, web_bind: bind
end

if token = System.get_env("NANO_WEB_TOKEN") do
  config :nano_agent, web_token: token
end

if dir = System.get_env("NANO_DATA_DIR") do
  config :nano_agent, data_dir: dir
end

case System.get_env("NANO_PROVIDER") do
  "deepseek" -> config :nano_agent, provider: NanoAgent.Provider.DeepSeek
  "openai" -> config :nano_agent, provider: NanoAgent.Provider.OpenAI
  "anthropic-stream" -> config :nano_agent, provider: NanoAgent.Provider.AnthropicStream
  "anthropic" -> config :nano_agent, provider: NanoAgent.Provider.Anthropic
  _ -> :ok
end

if n = System.get_env("NANO_MAX_CONCURRENCY") do
  config :nano_agent, max_concurrency: String.to_integer(n)
end
