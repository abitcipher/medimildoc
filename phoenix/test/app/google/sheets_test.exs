defmodule App.Google.SheetsTest do
  use ExUnit.Case, async: true

  alias App.Google.Sheets

  describe "get_values/3" do
    test "returns rows on success, with the bearer token and range in the request" do
      Req.Test.stub(Sheets, fn conn ->
        assert conn.method == "GET"
        # base_url's own "/v4" path shows up here too; the range is
        # percent-encoded (`!`/`:` aren't unreserved), matching
        # encode_range/1 in App.Google.Sheets.
        assert conn.request_path == "/v4/spreadsheets/ss-1/values/Sheet1%21A1%3AB2"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer the-token"]

        Req.Test.json(conn, %{"range" => "Sheet1!A1:B2", "values" => [["a", "b"], ["c", "d"]]})
      end)

      assert {:ok, [["a", "b"], ["c", "d"]]} =
               Sheets.get_values("the-token", "ss-1", "Sheet1!A1:B2")
    end

    test "returns an empty list when Sheets omits \"values\" (range has no data yet)" do
      Req.Test.stub(Sheets, fn conn -> Req.Test.json(conn, %{"range" => "Sheet1!A1:B2"}) end)

      assert {:ok, []} = Sheets.get_values("the-token", "ss-1", "Sheet1!A1:B2")
    end

    test "maps a 404 to {:error, :not_found}" do
      Req.Test.stub(Sheets, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not found"})
      end)

      assert {:error, :not_found} = Sheets.get_values("the-token", "missing-ss", "A1")
    end

    test "maps a 401 to {:error, :unauthorized} (expired/invalid OAuth token)" do
      Req.Test.stub(Sheets, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)
      assert {:error, :unauthorized} = Sheets.get_values("stale-token", "ss-1", "A1")
    end
  end

  describe "update_values/4" do
    test "PUTs with valueInputOption=USER_ENTERED and the rows as JSON" do
      Req.Test.stub(Sheets, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/v4/spreadsheets/ss-1/values/Sheet1%21A1"

        assert %{"valueInputOption" => "USER_ENTERED"} =
                 Plug.Conn.fetch_query_params(conn).query_params

        assert Jason.decode!(Req.Test.raw_body(conn))["values"] == [["42"]]

        Req.Test.json(conn, %{"spreadsheetId" => "ss-1", "updatedCells" => 1})
      end)

      assert {:ok, %{"updatedCells" => 1}} =
               Sheets.update_values("the-token", "ss-1", "Sheet1!A1", [["42"]])
    end

    test "maps a 403 to {:error, :forbidden}" do
      Req.Test.stub(Sheets, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)
      assert {:error, :forbidden} = Sheets.update_values("the-token", "ss-1", "A1", [["x"]])
    end
  end
end
