defmodule AppWeb.ClientIp do
  @moduledoc """
  The client's address for access events (docs/design/events-and-person-login.md):
  behind our reverse proxy (Nginx on the host, the app in Docker) the
  connection comes from a private address and the client is the last
  `X-Forwarded-For` entry — the one Nginx appended. A request from a
  public address is taken as it is, its header ignored (it could be
  forged).
  """

  @doc "The client address of `conn`, as a string."
  @spec of(Plug.Conn.t()) :: String.t()
  def of(conn), do: from(conn.remote_ip, Plug.Conn.get_req_header(conn, "x-forwarded-for"))

  @doc "The client address of a connected LiveView (`:peer_data`, `:x_headers`), or nil."
  @spec of_socket(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def of_socket(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} ->
        headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []
        from(address, for({"x-forwarded-for", value} <- headers, do: value))

      _ ->
        nil
    end
  end

  # An IPv4 address seen through IPv6 (::ffff:a.b.c.d) as plain IPv4.
  defp from({0, 0, 0, 0, 0, 65_535, a, b}, forwarded_headers),
    do: from({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)}, forwarded_headers)

  defp from(remote_ip, forwarded_headers) do
    forwarded =
      forwarded_headers
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> List.last()

    if forwarded && private?(remote_ip),
      do: forwarded,
      else: remote_ip |> :inet.ntoa() |> to_string()
  end

  defp private?({127, _, _, _}), do: true
  defp private?({10, _, _, _}), do: true
  defp private?({172, b, _, _}) when b in 16..31, do: true
  defp private?({192, 168, _, _}), do: true
  defp private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private?({0, 0, 0, 0, 0, 65_535, a, b}),
    do: private?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  defp private?(_ip), do: false
end
