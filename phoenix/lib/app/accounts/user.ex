defmodule App.Accounts.User do
  @moduledoc """
  A user of the standalone forms UI (`/people`, `/organizations`,
  `/positions`): Google OAuth, three-tier `role`
  (`:admin`/`:hr`/`:viewer`). Unrelated to `App.SheetsToken`:
  that HMAC token authenticates the *embedded* `/sheets` LiveView
  session inside the Google Sheets sidebar, a completely different trust
  boundary with no login screen at all (identity comes from
  `Session.getActiveUser()` inside the Apps Script sandbox). This resource
  is the one that actually logs a human into a browser session.

  Sessions are JWTs (`authentication.tokens`, via `AshAuthentication`/
  `Joken`), not Phoenix's default cookie-session mechanism — a deliberate
  choice, not just AshAuthentication's default: the user wants a future
  path to an external gateway (Envoy + OPA or similar) fronting
  authentication/authorization as its own service, and a self-contained,
  independently-verifiable JWT is what makes that swap possible later
  without restructuring this app. `AppWeb.LiveUserAuth` (installer-generated
  `on_mount` hooks, wired into the router's `:authenticated_routes`
  live_session) is the single seam where that swap would happen — it's the
  only place that decides how `current_user` gets into `socket.assigns`,
  so pointing it at a gateway-issued JWT later touches no LiveView code.
  """
  use Ash.Resource,
    otp_app: :app,
    domain: App.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  alias App.Accounts.UiPreferences

  postgres do
    table "users"
    repo App.Repo

    references do
      # Deleting a person unlinks their account rather than deleting it.
      reference :person, on_delete: :nilify
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # Any signed-in user can read the user list (needed to render e.g. a
    # manager's name next to a Person) — but only an admin can change
    # anyone's role. `register_with_google`'s own create
    # is handled entirely by the bypass above (no actor exists yet during
    # OAuth), so it's never subject to this block.
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action(:update_access) do
      authorize_if {App.Access.Checks.HasPermission, permission: "users.manage"}
    end

    # Interface settings: each user only their own.
    policy action(:update_preferences) do
      authorize_if expr(id == ^actor(:id))
    end
  end

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource App.Accounts.Token
      signing_secret App.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      google do
        client_id App.Secrets
        client_secret App.Secrets
        redirect_uri App.Secrets
        identity_resource App.Accounts.UserIdentity
      end

      # docs/design/events-and-person-login.md: PersonID + password. No
      # self-registration — the account comes from App.Accounts.PersonLogin,
      # the password from the e-mailed single-use link (the reset flow).
      password :password do
        identity_field :login_id
        hashed_password_field :hashed_password
        registration_enabled? false

        resettable do
          sender App.Accounts.SetPasswordSender
          token_lifetime {30, :minutes}
          request_password_reset_action_name :request_password_reset_token
          password_reset_action_name :password_reset_with_password
        end
      end
    end
  end

  attributes do
    # See App.People.Assignment for why uuid_v7 (project-wide convention).
    uuid_v7_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? true
      public? true
    end

    # three tiers, uniform across the whole People domain
    # (no per-kind exceptions yet, e.g. PersonRecord's :medical_condition —
    # deferred until a real need shows up, same call as AC/35-D/2000).
    # Defaults to :viewer (least privilege) — the first real admin has to be
    # promoted by hand once, via remote console, which
    # is deliberate: no auto-promote-first-user heuristic baked into this
    # action (explicit over implicit), since that would
    # silently hand admin to whoever happens to sign in first, including by
    # accident during testing.
    attribute :role, :atom do
      allow_nil? false
      public? true
      default :viewer
      constraints one_of: App.Access.roles()
    end

    # Access profiles on top of the base role (docs/design/access-control-
    # phase1.md): each adds a bundle of permissions declared in
    # priv/access_profiles.json. Empty by default.
    attribute :profiles, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      constraints items: [one_of: App.Access.profiles()]
    end

    # docs/design/events-and-person-login.md: the linked person's
    # PersonID, the sign-in name for a password; set by
    # App.Accounts.PersonLogin, never by a form.
    attribute :login_id, :ci_string do
      allow_nil? true
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? true
      sensitive? true
    end

    # When the account last signed in (any method), for the users list.
    attribute :last_sign_in_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    # Interface settings (App.Accounts.UiPreferences): how forms are shown
    # on narrow and wide screens. The user's own, changed only through
    # :update_preferences.
    attribute :ui_preferences, :map do
      allow_nil? false
      public? true
      default %{}
    end
  end

  relationships do
    has_many :identities, App.Accounts.UserIdentity

    # The Person this account belongs to (docs/design/access-control-phase2.md
    # Set explicitly by users.manage; a user's unit and clearance come
    # from it.
    belongs_to :person, App.People.Person do
      allow_nil? true
      public? true
    end
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    # Handles both first-time registration and every subsequent sign-in via
    # Google (upsert on the verified email) — per the AshAuthentication
    # Google tutorial. `user_info`/`oauth_tokens` are supplied by the
    # strategy itself, not client input.
    create :register_with_google do
      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false
      upsert? true
      upsert_identity :unique_email

      change AshAuthentication.GenerateTokenChange
      # Persists the provider's iss/sub identity claims (App.Accounts.UserIdentity).
      change AshAuthentication.Strategy.OAuth2.IdentityChange
      # The registration confirmation for a new account (App.Notify).
      change App.Notify.Changes.Registration

      change fn changeset, _context ->
        user_info = Ash.Changeset.get_argument(changeset, :user_info)

        Ash.Changeset.change_attributes(changeset, %{
          email: Map.get(user_info, "email"),
          name: Map.get(user_info, "name")
        })
      end
    end

    # users.manage only (see policies above) — the one seam for changing
    # anyone's access. `role` and `profiles` are deliberately excluded from
    # every other action (there's no generic :update here at all) so they
    # can never change as a side effect of some other operation.
    update :update_access do
      # The access event needs the changed attributes.
      require_atomic? false
      accept [:role, :profiles, :person_id]

      # docs/design/events-and-person-login.md: who changed whose access.
      change after_action(fn changeset, user, context ->
               if Ash.Changeset.changing_attribute?(changeset, :role) or
                    Ash.Changeset.changing_attribute?(changeset, :profiles) do
                 App.EventLog.emit(
                   "hrda.accounts.access.changed",
                   %{role: user.role, profiles: user.profiles},
                   actor: context.actor,
                   subject: "user/#{user.id}"
                 )
               end

               {:ok, user}
             end)
    end

    # The password set through the e-mailed link: at least 12
    # characters, typed twice; the link works once (the strategy revokes
    # it). Mirrors the action the strategy would build, with a longer
    # minimum.
    update :password_reset_with_password do
      require_atomic? false
      argument :reset_token, :string, allow_nil?: false, sensitive?: true

      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 12, max_length: 200
      end

      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true

      validate AshAuthentication.Strategy.Password.ResetTokenValidation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation
      change AshAuthentication.Strategy.Password.HashPasswordChange
      change AshAuthentication.GenerateTokenChange
      metadata :token, :string, allow_nil?: false
    end

    # An account for a person asking to sign in with their PersonID
    # (App.Accounts.PersonLogin, run as the system): the minimal role.
    create :create_for_person do
      accept [:email, :login_id, :person_id]
      change set_attribute(:role, :person)
    end

    # The PersonID of an existing linked account (App.Accounts.PersonLogin).
    update :set_login_id do
      accept [:login_id]
    end

    update :signed_in do
      accept []
      change set_attribute(:last_sign_in_at, &DateTime.utc_now/0)
    end

    # The user's own interface settings; unknown keys and values are dropped.
    update :update_preferences do
      require_atomic? false
      accept [:ui_preferences]

      change fn changeset, _context ->
        prefs = Ash.Changeset.get_attribute(changeset, :ui_preferences)

        Ash.Changeset.force_change_attribute(
          changeset,
          :ui_preferences,
          UiPreferences.normalize(prefs)
        )
      end
    end
  end

  identities do
    identity :unique_email, [:email]
    # One account per person.
    identity :unique_person, [:person_id]
    identity :unique_login_id, [:login_id]
  end

  aggregates do
    # Signed in with Google at least once (an identity from the provider).
    exists :google?, :identities do
      public? true
    end
  end

  calculations do
    # Whether a password is set (the hash itself never leaves the resource).
    calculate :password_set?, :boolean, expr(not is_nil(hashed_password)) do
      public? true
    end
  end
end
