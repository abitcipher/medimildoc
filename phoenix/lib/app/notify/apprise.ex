defmodule App.Notify.Apprise do
  @moduledoc """
  Sends one message through a self-hosted Apprise API
  (docs/design/search-timeline-notifications.md; stateless endpoint
  `POST /notify/`). Each channel kind has a base Apprise URL in the
  configuration holding the sender's credentials (SMTP account, Telegram
  bot, Signal relay, Matrix account); the recipient is added to it:

  - e-mail — `mailtos://user:pass@smtp.example.com?from=…` + `to=<address>`
  - Telegram — `tgram://<bot token>` + `/<chat id>`
  - Signal — `signal://<host>:<port>/<from number>` + `/<to number>`
  - Matrix — `matrixs://<user>:<pass>@<host>` + `/<room>`
  """

  @doc "Whether a channel kind has its base URL configured."
  @spec configured?(atom()) :: boolean()
  def configured?(kind), do: base_url(kind) != nil

  @doc "The Apprise URL for a recipient on a channel kind, or nil when not configured."
  @spec target(atom(), String.t()) :: String.t() | nil
  def target(kind, address) do
    case base_url(kind) do
      nil -> nil
      base -> add_recipient(kind, base, address)
    end
  end

  defp add_recipient(:email, base, address) do
    separator = if String.contains?(base, "?"), do: "&", else: "?"
    base <> separator <> "to=" <> URI.encode_www_form(address)
  end

  defp add_recipient(_kind, base, address),
    do: String.trim_trailing(base, "/") <> "/" <> URI.encode(address, &URI.char_unreserved?/1)

  @doc "Sends `title` and `body` to an Apprise URL."
  @spec send(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def send(url, title, body) do
    case Req.post(api_url() <> "/notify/",
           json: %{urls: url, title: title, body: body},
           receive_timeout: 30_000,
           retry: false,
           plug: config()[:req_plug]
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, "Apprise #{status}: #{short(body)}"}
      {:error, error} -> {:error, "Apprise unreachable: #{Exception.message(error)}"}
    end
  end

  defp short(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp short(body), do: body |> inspect() |> String.slice(0, 200)

  defp base_url(kind), do: get_in(config(), [:channels, kind])
  defp api_url, do: config()[:apprise_url] || "http://apprise:8000"
  defp config, do: Application.get_env(:app, App.Notify, [])
end
