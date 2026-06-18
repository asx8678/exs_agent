defmodule NanoAgent.Tools do
  @moduledoc """
  The agent's tool set: read, write, edit, list, glob, grep, bash.

  `run/2` is the safe entrypoint the agent uses — it never raises and truncates
  oversized output. Add a tool by extending `specs/0` and `execute/2`.
  Filesystem tools route through `NanoAgent.Safety` for sandboxing (M6).
  """

  alias NanoAgent.Safety

  @bash_timeout 30_000
  @max_output_bytes 30_000

  # ---- specs advertised to the model ----

  def specs do
    [
      tool(
        "read",
        "Read a UTF-8 text file and return its contents.",
        %{
          path: %{type: "string", description: "File path"}
        },
        ["path"]
      ),
      tool(
        "write",
        "Create or overwrite a file with the given content.",
        %{
          path: %{type: "string"},
          content: %{type: "string"}
        },
        ["path", "content"]
      ),
      tool(
        "edit",
        "Replace an exact, unique string in a file. Fails if the string is missing or not unique.",
        %{
          path: %{type: "string"},
          old_string: %{type: "string"},
          new_string: %{type: "string"}
        },
        ["path", "old_string", "new_string"]
      ),
      tool(
        "multi_edit",
        "Apply several exact-string edits to one file atomically (all-or-nothing). " <>
          "Each edit's old_string must be unique.",
        %{
          path: %{type: "string"},
          edits: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{old_string: %{type: "string"}, new_string: %{type: "string"}},
              required: ["old_string", "new_string"]
            }
          }
        },
        ["path", "edits"]
      ),
      tool(
        "list",
        "List entries in a directory.",
        %{
          path: %{type: "string", description: "Directory path (default '.')"}
        },
        []
      ),
      tool(
        "glob",
        "List files matching a glob pattern, e.g. lib/**/*.ex",
        %{
          pattern: %{type: "string"}
        },
        ["pattern"]
      ),
      tool(
        "grep",
        "Search files under a path for a regex; returns file:line:text.",
        %{
          pattern: %{type: "string", description: "Elixir/PCRE-style regex"},
          path: %{type: "string", description: "Root to search (default '.')"}
        },
        ["pattern"]
      ),
      tool(
        "http_fetch",
        "HTTP GET a URL and return the response body (text, truncated).",
        %{
          url: %{type: "string", description: "Absolute http(s) URL"}
        },
        ["url"]
      ),
      tool(
        "bash",
        "Run a bash command; returns combined stdout/stderr.",
        %{
          command: %{type: "string"}
        },
        ["command"]
      )
    ]
  end

  defp tool(name, description, properties, required) do
    %{
      name: name,
      description: description,
      input_schema: %{type: "object", properties: properties, required: required}
    }
  end

  # ---- safe execution ----

  @doc "Execute a tool, never raising; truncates large output."
  def run(name, input) do
    execute(name, input)
    |> truncate()
  rescue
    e -> "error: #{Exception.message(e)}"
  catch
    :exit, reason -> "error: #{inspect(reason)}"
  end

  defp truncate(s) when is_binary(s) do
    if byte_size(s) > @max_output_bytes do
      binary_part(s, 0, @max_output_bytes) <>
        "\n…[truncated #{byte_size(s) - @max_output_bytes} bytes]"
    else
      s
    end
  end

  defp truncate(other), do: inspect(other)

  # ---- tool implementations ----

  def execute("read", %{"path" => path}) do
    with {:ok, safe} <- Safety.resolve(path),
         {:ok, contents} <- File.read(safe) do
      contents
    else
      {:error, :denied} -> "error: path '#{path}' is outside the allowed root"
      {:error, reason} -> "error reading #{path}: #{:file.format_error(reason)}"
    end
  end

  def execute("write", %{"path" => path, "content" => content}) do
    with {:ok, safe} <- Safety.resolve(path),
         :ok <- File.mkdir_p(Path.dirname(safe)),
         :ok <- File.write(safe, content) do
      "wrote #{byte_size(content)} bytes to #{path}"
    else
      {:error, :denied} -> "error: path '#{path}' is outside the allowed root"
      {:error, reason} -> "error writing #{path}: #{:file.format_error(reason)}"
    end
  end

  def execute("edit", %{"path" => path, "old_string" => old, "new_string" => new}) do
    with {:ok, safe} <- Safety.resolve(path),
         {:ok, contents} <- File.read(safe) do
      case occurrences(contents, old) do
        0 -> "error: old_string not found in #{path}"
        1 -> write_edit(safe, path, String.replace(contents, old, new))
        n -> "error: old_string appears #{n} times in #{path}; make it unique"
      end
    else
      {:error, :denied} -> "error: path '#{path}' is outside the allowed root"
      {:error, reason} -> "error editing #{path}: #{:file.format_error(reason)}"
    end
  end

  def execute("multi_edit", %{"path" => path, "edits" => edits}) when is_list(edits) do
    with {:ok, safe} <- Safety.resolve(path),
         {:ok, contents} <- File.read(safe),
         {:ok, updated, n} <- apply_edits(contents, edits) do
      case File.write(safe, updated) do
        :ok -> "applied #{n} edit(s) to #{path}"
        {:error, reason} -> "error writing #{path}: #{:file.format_error(reason)}"
      end
    else
      {:error, :denied} -> "error: path '#{path}' is outside the allowed root"
      {:error, {:edit, msg}} -> "error: #{msg} (no changes written)"
      {:error, reason} -> "error editing #{path}: #{inspect(reason)}"
    end
  end

  def execute("http_fetch", %{"url" => url}) when is_binary(url) do
    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, fetch_opts(), body_format: :binary) do
      {:ok, {{_v, 200, _}, _h, body}} -> body
      {:ok, {{_v, status, _}, _h, _}} -> "error: HTTP #{status}"
      {:error, reason} -> "error fetching #{url}: #{inspect(reason)}"
    end
  end

  def execute("list", input) do
    path = Map.get(input, "path", ".")

    with {:ok, safe} <- Safety.resolve(path),
         {:ok, entries} <- File.ls(safe) do
      entries
      |> Enum.sort()
      |> Enum.map_join("\n", fn e ->
        if File.dir?(Path.join(safe, e)), do: e <> "/", else: e
      end)
      |> blank_as("(empty)")
    else
      {:error, :denied} -> "error: path '#{path}' is outside the allowed root"
      {:error, reason} -> "error listing #{path}: #{:file.format_error(reason)}"
    end
  end

  def execute("glob", %{"pattern" => pattern}) do
    case Safety.resolve(pattern) do
      {:ok, _} ->
        pattern
        |> Path.wildcard()
        |> Enum.take(500)
        |> Enum.join("\n")
        |> blank_as("(no matches)")

      {:error, :denied} ->
        "error: pattern '#{pattern}' is outside the allowed root"
    end
  end

  def execute("grep", %{"pattern" => pattern} = input) do
    root = Map.get(input, "path", ".")

    with {:ok, re} <- compile_regex(pattern),
         {:ok, safe} <- Safety.resolve(root) do
      Path.join(safe, "**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.take(2000)
      |> Enum.flat_map(&grep_file(&1, re))
      |> Enum.take(200)
      |> Enum.join("\n")
      |> blank_as("no matches")
    else
      {:error, :denied} -> "error: path '#{root}' is outside the allowed root"
      {:error, {:regex, msg}} -> "error: bad regex: #{msg}"
    end
  end

  def execute("bash", %{"command" => command}) do
    if Safety.allow_command?(command) do
      task = Task.async(fn -> System.cmd("bash", ["-c", command], stderr_to_stdout: true) end)

      case Task.yield(task, @bash_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, _exit}} -> output
        nil -> "error: command timed out after #{@bash_timeout}ms"
      end
    else
      "error: command blocked by bash policy"
    end
  end

  def execute(name, _input), do: "error: unknown tool #{name}"

  # ---- helpers ----

  defp write_edit(safe, path, new_contents) do
    case File.write(safe, new_contents) do
      :ok -> "edited #{path}"
      {:error, reason} -> "error writing #{path}: #{:file.format_error(reason)}"
    end
  end

  defp occurrences(haystack, needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end

  # Apply edits sequentially; each old_string must occur exactly once. All-or-nothing.
  defp apply_edits(contents, edits) do
    Enum.reduce_while(edits, {:ok, contents, 0}, fn edit, {:ok, acc, n} ->
      old = edit["old_string"]
      new = edit["new_string"]

      cond do
        not is_binary(old) or not is_binary(new) ->
          {:halt, {:error, {:edit, "each edit needs string old_string/new_string"}}}

        occurrences(acc, old) == 1 ->
          {:cont, {:ok, String.replace(acc, old, new), n + 1}}

        occurrences(acc, old) == 0 ->
          {:halt, {:error, {:edit, "old_string not found: #{String.slice(old, 0, 40)}"}}}

        true ->
          {:halt, {:error, {:edit, "old_string not unique: #{String.slice(old, 0, 40)}"}}}
      end
    end)
  end

  defp fetch_opts do
    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    [ssl: ssl_opts, timeout: 15_000, connect_timeout: 10_000]
  end

  defp compile_regex(pattern) do
    case Regex.compile(pattern) do
      {:ok, re} -> {:ok, re}
      {:error, {msg, _at}} -> {:error, {:regex, to_string(msg)}}
    end
  end

  defp grep_file(file, re) do
    case File.read(file) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> Regex.match?(re, line) end)
        |> Enum.map(fn {line, n} -> "#{file}:#{n}:#{String.slice(line, 0, 200)}" end)

      {:error, _} ->
        []
    end
  end

  defp blank_as("", default), do: default
  defp blank_as(s, _default), do: s
end
