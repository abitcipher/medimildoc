defmodule AppWeb.FhirController do
  @moduledoc """
  The FHIR R5 read API (docs/design/fhir-api.md): `GET /fhir/R5/metadata`
  (public CapabilityStatement), `GET /fhir/R5/:type/:id`, `GET
  /fhir/R5/:type?…` (searchset Bundle) and `GET /fhir/R5/Binary/:id` (a
  signed document's PDF, through a short-lived link). Responses are
  `application/fhir+json`; errors are OperationOutcomes.
  """
  use AppWeb, :controller

  alias App.Api.Smart
  alias App.Fhir
  alias App.Fhir.Map, as: FhirMap

  def metadata(conn, _params), do: send_fhir(conn, 200, capability_statement(base(conn)))

  @doc "SMART discovery (docs/design/fhir-api.md §Phase 2)."
  def smart_configuration(conn, _params) do
    json(conn, %{
      "token_endpoint" => token_url(),
      "grant_types_supported" => ["client_credentials"],
      "token_endpoint_auth_methods_supported" => ["private_key_jwt"],
      "token_endpoint_auth_signing_alg_values_supported" => Smart.algorithms(),
      "scopes_supported" => [
        "system/*.rs" | Enum.map(App.Fhir.external_types(), &"system/#{&1}.rs")
      ],
      "capabilities" => ["client-confidential-asymmetric"]
    })
  end

  @doc "SMART backend services token endpoint (`App.Api.Smart`)."
  def token(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Smart.token(params, token_url()) do
      {:ok, body} ->
        json(conn, body)

      {:error, error, description} ->
        conn
        |> put_status(if(error == "invalid_client", do: 401, else: 400))
        |> json(%{"error" => error, "error_description" => description})
    end
  end

  def read(conn, %{"type" => type, "id" => id}) do
    conn.assigns.fhir_actor |> Fhir.read(type, id, base(conn)) |> respond(conn)
  end

  def search(conn, %{"type" => type} = params) do
    conn.assigns.fhir_actor
    |> Fhir.search(type, Map.drop(params, ["type"]), base(conn))
    |> respond(conn)
  end

  def binary(conn, %{"id" => id}) do
    case Fhir.pdf(conn.assigns.fhir_actor, id) do
      {:ok, document} ->
        redirect(conn,
          external:
            App.Storage.link(document.pdf_key, "#{document.number}.pdf",
              inline: true,
              content_type: "application/pdf"
            )
        )

      {:error, :not_found} ->
        send_fhir(conn, 404, FhirMap.outcome("not-found", "No such document."))
    end
  end

  defp respond({:ok, resource}, conn), do: send_fhir(conn, 200, resource)

  defp respond({:error, :not_found}, conn),
    do:
      send_fhir(
        conn,
        404,
        FhirMap.outcome("not-found", "No such resource, or not readable with this token.")
      )

  defp respond({:error, :forbidden}, conn),
    do: send_fhir(conn, 403, FhirMap.outcome("forbidden", "Not allowed with this token."))

  defp respond({:error, :unsupported}, conn),
    do:
      send_fhir(conn, 404, FhirMap.outcome("not-supported", "This resource type is not served."))

  defp respond({:error, {:bad_request, text}}, conn),
    do: send_fhir(conn, 400, FhirMap.outcome("invalid", text))

  @doc false
  def send_fhir(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/fhir+json")
    |> Plug.Conn.send_resp(status, Jason.encode_to_iodata!(body))
  end

  # The public address (APP_URL, as in notifications) or the endpoint's.
  defp base(_conn), do: public_url() <> "/fhir/R5"

  @doc "The token endpoint's URL, which client assertions name as `aud`."
  def token_url, do: public_url() <> "/fhir/auth/token"

  defp public_url,
    do: Application.get_env(:app, App.Notify, [])[:app_url] || AppWeb.Endpoint.url()

  defp capability_statement(base) do
    %{
      "resourceType" => "CapabilityStatement",
      "status" => "active",
      "date" => "2026-09-30",
      "kind" => "instance",
      "fhirVersion" => "5.0.0",
      "format" => ["json"],
      "implementation" => %{"description" => "HR Admin FHIR read API", "url" => base},
      "rest" => [
        %{
          "mode" => "server",
          "security" => %{
            "service" => [
              %{
                "coding" => [
                  %{
                    "system" => "http://terminology.hl7.org/CodeSystem/restful-security-service",
                    "code" => "SMART-on-FHIR"
                  }
                ]
              }
            ],
            "extension" => [
              %{
                "url" => "http://fhir-registry.smarthealthit.org/StructureDefinition/oauth-uris",
                "extension" => [%{"url" => "token", "valueUri" => token_url()}]
              }
            ],
            "description" =>
              "Bearer token: of a service client or personal token, or from the token endpoint for external systems (SMART backend services, private_key_jwt)."
          },
          "resource" =>
            Enum.map(Fhir.types(), fn type ->
              %{
                "type" => type,
                "interaction" => [%{"code" => "read"}, %{"code" => "search-type"}],
                "searchParam" => search_params(type)
              }
            end)
        }
      ]
    }
  end

  defp search_params("Patient"),
    do: [param("_id", "token"), param("identifier", "token"), param("name", "string")]

  defp search_params("Organization"), do: [param("name", "string")]
  defp search_params("Practitioner"), do: []
  defp search_params(_type), do: [param("patient", "reference")]

  defp param(name, type), do: %{"name" => name, "type" => type}
end
