defmodule App.Access.Checks.HasPermission do
  @moduledoc """
  Policy check: the actor holds a named permission (`App.Access.can?/2`).

      authorize_if {App.Access.Checks.HasPermission, permission: "people.write"}
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor has permission #{Keyword.fetch!(opts, :permission)}"

  @impl true
  def match?(actor, _context, opts) do
    App.Access.can?(actor, Keyword.fetch!(opts, :permission))
  end
end
