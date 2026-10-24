defmodule App.Rules do
  @moduledoc """
  FSDC — the flexible system of data consistency
  (docs/design/data-consistency.md): rule sets (GoRules JDM graphs with a
  severity, the check points and subjects they apply to), their version
  history, and evaluation (`App.Rules.Check`). Rules run only when
  `App.Settings.fsdc?/0`.
  """
  use Ash.Domain

  resources do
    resource App.Rules.RuleSet
    resource App.Rules.RuleSetVersion
  end
end
