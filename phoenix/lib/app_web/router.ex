defmodule AppWeb.Router do
  use AppWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    # after :fetch_session (needs it), before anything that
    # renders — controller actions run in this same process, so this is
    # sufficient for them; LiveViews additionally need
    # AppWeb.LocaleHook's on_mount (this plug's process ends when the
    # initial HTTP response is sent, before the LiveView's own process
    # exists).
    plug AppWeb.Plugs.SetLocale
    plug :fetch_live_flash
    plug :put_root_layout, html: {AppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
    # PersonID as stored, for the password sign-in (docs/design/events-and-person-login.md).
    plug AppWeb.Plugs.NormalizeLoginId
  end

  # JSON for the app's own pages (reference data for pickers): the browser
  # session, locale and signed-in user of :browser, but JSON, no layout.
  pipeline :browser_json do
    plug :accepts, ["json"]
    plug :fetch_session
    plug AppWeb.Plugs.SetLocale
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  # required to let Google's HtmlService sidebar iframe embed
  # us. Kept as a separate pipeline (rather than folded into :browser) so it
  # only applies to routes actually meant to be framed.
  pipeline :embeddable do
    plug AppWeb.Plugs.FrameAncestors
  end

  # M2: the Apps Script shim's onEdit trigger POSTs here, not a
  # browser — no session/CSRF, just the HMAC token (same scheme as the
  # LiveView's sheets_token, App.SheetsToken) as a Bearer header.
  pipeline :sheets_webhook do
    plug :accepts, ["json"]
    plug AppWeb.Plugs.VerifySheetsToken
  end

  # M3 forms UI  — standalone admin pages, not
  # embedded in the Sheets sidebar (no :embeddable, plain default CSP).
  # Auth depth per : every LiveView here needs *a*
  # signed-in user at minimum; three routes below additionally require an
  # :admin/:hr role via a second on_mount hook stacked
  # after :live_user_required. Unrelated to `/sheets` below: that's
  # ADR-3's separate HMAC-token trust boundary for the embedded sidebar
  # session, not a Google-authenticated browser user.
  # FHIR R5 read API (docs/design/fhir-api.md): bearer tokens, no session.
  pipeline :fhir do
    plug :put_secure_browser_headers
  end

  pipeline :fhir_auth do
    plug AppWeb.Plugs.FhirAuth
  end

  scope "/fhir/R5", AppWeb do
    pipe_through :fhir
    get "/metadata", FhirController, :metadata
    get "/.well-known/smart-configuration", FhirController, :smart_configuration
  end

  scope "/fhir/auth", AppWeb do
    pipe_through :fhir
    post "/token", FhirController, :token
  end

  scope "/fhir/R5", AppWeb do
    pipe_through [:fhir, :fhir_auth]
    get "/Binary/:id", FhirController, :binary
    get "/:type/:id", FhirController, :read
    get "/:type", FhirController, :search
  end

  scope "/", AppWeb do
    pipe_through :browser

    # ORDER MATTERS HERE, confirmed live: "/people/new"
    # (this block) and "/people/:id" (the next block) collide on the
    # literal segment "new" vs. the wildcard "id". Within a *single*
    # scope/live_session, Phoenix's router sorts literal segments before
    # wildcards regardless of source order — but "/people/new" and
    # "/people/:id" live in two *different* live_session blocks (they need
    # different on_mount hooks), and across separate blocks like that,
    # plain source order wins instead. Putting this :editor_routes block
    # (the literal "/people/new") before :authenticated_routes (the
    # wildcard "/people/:id") is what makes "/people/new" actually route
    # to PeopleLive.New — reversed, it 500s inside PeopleLive.Show
    # (Ash.get! with primary key "new"). If you add another literal path
    # under an existing wildcard prefix in a new live_session, it needs
    # the same "more specific block first" treatment.
    #
    # people.write only — anyone else hitting these directly gets redirected
    # home with a flash rather than a form that 403s on submit.
    ash_authentication_live_session :editor_routes,
      on_mount: [
        {AppWeb.LocaleHook, :default},
        {AppWeb.LiveUserAuth, :live_user_required},
        {AppWeb.LiveUserAuth, {:require, "people.write"}}
      ] do
      live "/people/new", PeopleLive.New, :new
      live "/people/:id/edit", PeopleLive.Edit, :edit
      live "/import-export", ImportExportLive, :index
    end

    # Any signed-in user; what each one may read or change is enforced by
    # each resource's own Ash policies, not by this route.
    ash_authentication_live_session :authenticated_routes,
      session: {AppWeb.LiveSessionExtras, :session, []},
      on_mount: [
        {AppWeb.LocaleHook, :default},
        {AppWeb.LiveUserAuth, :live_user_required}
      ] do
      live "/people", PeopleLive.Index, :index
      live "/people/:id", PeopleLive.Show, :show
      live "/organizations", OrganizationsLive.Index, :index
      live "/org-graph", OrgGraphLive, :index
      live "/positions", PositionsLive.Index, :index
      live "/care-providers", CareProvidersLive.Index, :index
      # Documents with a lifecycle (docs/design/documents-core.md).
      live "/tasks", TasksLive, :index
      # The signed-in person's own data (docs/design/events-and-person-login.md).
      live "/me", MyDataLive, :index
      live "/search", SearchLive, :index
      live "/notifications", NotificationsLive, :index
      live "/api-access", ApiAccessLive, :index
      live "/interface", InterfaceLive, :index
      live "/acknowledgements", AcknowledgementsLive, :index
      live "/leave-calendar", LeaveCalendarLive, :index
      live "/duty-roster", DutyRosterLive, :index
      live "/documents/:id", DocumentsLive.Show, :show
    end

    # users.manage — assigning roles and access profiles.
    ash_authentication_live_session :users_routes,
      on_mount: [
        {AppWeb.LocaleHook, :default},
        {AppWeb.LiveUserAuth, :live_user_required},
        {AppWeb.LiveUserAuth, {:require, "users.manage"}}
      ] do
      live "/users", UsersLive.Index, :index
    end

    # Registers and the file plan (docs/design/registers-file-plan.md):
    # records officers and HR; changing the plan is records.manage (policies).
    ash_authentication_live_session :records_routes,
      on_mount: [
        {AppWeb.LocaleHook, :default},
        {AppWeb.LiveUserAuth, :live_user_required},
        {AppWeb.LiveUserAuth, {:require_any, ["records.manage", "people.write"]}}
      ] do
      live "/registers", RegistersLive, :index
      live "/file-plan", FilePlanLive, :index
    end

    # System settings and FSDC rules (docs/design/data-consistency.md).
    ash_authentication_live_session :settings_routes,
      on_mount: [
        {AppWeb.LocaleHook, :default},
        {AppWeb.LiveUserAuth, :live_user_required},
        {AppWeb.LiveUserAuth, {:require, "settings.manage"}}
      ] do
      live "/settings", SettingsLive, :index
      # The Sheets sidebar per role (docs/design/sheets-ui.md §Sidebar layout).
      live "/sidebar-layout", SidebarLayoutLive, :index
    end

    ash_authentication_live_session :rules_routes,
      on_mount: [
        {AppWeb.LocaleHook, :default},
        {AppWeb.LiveUserAuth, :live_user_required},
        {AppWeb.LiveUserAuth, {:require, "rules.manage"}}
      ] do
      live "/rules", RulesLive.Index, :index
      live "/rules/:key", RulesLive.Edit, :edit
    end

    # audit.read — detected write collisions and
    # the sensitive-read access log (docs/design/access-control-phase1.md).
    ash_authentication_live_session :audit_routes,
      on_mount: [
        {AppWeb.LocaleHook, :default},
        {AppWeb.LiveUserAuth, :live_user_required},
        {AppWeb.LiveUserAuth, {:require, "audit.read"}}
      ] do
      live "/change-conflicts", ChangeConflictsLive.Index, :index
      live "/access-log", AccessLogLive.Index, :index
      # The general event log (docs/design/events-and-person-login.md).
      live "/events", EventsLive.Index, :index
      # FSDC incidents (docs/design/data-consistency.md).
      live "/incidents", IncidentsLive, :index
    end
  end

  scope "/", AppWeb do
    pipe_through :browser

    get "/", PageController, :home
    # Stored files: access check, access log, redirect to a signed link.
    get "/files/:id", FileController, :show
    # A signed document's PDF: access check, access log, signed link.
    get "/documents/:id/pdf", DocumentController, :pdf
    # A document's file (a letter's scan), docs/design/correspondence.md.
    get "/documents/:id/files/:file_id", DocumentController, :file
    # Offline assignments workbook (docs/design/assignments-sheets.md).
    get "/exports/assignments.xlsx", ExportController, :assignments
    # A register for a year, or a case's contents (docs/design/registers-file-plan.md).
    get "/exports/register.xlsx", ExportController, :register
    # The inventory of a year's closed cases of one retention class.
    get "/exports/case-inventory.pdf", ExportController, :case_inventory_pdf
    get "/exports/case-inventory.xlsx", ExportController, :case_inventory_xlsx
    get "/exports/disposal-act.pdf", ExportController, :disposal_act
    # Own data downloads, with the token /me gives (docs/design/events-and-person-login.md).
    get "/me/export/:format", MyDataController, :export
    get "/me/confirm-google", MyDataController, :confirm_google
    auth_routes AuthController, App.Accounts.User, path: "/auth"

    sign_out_route AuthController, "/sign-out",
      overrides: [AppWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]

    # Only the Google strategy is configured on App.Accounts.User 
    # "just authenticated vs not", no password/magic-link/
    # confirmation strategies), so `sign_in_route` needs neither
    # `register_path`/`reset_path` (password-strategy-only options) nor the
    # `reset_route`/`confirm_route`/`magic_sign_in_route` macros below it in
    # the installer's default template — those reference strategies this
    # resource doesn't have and were removed rather than left as dead routes.
    # Our own page (docs/design/events-and-person-login.md): Google, and
    # PersonID + password.
    sign_in_route auth_routes_prefix: "/auth",
                  live_view: AppWeb.SignInLive,
                  on_mount: [{AppWeb.LocaleHook, :default}, {AppWeb.LiveUserAuth, :live_no_user}],
                  overrides: [AppWeb.AuthOverrides, AshAuthentication.Phoenix.Overrides.Default]

    ash_authentication_live_session :person_sign_in,
      on_mount: [{AppWeb.LocaleHook, :default}, {AppWeb.LiveUserAuth, :live_no_user}] do
      live "/sign-in/person", SignInLive, :person
      live "/sign-in/person/request", SignInLive, :request
      live "/sign-in/person/password", SignInLive, :password
    end
  end

  scope "/", AppWeb do
    pipe_through :browser_json

    # docs/design/reference-data-and-files.md
    get "/reference/:dataset", ReferenceController, :show
    get "/reference/:dataset/search", ReferenceController, :search
    get "/reference/learned/:category/search", ReferenceController, :learned
  end

  scope "/", AppWeb do
    pipe_through [:browser, :embeddable]

    live "/sheets", SheetsLive
  end

  scope "/webhooks", AppWeb do
    pipe_through :sheets_webhook

    post "/sheets/edit", SheetsWebhookController, :edit
  end

  # Other scopes may use custom stacks.
  # scope "/api", AppWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:app, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AppWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview

      # dev-only sign-in bypass (no Google OAuth needed to
      # click through the app locally). Same `dev_routes` guard as the two
      # routes above; AppWeb.DevAuthController itself doesn't even exist
      # as a compiled module outside :dev.
      get "/sign-in", AppWeb.DevAuthController, :new
      post "/sign-in", AppWeb.DevAuthController, :create
    end
  end
end
