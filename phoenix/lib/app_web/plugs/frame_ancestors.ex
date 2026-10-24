defmodule AppWeb.Plugs.FrameAncestors do
  @moduledoc """
  Allows this endpoint to be embedded in the `<iframe>` that the Apps Script
  shim's `HtmlService` sidebar loads.

  `put_secure_browser_headers/2` (in the `:browser` pipeline) sets
  `x-frame-options`, which blocks framing outright. We drop that header and
  rely on the modern `Content-Security-Policy: frame-ancestors` directive
  instead, scoped to Google's sandbox origins only — never wildcard-open
  framing globally.
  """
  import Plug.Conn

  @frame_ancestors "https://*.googleusercontent.com https://docs.google.com"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> delete_resp_header("x-frame-options")
    |> put_resp_header("content-security-policy", "frame-ancestors #{@frame_ancestors}")
  end
end
