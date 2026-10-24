defmodule AppWeb.LocaleHook do
  @moduledoc """
  LiveView-side half of locale selection —
  `AppWeb.Plugs.SetLocale` only reaches controller actions, since a
  LiveView's socket runs in its own process, separate from the one that
  handled the initial HTTP request; `Gettext.put_locale/2` is per-process,
  so it has to be set again here. Re-derives the same value
  `AppWeb.Plugs.SetLocale` already wrote into the session (rather than
  re-parsing `?locale=`/`Accept-Language` independently) — the two are
  meant to agree, never disagree.

  Add `on_mount {AppWeb.LocaleHook, :default}` first in any `live_session`
  that renders translated content.
  """
  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    locale = session["locale"] || Gettext.get_locale(AppWeb.Gettext)
    # See AppWeb.Plugs.SetLocale's matching comment — /1, not /2, so this
    # LiveView process's Cinder.Gettext (and any other third-party
    # Gettext backend) picks up the same locale, not just AppWeb.Gettext.
    Gettext.put_locale(locale)
    {:cont, assign(socket, :locale, locale)}
  end
end
