defmodule App.SheetsToken do
  @moduledoc """
  Verifies the short-lived HMAC token minted by `mintToken()` in the Apps
  Script shim (`apps_script/src/main.ts`) — auth is a
  signed token carried outside cookies, not a cookie itself (third-party
  frame cookies are unreliable); covers the separate, unrelated
  question of *Google API* auth (OAuth per-user).

  Token shape (produced by the shim, not here — this module only verifies):

      base64url(json_payload) <> "." <> base64url(hmac_sha256(json_payload, secret))

  where `json_payload` is `{"sub": email, "ssid": spreadsheet_id, "exp": unix_seconds}`.

  Only `sub` and `ssid` are cryptographically covered by the signature —
  that's the entire trust boundary. Anything else the shim sends alongside
  (sheet name, active cell) rides unsigned and must stay informational only,
  never used for authorization.

  Pure core: verification is a plain function of its inputs (token, secret,
  current time) with no process state — callers
  (`AppWeb.SheetsLive.mount/3`, `AppWeb.Plugs.VerifySheetsToken`) are the
  imperative shell that source the secret and the clock.
  """

  @type claims :: %{sub: String.t(), spreadsheet_id: String.t()}
  @type error :: :malformed | :bad_signature | :invalid_payload | :expired

  @spec verify(String.t(), String.t(), integer()) :: {:ok, claims()} | {:error, error()}
  def verify(token, secret, now \\ System.system_time(:second))

  def verify(token, secret, now) when is_binary(token) and is_binary(secret) do
    with {:ok, payload_b64, sig_b64} <- split_token(token),
         :ok <- verify_signature(payload_b64, sig_b64, secret),
         {:ok, payload} <- decode_payload(payload_b64),
         :ok <- verify_not_expired(payload, now) do
      {:ok, %{sub: payload["sub"], spreadsheet_id: payload["ssid"]}}
    end
  end

  defp split_token(token) do
    case String.split(token, ".", parts: 2) do
      [payload_b64, sig_b64] when payload_b64 != "" and sig_b64 != "" ->
        {:ok, payload_b64, sig_b64}

      _ ->
        {:error, :malformed}
    end
  end

  defp verify_signature(payload_b64, sig_b64, secret) do
    with {:ok, given_sig} <- url_decode(sig_b64) do
      expected_sig = :crypto.mac(:hmac, :sha256, secret, payload_b64)

      if Plug.Crypto.secure_compare(given_sig, expected_sig) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  defp decode_payload(payload_b64) do
    with {:ok, json} <- url_decode(payload_b64),
         {:ok, payload} <- Jason.decode(json),
         %{"sub" => sub, "ssid" => ssid, "exp" => exp}
         when is_binary(sub) and is_binary(ssid) and is_integer(exp) <- payload do
      {:ok, payload}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp verify_not_expired(%{"exp" => exp}, now),
    do: if(now <= exp, do: :ok, else: {:error, :expired})

  # GAS's Utilities.base64EncodeWebSafe pads by default; tolerate either.
  defp url_decode(str) do
    case str |> String.trim_trailing("=") |> Base.url_decode64(padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :malformed}
    end
  end
end
