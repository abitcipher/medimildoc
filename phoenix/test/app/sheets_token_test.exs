defmodule App.SheetsTokenTest do
  use ExUnit.Case, async: true

  import App.SheetsTokenFixtures

  alias App.SheetsToken

  @secret "test-shared-secret"

  test "verifies a well-formed, unexpired, correctly-signed token" do
    token = sheets_token(secret: @secret, sub: "person@example.com", ssid: "ss-1")

    assert {:ok, %{sub: "person@example.com", spreadsheet_id: "ss-1"}} =
             SheetsToken.verify(token, @secret)
  end

  test "rejects a token signed with a different secret" do
    token = sheets_token(secret: "wrong-secret")
    assert {:error, :bad_signature} = SheetsToken.verify(token, @secret)
  end

  test "rejects a tampered payload (signature no longer matches)" do
    [payload_b64, sig_b64] = sheets_token(secret: @secret) |> String.split(".", parts: 2)
    tampered_payload = String.reverse(payload_b64)
    refute tampered_payload == payload_b64

    assert {:error, :bad_signature} =
             SheetsToken.verify("#{tampered_payload}.#{sig_b64}", @secret)
  end

  test "rejects an expired token" do
    now = System.system_time(:second)
    token = sheets_token(secret: @secret, exp: now - 1)
    assert {:error, :expired} = SheetsToken.verify(token, @secret, now)
  end

  test "accepts a token at the exact expiry second" do
    now = System.system_time(:second)
    token = sheets_token(secret: @secret, exp: now)
    assert {:ok, _claims} = SheetsToken.verify(token, @secret, now)
  end

  test "rejects malformed tokens" do
    assert {:error, :malformed} = SheetsToken.verify("not-a-token", @secret)
    assert {:error, :malformed} = SheetsToken.verify("", @secret)
    assert {:error, :malformed} = SheetsToken.verify(".", @secret)
  end

  test "rejects a payload missing required claims, even if correctly signed" do
    payload = Base.url_encode64(Jason.encode!(%{"sub" => "person@example.com"}), padding: false)
    sig = Base.url_encode64(:crypto.mac(:hmac, :sha256, @secret, payload), padding: false)

    assert {:error, :invalid_payload} = SheetsToken.verify("#{payload}.#{sig}", @secret)
  end
end
