defmodule AppWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AppWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AppWeb.Endpoint

      use AppWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AppWeb.ConnCase
    end
  end

  setup tags do
    App.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Returns `conn` with a real signed session for `user` — the same
  JWT-mint technique used throughout this project for live-verifying
  authenticated flows, applied inside `ExUnit` instead
  of via `curl`/a minted cookie against a running server. `Plug.Test.
  init_test_session/2` resets the session first — reusing a `conn` that
  already carries a session (e.g. from a previous call) would otherwise
  merge onto it rather than replace it (confirmed live: that's exactly
  what silently defeated an "unauthenticated" test case's own fresh
  `%{}` the first time this was written).
  """
  def authenticated_conn(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{}, [])

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end
end
