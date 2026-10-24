defmodule App.Clinical.Changes.CodeMedication do
  @moduledoc """
  On saving a medication record (docs/design/clinical-medications.md):

  - `medication.coding` is set from the app's drug list when the text names
    a listed drug (`App.Clinical.Drugs`), and removed otherwise;
  - `allergyWarning` notes every recorded allergy of the person the drug
    matches (`App.Clinical.AllergyCheck`), and is removed when none does;
  - `interactionWarning` notes interactions and duplicates with what the
    person takes or was given in the last day (`App.Clinical.Interactions`,
    §Interactions), removed when there are none.

  Never blocks the save. Both fields are computed here, never taken from
  the form. Applies to kinds whose schema has a `medication` object with
  a drug list (`x-suggest-list: "drugs"`): given medications now, a
  medication list later.

  The allergies are read without an actor (a check the system makes, so
  not an access-log entry); the writer sees only whether their own drug
  matches.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias App.Clinical.{AllergyCheck, Drugs, Interactions}
  alias App.People.{PersonRecord, PersonRecordSchema}

  # The coding is pure and set here, before the kind's schema validation
  # (declared after this change in PersonRecord), so it is validated too.
  # The allergy warning needs the database, so it is set in a before-action
  # hook, which runs only when the action really runs (not for
  # `Ash.can?/3`), first among the hooks: AshCloak's own hook encrypts the
  # `data` argument and removes it.
  @impl true
  def change(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    with true <- medication_kind?(kind),
         {:ok, %{} = data} <- Ash.Changeset.fetch_argument(changeset, :data) do
      changeset
      |> Ash.Changeset.set_argument(:data, with_coding(data))
      |> Ash.Changeset.before_action(&warn/1, prepend?: true)
    else
      _ -> changeset
    end
  end

  defp warn(changeset) do
    person_id = Ash.Changeset.get_attribute(changeset, :person_id)
    data = Ash.Changeset.get_argument(changeset, :data)
    current = current_drugs(person_id, changeset.data.id)

    data =
      data
      |> with_warning(allergies(person_id))
      |> with_interactions(current)

    Ash.Changeset.force_set_argument(changeset, :data, data)
  end

  @doc "Does `kind` record a medication (a `medication.text` with the drug list)?"
  @spec medication_kind?(atom()) :: boolean()
  def medication_kind?(kind) do
    get_in(PersonRecordSchema.schema(kind) || %{}, [
      "properties",
      "medication",
      "properties",
      "text",
      "x-suggest-list"
    ]) == "drugs"
  end

  @doc "The data with `medication.coding` set from the drug list, or removed (pure)."
  @spec with_coding(map()) :: map()
  def with_coding(data) do
    medication = data["medication"] || %{}

    medication =
      case Drugs.resolve(medication["text"]) do
        nil ->
          Map.delete(medication, "coding")

        drug ->
          Map.put(medication, "coding", [
            %{"system" => Drugs.system(), "code" => drug["id"], "display" => drug["names"]["en"]}
          ])
      end

    Map.put(data, "medication", medication)
  end

  @doc "The data with `allergyWarning` set for matching allergies, or removed (pure)."
  @spec with_warning(map(), [map()]) :: map()
  def with_warning(data, allergies) do
    case get_in(data, ["medication", "text"])
         |> AllergyCheck.matches(allergies)
         |> AllergyCheck.note() do
      nil -> Map.delete(data, "allergyWarning")
      note -> Map.put(data, "allergyWarning", String.slice(note, 0, 1000))
    end
  end

  @doc """
  The data with `interactionWarning` set for interactions and duplicates
  with `current` drug ids (`App.Clinical.Interactions`), or removed (pure).
  """
  @spec with_interactions(map(), [String.t()]) :: map()
  def with_interactions(data, current) do
    data
    |> drug_id()
    |> Interactions.check(current)
    |> Interactions.note()
    |> case do
      nil -> Map.delete(data, "interactionWarning")
      note -> Map.put(data, "interactionWarning", String.slice(note, 0, 1000))
    end
  end

  defp drug_id(data) do
    case get_in(data, ["medication", "coding"]) do
      [%{"code" => code} | _] -> code
      _ -> nil
    end
  end

  # What the person takes now (their medication list, not stopped or
  # ended) and was given in the last day — coded drugs only; the record
  # being edited left out.
  @recent_hours 24

  defp current_drugs(person_id, editing_id) do
    # Form times are local (the app's time zone), so is the window.
    zone = Application.get_env(:app, :app_time_zone, "Etc/UTC")
    now = DateTime.now!(zone, Tz.TimeZoneDatabase)
    since = DateTime.add(now, -@recent_hours, :hour, Tz.TimeZoneDatabase)
    today = DateTime.to_date(now)

    PersonRecord
    |> Ash.Query.filter(
      person_id == ^person_id and kind in [:medication_statement, :medication_administration]
    )
    |> Ash.Query.load(:data)
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&(&1.id == editing_id))
    |> Enum.filter(&current?(&1, today, since))
    |> Enum.map(&drug_id(&1.data || %{}))
    |> Enum.reject(&is_nil/1)
  end

  defp current?(%{kind: :medication_statement, data: data}, today, _since) do
    data["adherence"] not in ["stopped", "not-taking"] and
      (is_nil(data["effectiveEnd"]) or data["effectiveEnd"] >= Date.to_iso8601(today))
  end

  defp current?(%{kind: :medication_administration, data: data}, _today, since) do
    data["status"] in ["completed", "in-progress"] and
      is_binary(data["occurrence"]) and
      data["occurrence"] >= Calendar.strftime(since, "%Y-%m-%dT%H:%M")
  end

  defp allergies(person_id) do
    PersonRecord
    |> Ash.Query.filter(person_id == ^person_id and kind == :allergy_intolerance)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.data)
  end
end
