defmodule App.AshErrors do
  @moduledoc """
  A concise, user-facing summary of an Ash error, for flash messages.

  `Exception.message/1` on an `Ash.Error.*` is *not* fit for that purpose —
  confirmed live (deleting a `Person` with dependent `Assignment`s): it
  renders "Bread Crumbs: > Error returned from: ...", blank lines, and
  file/line references from the error's own stacktrace, meant for logs.
  Every field-level error under `.errors` carries a clean, short `.message`
  on its own (e.g. "would leave records behind" for the FK-violation case
  above) — this joins those instead.
  """

  @spec summarize(Exception.t()) :: String.t()
  def summarize(%{errors: errors}) when is_list(errors) and errors != [] do
    Enum.map_join(errors, "; ", &summarize_one/1)
  end

  def summarize(error), do: Exception.message(error)

  defp summarize_one(%{field: field, message: message})
       when not is_nil(field) and not is_nil(message) do
    "#{field}: #{message}"
  end

  defp summarize_one(%{message: message}) when not is_nil(message), do: message
  defp summarize_one(error), do: Exception.message(error)
end
