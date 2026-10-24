defmodule App.Audit do
  @moduledoc """
  Ash domain for collision-observability requirement
  — fulfilling the clause, unaddressed since was recorded early in
  this project, before M3 even started.
  """
  use Ash.Domain,
    otp_app: :app

  resources do
    resource App.Audit.ChangeConflict
    resource App.Audit.AccessLog
    resource App.Audit.EmergencyAccess
    resource App.Audit.Correction
    resource App.Audit.Incident
  end
end
