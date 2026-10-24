defmodule App.Documents.Changes.CastData do
  @moduledoc """
  A document's fields against its type's schema: a draft is checked for
  types and formats only (`stage: :draft`, it may be incomplete); sending
  it (`stage: :submit`) checks everything, required fields included.
  Runs in the change body, before AshCloak encrypts the `data` argument.
  """
  use Ash.Resource.Change

  alias App.Documents.Types

  @impl true
  def change(changeset, opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :type)

    case opts[:stage] do
      :draft -> cast_argument(changeset, type)
      :submit -> check_stored(changeset, type)
    end
  end

  defp cast_argument(changeset, type) do
    case Ash.Changeset.fetch_argument(changeset, :data) do
      {:ok, data} when is_map(data) ->
        case Types.cast_draft(type, data) do
          {:ok, data} -> Ash.Changeset.set_argument(changeset, :data, data)
          {:error, errors} -> add_errors(changeset, errors)
        end

      _ ->
        changeset
    end
  end

  # The stored fields: as loaded by the caller, or decrypted here by the
  # system (no access-log entry: nothing is shown).
  defp check_stored(changeset, type) do
    # (Ash.NotLoaded is a struct, so it matches %{} — test for it first.)
    data =
      case changeset.data.data do
        %Ash.NotLoaded{} -> Ash.load!(changeset.data, :data, authorize?: false).data
        %{} = data -> data
        _ -> Ash.load!(changeset.data, :data, authorize?: false).data
      end

    case Types.cast(type, data) do
      {:ok, _data} -> changeset
      {:error, errors} -> add_errors(changeset, errors)
    end
  end

  # Without a field, so the page shows (and translates) the message alone.
  defp add_errors(changeset, errors),
    do: Ash.Changeset.add_error(changeset, message: Enum.join(errors, "; "))
end
