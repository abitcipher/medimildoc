defmodule AppWeb.ClientIpTest do
  use ExUnit.Case, async: true

  alias AppWeb.ClientIp

  defp conn(remote, forwarded) do
    conn = %{Plug.Test.conn(:get, "/") | remote_ip: remote}
    if forwarded, do: Plug.Conn.put_req_header(conn, "x-forwarded-for", forwarded), else: conn
  end

  test "behind the proxy: the last forwarded address (the one Nginx added)" do
    assert ClientIp.of(conn({172, 18, 0, 1}, "198.51.100.7, 203.0.113.5")) == "203.0.113.5"
    assert ClientIp.of(conn({127, 0, 0, 1}, nil)) == "127.0.0.1"
  end

  test "a public peer: its own address, the header ignored" do
    assert ClientIp.of(conn({203, 0, 113, 9}, "10.0.0.1")) == "203.0.113.9"
  end

  test "an IPv4 address seen through IPv6 shows as IPv4" do
    assert ClientIp.of(conn({0, 0, 0, 0, 0, 65_535, 49_320, 4_097}, nil)) == "192.168.16.1"
  end
end
