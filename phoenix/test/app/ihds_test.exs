defmodule App.IHDSTest do
  # Not async: swaps the global IHDS request options.
  use ExUnit.Case, async: false

  alias App.Cache

  setup do
    Cache.clear()
    on_exit(&Cache.clear/0)
  end

  test "lookup by stored code, label in the requested language" do
    assert %{"label" => "Україна", "flag" => "ua"} = App.IHDS.lookup("countries", "UA", "uk")
    assert %{"label" => "Allemagne"} = App.IHDS.lookup("countries", "de", "fr")
    assert App.IHDS.lookup("countries", "XX", "en") == nil
    assert App.IHDS.lookup("countries", nil, "en") == nil
  end

  test "list and search" do
    assert {:ok, [_ | _] = all} = App.IHDS.list("countries", "en")
    assert length(all) > 240
    assert {:ok, [%{"code" => "DE"} | _]} = App.IHDS.search("countries", "germ", "en")
  end

  test "an unreachable service gives errors, never exceptions" do
    previous = Application.get_env(:app, :ihds_req_options)

    Application.put_env(:app, :ihds_req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 503, "") end
    )

    on_exit(fn -> Application.put_env(:app, :ihds_req_options, previous) end)

    assert App.IHDS.list("countries", "en") == {:error, {:status, 503}}
    assert App.IHDS.lookup("countries", "UA", "uk") == nil
  end
end
