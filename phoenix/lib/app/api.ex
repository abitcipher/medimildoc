defmodule App.Api do
  @moduledoc """
  Clients of the FHIR read API (docs/design/fhir-api.md): service accounts
  and personal tokens, external systems and their access tokens. A
  presented token becomes an actor in `App.Api.Tokens` (kept out of this
  module: the resources name their domain, so helpers here make a cycle).
  """
  use Ash.Domain

  resources do
    resource App.Api.Client
    resource App.Api.AccessToken
    resource App.Api.UsedJti
  end
end
