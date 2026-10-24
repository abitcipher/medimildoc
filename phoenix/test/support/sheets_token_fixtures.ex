defmodule App.SheetsTokenFixtures do
  @moduledoc """
  Test-only: mints tokens shaped exactly like `mintToken()` in the Apps
  Script shim (`apps_script/src/main.ts`), so `App.SheetsToken.verify/2,3`
  and `AppWeb.SheetsLive` can be exercised without a real Apps
  Script/Sheets round-trip. Production Elixir code never mints tokens —
  only the shim does.
  """

  @default_secret "test-shared-secret"

  @spec sheets_token(keyword()) :: String.t()
  def sheets_token(opts \\ []) do
    secret = Keyword.get(opts, :secret, @default_secret)
    sub = Keyword.get(opts, :sub, "person@example.com")
    ssid = Keyword.get(opts, :ssid, "spreadsheet-123")
    exp = Keyword.get(opts, :exp, System.system_time(:second) + 300)

    payload =
      %{"sub" => sub, "ssid" => ssid, "exp" => exp}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    sig = Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, payload), padding: false)

    "#{payload}.#{sig}"
  end
end
