defmodule NanoAgent.M5Test do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias NanoAgent.{Web, Store, CLI, Provider.OpenAI, Provider.Mock}

  setup do
    Store.clear()
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  describe "OpenAI provider translation (offline)" do
    test "tools translate to function format" do
      [t | _] = OpenAI.to_openai_tools(NanoAgent.Tools.specs())
      assert t.type == "function"
      assert t.function.name == "read"
      assert is_map(t.function.parameters)
    end

    test "messages translate, including tool results" do
      messages = [
        %{role: "user", content: "hi"},
        %{
          role: "assistant",
          content: [
            %{
              "type" => "tool_use",
              "id" => "c1",
              "name" => "bash",
              "input" => %{"command" => "ls"}
            }
          ]
        },
        %{
          role: "user",
          content: [%{"type" => "tool_result", "tool_use_id" => "c1", "content" => "a\nb"}]
        }
      ]

      out = OpenAI.to_openai_messages(messages, "sys")
      assert hd(out) == %{role: "system", content: "sys"}
      assert Enum.any?(out, &(&1[:role] == "tool" and &1[:tool_call_id] == "c1"))
      assert Enum.any?(out, &(&1[:role] == "assistant" and is_list(&1[:tool_calls])))
    end

    test "an OpenAI response with a tool call normalizes correctly" do
      resp = %{
        "choices" => [
          %{
            "message" => %{
              "content" => nil,
              "tool_calls" => [
                %{"id" => "x", "function" => %{"name" => "read", "arguments" => ~s({"path":"a"})}}
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 4}
      }

      norm = OpenAI.from_openai(resp)
      assert norm["stop_reason"] == "tool_use"

      assert [%{"type" => "tool_use", "name" => "read", "input" => %{"path" => "a"}}] =
               norm["content"]

      assert norm["usage"]["input_tokens"] == 10
    end
  end

  test "HTTP API: POST /runs starts a run, GET /runs/:id reports it" do
    Application.put_env(:nano_agent, :mock, [Mock.end_turn("api done")])
    start_supervised!({Web, port: 0})
    port = Web.port()
    base = ~c"http://127.0.0.1:#{port}"

    {:ok, {{_, 202, _}, _h, body}} =
      :httpc.request(
        :post,
        {base ++ ~c"/runs", [], ~c"application/json", ~s({"plan":"do it"})},
        [],
        body_format: :binary
      )

    %{"run_id" => run_id, "status" => "running"} = :json.decode(body)

    # Give the agent a moment to finish and persist.
    Process.sleep(150)

    {:ok, {{_, 200, _}, _h, detail}} =
      :httpc.request(:get, {base ++ ~c"/runs/" ++ String.to_charlist(run_id), []}, [],
        body_format: :binary
      )

    assert %{"status" => "ok", "summary" => "api done"} = :json.decode(detail)
  end

  test "CLI runs a goal and prints NDJSON" do
    Application.put_env(:nano_agent, :mock, fn _m, tools, _o ->
      if Enum.any?(tools, &(&1[:name] == "submit_plan")) do
        {:ok,
         Mock.tool_use("p", "submit_plan", %{
           "plans" => [%{"id" => "1", "description" => "do it", "depends_on" => []}]
         })}
      else
        {:ok, Mock.end_turn("cli done")}
      end
    end)

    out = capture_io(fn -> assert {:ok, _} = CLI.run(["--json", "accomplish", "something"]) end)
    assert out =~ "cli done"
    # final line is JSON with the goal status
    assert out =~ ~s("status":"ok")
  end
end
