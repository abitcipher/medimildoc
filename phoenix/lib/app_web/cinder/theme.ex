defmodule AppWeb.Cinder.Theme do
  @moduledoc """
  The app's default Cinder theme (config :cinder, default_theme): the
  daisyUI theme, with tables scrolling sideways inside their own card on
  narrow screens instead of widening the whole page
  (docs/design/ui-plan.md, tables at phone width).
  """
  use Cinder.Theme
  extends :daisy_ui

  set :table_wrapper_class, "card card-border bg-base-100 overflow-x-auto"
end
