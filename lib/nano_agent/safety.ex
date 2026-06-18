defmodule NanoAgent.Safety do
  @moduledoc """
  Filesystem + command guardrails.

  Configure via application env:

      config :nano_agent,
        sandbox: [root: "/path/to/project", enforce: true],
        bash_policy: [deny: [~r/rm\\s+-rf/], allow: nil],
        approval_tools: ["write", "edit"]   # tools that require human approval

  * `resolve/1`           — confine a path to the sandbox root (blocks `..` escape).
  * `allow_command?/1`    — apply the bash allow/deny policy.
  * `requires_approval?/2`— whether a tool call must be approved before running.
  """

  @destructive [
    ~r/\brm\s+-rf\b/,
    ~r/\bmkfs\b/,
    ~r/\bdd\s+if=/,
    ~r/:\(\)\s*\{.*\};:/,
    ~r/\bshutdown\b/,
    ~r/>\s*\/dev\/sd[a-z]/
  ]

  # ---- path sandboxing ----

  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, :denied}
  def resolve(path) do
    case sandbox_root() do
      nil ->
        {:ok, path}

      root ->
        root = canonical(Path.expand(root))
        full = Path.expand(path, root)
        # Check the *real* path (symlinks resolved), not just the lexical one, so a
        # symlink inside the root pointing outside can't be used to escape.
        if within?(canonical(full), root), do: {:ok, full}, else: {:error, :denied}
    end
  end

  defp sandbox_root do
    cfg = Application.get_env(:nano_agent, :sandbox, [])
    if cfg[:enforce], do: cfg[:root], else: nil
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Resolve symlinks (including symlinked ancestors of a not-yet-existing path).
  # `fuel` bounds symlink-cycle recursion; exhausting it yields a path that will
  # fail containment, i.e. fail closed.
  defp canonical(path, fuel \\ 40)
  defp canonical(path, 0), do: path

  defp canonical(path, fuel) do
    case File.read_link(path) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(path))

        canonical(target, fuel - 1)

      {:error, _} ->
        dir = Path.dirname(path)
        if dir == path, do: path, else: Path.join(canonical(dir, fuel - 1), Path.basename(path))
    end
  end

  # ---- bash command policy ----

  @spec allow_command?(String.t()) :: boolean()
  def allow_command?(command) do
    policy = Application.get_env(:nano_agent, :bash_policy, [])
    deny = policy[:deny] || []
    allow = policy[:allow]

    cond do
      Enum.any?(deny, &match_pattern?(&1, command)) -> false
      is_list(allow) -> Enum.any?(allow, &match_pattern?(&1, command))
      true -> true
    end
  end

  # ---- approval gating ----

  @spec requires_approval?(String.t(), map()) :: boolean()
  def requires_approval?(name, input) do
    name in Application.get_env(:nano_agent, :approval_tools, []) or
      destructive_bash?(name, input)
  end

  defp destructive_bash?("bash", %{"command" => cmd}),
    do: Enum.any?(@destructive, &Regex.match?(&1, cmd))

  defp destructive_bash?(_, _), do: false

  # ---- helpers ----

  defp match_pattern?(%Regex{} = re, s), do: Regex.match?(re, s)
  defp match_pattern?(str, s) when is_binary(str), do: String.contains?(s, str)
end
