defmodule NanoAgent.Web do
  @moduledoc """
  Zero-dependency HTTP + Server-Sent-Events server (`:gen_tcp`). Serves the live
  dashboard and a small JSON API. Routes:

    * `GET  /`            — dashboard HTML
    * `GET  /events`      — SSE stream of live events
    * `GET  /api/events`  — recent events snapshot (JSON)
    * `GET  /api/runs`      — persisted run history (JSON)
    * `GET  /api/approvals` — pending approval requests (JSON)
    * `GET  /runs/:id`      — one persisted run (JSON)
    * `POST /runs`          — start a run: body `{"plan": "..."}` or `{"goal": "..."}`
    * `POST /approvals/:id` — decide: body `{"decision": "approve" | "deny"}`

  The dashboard is a single self-contained page (per-agent cards, live transcripts,
  token/status/duration, and approve/deny buttons). Drop-in replaceable by Phoenix
  LiveView; this keeps the app dependency-free.
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
        pid =
          spawn(fn ->
            receive do: (:go -> handle(sock)), after: (5_000 -> :gen_tcp.close(sock))
          end)

        :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept_loop(lsock)

      {:error, :closed} ->
        :ok

      {:error, _transient} ->
        # e.g. :emfile under fd pressure — keep the acceptor alive rather than
        # crashing the Web GenServer (it's spawn_linked to us).
        accept_loop(lsock)
    end
  end

  @max_body 1_000_000

  defp handle(sock) do
    case read_request(sock) do
      {:ok, _method, _path, clen} when clen > @max_body ->
        respond(sock, 413, "text/plain", "request body too large")

      {:ok, method, path, clen} ->
        body = if method == :POST and clen > 0, do: read_body(sock, clen), else: ""
        route(sock, method, path, body)

      _ ->
        :gen_tcp.close(sock)
    end
  end

  @max_headers 100

  # packet: :http_bin makes gen_tcp parse the request line + headers for us.
  defp read_request(sock, acc \\ %{method: nil, path: nil, clen: 0, hn: 0}) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, {:http_request, method, {:abs_path, p}, _v}} ->
        read_request(sock, %{acc | method: method, path: p})

      {:ok, {:http_header, _, _name, _, _value}} when acc.hn >= @max_headers ->
        {:error, :too_many_headers}

      {:ok, {:http_header, _, name, _, value}} ->
        acc =
          if String.downcase(to_string(name)) == "content-length",
            do: %{acc | clen: parse_int(value)},
            else: acc

        read_request(sock, %{acc | hn: acc.hn + 1})

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

  defp route(sock, :GET, "/api/approvals", _),
    do: respond(sock, 200, "application/json", approvals_json())

  defp route(sock, :GET, "/api/metrics", _),
    do:
      respond(
        sock,
        200,
        "application/json",
        NanoAgent.Metrics.snapshot() |> jsonable() |> encode()
      )

  defp route(sock, :GET, "/events", _), do: stream_sse(sock)
  defp route(sock, :POST, "/runs", body), do: start_run(sock, body)

  defp route(sock, :GET, "/runs/" <> rest, _) when rest != "", do: run_route(sock, rest)
  defp route(sock, :POST, "/runs/" <> rest, _) when rest != "", do: post_run_route(sock, rest)
  defp route(sock, :POST, "/approvals/" <> id, body) when id != "", do: decide(sock, id, body)

  defp route(sock, _method, _path, _body), do: respond(sock, 404, "text/plain", "not found")

  defp post_run_route(sock, rest) do
    case String.split(rest, "/") do
      [id, "cancel"] ->
        case NanoAgent.cancel(id) do
          :ok ->
            respond(sock, 200, "application/json", encode(%{"ok" => true}))

          {:error, reason} ->
            respond(sock, 404, "application/json", encode(%{"error" => to_string(reason)}))
        end

      _ ->
        respond(sock, 404, "text/plain", "not found")
    end
  end

  defp run_route(sock, rest) do
    case String.split(rest, "/") do
      [id] -> run_detail(sock, id)
      [id, "export.md"] -> export(sock, id, :markdown, "text/markdown; charset=utf-8")
      [id, "export.json"] -> export(sock, id, :json, "application/json")
      _ -> respond(sock, 404, "text/plain", "not found")
    end
  end

  defp export(sock, id, format, ctype) do
    result =
      if format == :json, do: NanoAgent.Export.json(id), else: NanoAgent.Export.markdown(id)

    case result do
      {:ok, body} -> respond(sock, 200, ctype, body)
      {:error, :not_found} -> respond(sock, 404, "text/plain", "not found")
    end
  end

  defp decide(sock, id, body) do
    case safe_decode(body) do
      %{"decision" => "approve"} ->
        NanoAgent.Approvals.approve(id)
        respond(sock, 200, "application/json", encode(%{"ok" => true}))

      %{"decision" => "deny"} ->
        NanoAgent.Approvals.deny(id)
        respond(sock, 200, "application/json", encode(%{"ok" => true}))

      _ ->
        respond(
          sock,
          400,
          "application/json",
          encode(%{"error" => ~s(expected {"decision":"approve"|"deny"})})
        )
    end
  end

  defp approvals_json do
    NanoAgent.Approvals.pending_details() |> jsonable() |> encode()
  end

  defp start_run(sock, body) do
    case safe_decode(body) do
      %{"plan" => plan} when is_binary(plan) ->
        case NanoAgent.start_run(plan) do
          {:ok, run_id} ->
            respond(
              sock,
              202,
              "application/json",
              encode(%{"run_id" => run_id, "status" => "running"})
            )

          {:error, reason} ->
            respond(sock, 503, "application/json", encode(%{"error" => inspect(reason)}))
        end

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
      {n, _} -> max(n, 0)
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
      :root{--bg:#0b0e14;--panel:#11151c;--line:#1f2430;--fg:#cdd6f4;--dim:#6c7086}
      *{box-sizing:border-box}
      body{font:13px/1.55 ui-monospace,Menlo,Consolas,monospace;margin:0;background:var(--bg);color:var(--fg)}
      header{display:flex;gap:16px;align-items:center;padding:10px 16px;background:var(--panel);border-bottom:1px solid var(--line);position:sticky;top:0}
      header b{font-weight:600}header .dot{color:#a6e3a1}
      .counts span{margin-left:12px;color:var(--dim)}
      .counts b{color:var(--fg)}
      #approvals:empty{display:none}
      #approvals{margin:12px 16px;padding:10px 12px;background:#241a1a;border:1px solid #6f3b3b;border-radius:8px}
      #approvals h3{margin:0 0 6px;font-size:12px;color:#f9c2c2;text-transform:uppercase;letter-spacing:.05em}
      .appr{display:flex;align-items:center;gap:8px;padding:4px 0}
      .appr code{color:#f9e2af}
      .appr .grow{flex:1;color:#bac2de;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      button{font:inherit;cursor:pointer;border:0;border-radius:5px;padding:3px 10px}
      .ok-btn{background:#2e6b3e;color:#dff5e1}.no-btn{background:#6b2e2e;color:#f5dede}
      #grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:12px;padding:12px 16px}
      .card{background:var(--panel);border:1px solid var(--line);border-left:3px solid #45475a;border-radius:0 8px 8px 0}
      .card.running{border-left-color:#89b4fa}.card.ok{border-left-color:#a6e3a1}
      .card.error{border-left-color:#f38ba8}.card.max_iterations,.card.budget{border-left-color:#fab387}
      .card h4{margin:0;padding:8px 10px;border-bottom:1px solid var(--line);display:flex;gap:8px;align-items:center}
      .badge{font-size:11px;padding:1px 7px;border-radius:10px;background:#1f2430;color:#cdd6f4}
      .card.running .badge{background:#1e2b44;color:#89b4fa}.card.ok .badge{background:#1e3a26;color:#a6e3a1}
      .card.error .badge{background:#3a1e22;color:#f38ba8}
      .card h4 .ref{color:var(--dim);font-size:11px}
      .card h4 .meta{margin-left:auto;color:var(--dim);font-size:11px}
      .plan{padding:6px 10px;color:#bac2de;white-space:pre-wrap;border-bottom:1px solid var(--line);max-height:64px;overflow:auto}
      .tx{padding:4px 10px 8px;max-height:240px;overflow:auto}
      .tx div{padding:2px 0;border-bottom:1px dashed #1a1f29}
      .tx .call{color:#f9e2af}.tx .res{color:#94e2d5}.tx .txt{color:#cdd6f4}
      .tx code{color:#fff}
      .todos{padding:6px 10px;border-bottom:1px solid var(--line)}
      .td{color:#9399b2}.td.completed{color:#a6e3a1}.td.in_progress{color:#f9e2af;font-weight:600}
    </style></head><body>
    <header>
      <b><span class="dot">●</span> nano_agent fleet</b>
      <span class="counts" id="counts"></span>
      <span class="counts" id="stats" style="margin-left:auto"></span>
    </header>
    <div id="approvals"></div>
    <div id="grid"></div>
    <script>
      const runs={}, approvals={};
      const $=id=>document.getElementById(id);
      const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
      const shortRef=r=>String(r).replace('#Reference','').replace(/[<>]/g,'').slice(0,14);

      function getRun(ref){
        if(!runs[ref]) runs[ref]={ref,status:'running',plan:'',tokens:null,tools:0,dur:null,tx:[],todos:null,at:0};
        return runs[ref];
      }
      function apply(e){
        const p=e.payload||{}; if(e.at) {}
        if(e.type=='approval_requested'){approvals[p.id]={id:p.id,name:p.name,input:p.input};return;}
        if(e.type=='approval_resolved'){delete approvals[p.id];return;}
        if(e.type=='planned') return;
        const r=getRun(e.ref); r.at=e.at||r.at;
        if(e.type=='started'){r.status='running'; r.plan=p.plan||p.run_id||'';}
        else if(e.type=='todos'){r.todos=p.items;}
        else if(e.type=='tool_call'){if(p.name!='todo_write')r.tools++; r.tx.push({k:'call',t:p.name+' '+JSON.stringify(p.input||{})});}
        else if(e.type=='tool_result'){r.tx.push({k:'res',t:(p.name||'')+' → '+(p.output_preview||'')});}
        else if(['ok','error','max_iterations','budget'].includes(e.type)){
          r.status=e.type; r.tokens=p.tokens; r.tools=p.tool_calls!=null?p.tool_calls:r.tools; r.dur=p.duration_ms;
          if(p.summary) r.tx.push({k:'txt',t:p.summary});
        }
      }
      function render(){
        // approvals
        const ap=Object.values(approvals);
        $('approvals').innerHTML = ap.length
          ? '<h3>approvals needed</h3>'+ap.map(a=>
              '<div class="appr"><code>'+esc(a.name)+'</code>'+
              '<span class="grow">'+esc(JSON.stringify(a.input||{}))+'</span>'+
              '<button class="ok-btn" onclick="decide(\\''+a.id+'\\',\\'approve\\')">approve</button>'+
              '<button class="no-btn" onclick="decide(\\''+a.id+'\\',\\'deny\\')">deny</button></div>').join('')
          : '';
        // counts
        const all=Object.values(runs);
        const c=t=>all.filter(r=>r.status==t).length;
        $('counts').innerHTML='<span>runs <b>'+all.length+'</b></span><span>running <b>'+c('running')+
          '</b></span><span>ok <b>'+c('ok')+'</b></span><span>failed <b>'+(c('error'))+'</b></span>';
        // cards (newest activity first)
        $('grid').innerHTML=all.sort((a,b)=>b.at-a.at).map(r=>{
          const meta=[r.tools+' tools', r.tokens?(r.tokens.output+' out tok'):'', r.dur?(r.dur+'ms'):'']
            .filter(Boolean).join(' · ');
          const tx=r.tx.slice(-40).map(x=>'<div class="'+(x.k=='call'?'call':x.k=='res'?'res':'txt')+'">'+esc(x.t)+'</div>').join('');
          const mark={completed:'✓',in_progress:'▸',pending:'☐'};
          const todos=r.todos?'<div class="todos">'+r.todos.map(t=>
            '<div class="td '+(t.status||'pending')+'">'+(mark[t.status]||'☐')+' '+esc(t.content)+'</div>').join('')+'</div>':'';
          return '<div class="card '+r.status+'"><h4><span class="badge">'+r.status+'</span>'+
            '<span class="ref">'+shortRef(r.ref)+'</span><span class="meta">'+meta+'</span></h4>'+
            (r.plan?'<div class="plan">'+esc(r.plan)+'</div>':'')+todos+'<div class="tx">'+tx+'</div></div>';
        }).join('');
      }
      function decide(id,decision){
        fetch('/approvals/'+id,{method:'POST',headers:{'Content-Type':'application/json'},
          body:JSON.stringify({decision})}); delete approvals[id]; render();
      }
      Promise.all([
        fetch('/api/events').then(r=>r.json()).then(es=>es.forEach(apply)).catch(()=>{}),
        fetch('/api/approvals').then(r=>r.json()).then(as=>as.forEach(a=>approvals[a.id]=a)).catch(()=>{})
      ]).then(render);
      function loadStats(){
        fetch('/api/metrics').then(r=>r.json()).then(m=>{
          $('stats').innerHTML='<span>tok in/out <b>'+m.tokens.input+'/'+m.tokens.output+
            '</b></span><span>dur p50/p95 <b>'+m.duration_ms.p50+'/'+m.duration_ms.p95+'ms</b></span>';
        }).catch(()=>{});
      }
      loadStats(); setInterval(loadStats,3000);
      const src=new EventSource('/events');
      src.onmessage=ev=>{try{apply(JSON.parse(ev.data));render()}catch(e){}};
    </script></body></html>
    """
  end
end
