defmodule App.Documents.Step do
  @moduledoc """
  One step of a document's route (docs/design/documents-core.md): who
  approves or signs, in which order, and what they decided. Created when
  the author sends the draft; a new round of steps each time it is sent
  again after being returned. Written only by the document's own actions.

  Reading: an assignee sees their own steps (the inbox); the document page
  loads the steps of a document the viewer may already read.
  """
  use Ash.Resource,
    domain: App.Documents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "document_steps"
    repo App.Repo

    references do
      reference :document, on_delete: :delete
      reference :assignee, on_delete: :nilify
      reference :decided_by, on_delete: :nilify
    end

    custom_indexes do
      index [:document_id, :round, :position]
      index [:assignee_id, :status]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(assignee_id == ^actor(:id))
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :round, :integer, allow_nil?: false, public?: true
    attribute :position, :integer, allow_nil?: false, public?: true
    # The route entry it comes from (1-based); steps of one stage marked
    # `parallel` are pending together and decided in any order
    # (docs/design/parallel-approval.md).
    attribute :stage, :integer, public?: true
    attribute :parallel, :boolean, allow_nil?: false, default: false, public?: true

    attribute :action, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:approve, :sign]
    end

    attribute :label, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:waiting, :pending, :approved, :returned, :signed, :cancelled]
    end

    attribute :comment, :string, public?: true
    attribute :decided_at, :utc_datetime_usec, public?: true
    # docs/design/inbox-first.md: when the step became pending (its
    # deadline counts from here), and when its assignee was reminded that
    # it is overdue (once).
    attribute :pending_since, :utc_datetime_usec, public?: true
    attribute :reminded_at, :utc_datetime_usec, public?: true
    timestamps()
  end

  relationships do
    belongs_to :document, App.Documents.Document, allow_nil?: false, public?: true
    belongs_to :assignee, App.Accounts.User, public?: true
    # Who decided, when a deputy did it for the assignee.
    belongs_to :decided_by, App.Accounts.User, public?: true
  end

  actions do
    defaults [:read, create: :*, update: :*]
  end
end
