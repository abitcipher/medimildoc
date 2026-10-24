defmodule App.Care do
  @moduledoc """
  Care outside the person record (docs/design/referral-discharge.md): the
  registry of organizations providing medical care — internal priority
  units first — that referrals and discharge summaries name.
  """
  use Ash.Domain

  resources do
    resource App.Care.Provider
  end
end
