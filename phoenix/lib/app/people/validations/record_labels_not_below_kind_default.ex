defmodule App.People.Validations.RecordLabelsNotBelowKindDefault do
  @moduledoc """
  A writer may raise a record's security labels but never set them below
  its kind's defaults (docs/design/access-control-phase1.md) — a
  diagnosis can't be relabelled as ordinary personnel data.
  """
  use Ash.Resource.Validation

  alias App.Access.SecurityLabels
  alias App.People.PersonRecordSchema

  @impl true
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    if kind in PersonRecordSchema.kinds(), do: check(changeset, kind), else: :ok
  end

  defp check(changeset, kind) do
    confidentiality = Ash.Changeset.get_attribute(changeset, :confidentiality)
    classification = Ash.Changeset.get_attribute(changeset, :classification)
    min_confidentiality = PersonRecordSchema.default_confidentiality(kind)
    min_classification = PersonRecordSchema.default_classification(kind)

    cond do
      not SecurityLabels.confidentiality_at_least?(confidentiality, min_confidentiality) ->
        {:error,
         field: :confidentiality,
         message: "can't be lower than %{minimum} for this kind",
         vars: [minimum: min_confidentiality]}

      not SecurityLabels.classification_at_least?(classification, min_classification) ->
        {:error,
         field: :classification,
         message: "can't be lower than %{minimum} for this kind",
         vars: [minimum: min_classification]}

      true ->
        :ok
    end
  end
end
