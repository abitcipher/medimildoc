defmodule App.Documents.Document do
  @moduledoc """
  A document with a lifecycle (docs/design/documents-core.md): typed by
  `App.Documents.Types`, about one person, drafted, sent along its route,
  approved, and signed — which numbers it in its register, stores its PDF
  and applies its effects. A signed document is never edited or deleted.

  `data` (the fields) is encrypted at rest like person records; reads of
  documents in a sensitive category are in the access log.
  """
  use Ash.Resource,
    domain: App.Documents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak, AshStateMachine]

  alias App.Documents.{Changes, Checks, Types}

  postgres do
    table "documents"
    repo App.Repo

    references do
      # Demo purge and person deletion take the person's documents along.
      reference :person, on_delete: :delete
      reference :basis, on_delete: :nilify
      reference :author, on_delete: :nilify
      reference :signed_by, on_delete: :nilify
      reference :handling_unit, on_delete: :nilify
      reference :recipient_provider, on_delete: :nilify
      # A case with documents in it can't be removed.
      reference :case, on_delete: :restrict
    end

    custom_indexes do
      index [:person_id]
      index [:state]
      index [:case_id]

      index [:register, :register_year, :register_seq],
        unique: true,
        where: "register_seq IS NOT NULL"
    end
  end

  policies do
    # Effects and maintenance run without an actor (authorize?: false).
    policy action([:attach_pdf, :attach_facts, :file]) do
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if Checks.ReadableDocuments
    end

    policy action([:create, :update_fields, :submit, :cancel]) do
      authorize_if Checks.CanWriteType
    end

    policy action([:approve, :return]) do
      authorize_if Checks.CurrentAssignee
    end

    policy action(:sign) do
      authorize_if {Checks.CurrentAssignee, step_action: :sign}
    end
  end

  cloak do
    vault App.Vault
    attributes [:data]
    # Decrypted only where the fields are shown (load :data): lists and the
    # inbox don't read them, so they add nothing to the access log.
    on_decrypt {App.Audit.AccessLogger, :on_decrypt, []}
  end

  state_machine do
    initial_states([:draft])
    default_initial_state(:draft)

    transitions do
      transition(:submit, from: :draft, to: :in_review)
      transition(:return, from: :in_review, to: :draft)
      transition(:sign, from: :in_review, to: :signed)
      transition(:cancel, from: [:draft, :in_review], to: :cancelled)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :type, :atom do
      allow_nil? false
      public? true
      constraints one_of: Types.ids()
    end

    attribute :data, :map do
      allow_nil? false
      default %{}
    end

    # Scheduled documents (a re-examination referral): when it is due.
    attribute :due_on, :date, public?: true

    # Register entry (docs/design/documents-core.md §Registers): register
    # code, year and sequence stored apart; `number` is their display
    # (`15-ос`), unique only together with the register and year.
    attribute :register, :string, public?: true
    attribute :register_year, :integer, public?: true
    attribute :register_seq, :integer, public?: true
    attribute :number, :string, public?: true
    attribute :registered_on, :date, public?: true
    attribute :signed_at, :utc_datetime_usec, public?: true

    # SHA-256 of what was signed (type, person, number, fields) and of the
    # stored PDF (docs/design/documents-core.md §Decisions: internal
    # signatures).
    attribute :content_sha256, :string, public?: true
    attribute :pdf_key, :string
    attribute :pdf_sha256, :string, public?: true

    timestamps()
  end

  relationships do
    # Nil only for types about no person (`"subject": "none"`, letters).
    belongs_to :person, App.People.Person do
      public? true
    end

    # The document this one follows from (a conclusion's referral).
    belongs_to :basis, __MODULE__, public?: true

    # The unit of the post or care provider the document names
    # (Changes.SetHandlingUnit, App.Documents.Access).
    belongs_to :handling_unit, App.People.Organization, public?: true

    # The care provider the document is addressed to (Changes.SetHandlingUnit):
    # what an external system of that provider may read (App.Fhir).
    belongs_to :recipient_provider, App.Care.Provider, public?: true

    # Nil for documents created by an effect (the system).
    belongs_to :author, App.Accounts.User, public?: true
    belongs_to :signed_by, App.Accounts.User, public?: true
    # The file plan case it is filed into when signed (docs/design/registers-file-plan.md).
    belongs_to :case, App.Records.Case, public?: true

    has_many :steps, App.Documents.Step
    has_many :events, App.Documents.Event
    has_many :files, App.Documents.DocumentFile
    has_many :instructions, App.Documents.Instruction
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:type, :person_id, :data, :basis_id, :due_on]
      validate App.Documents.Validations.Subject
      change relate_actor(:author, allow_nil?: true)
      change {Changes.CastData, stage: :draft}
      change Changes.SetHandlingUnit
      change {Changes.RecordEvent, action: :created}
    end

    update :update_fields do
      require_atomic? false
      accept [:data, :due_on]
      validate attribute_equals(:state, :draft)
      change {Changes.CastData, stage: :draft}
      change Changes.SetHandlingUnit
    end

    update :submit do
      require_atomic? false

      argument :assignees, {:array, {:array, :uuid}} do
        allow_nil? false
        description "Assignees per route entry, in route order."
      end

      change {Changes.CastData, stage: :submit}
      change Changes.CheckEffects
      change {App.Rules.Changes.Check, point: "document.submit"}
      change transition_state(:in_review)
      change Changes.CreateSteps
      change {Changes.RecordEvent, action: :submitted}
      change {App.Notify.Changes.DocumentEvents, event: :waiting}
    end

    update :approve do
      require_atomic? false
      argument :comment, :string
      change {Changes.DecideStep, decision: :approved}
      change {Changes.RecordEvent, action: :approved}
      change {App.Notify.Changes.DocumentEvents, event: :waiting}
    end

    update :return do
      require_atomic? false

      argument :comment, :string do
        allow_nil? false
        constraints min_length: 1
      end

      change transition_state(:draft)
      change {Changes.DecideStep, decision: :returned}
      change {Changes.RecordEvent, action: :returned}
      change {App.Notify.Changes.DocumentEvents, event: :returned}
    end

    update :sign do
      require_atomic? false
      argument :comment, :string
      change transition_state(:signed)
      change Changes.CheckEffects
      change {App.Rules.Changes.Check, point: "document.sign"}
      change {Changes.DecideStep, decision: :signed}
      change Changes.Sign
      change {Changes.RecordEvent, action: :signed}
      change {App.Notify.Changes.DocumentEvents, event: :signed}
    end

    update :cancel do
      require_atomic? false
      argument :comment, :string
      change transition_state(:cancelled)
      change Changes.CancelSteps
      change {Changes.RecordEvent, action: :cancelled}
    end

    # Internal: the stored PDF of a signed document (App.Documents.Changes.Sign).
    update :attach_pdf do
      accept [:pdf_key, :pdf_sha256]
    end

    # Internal: filing a signed document into a case created after it was
    # signed (App.Records.FilePlan).
    update :file do
      accept [:case_id]
    end

    # Internal: a certificate's fields with the facts frozen when it is
    # signed (App.Documents.Changes.Sign, docs/design/certificates.md).
    update :attach_facts do
      require_atomic? false
      accept [:data]
    end
  end
end
