defmodule App.StorageStub do
  @moduledoc """
  In-memory stand-in for RustFS in tests (config/test.exs): an `ex_aws`
  HTTP client that understands the S3 calls `App.Storage` makes — bucket
  check/create, multipart upload, delete. Objects live in a public ETS
  table, keyed by object key, so tests can check what was stored or
  deleted (`object/1`).
  """
  @behaviour ExAws.Request.HttpClient

  @table __MODULE__

  @doc "The stored bytes of `key`, or nil."
  def object(key) do
    ensure_table()

    case :ets.lookup(@table, {:object, key}) do
      [{_, bytes}] -> bytes
      [] -> nil
    end
  end

  @impl true
  def request(method, url, body, _headers, _opts) do
    ensure_table()
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    key = uri.path |> String.split("/", parts: 3) |> Enum.at(2)
    handle(method, key, query, body)
  end

  defp handle(:head, nil, _query, _body), do: ok("")
  defp handle(:put, nil, _query, _body), do: ok("")

  defp handle(:post, key, %{"uploads" => _}, _body) do
    upload_id = "up-" <> Integer.to_string(System.unique_integer([:positive]))
    :ets.insert(@table, {{:upload, upload_id}, key, []})

    ok(
      "<InitiateMultipartUploadResult><UploadId>#{upload_id}</UploadId></InitiateMultipartUploadResult>"
    )
  end

  defp handle(:put, _key, %{"partNumber" => n, "uploadId" => id}, body) do
    [{_, key, parts}] = :ets.lookup(@table, {:upload, id})
    :ets.insert(@table, {{:upload, id}, key, [{String.to_integer(n), body} | parts]})
    {:ok, %{status_code: 200, headers: [{"ETag", ~s("etag-#{n}")}], body: ""}}
  end

  defp handle(:post, key, %{"uploadId" => id}, _body) do
    [{_, ^key, parts}] = :ets.lookup(@table, {:upload, id})
    bytes = parts |> Enum.sort() |> Enum.map_join(&elem(&1, 1))
    :ets.insert(@table, {{:object, key}, bytes})
    :ets.delete(@table, {:upload, id})

    ok(
      "<CompleteMultipartUploadResult><Location>x</Location><Bucket>b</Bucket>" <>
        "<Key>#{key}</Key><ETag>e</ETag></CompleteMultipartUploadResult>"
    )
  end

  defp handle(:delete, key, _query, _body) do
    :ets.delete(@table, {:object, key})
    {:ok, %{status_code: 204, headers: [], body: ""}}
  end

  defp ok(body), do: {:ok, %{status_code: 200, headers: [], body: body}}

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      # Owned by a long-lived process, so it outlives the test that created it.
      spawn(fn ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
          Process.sleep(:infinity)
        rescue
          ArgumentError -> :ok
        end
      end)

      wait_for_table()
    end
  end

  defp wait_for_table do
    if :ets.whereis(@table) == :undefined do
      Process.sleep(1)
      wait_for_table()
    end
  end
end
