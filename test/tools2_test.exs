defmodule NanoAgent.Tools2Test do
  use ExUnit.Case, async: false

  alias NanoAgent.{Tools, Web}

  setup do
    tmp = Path.join(System.tmp_dir!(), "tools2_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "multi_edit" do
    test "applies multiple unique edits atomically", %{tmp: tmp} do
      path = Path.join(tmp, "f.txt")
      File.write!(path, "alpha beta gamma")

      out =
        Tools.run("multi_edit", %{
          "path" => path,
          "edits" => [
            %{"old_string" => "alpha", "new_string" => "A"},
            %{"old_string" => "gamma", "new_string" => "G"}
          ]
        })

      assert out =~ "applied 2 edit"
      assert File.read!(path) == "A beta G"
    end

    test "fails atomically when an edit doesn't match — no file changes", %{tmp: tmp} do
      path = Path.join(tmp, "g.txt")
      File.write!(path, "one two")

      out =
        Tools.run("multi_edit", %{
          "path" => path,
          "edits" => [
            %{"old_string" => "one", "new_string" => "1"},
            %{"old_string" => "MISSING", "new_string" => "x"}
          ]
        })

      assert out =~ "no changes written"
      # first edit must NOT have been persisted
      assert File.read!(path) == "one two"
    end
  end

  describe "http_fetch" do
    test "fetches a URL over HTTP", %{tmp: _tmp} do
      # serve a tiny response from our own zero-dep web server
      start_supervised!({Web, port: 0})
      port = Web.port()
      body = Tools.run("http_fetch", %{"url" => "http://127.0.0.1:#{port}/api/events"})
      # /api/events returns a JSON array
      assert body =~ "["
    end

    test "reports HTTP errors as a string", %{tmp: _tmp} do
      start_supervised!({Web, port: 0})
      port = Web.port()
      assert Tools.run("http_fetch", %{"url" => "http://127.0.0.1:#{port}/nope"}) =~ "HTTP 404"
    end
  end
end
