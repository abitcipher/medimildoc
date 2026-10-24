defmodule App.TypedId do
  @moduledoc """
  Formats/parses "typed" UUIDv7 references — a short
  resource-type prefix glued onto the real `uuid_v7_primary_key`, e.g.
  `"person_01a08cd8-c353-75e2-a1c3-e8d3b73e07ba"`. Same idea as Stripe/
  Shopify-style prefixed IDs: makes a bare UUID self-describing in logs,
  error messages, and (eventually) any external-facing API, without
  changing what's actually stored — every DB column/FK stays a plain
  native `:uuid`, this is a **display/reference format only**, computed
  on the way out and parsed back on the way in, never persisted as its
  own column. That's also why this isn't the "2⁷⁴/~18 sextillion"
  identifier from in any special sense — it's just
  the resource's ordinary UUIDv7 with a label on it; the entropy is
  whatever `Ash.UUIDv7.generate/0` already gives every resource in this
  domain.

  Every resource gets a prefix here, not just `Person` — "typed
  structures that serve as reference points for entity searches"
  reads as a general convention, not a `Person`-only concern.
  """

  @prefixes %{
    App.People.Person => "person",
    App.People.Organization => "org",
    App.People.Position => "pos",
    App.People.Assignment => "asgn",
    App.People.PersonRecord => "prec",
    App.People.PersonIdentifier => "pid",
    App.People.IdentityDocument => "doc",
    App.People.BiometricRecord => "bio",
    App.Audit.ChangeConflict => "conflict",
    App.Accounts.User => "user"
  }

  @doc "The known resource modules and their prefixes."
  @spec prefixes() :: %{module() => String.t()}
  def prefixes, do: @prefixes

  @doc """
  `"<prefix>_<uuid>"` for `resource`'s `uuid`. Raises `ArgumentError`
  for a resource with no registered prefix — a missing entry here is a
  bug to fix (add the resource to `@prefixes`), not a runtime
  condition to handle gracefully.
  """
  @spec format(module(), String.t() | nil) :: String.t()
  def format(resource, uuid) when is_binary(uuid) do
    case Map.fetch(@prefixes, resource) do
      {:ok, prefix} -> "#{prefix}_#{uuid}"
      :error -> raise ArgumentError, "no App.TypedId prefix registered for #{inspect(resource)}"
    end
  end

  @doc """
  The inverse of `format/2` — `{:ok, resource, uuid}` if `typed_id` is
  `"<known prefix>_<well-formed uuid>"`, `{:error, :unknown_prefix}` or
  `{:error, :invalid_uuid}` otherwise. Never raises — this is the
  direction untrusted input (a pasted reference, a URL param) comes in
  from, unlike `format/2`.
  """
  @spec parse(String.t()) ::
          {:ok, module(), String.t()} | {:error, :unknown_prefix | :invalid_uuid}
  def parse(typed_id) when is_binary(typed_id) do
    with [prefix, uuid] <- String.split(typed_id, "_", parts: 2),
         {:ok, resource} <- resource_for_prefix(prefix),
         true <- valid_uuid?(uuid) do
      {:ok, resource, uuid}
    else
      {:error, :unknown_prefix} -> {:error, :unknown_prefix}
      false -> {:error, :invalid_uuid}
      _ -> {:error, :unknown_prefix}
    end
  end

  defp resource_for_prefix(prefix) do
    case Enum.find(@prefixes, fn {_resource, p} -> p == prefix end) do
      {resource, _prefix} -> {:ok, resource}
      nil -> {:error, :unknown_prefix}
    end
  end

  # Ash.UUIDv7 values are canonical 36-char hyphenated UUID strings —
  # cheap shape check, not a full RFC 9562 validation (Ash/Ecto's own
  # :uuid type does that when this is actually used to query).
  defp valid_uuid?(uuid) do
    String.match?(
      uuid,
      ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
    )
  end
end
