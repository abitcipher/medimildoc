defmodule App.Access.Checks.ReadableAttachments do
  @moduledoc """
  Read filter for `App.People.Attachment` — a file is readable exactly when
  what it belongs to is:

  - on a record: the record read filter (`ReadableRecords`) over the
    kind and classification the attachment copies from its record;
  - a person's portrait photo: `people.read`;
  - any other file about a person: `people.private.read`, in scope.
  """
  use Ash.Policy.FilterCheck

  require Ash.Expr

  alias App.Access.Checks.{ReadableRecords, ScopedPermission}

  @impl true
  def describe(_opts), do: "the file's record or person is readable by the actor"

  @impl true
  def filter(nil, _authorizer, _opts), do: Ash.Expr.expr(false)

  def filter(actor, authorizer, _opts) do
    on_record = ReadableRecords.filter(actor, authorizer, [])
    private = ScopedPermission.filter(actor, authorizer, permission: "people.private.read")
    photos? = App.Access.can?(actor, "people.read")

    Ash.Expr.expr(
      (not is_nil(record_id) and ^on_record) or
        (is_nil(record_id) and purpose == :photo and ^photos?) or
        (is_nil(record_id) and purpose != :photo and ^private)
    )
  end
end
