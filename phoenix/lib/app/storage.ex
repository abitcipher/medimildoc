defmodule App.Storage do
  @moduledoc """
  File storage in RustFS through its S3 API (`ex_aws_s3`;
  docs/design/reference-data-and-files.md). One private bucket; object
  keys are opaque (`App.People.Attachment` holds names and metadata).

  - Uploads go through the app, which checks and hashes them first.
  - Downloads use short-lived signed links: the app checks access (and
    logs sensitive files), then hands the browser a link valid for a few
    minutes, and the browser fetches the file from RustFS directly. Files
    are not encrypted by the app (the user's choice); at-rest protection is
    the server disk's encryption (infra/README.md go-live checklist).

  Configuration (`config :app, :storage`): `bucket`, `endpoint` (how the
  app reaches RustFS, e.g. `http://rustfs:9000`), `public_url` (the base
  signed links use, reachable by browsers — in production the app's own
  host, where Nginx forwards `/<bucket>/` to RustFS), `access_key`,
  `secret_key`, `region`. Path-style addressing: `<base>/<bucket>/<key>`.
  """

  alias ExAws.S3.Upload

  @link_seconds 300

  @doc """
  Stores the file at `path` under `key`, streamed in 8 MB parts (multipart
  upload), so a large file is never held in memory whole.
  """
  @spec put_file(String.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def put_file(key, path, content_type) do
    path
    |> Upload.stream_file(chunk_size: 8 * 1024 * 1024)
    |> ExAws.S3.upload(bucket(), key, content_type: content_type)
    |> request()
  end

  @doc "Deletes the object at `key` (no error if it is already gone)."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key), do: bucket() |> ExAws.S3.delete_object(key) |> request()

  @doc "Creates the bucket unless it exists. Idempotent; run at release start."
  @spec ensure_bucket() :: :ok | {:error, term()}
  def ensure_bucket do
    case bucket() |> ExAws.S3.head_bucket() |> request() do
      :ok -> :ok
      {:error, _} -> bucket() |> ExAws.S3.put_bucket(region()) |> request()
    end
  end

  @doc """
  A link to download `key` valid for #{@link_seconds} seconds (or
  `expires_in`), naming the file `file_name` for the browser; `inline:
  true` lets the browser show it (images, PDF) instead of saving it;
  `content_type` is forced on the response (the type the app validated,
  whatever was stored).
  """
  @spec link(String.t(), String.t(), keyword()) :: String.t()
  def link(key, file_name, opts \\ []) do
    disposition = if opts[:inline], do: "inline", else: "attachment"

    {:ok, url} =
      ExAws.Config.new(:s3, public_config())
      |> ExAws.S3.presigned_url(:get, bucket(), key,
        expires_in: opts[:expires_in] || @link_seconds,
        virtual_host: false,
        query_params:
          [
            {"response-content-disposition",
             "#{disposition}; filename*=UTF-8''#{URI.encode(file_name, &URI.char_unreserved?/1)}"}
          ] ++
            if(opts[:content_type],
              do: [{"response-content-type", opts[:content_type]}],
              else: []
            )
      )

    url
  end

  defp request(operation) do
    case ExAws.request(operation, internal_config()) do
      {:ok, _} -> :ok
      {:error, {:http_error, 404, _}} when operation.http_method == :delete -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp internal_config, do: endpoint_config(setting(:endpoint))
  defp public_config, do: endpoint_config(setting(:public_url))

  defp endpoint_config(url) do
    uri = URI.parse(url)

    [
      access_key_id: setting(:access_key),
      secret_access_key: setting(:secret_key),
      region: region(),
      scheme: "#{uri.scheme}://",
      host: uri.host,
      port: uri.port
    ] ++ Application.get_env(:app, :storage_request_options, [])
  end

  defp bucket, do: setting(:bucket)
  defp region, do: setting(:region) || "us-east-1"
  defp setting(key), do: Application.fetch_env!(:app, :storage)[key]
end
