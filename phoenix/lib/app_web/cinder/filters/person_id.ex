defmodule AppWeb.Cinder.Filters.PersonId do
  @moduledoc """
  Fixes the `person_id` filter's known rough edge:
  `PeopleLive.Index`'s `person_id` column displayed the value grouped
  `AAAA-BBBB-CCCC` (`App.People.PersonId.format/1`) but its plain `:text`
  Cinder filter matched against the raw stored code — pasting the code
  back in exactly as displayed (with dashes) silently matched nothing,
  because Cinder's generic text filter has no idea this domain groups
  the value for display.

  Everything here delegates straight to `Cinder.Filters.Text` (same
  widget, same `:contains`/`:equals`/etc. operators, same query
  building) — the ONLY change is `process/2` running the raw input
  through `App.People.PersonId.unformat/1` first, so `"CORO-NAWI-CESE"`
  and `"coronawicese"` and `"CORONAWICESE"` all filter identically.
  Registered as the `:person_id` filter type (`config :cinder,
  :filters`, `config/config.exs`) — used via `filter={:person_id}` on
  the one column that needs it, not a change to Cinder's default `:text`
  filter for everyone else.
  """
  @behaviour Cinder.Filter

  alias App.People.PersonId
  alias Cinder.Filters.Text

  @impl true
  defdelegate render(column, current_value, theme, assigns), to: Text

  @impl true
  def process(raw_value, column) when is_binary(raw_value) do
    Text.process(PersonId.unformat(raw_value), column)
  end

  def process(raw_value, column), do: Text.process(raw_value, column)

  @impl true
  defdelegate validate(value), to: Text

  @impl true
  defdelegate default_options(), to: Text

  @impl true
  defdelegate empty?(value), to: Text

  @impl true
  defdelegate build_query(query, field, filter_value), to: Text
end
