defmodule App.Documents.Counter do
  @moduledoc """
  Register numbering (docs/design/documents-core.md §Registers): the last
  sequence taken per register (its code, e.g. `ос`) and year. `next/2` takes the next one in a
  single `INSERT … ON CONFLICT … DO UPDATE` (row-locked), inside the
  signing transaction, so numbers are unique and a rolled-back signature
  gives its number back. Only this module writes the table.
  """
  use Ash.Resource,
    domain: App.Documents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "document_counters"
    repo App.Repo
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    attribute :register, :string, primary_key?: true, allow_nil?: false
    attribute :year, :integer, primary_key?: true, allow_nil?: false
    attribute :last, :integer, allow_nil?: false, default: 0
  end

  actions do
    defaults [:read]
  end

  @doc "The next number in `register` for `year` (1, 2, …)."
  @spec next(String.t(), integer()) :: pos_integer()
  def next(register, year) do
    %{rows: [[last]]} =
      App.Repo.query!(
        """
        INSERT INTO document_counters (register, year, last) VALUES ($1, $2, 1)
        ON CONFLICT (register, year) DO UPDATE SET last = document_counters.last + 1
        RETURNING last
        """,
        [register, year]
      )

    last
  end
end
