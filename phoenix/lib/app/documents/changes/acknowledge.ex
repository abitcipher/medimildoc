defmodule App.Documents.Changes.Acknowledge do
  @moduledoc """
  Both ways of acknowledging an order (`App.Documents.Acknowledgement`),
  before the write: the order must be signed and of a type that is
  acknowledged; the person is the order's person; who recorded it is the
  actor; the date is today for the person themselves, and for a record on
  their behalf any day from the signing to today. After the write: a row
  in the order's history (`:acknowledged`, with the note).

  The document is read in the hook, not in the change body (a read there
  would break `Ash.can?/3`).
  """
  use Ash.Resource.Change

  alias App.Documents.Changes.RecordEvent
  alias App.Documents.{Document, Types}

  @impl true
  def change(changeset, _opts, context) do
    actor = context.actor

    changeset
    |> Ash.Changeset.before_action(&prepare(&1, actor))
    |> Ash.Changeset.after_action(fn changeset, acknowledgement ->
      RecordEvent.write(
        %{id: acknowledgement.document_id},
        :acknowledged,
        actor,
        Ash.Changeset.get_attribute(changeset, :note)
      )

      {:ok, acknowledgement}
    end)
  end

  defp prepare(changeset, actor) do
    document_id = Ash.Changeset.get_attribute(changeset, :document_id)

    with {:ok, document} <- Ash.get(Document, document_id, authorize?: false),
         :ok <- acknowledgeable(document),
         {:ok, on} <- date(changeset, document) do
      Ash.Changeset.force_change_attributes(changeset, %{
        person_id: document.person_id,
        acknowledged_on: on,
        recorded_by_id: actor && actor.id,
        recorded_by_email: actor && to_string(actor.email)
      })
    else
      {:error, message} when is_binary(message) ->
        Ash.Changeset.add_error(changeset, message: message)

      _ ->
        Ash.Changeset.add_error(changeset,
          field: :document_id,
          message: "The order does not exist."
        )
    end
  end

  defp acknowledgeable(%{state: :signed, type: type}) do
    if Types.acknowledge?(type), do: :ok, else: {:error, "This document is not acknowledged."}
  end

  defp acknowledgeable(_document), do: {:error, "Only a signed order can be acknowledged."}

  # The person themselves: today. On their behalf: the given day (today by
  # default), not before the order was signed and not in the future.
  defp date(%{action: %{name: :acknowledge}}, _document), do: {:ok, Date.utc_today()}

  defp date(changeset, document) do
    today = Date.utc_today()
    on = Ash.Changeset.get_attribute(changeset, :acknowledged_on) || today
    signed_on = DateTime.to_date(document.signed_at)

    cond do
      Date.compare(on, today) == :gt -> {:error, "The date is in the future."}
      Date.compare(on, signed_on) == :lt -> {:error, "The date is before the order was signed."}
      true -> {:ok, on}
    end
  end
end
