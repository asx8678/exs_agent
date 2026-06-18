defmodule NanoAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :nano_agent,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: NanoAgent.CLI, name: "nano_agent"],
      deps: deps()
    ]
  end

  def application do
    [
      # :inets/:ssl give us :httpc; :json is built into OTP 27+.
      # Zero external dependencies — fitting for a "nano" agent.
      extra_applications: [:logger, :inets, :ssl],
      mod: {NanoAgent.Application, []}
    ]
  end

  defp deps do
    []
  end
end
