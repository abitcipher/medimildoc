defmodule App.Clinical.Changes.InterpretLab do
  @moduledoc """
  On saving a lab result (docs/design/lab-results.md), the server sets —
  never the form:

  - `unit` and `referenceRange` from the test list (`App.Clinical.LabTests`);
  - `interpretation`: low, normal or high against that range;
  - `previous`: the person's last earlier result of the same test
    ("4.1 (12.09.2026 08:30)"), for comparison — read in a before-action
    hook (the database), first among the hooks, as with medications
    (AshCloak's own hook removes the `data` argument).
  """
  use Ash.Resource.Change

  require Ash.Query

  alias App.Clinical.LabTests
  alias App.People.PersonRecord

  @impl true
  def change(changeset, _opts, _context) do
    with :lab_result <- Ash.Changeset.get_attribute(changeset, :kind),
         {:ok, %{} = data} <- Ash.Changeset.fetch_argument(changeset, :data) do
      changeset
      |> Ash.Changeset.set_argument(:data, interpret(data))
      |> Ash.Changeset.before_action(&previous/1, prepend?: true)
    else
      _ -> changeset
    end
  end

  @doc "The data with unit, reference range and interpretation set from the test list (pure)."
  @spec interpret(map()) :: map()
  def interpret(data) do
    data = Map.drop(data, ["unit", "referenceRange", "interpretation", "previous"])

    case LabTests.get(data["test"]) do
      nil ->
        data

      test ->
        %{
          "unit" => test["unit"],
          "referenceRange" => LabTests.range(test),
          "interpretation" => LabTests.interpret(test, number(data["value"]))
        }
        |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
        |> then(&Map.merge(data, &1))
    end
  end

  defp previous(changeset) do
    data = Ash.Changeset.get_argument(changeset, :data)
    person_id = Ash.Changeset.get_attribute(changeset, :person_id)

    case earlier(person_id, changeset.data.id, data["test"], data["collectedAt"]) do
      nil -> changeset
      text -> Ash.Changeset.force_set_argument(changeset, :data, Map.put(data, "previous", text))
    end
  end

  # The latest result of the same test collected before this one (read as
  # the system: the writer sees only this one value on their own record).
  defp earlier(_person_id, _id, nil, _collected_at), do: nil

  defp earlier(person_id, id, test, collected_at) do
    PersonRecord
    |> Ash.Query.filter(person_id == ^person_id and kind == :lab_result)
    |> Ash.Query.load(:data)
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&(&1.id == id))
    |> Enum.filter(fn r ->
      r.data["test"] == test and is_binary(r.data["collectedAt"]) and
        (is_nil(collected_at) or r.data["collectedAt"] < collected_at)
    end)
    |> Enum.max_by(& &1.data["collectedAt"], fn -> nil end)
    |> case do
      nil -> nil
      r -> "#{format(r.data["value"])} (#{String.replace(r.data["collectedAt"], "T", " ")})"
    end
  end

  defp format(value) when is_number(value), do: LabTests.number(value)
  defp format(value), do: to_string(value)

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(String.replace(value, ",", ".")) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp number(_value), do: nil
end
