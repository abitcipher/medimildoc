defmodule AppWeb.Cinder.RecordListTheme do
  @moduledoc """
  Cinder theme for the person page's record list: the app theme, but
  items are a plain vertical stack, because each record already renders as
  its own card (`AppWeb.RecordComponents.record_card/1`). Without this the
  daisyUI list wraps every card in a second card.
  """
  use Cinder.Theme
  # The base theme must be compiled first; Cinder resolves it at compile time.
  require AppWeb.Cinder.Theme
  extends AppWeb.Cinder.Theme

  set :list_container_class, "flex flex-col gap-3"
  set :list_item_class, ""
end
