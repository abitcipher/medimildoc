defmodule App.Documents.Drafts do
  @moduledoc """
  Who may edit a draft: whoever may write its type for its person or unit
  (`App.Documents.Access.can_write?/4`), or — for a reply — the executor of
  an open instruction on its basis letter (docs/design/correspondence.md).
  Kept apart from `Access` so that module doesn't depend on instructions.
  """

  alias App.Documents.{Access, Instructions, Types}

  @doc "Whether `actor` may edit `document` (a draft), its fields and files."
  @spec editable?(map() | nil, map()) :: boolean()
  def editable?(nil, _document), do: false

  def editable?(actor, document) do
    document.state == :draft and
      (Access.can_write?(actor, document.type, document.person_id, document.handling_unit_id) or
         (Types.reply_by_executor?(document.type) and
            Instructions.executor_of?(actor.id, document.basis_id)))
  end

  @doc """
  Whether `actor` registers `document` in one go: its route is a single
  signature step whose permission the actor holds for it (an incoming
  letter registered by the records officer).
  """
  @spec registers_directly?(map(), map()) :: boolean()
  def registers_directly?(actor, document) do
    case Types.route(document.type) do
      [%{"action" => "sign", "permission" => permission}] ->
        not Types.about_person?(document.type) and Access.holds?(actor, permission, document)

      _ ->
        false
    end
  end
end
