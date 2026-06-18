defmodule NanoAgent.Web do
  @moduledoc """
  Zero-dependency HTTP + Server-Sent-Events server (`:gen_tcp`). Serves the live
  dashboard and a small JSON API. Routes:

    * `GET  /`            — dashboard HTML
    * `GET  /events`      — SSE stream of live events
    * `GET  /api/events`  — recent events snapshot (JSON)
    * `GET  /api/runs`    — persisted run history (JSON)
    * `GET  /runs/:id`    — one persisted run (JSON)
    * `POST /runs`        — start a run: body `{"plan": "..."}` or `{"goal": "..."}`

  Drop-in replaceable by Phoenix/LiveView; this keeps the app dependency-free.
  """
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The actual bound port (useful when started with port: 0)."
  def port, do: GenServer.call(__MODULE__, :port)

  @impl true
  def init(opts) do
    requested = opts[:port] || Application.get_env(:nano_agent, :web_port, 4000)
    listen_opts = [:binary, packet: :http_bin, active: false, reuseaddr: true, backlog: 32]

    case :gen_tcp.listen(requested, listen_opts) do
      {:ok, lsock} ->
        {:ok, port} = :inet.port(lsock)
        Logger.info("dashboard listening on http://localhost:#{port}")
        spawn_link(fn -> accept_loop(lsock) end)
        {:ok, %{lsock: lsock, port: port}}

      {:error, reason} ->
        Logger.warning("dashboard disabled: cannot bind #{requested} (#{inspect(reason)})")
        :ignore
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  # ---- accept + per-connection handlers ----

  defp accept_loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        # Transfer ownership BEFORE the handler touches the socket, otherwise it
        # may recv / go active before it owns the socket (races on SSE delivery).
        pid = spawn(fn -> receive do: (:go -> handle(sock)) end)
        :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept_loop(lsock)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle(sock) do
    case read_request(sock) do
      {:ok, method, path, clen} ->
        body = if method == :POST and clen > 0, do: read_body(sock, clen), else: ""
        route(sock, method, path, body)

      _ ->
        :gen_tcp.close(sock)
    end
  end

  # packet: :http_bin makes gen_tcp parse the request line + headers for us.
  defp read_request(sock, acc \\ %{method: nil, path: nil, clen: 0}) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, {:http_request, method, {:abs_path, p}, _v}} ->
        read_request(sock, %{acc | method: method, path: p})

      {:ok, {:http_header, _, name, _, value}} ->
        acc =
          if String.downcase(to_string(name)) == "content-length",
            do: %{acc | clen: parse_int(value)},
            else: acc

        read_request(sock, acc)

      {:ok, :http_eoh} ->
        {:ok, acc.method, acc.path, acc.clen}

      other ->
        other
    end
  end

  defp read_body(sock, clen) do
    :inet.setopts(sock, packet: :raw)

    case :gen_tcp.recv(sock, clen, 10_000) do
      {:ok, data} -> data
      _ -> ""
    end
  end

  # ---- routing ----

  defp route(sock, :GET, "/", _),
    do: respond(sock, 200, "text/html; charset=utf-8", dashboard_html())

  defp route(sock, :GET, "/api/events", _),
    do: respond(sock, 200, "application/json", snapshot_json())

  defp route(sock, :GET, "/api/runs", _), do: respond(sock, 200, "application/json", runs_json())
  defp route(sock, :GET, "/events", _), do: stream_sse(sock)
  defp route(sock, :POST, "/runs", body), do: start_run(sock, body)

  defp route(sock, :GET, "/runs/" <> id, _) when id != "", do: run_detail(sock, id)

  defp route(sock, _method, _path, _body), do: respond(sock, 404, "text/plain", "not found")

  defp start_run(sock, body) do
    case safe_decode(body) do
      %{"plan" => plan} when is_binary(plan) ->
        run_id = NanoAgent.start_run(plan)

        respond(
          sock,
          202,
          "application/json",
          encode(%{"run_id" => run_id, "status" => "running"})
        )

      %{"goal" => goal} when is_binary(goal) ->
        Task.start(fn -> NanoAgent.run_goal(goal) end)
        respond(sock, 202, "application/json", encode(%{"status" => "started"}))

      _ ->
        respond(
          sock,
          400,
          "application/json",
          encode(%{"error" => ~s(expected {"plan":...} or {"goal":...})})
        )
    end
  end

  defp run_detail(sock, id) do
    case NanoAgent.Store.get(id) do
      nil ->
        respond(sock, 404, "application/json", encode(%{"error" => "not found"}))

      rec ->
        respond(
          sock,
          200,
          "application/json",
          rec |> Map.delete(:messages) |> jsonable() |> encode()
        )
    end
  end

  # ---- responses ----

  defp respond(sock, status, ctype, body) do
    reason = if status < 400, do: "OK", else: "ERR"

    head =
      "HTTP/1.1 #{status} #{reason}\r\n" <>
        "Content-Type: #{ctype}\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Access-Control-Allow-Origin: *\r\n" <>
        "Connection: close\r\n\r\n"

    :gen_tcp.send(sock, [head, body])
    :gen_tcp.close(sock)
  end

  defp stream_sse(sock) do
    headers =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: text/event-stream\r\n" <>
        "Cache-Control: no-cache\r\n" <>
        "Access-Control-Allow-Origin: *\r\n" <>
        "Connection: keep-alive\r\n\r\n"

    :gen_tcp.send(sock, headers)
    NanoAgent.Events.subscribe(:all)
    :inet.setopts(sock, active: true, packet: :raw)
    sse_loop(sock)
  end

  defp sse_loop(sock) do
    receive do
      {:nano_event, e} ->
        case :gen_tcp.send(sock, ["data: ", encode_event(e), "\n\n"]) do
          :ok -> sse_loop(sock)
          {:error, _} -> :gen_tcp.close(sock)
        end

      {:tcp_closed, ^sock} ->
        :ok

      {:tcp_error, ^sock, _} ->
        :gen_tcp.close(sock)

      {:tcp, ^sock, _ignored} ->
        sse_loop(sock)
    after
      25_000 ->
        case :gen_tcp.send(sock, ": keepalive\n\n") do
          :ok -> sse_loop(sock)
          _ -> :gen_tcp.close(sock)
        end
    end
  end

  # ---- encoding ----

  @doc false
  def encode_event(e) do
    encode(%{
      "ref" => inspect(e.ref),
      "type" => to_string(e.type),
      "payload" => jsonable(e.payload),
      "at" => e.at
    })
  end

  defp snapshot_json do
    NanoAgent.Tracker.events()
    |> Enum.map(fn e ->
      %{
        "ref" => inspect(e.ref),
        "type" => to_string(e.type),
        "payload" => jsonable(e.payload),
        "at" => e.at
      }
    end)
    |> encode()
  end

  defp runs_json do
    NanoAgent.Store.list()
    |> Enum.map(fn r -> r |> Map.delete(:messages) |> jsonable() end)
    |> encode()
  end

  defp encode(term), do: term |> :json.encode() |> IO.iodata_to_binary()

  defp safe_decode(body) do
    :json.decode(body)
  rescue
    _ -> nil
  end

  defp parse_int(v) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      :error -> 0
    end
  end

  # Make arbitrary values JSON-encodable (refs, pids, tuples -> strings).
  defp jsonable(%{} = m) when not is_struct(m),
    do: Map.new(m, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp jsonable(v) when is_atom(v), do: to_string(v)
  defp jsonable(v), do: inspect(v)

  # ---- dashboard page ----

  defp dashboard_html do
    """
    <!doctype html><html><head><meta charset="utf-8"><title>nano_agent fleet</title>
    <style>
      body{font:14px/1.5 ui-monospace,Menlo,Consolas,monospace;margin:0;background:#0b0e14;color:#cdd6f4}
      header{padding:12px 16px;background:#11151c;border-bottom:1px solid #1f2430;font-weight:600}
      header .dot{color:#a6e3a1}
      #log{padding:8px 16px}
      .e{padding:4px 8px;margin:3px 0;border-left:3px solid #45475a;background:#11151c;border-radius:0 4px 4px 0}
      .e .t{color:#89b4fa;font-weight:600}.e .r{color:#6c7086}
      .started{border-color:#89b4fa}.tool_call{border-color:#f9e2af}.tool_result{border-color:#94e2d5}
      .ok{border-color:#a6e3a1}.error{border-color:#f38ba8}.max_iterations{border-color:#fab387}.planned{border-color:#cba6f7}
      pre{margin:2px 0 0;white-space:pre-wrap;color:#bac2de}
    </style></head><body>
    <header><span class="dot">●</span> nano_agent fleet — live</header>
    <div id="log"></div>
    <script>
      const log=document.getElementById('log');
      function row(e){
        const d=document.createElement('div'); d.className='e '+e.type;
        const ref=String(e.ref).replace('#Reference','ref').slice(0,16);
        const p=e.payload||{}; let body='';
        if(p.name) body=p.name+' '+JSON.stringify(p.input||p.output_preview||'');
        else if(p.summary) body=p.summary; else body=JSON.stringify(p);
        d.innerHTML='<span class="t">'+e.type+'</span> <span class="r">'+ref+'</span><pre>'+
          body.replace(/</g,'&lt;')+'</pre>';
        log.prepend(d);
      }
      fetch('/api/events').then(r=>r.json()).then(es=>es.forEach(row)).catch(()=>{});
      const src=new EventSource('/events');
      src.onmessage=ev=>{try{row(JSON.parse(ev.data))}catch(e){}};
    </script></body></html>
    """
  end
end
