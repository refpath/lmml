defmodule Lmml.Manifest do
  @moduledoc """
  The `manifest.json` metadata of an `Lmml.Bundle`: a versioned JSON
  object that binds every embed the narrative mentions to a content
  digest, so a reader can verify that what it resolved is what the author
  packed.

  ## Where the manifest lives

  `manifest.json` is not a distinct front-matter mechanism -- it is an
  embed literally named `"manifest.json"`, exactly like any other embed:
  `@@@manifest.json ... @@@` inline, or `@manifest.json` referencing a
  zip entry inside a `.lmmlz`. An archive may also carry a `manifest.json`
  entry that the narrative never mentions; `load/1` finds it there too,
  so a manifest can be attached to an archive without editing the prose.
  A bundle with no manifest at all is a normal, fully-supported state
  (`load/1` returns `{:ok, nil}`), not something to special-case at every
  call site.

  ## Schema (version `1`)

  | key | required | meaning |
  |---|---|---|
  | `lmml_version` | yes | the manifest schema major version, `"1"` |
  | `entries` | yes | object keyed by embed name; each value has `sha256` (64 lowercase hex chars), `size` (bytes) and optionally `media_type` and `trust` (`"trusted"` or `"untrusted"`) |
  | `extensions` | no | object keyed by reverse-DNS namespace; values are opaque objects other tools may read and must preserve |

  Any other top-level key is application metadata: `load/1` preserves it
  and `verify/2` ignores it. `entries` never lists `manifest.json`
  itself. A manifest with no `lmml_version` is *legacy metadata*: it
  loads, but `verify/2` reports it as unversioned and checks nothing. A
  manifest whose major version this library does not know is refused by
  `load/1` (`{:unsupported_version, v}`) so an older reader never
  silently misinterprets a newer document.

  ## Digests

  `digest/1` is the SHA-256 of the manifest's *canonical* encoding
  (`Lmml.Canonical`), not of whatever bytes happened to be stored: two
  manifests with the same members have the same digest however they were
  formatted. Binding that digest into a signature or a log entry commits
  to every entry digest and therefore to every embed's content.
  """

  alias Lmml.Bundle
  alias Lmml.Canonical
  alias Lmml.Digest
  alias Lmml.Embed
  alias Lmml.Narrative.Renderer

  @manifest_name "manifest.json"
  @version "1"
  @supported_versions [@version]
  @trust_values ["trusted", "untrusted"]

  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: map()}

  @typedoc "One issue found by `verify/2`."
  @type issue ::
          :no_manifest
          | :unversioned_manifest
          | {:malformed_entries, term()}
          | {:malformed_entry, String.t()}
          | {:missing_entry, String.t()}
          | {:unknown_entry, String.t()}
          | {:digest_mismatch, String.t()}
          | {:size_mismatch, String.t()}
          | {:unknown_trust, String.t()}
          | {:unresolvable_embed, String.t()}
          | {:malformed_extensions, term()}

  @doc "The reserved embed name a bundle's manifest is looked up by, if present."
  @spec name() :: String.t()
  def name, do: @manifest_name

  @doc "The manifest schema version this library writes."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The manifest schema versions this library can read."
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @doc "The values `trust` may take on an entry."
  @spec trust_values() :: [String.t()]
  def trust_values, do: @trust_values

  # ---------------------------------------------------------------------
  # Loading
  # ---------------------------------------------------------------------

  @doc """
  Loads and decodes `bundle`'s `manifest.json`, if any.

  Returns:
    - `{:ok, %Lmml.Manifest{}}` -- a `manifest.json` embed or archive
      entry exists and decodes to a JSON object of a supported version
      (or carries no version at all).
    - `{:ok, nil}` -- no `manifest.json` is mentioned or carried anywhere.
      This is the common case for a manifest-less bundle, not an error.
    - `{:error, reason}` -- a `manifest.json` embed *is* mentioned but its
      content is unresolvable (see `Lmml.Bundle.embed/2`), is not a JSON
      object (`{:invalid_manifest, reason}`), or declares a version this
      library cannot read (`{:unsupported_version, version}`).
  """
  @spec load(Bundle.t()) :: {:ok, t() | nil} | {:error, term()}
  def load(%Bundle{} = bundle) do
    case fetch_content(bundle) do
      :none -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      {:ok, content} -> decode(content)
    end
  end

  @doc "Same as `load/1`, but raises on failure. A manifest-less bundle still returns `nil`, not an exception."
  @spec load!(Bundle.t()) :: t() | nil
  def load!(bundle) do
    case load(bundle) do
      {:ok, manifest} -> manifest
      {:error, reason} -> raise "Failed to load lmml manifest: #{inspect(reason)}"
    end
  end

  defp fetch_content(%Bundle{entries: entries} = bundle) do
    case Bundle.embed(bundle, @manifest_name) do
      {:error, :not_found} ->
        case Map.fetch(entries, @manifest_name) do
          {:ok, content} -> {:ok, content}
          :error -> :none
        end

      other ->
        other
    end
  end

  @doc "Fetches a top-level key from the manifest's decoded data, or `nil` if absent."
  @spec get(t(), String.t()) :: term() | nil
  def get(%__MODULE__{data: data}, key) when is_binary(key), do: Map.get(data, key)

  @doc """
  Fetches a top-level key from the manifest's decoded data, distinguishing a
  missing key (`:error`) from one whose value is explicitly `null`
  (`{:ok, nil}`). `get/2` cannot tell these apart; `fetch/2` can.
  """
  @spec fetch(t(), String.t()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{data: data}, key) when is_binary(key), do: Map.fetch(data, key)

  @doc "The manifest's declared schema version, or `nil` for a legacy manifest without one."
  @spec declared_version(t()) :: String.t() | nil
  def declared_version(%__MODULE__{data: data}) do
    case Map.get(data, "lmml_version") do
      version when is_binary(version) -> version
      _ -> nil
    end
  end

  @doc "The `entries` object, or an empty map for a legacy manifest."
  @spec entries(t()) :: %{optional(String.t()) => map()}
  def entries(%__MODULE__{data: data}) do
    case Map.get(data, "entries") do
      entries when is_map(entries) -> entries
      _ -> %{}
    end
  end

  @doc "The `extensions` object, or an empty map when there are none."
  @spec extensions(t()) :: %{optional(String.t()) => map()}
  def extensions(%__MODULE__{data: data}) do
    case Map.get(data, "extensions") do
      extensions when is_map(extensions) -> extensions
      _ -> %{}
    end
  end

  defp decode(content) do
    with {:ok, data} <- decode_object(content),
         :ok <- check_version(data) do
      {:ok, %__MODULE__{data: data}}
    end
  end

  defp decode_object(content) do
    case Canonical.decode(content) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, other} -> {:error, {:invalid_manifest, {:not_an_object, other}}}
      {:error, {:invalid_json, reason}} -> {:error, {:invalid_manifest, reason}}
    end
  end

  # A manifest without a version is legacy metadata and loads as-is; one
  # with a version this library does not know is refused rather than
  # misread.
  defp check_version(data) do
    case Map.fetch(data, "lmml_version") do
      :error -> :ok
      {:ok, version} when version in @supported_versions -> :ok
      {:ok, version} -> {:error, {:unsupported_version, version}}
    end
  end

  # ---------------------------------------------------------------------
  # Building
  # ---------------------------------------------------------------------

  @doc """
  Builds a version-`#{@version}` manifest for `bundle`, binding every embed
  the narrative mentions (each distinct name once) to its resolved
  content's digest, size and inferred media type. Fails with
  `{:error, {:unresolvable_embed, name}}` when an embed cannot be
  resolved, since an entry with no bytes has no digest.

  Options:

    - `:data` -- a map of additional top-level members to carry (session
      ids, model names, an `extensions` object). It cannot
      override `lmml_version` or `entries`; an attempt is an
      `{:error, {:reserved_key, key}}`.
    - `:trust` -- a map of embed name to `"trusted"` / `"untrusted"`,
      recorded on the matching entries. An unknown value is
      `{:error, {:unknown_trust, name}}`.

  `manifest.json` itself is never listed among the entries.
  """
  @spec build(Bundle.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(%Bundle{} = bundle, opts \\ []) do
    data = Keyword.get(opts, :data, %{})
    trust = Keyword.get(opts, :trust, %{})

    with :ok <- reserved_keys(data),
         :ok <- valid_trust(trust),
         {:ok, entries} <- build_entries(bundle, trust) do
      {:ok,
       %__MODULE__{data: Map.merge(data, %{"lmml_version" => @version, "entries" => entries})}}
    end
  end

  defp reserved_keys(data) when is_map(data) do
    case Enum.find(["lmml_version", "entries"], &Map.has_key?(data, &1)) do
      nil -> :ok
      key -> {:error, {:reserved_key, key}}
    end
  end

  defp valid_trust(trust) when is_map(trust) do
    case Enum.find(trust, fn {_name, value} -> value not in @trust_values end) do
      nil -> :ok
      {name, _value} -> {:error, {:unknown_trust, name}}
    end
  end

  defp build_entries(bundle, trust) do
    bundle
    |> Bundle.embeds()
    |> Enum.uniq_by(& &1.name)
    |> Enum.reject(&(&1.name == @manifest_name))
    |> Enum.reduce_while({:ok, %{}}, fn %Embed{name: name}, {:ok, acc} ->
      case Bundle.embed(bundle, name) do
        {:ok, content} -> {:cont, {:ok, Map.put(acc, name, entry(name, content, trust))}}
        {:error, _reason} -> {:halt, {:error, {:unresolvable_embed, name}}}
      end
    end)
  end

  defp entry(name, content, trust) do
    base = %{
      "sha256" => Digest.sha256(content),
      "size" => byte_size(content),
      "media_type" => Renderer.mime_type(name)
    }

    case Map.fetch(trust, name) do
      {:ok, value} -> Map.put(base, "trust", value)
      :error -> base
    end
  end

  # ---------------------------------------------------------------------
  # Encoding, digests and attaching
  # ---------------------------------------------------------------------

  @doc "The manifest as canonical JSON (see `Lmml.Canonical`)."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{data: data}), do: Canonical.encode(data)

  @doc "The SHA-256 of the manifest's canonical encoding, as lowercase hex."
  @spec digest(t()) :: {:ok, Digest.t()} | {:error, term()}
  def digest(%__MODULE__{} = manifest) do
    with {:ok, binary} <- encode(manifest), do: {:ok, Digest.sha256(binary)}
  end

  @doc """
  Returns `bundle` carrying `manifest` as its `manifest.json`, encoded
  canonically. A `:zip` bundle gets (or replaces) a `manifest.json`
  archive entry, leaving the narrative untouched; a `:text` bundle has
  nowhere else to put it, so an inline `@@@manifest.json ... @@@` block
  is appended to the narrative (replacing any existing inline manifest).
  """
  @spec attach(Bundle.t(), t()) :: {:ok, Bundle.t()} | {:error, term()}
  def attach(%Bundle{} = bundle, %__MODULE__{} = manifest) do
    with {:ok, binary} <- encode(manifest) do
      attach_encoded(bundle, binary)
    end
  end

  defp attach_encoded(%Bundle{kind: :zip} = bundle, binary) do
    Bundle.new_zip(
      Bundle.name(bundle),
      Bundle.narrative(bundle),
      Map.put(bundle.entries, @manifest_name, binary)
    )
  end

  defp attach_encoded(%Bundle{kind: :text} = bundle, binary) do
    narrative = strip_inline_manifest(bundle)
    block = "@@@" <> @manifest_name <> "\n" <> binary <> "\n@@@"

    Bundle.new_text(Bundle.name(bundle), narrative <> "\n\n" <> block)
  end

  defp strip_inline_manifest(bundle) do
    narrative = Bundle.narrative(bundle)

    bundle
    |> Bundle.embeds()
    |> Enum.filter(&(&1.name == @manifest_name and Embed.inline?(&1)))
    |> Enum.reduce(narrative, fn %Embed{content: {:inline, content}}, text ->
      fence = "@@@" <> @manifest_name <> "\n" <> content <> "@@@"
      text |> String.replace(fence, "") |> String.trim_trailing()
    end)
  end

  # ---------------------------------------------------------------------
  # Verification
  # ---------------------------------------------------------------------

  @doc """
  Verifies `bundle` against its own manifest: every embed the narrative
  mentions must have an entry whose digest and size match the resolved
  content, every entry must correspond to an embed or archive entry that
  exists, and every declared `trust` and `extensions` member must be
  well-formed. Every issue found is reported at once.

  Returns `:ok`, or `{:error, issues}` where `issues` is a non-empty list
  of `t:issue/0`. A bundle with no manifest is `{:error, [:no_manifest]}`
  and a legacy manifest without `lmml_version` is
  `{:error, [:unversioned_manifest]}` -- neither has anything a reader can
  verify against, and silently passing them would defeat the point.

  Verification reads only the bundle: it never dereferences a URI or
  touches the filesystem.
  """
  @spec verify(Bundle.t()) :: :ok | {:error, [issue(), ...]}
  def verify(%Bundle{} = bundle) do
    case load(bundle) do
      {:ok, nil} -> {:error, [:no_manifest]}
      {:error, reason} -> {:error, [{:invalid_manifest, reason}]}
      {:ok, %__MODULE__{} = manifest} -> verify(bundle, manifest)
    end
  end

  @doc "Same as `verify/1`, but against an explicitly supplied manifest instead of the bundle's own."
  @spec verify(Bundle.t(), t()) :: :ok | {:error, [issue(), ...]}
  def verify(%Bundle{} = bundle, %__MODULE__{} = manifest) do
    case declared_version(manifest) do
      nil ->
        {:error, [:unversioned_manifest]}

      _version ->
        issues = entries_issues(bundle, manifest) ++ extensions_issues(manifest)

        if issues == [], do: :ok, else: {:error, issues}
    end
  end

  defp entries_issues(bundle, %__MODULE__{data: data}) do
    case Map.get(data, "entries") do
      entries when is_map(entries) ->
        mentioned = mentioned_names(bundle)
        carried = MapSet.new(Bundle.entries(bundle))

        missing =
          mentioned
          |> Enum.reject(&Map.has_key?(entries, &1))
          |> Enum.map(&{:missing_entry, &1})

        per_entry =
          entries
          |> Enum.sort_by(fn {name, _} -> name end)
          |> Enum.flat_map(fn {name, entry} ->
            entry_issues(bundle, name, entry, mentioned, carried)
          end)

        missing ++ per_entry

      other ->
        [{:malformed_entries, other}]
    end
  end

  defp mentioned_names(bundle) do
    bundle
    |> Bundle.embeds()
    |> Enum.map(& &1.name)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == @manifest_name))
  end

  defp entry_issues(bundle, name, entry, mentioned, carried) do
    cond do
      name == @manifest_name ->
        [{:unknown_entry, name}]

      not well_formed_entry?(entry) ->
        [{:malformed_entry, name}]

      name not in mentioned and not MapSet.member?(carried, name) ->
        [{:unknown_entry, name}]

      true ->
        content_issues(bundle, name, entry) ++ trust_issues(name, entry)
    end
  end

  defp well_formed_entry?(%{"sha256" => sha, "size" => size})
       when is_integer(size) and size >= 0 do
    Digest.valid?(sha)
  end

  defp well_formed_entry?(_other), do: false

  defp content_issues(bundle, name, %{"sha256" => sha, "size" => size}) do
    case resolve(bundle, name) do
      {:ok, content} ->
        digest_issue(name, content, sha) ++ size_issue(name, content, size)

      :error ->
        [{:unresolvable_embed, name}]
    end
  end

  # An entry may name an embed the narrative mentions (resolved through the
  # bundle) or an archive entry it does not (read directly).
  defp resolve(%Bundle{entries: entries} = bundle, name) do
    case Bundle.embed(bundle, name) do
      {:ok, content} ->
        {:ok, content}

      {:error, _} ->
        case Map.fetch(entries, name) do
          {:ok, content} -> {:ok, content}
          :error -> :error
        end
    end
  end

  defp digest_issue(name, content, sha) do
    case Digest.verify(content, sha) do
      :ok -> []
      {:error, _} -> [{:digest_mismatch, name}]
    end
  end

  defp size_issue(name, content, size) do
    if byte_size(content) == size, do: [], else: [{:size_mismatch, name}]
  end

  defp trust_issues(name, entry) do
    case Map.fetch(entry, "trust") do
      :error -> []
      {:ok, value} when value in @trust_values -> []
      {:ok, _other} -> [{:unknown_trust, name}]
    end
  end

  defp extensions_issues(%__MODULE__{data: data}) do
    case Map.fetch(data, "extensions") do
      :error -> []
      {:ok, extensions} when is_map(extensions) -> namespace_issues(extensions)
      {:ok, other} -> [{:malformed_extensions, other}]
    end
  end

  defp namespace_issues(extensions) do
    if Enum.all?(extensions, fn {ns, value} -> is_binary(ns) and is_map(value) end),
      do: [],
      else: [{:malformed_extensions, extensions}]
  end
end
