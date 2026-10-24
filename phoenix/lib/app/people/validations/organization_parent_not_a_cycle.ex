defmodule App.People.Validations.OrganizationParentNotACycle do
  @moduledoc """
  Rejects setting an Organization's `parent_id` to itself, or to any of its
  own descendants — either would make the hierarchy exposed in
  `AppWeb.OrganizationsLive.Index` an actual cycle, which
  would infinite-loop any future code that walks up the `parent`
  chain (e.g. a breadcrumb, or a future "which brigade is this unit
  under" lookup).

  Only meaningful for `:update` — a brand-new organization (whether or not
  its uuid_v7 id is already generated app-side by the time this runs)
  can't yet be any existing row's ancestor, since nothing points at it.
  Walks the proposed parent's own ancestor chain looking for this
  organization's id; bounded depth as a defensive backstop against an
  already-corrupted chain looping forever, not because a legitimate
  hierarchy should ever get that deep.
  """
  use Ash.Resource.Validation

  # Generous: real org charts (brigade -> battalion -> company -> platoon,
  # or the civilian equivalent) are nowhere near this deep. Only exists to
  # bound the walk if data is ever corrupted outside this validation
  # (direct SQL, a future bulk import, ...).
  @max_depth 100

  @impl true
  def validate(changeset, _opts, _context) do
    org_id = Ash.Changeset.get_attribute(changeset, :id)
    parent_id = Ash.Changeset.get_attribute(changeset, :parent_id)

    cond do
      is_nil(org_id) or is_nil(parent_id) ->
        :ok

      parent_id == org_id ->
        {:error, field: :parent_id, message: "cannot be its own parent"}

      cycle?(parent_id, org_id, 0) ->
        {:error, field: :parent_id, message: "would create a cycle in the organization hierarchy"}

      true ->
        :ok
    end
  end

  defp cycle?(_ancestor_id, _org_id, depth) when depth > @max_depth, do: false
  defp cycle?(nil, _org_id, _depth), do: false
  defp cycle?(ancestor_id, org_id, _depth) when ancestor_id == org_id, do: true

  defp cycle?(ancestor_id, org_id, depth) do
    case Ash.get(App.People.Organization, ancestor_id, authorize?: false) do
      {:ok, %{parent_id: next_ancestor_id}} -> cycle?(next_ancestor_id, org_id, depth + 1)
      # Dangling/missing parent isn't this validation's problem — the FK
      # constraint already guarantees parent_id points at a real row when
      # set, this is just defensive against a race (deleted mid-check).
      _ -> false
    end
  end
end
