defmodule App.Duty do
  @moduledoc """
  Duty rosters (docs/design/duty-roster.md): who of a unit is on which
  duty which day (`App.Duty.Shift`), the duty types (`App.Duty.Types`) and
  the roster's checks (`App.Duty.Roster`).
  """
  use Ash.Domain

  resources do
    resource(App.Duty.Shift)
  end
end
