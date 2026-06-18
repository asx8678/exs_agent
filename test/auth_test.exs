defmodule NanoAgent.AuthTest do
  use ExUnit.Case, async: false

  alias NanoAgent.Web

  setup do
    on_exit(fn -> Application.put_env(:nano_agent, :web_token, nil) end)
    start_supervised!({Web, port: 0})
    {:ok, port: Web.port()}
  end

  defp get(port, path, headers \\ []) do
    {:ok, {{_, code, _}, _h, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}#{path}", headers}, [],
        body_format: :binary
      )

    {code, body}
  end

  test "no token configured: requests are allowed", %{port: port} do
    assert {200, _} = get(port, "/api/events")
  end

  test "token configured: request without it is 401", %{port: port} do
    Application.put_env(:nano_agent, :web_token, "s3cret")
    assert {401, body} = get(port, "/api/events")
    assert body =~ "unauthorized"
  end

  test "token configured: Bearer header is accepted", %{port: port} do
    Application.put_env(:nano_agent, :web_token, "s3cret")
    assert {200, _} = get(port, "/api/events", [{~c"authorization", ~c"Bearer s3cret"}])
  end

  test "token configured: ?token= query is accepted (for browser SSE)", %{port: port} do
    Application.put_env(:nano_agent, :web_token, "s3cret")
    assert {200, _} = get(port, "/api/events?token=s3cret")
    assert {401, _} = get(port, "/api/events?token=wrong")
  end

  test "dashboard injects the token into its client URLs", %{port: port} do
    Application.put_env(:nano_agent, :web_token, "s3cret")
    {200, html} = get(port, "/?token=s3cret")
    assert html =~ ~s(const Q="?token=s3cret")
  end
end
