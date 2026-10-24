defmodule App.Documents.Instructions do
  @moduledoc """
  Reading and closing instructions on letters (docs/design/correspondence.md).
  Giving and completing go through `App.Documents.Instruction`'s actions
  and policies; these read as the system for documents the caller has
  already read, or for the executor's own instructions.
  """
  require Ash.Query

  alias App.Documents.Instruction

  @doc "The instructions on `document`, oldest first, with executor, issuer and reply."
  @spec for_document(map()) :: [Instruction.t()]
  def for_document(%{id: id}) do
    Instruction
    |> Ash.Query.filter(document_id == ^id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.load([:executor, :issued_by, :reply])
    |> Ash.read!(authorize?: false)
  end

  @doc "Open instructions `actor` is to carry out, soonest due first, with their letter."
  @spec open_for(map()) :: [Instruction.t()]
  def open_for(%{id: actor_id}) do
    Instruction
    |> Ash.Query.filter(executor_id == ^actor_id and status == :open)
    |> Ash.Query.load(document: [:person])
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(&(&1.due_on || ~D[9999-12-31]), Date)
  end

  @doc "Whether `actor_id` has an open instruction on document `document_id`."
  @spec executor_of?(String.t() | nil, String.t() | nil) :: boolean()
  def executor_of?(actor_id, document_id) when is_binary(actor_id) and is_binary(document_id) do
    Instruction
    |> Ash.Query.filter(
      executor_id == ^actor_id and document_id == ^document_id and status == :open
    )
    |> Ash.exists?(authorize?: false)
  end

  def executor_of?(_actor_id, _document_id), do: false

  @doc "Closes the open instructions on `reply`'s basis letter by `reply` (when it is signed)."
  @spec close_by_reply(map()) :: {:ok, non_neg_integer()}
  def close_by_reply(%{basis_id: basis_id} = reply) when is_binary(basis_id) do
    closed =
      Instruction
      |> Ash.Query.filter(document_id == ^basis_id and status == :open)
      |> Ash.read!(authorize?: false)
      |> Enum.map(fn instruction ->
        instruction
        |> Ash.Changeset.for_update(:close_by_reply, %{reply_id: reply.id}, authorize?: false)
        |> Ash.update!(authorize?: false)
      end)

    {:ok, length(closed)}
  end

  def close_by_reply(_reply), do: {:ok, 0}

  @doc "Who may be named an executor: every user, by name."
  @spec executors() :: [map()]
  def executors do
    App.Accounts.User
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(&String.downcase(&1.name || to_string(&1.email)))
  end
end
