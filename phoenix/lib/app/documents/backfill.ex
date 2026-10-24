defmodule App.Documents.Backfill do
  @moduledoc """
  Fills the plain `recipient_provider_id` of documents saved before it
  existed, from their (decrypted, as the system) fields. Runs after the
  release migrations; does nothing once all are filled.
  """

  require Ash.Query

  alias App.Documents.{Access, Document}

  @doc "Returns how many documents got a recipient."
  @spec recipients() :: non_neg_integer()
  def recipients do
    Document
    |> Ash.Query.filter(is_nil(recipient_provider_id))
    |> Ash.Query.load(:data)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn document, count ->
      case Access.recipient_provider(document.data || %{}) do
        nil ->
          count

        provider_id ->
          App.Repo.query!("UPDATE documents SET recipient_provider_id = $1 WHERE id = $2", [
            Ecto.UUID.dump!(provider_id),
            Ecto.UUID.dump!(document.id)
          ])

          count + 1
      end
    end)
  end
end
