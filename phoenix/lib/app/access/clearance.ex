defmodule App.Access.Clearance do
  @moduledoc """
  The reader's security clearance (docs/design/access-control-phase2.md
  the `clearanceLevel` of the latest `security_clearance` record of
  the account's linked person, if it is granted and not expired. A record
  whose `classification` is above it is not readable.

  The clearance is read without an actor: it's the system deciding what the
  user may see, not the user reading someone's record (and so it isn't in
  the access log).
  """
  require Ash.Query

  alias App.Access.SecurityLabels
  alias App.People.PersonRecord

  # security_clearance.clearanceLevel -> the highest classification it
  # opens, in SecurityLabels.classifications/0 terms.
  @level_to_classification %{
    "NONE" => :nato_unclassified,
    "NATO_RESTRICTED" => :nato_restricted,
    "NATO_CONFIDENTIAL" => :nato_confidential,
    "NATO_SECRET" => :nato_secret,
    "COSMIC_TOP_SECRET" => :cosmic_top_secret
  }

  @doc """
  Classifications `user` may read. Unclassified is always included; the
  development admin override opens everything.
  """
  @spec readable_classifications(map() | nil) :: [atom()]
  def readable_classifications(%{role: :admin} = user) do
    if App.Access.admin_full_data_access?(),
      do: SecurityLabels.classifications(),
      else: up_to(highest(user))
  end

  def readable_classifications(user), do: up_to(highest(user))

  @doc "The highest classification `user` is currently cleared for."
  @spec highest(map() | nil) :: atom()
  def highest(%{person_id: person_id}) when is_binary(person_id) do
    PersonRecord
    |> Ash.Query.filter(person_id == ^person_id and kind == :security_clearance)
    |> Ash.Query.sort(recorded_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%{data: data}] -> if valid?(data), do: to_classification(data), else: :nato_unclassified
      [] -> :nato_unclassified
    end
  end

  def highest(_user), do: :nato_unclassified

  defp valid?(%{"status" => "granted"} = data) do
    case data["expiryDate"] && Date.from_iso8601(data["expiryDate"]) do
      {:ok, expiry} -> Date.compare(expiry, Date.utc_today()) != :lt
      _ -> true
    end
  end

  defp valid?(_data), do: false

  defp to_classification(data),
    do: Map.get(@level_to_classification, data["clearanceLevel"], :nato_unclassified)

  defp up_to(highest) do
    Enum.filter(
      SecurityLabels.classifications(),
      &SecurityLabels.classification_at_least?(highest, &1)
    )
  end
end
