defmodule App.Vault do
  @moduledoc """
  Encryption at rest (docs/design/access-control-phase1.md): the Cloak
  vault behind AshCloak-encrypted attributes (`PersonRecord.data`,
  `PersonIdentifier.value`, `IdentityDocument.number`).

  Ciphers come from `config :app, App.Vault` — fixed throwaway keys in
  dev/test, `CLOAK_KEY` in production (`config/runtime.exs`). Key rotation
  is described in `infra/README.md`.
  """
  use Cloak.Vault, otp_app: :app
end
