defmodule App.Api.Checks.LinkedToPerson do
  @moduledoc "The actor's account is linked to a person (personal tokens read only that person)."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is linked to a person"

  @impl true
  def match?(%{person_id: person_id}, _context, _opts), do: is_binary(person_id)
  def match?(_actor, _context, _opts), do: false
end
