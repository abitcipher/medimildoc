defmodule App.Rules.Engine do
  @moduledoc """
  The FSDC rules engine (docs/design/data-consistency.md): GoRules ZEN
  evaluating JSON Decision Model graphs, in-process as a NIF
  (`native/rules`). Graphs are the JSON the JDM Editor produces; the same
  graphs run in the browser through ZEN's WebAssembly build.

  In dev and test Rustler builds the crate (release mode, cached in
  `_build`); the production image loads a library built in its own
  Dockerfile stage (`RULES_NIF_PREBUILT=1`).
  """
  use Rustler,
    otp_app: :app,
    crate: "rules",
    mode: :release,
    skip_compilation?: System.get_env("RULES_NIF_PREBUILT") == "1"

  @doc """
  Evaluates `graph` (a JDM map) with `context` (a map). `{:ok, result}` with
  the output node's value (and `%{"trace" => …}` merged in when
  `trace: true`), or `{:error, reason}`.
  """
  @spec evaluate(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def evaluate(graph, context, opts \\ []) do
    trace? = Keyword.get(opts, :trace, false)

    case nif_evaluate(Jason.encode!(graph), Jason.encode!(context), trace?) do
      {:ok, json} ->
        response = Jason.decode!(json)

        {:ok,
         if(trace?,
           do: Map.put(response["result"] || %{}, "trace", response["trace"]),
           else: response["result"] || %{}
         )}

      {:error, json} ->
        {:error, decode_error(json)}
    end
  end

  @doc """
  A traced evaluation for the editor's simulation view: `{:ok, %{"result",
  "trace", "performance"}}` as the engine returns them (the trace is keyed
  by node id), or `{:error, reason}`.
  """
  @spec simulate(map(), map()) :: {:ok, map()} | {:error, term()}
  def simulate(graph, context) do
    case nif_evaluate(Jason.encode!(graph), Jason.encode!(context), true) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, json} -> {:error, decode_error(json)}
    end
  end

  @doc "Whether `graph` is a well-formed decision graph."
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(graph) do
    case nif_validate(Jason.encode!(graph)) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp decode_error(json) do
    case Jason.decode(json) do
      {:ok, map} -> map
      _ -> json
    end
  end

  # NIF stubs, replaced when the library loads.
  defp nif_evaluate(_graph, _context, _trace), do: :erlang.nif_error(:nif_not_loaded)
  defp nif_validate(_graph), do: :erlang.nif_error(:nif_not_loaded)
end
