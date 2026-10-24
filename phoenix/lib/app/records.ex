defmodule App.Records do
  @moduledoc """
  Records management (docs/design/registers-file-plan.md): the file plan
  (номенклатура справ) — cases a year's documents are filed into, with
  their retention periods. Registers themselves are the numbering of
  `App.Documents` (register, year, sequence).
  """
  use Ash.Domain

  resources do
    resource(App.Records.Case)
  end
end
