defmodule App.Events do
  @moduledoc """
  The general event log (docs/design/events-and-person-login.md): one
  `App.Events.Event` per emitted event, which is also the outbox for
  publishing to external subscribers. Written and read through
  `App.EventLog`, kept out of this module (resources name their domain,
  so helpers here would make an import cycle).
  """
  use Ash.Domain

  resources do
    resource App.Events.Event
  end
end
