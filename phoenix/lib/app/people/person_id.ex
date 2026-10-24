defmodule App.People.PersonId do
  @moduledoc """
  The short, human-memorable identifier a `Person` can use to identify
  themselves. **Secondary to `Person.id` 
  (`uuid_v7_primary_key`), not a replacement for it**: every real
  operation/reference/foreign key in this system uses the UUIDv7: this
  code exists only so a human can *say*/*type*/*remember* something
  shorter than a UUID, for two purposes — self-identification (a future
  login path, not built yet) and narrowing a search
  before landing on the exact `Person` by UUID.

  ## Shape

  12 characters, alternating consonant/vowel (or vowel/consonant — the
  starting parity is random), no letter used more than twice. Displayed
  grouped 4-4-4 (`format/1`) but stored as one unbroken string — the
  grouping is a UI nicety, not part of the identity.

  ## Keyspace and collisions — read this before changing the shape

  The exact keyspace is **1,332,964,836,000 (~2^40.3)**, computed
  exactly (not estimated) in the session that added this — see
  for the full derivation and the collision-rate
  discussion. This is deliberately NOT sized for "one flat space safe
  for the entire population of the planet" — per the user's own
  clarification (amendment), it only has to comfortably
  cover this deployment's *live* population (deceased/archived records
  move out of the active pool, per the user's own note) and it is
  explicitly **not** the uniqueness guarantee — `Person.id` is. A
  collision here is a "needs disambiguation" case (two different living
  people who'd generate the same code), not a data-integrity failure —
  `identities do identity :unique_person_id, [:person_id] end` on
  `App.People.Person` is the actual backstop; `generate_unique/0` below
  just makes hitting it in practice rare rather than routine.

  ## Why generation stays in Elixir, not Rust

  The Python sketch this was ported from suggested Rust/PL-pgSQL "for
  optimal performance" — deliberately not done: this runs once per
  `Person` creation (bounded by real HR volume, nowhere near a hot
  path), and the rejection-sampling algorithm below is O(1) amortized
  per character. There's no throughput case here that would justify a
  NIF; revisit only if a real profiling number says otherwise.
  """

  @vowels ~c"AEIOU"
  @consonants ~c"BCDFGHJKLMNPQRSTVWXYZ"
  @length 12
  @max_repeats 2

  @doc """
  Generates one candidate code. Not guaranteed unique by itself — see
  `generate_unique/0` for the check-and-retry loop
  `App.People.Person.person_id`'s `default` actually uses.
  """
  @spec generate() :: String.t()
  def generate do
    starts_with_vowel? = Enum.random([true, false])

    {chars, _counts} =
      Enum.reduce(1..@length, {[], %{}}, fn i, {acc, counts} ->
        odd_position? = rem(i, 2) == 1
        is_vowel? = odd_position? == starts_with_vowel?
        pool = if is_vowel?, do: @vowels, else: @consonants
        available = Enum.reject(pool, &(Map.get(counts, &1, 0) >= @max_repeats))
        char = Enum.random(available)
        {[char | acc], Map.update(counts, char, 1, &(&1 + 1))}
      end)

    chars |> Enum.reverse() |> List.to_string()
  end

  @max_generation_attempts 20

  @doc """
  Generates a code and checks it against the DB, retrying on collision
  (bounded — see moduledoc for why a real collision here is expected to
  be exceedingly rare, not why the bound is needed for correctness: the
  bound exists so a pathological run can't loop forever, not because
  retries are expected to happen in practice). This is what
  `App.People.Person.person_id`'s attribute `default` calls — it's an
  Ash attribute default, so it runs during changeset construction (same
  timing as `Ash.UUIDv7.generate/0` for every `uuid_v7_primary_key` in
  this domain), before `allow_nil?` validation, and can safely do a DB
  read (defaults aren't restricted to pure computation in Ash).

  Raises after `#{@max_generation_attempts}` failed attempts — at that
  point either the keyspace is genuinely near saturation or something
  else is wrong, and silently accepting an unchecked value would be
  worse than a loud failure.
  """
  @spec generate_unique() :: String.t()
  def generate_unique(attempt \\ 1)

  def generate_unique(attempt) when attempt > @max_generation_attempts do
    raise "App.People.PersonId: could not generate a unique person_id after " <>
            "#{@max_generation_attempts} attempts"
  end

  def generate_unique(attempt) do
    candidate = generate()

    if taken?(candidate) do
      generate_unique(attempt + 1)
    else
      candidate
    end
  end

  defp taken?(candidate) do
    require Ash.Query

    App.People.Person
    |> Ash.Query.filter(person_id == ^candidate)
    |> Ash.exists(authorize?: false)
    |> case do
      {:ok, exists?} -> exists?
      # Can't confirm either way — treat as taken so we regenerate
      # rather than risk skipping the check on a candidate that turns
      # out to actually collide.
      _ -> true
    end
  end

  @doc "Groups a bare 12-character code into `AAAA-BBBB-CCCC` for display. Round-trips with `unformat/1`."
  @spec format(String.t()) :: String.t()
  def format(code) when byte_size(code) == @length do
    code
    |> String.to_charlist()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &List.to_string/1)
  end

  @doc "Strips grouping punctuation/whitespace and upcases — the inverse of `format/1`, tolerant of however a human typed it back in."
  @spec unformat(String.t()) :: String.t()
  def unformat(input) do
    input
    |> String.upcase()
    |> String.replace(~r/[^A-Z]/, "")
  end

  @doc """
  Whether `code` (bare, unformatted) actually conforms to the shape
  rules above — length, alternating consonant/vowel, no letter more
  than twice. Used to validate a person-typed code (e.g. a future
  login/search box) before ever querying the DB with it.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(code) when is_binary(code) do
    chars = String.to_charlist(code)

    length(chars) == @length and
      Enum.all?(chars, &(&1 in @vowels or &1 in @consonants)) and
      alternates?(chars) and
      within_repeat_limit?(chars)
  end

  def valid?(_), do: false

  defp alternates?(chars) do
    kinds = Enum.map(chars, &(&1 in @vowels))
    Enum.chunk_every(kinds, 2, 1, :discard) |> Enum.all?(fn [a, b] -> a != b end)
  end

  defp within_repeat_limit?(chars) do
    chars
    |> Enum.frequencies()
    |> Enum.all?(fn {_char, count} -> count <= @max_repeats end)
  end

  @doc """
  The `did:<method>:person:<code>` URI form (DID/SSI mention)
  — `<method>` is this deployment's own, not a hardcoded
  government/country (the example the user gave, `did:gov:ua:person:
  ...`, is one possible deployment's choice, not this library's), set
  via `config :app, :did_method`. This is a URI *string* only — no DID
  Document, resolver, or verifiable-credential machinery is implemented
  (explicitly scopes that out).
  """
  @spec to_did(String.t()) :: String.t()
  def to_did(code) when byte_size(code) == @length do
    "did:#{did_method()}:person:#{code}"
  end

  @doc "The inverse of `to_did/1` — `nil` if `uri` isn't `did:<method>:person:<12-char code>` for this deployment's configured method."
  @spec from_did(String.t()) :: String.t() | nil
  def from_did(uri) when is_binary(uri) do
    prefix = "did:#{did_method()}:person:"

    case String.split(uri, prefix, parts: 2) do
      ["", code] when byte_size(code) == @length -> code
      _ -> nil
    end
  end

  def from_did(_), do: nil

  defp did_method, do: Application.get_env(:app, :did_method, "example")
end
