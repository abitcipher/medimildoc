defmodule AppWeb.Plugs.SetLocale do
  @moduledoc """
  Picks the locale for this request (English base,
  others "added later"; this is the "later" starting to happen) and calls
  `Gettext.put_locale/2` so every `gettext/1`/`ngettext/3` call in the
  request sees it.

  Precedence: `?locale=` query param (explicit switch, e.g. the language
  links in the nav) > previously chosen locale stored in the session >
  `Accept-Language` header > `Gettext.get_locale/1`'s own default ("en").
  A `?locale=` param is also written back into the session, so the choice
  survives past this one request.

  Controller actions run in the same process this plug ran in, so this is
  enough for them on its own. LiveViews run in a *different* process per
  socket — `AppWeb.LiveUserAuth`'s `:set_locale` on_mount hook (added to
  every `live_session` that needs this) re-derives the same locale from
  the session for that reason; this plug alone does not reach LiveViews.
  """
  import Plug.Conn

  @known_locales Gettext.known_locales(AppWeb.Gettext)

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_session(conn)

    case fetch_query_params(conn).query_params["locale"] do
      locale when is_binary(locale) ->
        if locale in @known_locales do
          conn
          |> put_session("locale", locale)
          |> put_locale(locale)
        else
          # An unknown ?locale= is left alone rather than silently
          # accepted — falls through to whatever the session/header/
          # default would otherwise pick.
          put_locale(conn, locale_from_session_or_header(conn))
        end

      nil ->
        put_locale(conn, locale_from_session_or_header(conn))
    end
  end

  defp locale_from_session_or_header(conn) do
    get_session(conn, "locale") || locale_from_accept_language(conn) ||
      Gettext.get_locale(AppWeb.Gettext)
  end

  defp locale_from_accept_language(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> parse_accept_language()
  end

  defp parse_accept_language(nil), do: nil

  defp parse_accept_language(header) do
    header
    |> String.split(",")
    |> Enum.map(&(&1 |> String.split(";") |> List.first() |> String.trim()))
    |> Enum.map(&primary_subtag/1)
    |> Enum.find(&(&1 in @known_locales))
  end

  # "en-US" -> "en" — we match on language, not region.
  defp primary_subtag(tag), do: tag |> String.split("-") |> List.first()

  defp put_locale(conn, locale) do
    # "full UI translation" — Gettext.put_locale/1 (not the
    # /2, single-backend form) sets the locale for every Gettext backend
    # registered in this process at once. Needed because Cinder ships its
    # own separate gettext domain/backend (Cinder.Gettext, "Filters"/
    # "Clear all"/...) — /2 against only AppWeb.Gettext left Cinder stuck
    # on its own default ("en") regardless of the app's chosen locale,
    # confirmed live. The /1 form reaches any such third-party Gettext
    # backend automatically, not just ones we know to name explicitly.
    Gettext.put_locale(locale)
    conn
  end
end
