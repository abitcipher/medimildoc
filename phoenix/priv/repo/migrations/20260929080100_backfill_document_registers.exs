defmodule App.Repo.Migrations.BackfillDocumentRegisters do
  @moduledoc """
  Data step after `DocumentRegisters` (docs/design/documents-core.md
  §Registers): documents signed under the first numbering patterns
  (`НВЛК-2026-0001`, `ВЛК-2026-0001`, `0001-ОС/2026`) get their register
  code, year and sequence; their printed `number` is kept, since it is part
  of what was signed (content hash, stored PDF). Counters move from the
  old pattern keys to register codes, so new numbers continue the same
  sequences in the new style (`2-ос`).
  """
  use Ecto.Migration

  @patterns [
    {"нвлк", "^НВЛК-(\\d{4})-(\\d+)$", 1, 2, "НВЛК-{year}-{seq}"},
    {"влк", "^ВЛК-(\\d{4})-(\\d+)$", 1, 2, "ВЛК-{year}-{seq}"},
    {"ос", "^(\\d+)-ОС/(\\d{4})$", 2, 1, "{seq}-ОС/{year}"}
  ]

  def up do
    for {code, regex, year_group, seq_group, old_key} <- @patterns do
      execute("""
      UPDATE documents
      SET register = '#{code}',
          register_year = (regexp_match(number, '#{regex}'))[#{year_group}]::bigint,
          register_seq = (regexp_match(number, '#{regex}'))[#{seq_group}]::bigint
      WHERE number ~ '#{regex}' AND register_seq IS NULL
      """)

      execute("UPDATE document_counters SET register = '#{code}' WHERE register = '#{old_key}'")
    end
  end

  # The structured fields go with the schema step's own rollback; the old
  # counter keys come back here.
  def down do
    for {code, _regex, _y, _s, old_key} <- @patterns do
      execute("UPDATE document_counters SET register = '#{old_key}' WHERE register = '#{code}'")
    end
  end
end
