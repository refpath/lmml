defmodule Lmml.Bundle do
  @moduledoc """
  A loaded `lmml` entity, regardless of which of the two on-disk forms it
  came from:

    - `.lmml` -- a bare, self-contained Markdown-superset text file. There
      is nowhere for an external reference to point to, so every embed it
      mentions must be inline.
    - `.lmmlz` -- a zip archive whose canonical narrative entry is named
      by stripping the trailing `z` from the archive's own filename
      (`foo.lmmlz` contains `foo.lmml`), plus whatever other entries its
      `@name.ext` references point at.

  `open/2` detects which form a file is by sniffing its content (the zip
  local-file-header magic bytes), not by trusting its extension, and
  either way returns a `Bundle` exposing the exact same API: `narrative/1`,
  `embeds/1`, `embed/2`, `entries/1`. `load/3` does the same for bytes
  already in memory, which is how a host that receives an archive over
  the network (rather than from its own disk) opens it.

  ## Opening untrusted archives

  A zip archive is untrusted input. Before any entry is inflated, `load/3`
  reads the archive's central directory and rejects it when:

    - an entry name could escape the bundle root or is ambiguous -- see
      `validate_entry_names/1`;
    - two entries would collide once names are Unicode-normalized and
      case-folded (`{:duplicate_entry, name}`);
    - an entry is not a regular file -- a directory, symlink or device
      entry (`{:non_regular_entry, name}`);
    - the declared sizes, entry count, name lengths or compression ratios
      exceed the `Lmml.Archive.Policy` in effect (`:policy` option,
      default `Lmml.Archive.Policy.default/0`).

  After inflation every entry's actual byte size must match what the
  directory declared (`{:size_mismatch, name}`), so a header that lies
  about its size cannot slip past the policy.

  Nothing in this module ever dereferences a URI or reads a file other
  than the one path handed to `open/2`: an external reference resolves
  against the archive's own entries or not at all.
  """

  alias Lmml.Archive.Policy
  alias Lmml.Document
  alias Lmml.Embed

  require Record

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @enforce_keys [:kind, :name, :narrative, :document, :entries]
  defstruct [:kind, :name, :narrative, :document, :entries]

  @typedoc "Which on-disk form this bundle was loaded from (or is destined for)."
  @type kind :: :text | :zip

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t(),
          narrative: binary(),
          document: Document.t(),
          entries: %{optional(String.t()) => binary()}
        }

  @typedoc "Options accepted by `open/2` and `load/3`."
  @type load_opts :: [policy: Policy.t() | keyword()]

  # Local file header signature ("PK\x03\x04"), the byte sequence every
  # non-empty zip archive starts with. Sniffing this (rather than trusting
  # the `.lmml`/`.lmmlz` extension) is what lets `open/2` treat a
  # misnamed or extensionless file correctly, and is the same technique
  # `.docx`/`.epub`-style "zip wearing a different extension" formats rely on.
  @zip_magic <<0x50, 0x4B, 0x03, 0x04>>

  # Every archive `to_binary/2` produces carries this timestamp on every
  # entry (the earliest instant the zip format can represent), so the same
  # bundle always yields the same bytes and a digest over the archive is
  # meaningful. Real modification times belong in a manifest, not in
  # container metadata a reader cannot verify.
  @fixed_mtime {{1980, 1, 1}, {0, 0, 0}}

  # ---------------------------------------------------------------------
  # Opening from disk or memory
  # ---------------------------------------------------------------------

  @doc """
  Opens a `lmml` entity from disk, auto-detecting whether `path` is a bare
  text narrative or a zip archive by sniffing its content. Accepts the
  same `opts` as `load/3`.
  """
  @spec open(Path.t(), load_opts()) :: {:ok, t()} | {:error, term()}
  def open(path, opts \\ []) do
    with {:ok, content} <- File.read(path) do
      load(Path.basename(path), content, opts)
    end
  end

  @doc "Same as `open/2`, but raises on failure."
  @spec open!(Path.t(), load_opts()) :: t()
  def open!(path, opts \\ []) do
    case open(path, opts) do
      {:ok, bundle} -> bundle
      {:error, reason} -> raise "Failed to open lmml bundle at #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Loads a `lmml` entity from bytes already in memory. `name` plays the
  role `open/2` gives the file's basename: it is normalized to the
  logical narrative name (`convo.lmmlz` and `convo` both become
  `convo.lmml`) and, for an archive, names the entry that must hold the
  narrative.

  Options:

    - `:policy` -- an `Lmml.Archive.Policy` (or keyword overrides for
      `Lmml.Archive.Policy.new/1`) bounding what an archive may declare.
      Defaults to `Lmml.Archive.Policy.default/0`. Ignored for bare text.
  """
  @spec load(String.t(), binary(), load_opts()) :: {:ok, t()} | {:error, term()}
  def load(name, content, opts \\ []) when is_binary(name) and is_binary(content) do
    narrative_name = narrative_name_for(name)

    if zip_content?(content) do
      policy = opts |> Keyword.get(:policy, Policy.default()) |> Policy.new()
      open_zip(narrative_name, content, policy)
    else
      open_text(narrative_name, content)
    end
  end

  @spec zip_content?(binary()) :: boolean()
  defp zip_content?(content) when is_binary(content) do
    byte_size(content) >= byte_size(@zip_magic) and
      binary_part(content, 0, byte_size(@zip_magic)) == @zip_magic
  end

  defp open_text(name, content) do
    with {:ok, document} <- Document.parse(content) do
      {:ok,
       %__MODULE__{kind: :text, name: name, narrative: content, document: document, entries: %{}}}
    end
  end

  defp open_zip(name, content, policy) do
    with {:ok, table} <- read_table(content),
         :ok <- validate_table(table, policy),
         {:ok, raw_entries} <- unzip(content),
         :ok <- validate_sizes(raw_entries, table),
         {:ok, narrative} <- fetch_narrative(raw_entries, name),
         {:ok, document} <- Document.parse(narrative) do
      entries = Map.delete(raw_entries, name)

      {:ok,
       %__MODULE__{
         kind: :zip,
         name: name,
         narrative: narrative,
         document: document,
         entries: entries
       }}
    end
  end

  # Reads the archive's central directory into `{name, file_info,
  # compressed_size}` triples, keeping only real file entries (`:zip.table/1`
  # also yields a leading `{:zip_comment, ...}` tuple).
  defp read_table(content) do
    case :zip.table(content) do
      {:ok, table} ->
        {:ok,
         for {:zip_file, name, info, _comment, _offset, compressed_size} <- table do
           {to_string(name), info, compressed_size}
         end}

      {:error, reason} ->
        {:error, {:invalid_zip, reason}}
    end
  end

  # Every check here runs against the central directory alone, *before*
  # `:zip.unzip/2` inflates a single entry: name safety, duplicate and
  # non-regular entries, then the resource policy.
  defp validate_table(table, policy) do
    names = Enum.map(table, fn {name, _info, _csize} -> name end)

    with :ok <- validate_entry_names(names),
         :ok <- validate_regular(table) do
      Policy.check_table(policy, Enum.map(table, &table_entry/1))
    end
  end

  defp validate_regular(table) do
    case Enum.find(table, fn {_name, info, _csize} -> file_info(info, :type) != :regular end) do
      nil -> :ok
      {name, _info, _csize} -> {:error, {:non_regular_entry, name}}
    end
  end

  defp table_entry({name, info, compressed_size}) do
    %{name: name, size: file_info(info, :size), compressed_size: compressed_size}
  end

  defp unzip(content) do
    case :zip.unzip(content, [:memory]) do
      {:ok, files} ->
        {:ok, Map.new(files, fn {filename, data} -> {to_string(filename), data} end)}

      {:error, reason} ->
        {:error, {:invalid_zip, reason}}
    end
  end

  # The directory's declared sizes are what the policy was checked against;
  # an entry that inflates to a different size lied, and is rejected so a
  # forged header cannot smuggle more bytes past the limit than declared.
  defp validate_sizes(entries, table) do
    Enum.reduce_while(table, :ok, fn {name, info, _csize}, :ok ->
      case Map.fetch(entries, name) do
        {:ok, data} when byte_size(data) == file_info(info, :size) -> {:cont, :ok}
        _mismatch_or_missing -> {:halt, {:error, {:size_mismatch, name}}}
      end
    end)
  end

  defp fetch_narrative(entries, name) do
    case Map.fetch(entries, name) do
      {:ok, narrative} -> {:ok, narrative}
      :error -> {:error, {:missing_narrative_entry, name}}
    end
  end

  # ---------------------------------------------------------------------
  # Building in memory
  # ---------------------------------------------------------------------

  @doc """
  Builds a bare-text bundle directly from narrative text, without touching
  disk. `name` is normalized to always end in `.lmml` (the logical
  narrative name is the same regardless of file form).
  """
  @spec new_text(String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def new_text(name, narrative) when is_binary(name) and is_binary(narrative) do
    with {:ok, document} <- Document.parse(narrative) do
      {:ok,
       %__MODULE__{
         kind: :text,
         name: narrative_name_for(name),
         narrative: narrative,
         document: document,
         entries: %{}
       }}
    end
  end

  @doc """
  Builds a zip-backed bundle directly from narrative text plus a map of
  external entries (`%{"image.png" => <<bytes>>}`), without touching disk.
  Every entry name is validated the same way `load/3` validates entries
  read from a real archive (see `validate_entry_names/1`).
  """
  @spec new_zip(String.t(), binary(), %{optional(String.t()) => binary()}) ::
          {:ok, t()} | {:error, term()}
  def new_zip(name, narrative, entries \\ %{})
      when is_binary(name) and is_binary(narrative) and is_map(entries) do
    narrative_name = narrative_name_for(name)

    with :ok <- validate_entry_names([narrative_name | Map.keys(entries)]),
         {:ok, document} <- Document.parse(narrative) do
      {:ok,
       %__MODULE__{
         kind: :zip,
         name: narrative_name,
         narrative: narrative,
         document: document,
         entries: entries
       }}
    end
  end

  # ---------------------------------------------------------------------
  # Serializing and writing
  # ---------------------------------------------------------------------

  @doc """
  Serializes a `:zip` bundle into the bytes of an `.lmmlz` archive,
  without touching disk.

  The output is deterministic: entries are written in byte order of their
  names and every entry carries the same fixed timestamp, so serializing
  the same bundle twice yields identical bytes and a digest over the
  archive identifies its content. `name` overrides the narrative entry's
  name (normalized like `load/3`'s); it defaults to the bundle's own.

  Returns `{:error, :not_a_zip_bundle}` for a `:text` bundle -- a bare
  narrative's bytes are simply `narrative/1`.
  """
  @spec to_binary(t(), String.t() | nil) :: {:ok, binary()} | {:error, term()}
  def to_binary(bundle, name \\ nil)

  def to_binary(%__MODULE__{kind: :zip, narrative: narrative, entries: entries} = bundle, name) do
    narrative_name = narrative_name_for(name || bundle.name)

    file_entries =
      [{narrative_name, narrative} | Map.to_list(entries)]
      |> Enum.sort_by(fn {entry_name, _data} -> entry_name end)
      |> Enum.map(fn {entry_name, data} ->
        {String.to_charlist(entry_name), data, fixed_file_info(byte_size(data))}
      end)

    case :zip.create(String.to_charlist(narrative_name <> "z"), file_entries, [:memory]) do
      {:ok, {_name, binary}} -> {:ok, binary}
      {:error, reason} -> {:error, {:zip_create_failed, reason}}
    end
  end

  def to_binary(%__MODULE__{kind: :text}, _name), do: {:error, :not_a_zip_bundle}

  defp fixed_file_info(size) do
    file_info(
      size: size,
      type: :regular,
      access: :read_write,
      atime: @fixed_mtime,
      mtime: @fixed_mtime,
      ctime: @fixed_mtime,
      mode: 0o644,
      links: 1,
      major_device: 0,
      minor_device: 0,
      inode: 0,
      uid: 0,
      gid: 0
    )
  end

  @doc """
  Persists a bundle to disk in its *current* form (text stays text, zip
  stays zip) -- this does not convert between forms; see `Lmml.Pack` for
  that. For a `:zip` bundle, the internal narrative entry name is always
  freshly derived from `path`'s own basename (not from whatever name the
  bundle was constructed/opened with), so whatever you write is always
  internally self-consistent with its own filename, and the bytes are
  exactly what `to_binary/2` produces.
  """
  @spec write!(t(), Path.t()) :: :ok
  def write!(%__MODULE__{kind: :text, narrative: narrative}, path) do
    File.write!(path, narrative)
  end

  def write!(%__MODULE__{kind: :zip} = bundle, path) do
    case to_binary(bundle, Path.basename(path)) do
      {:ok, binary} -> File.write!(path, binary)
      {:error, reason} -> raise "Failed to write .lmmlz archive to #{path}: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------
  # Uniform accessors
  # ---------------------------------------------------------------------

  @doc "The bundle's own logical name (always ending in `.lmml`, regardless of bundle kind)."
  @spec name(t()) :: String.t()
  def name(%__MODULE__{name: name}), do: name

  @doc "The bundle's raw narrative text."
  @spec narrative(t()) :: binary()
  def narrative(%__MODULE__{narrative: narrative}), do: narrative

  @doc "Every embed mentioned in the narrative (see `Lmml.Document`'s `embeds` field)."
  @spec embeds(t()) :: [Embed.t()]
  def embeds(%__MODULE__{document: document}), do: document.embeds

  @doc "Names of the zip entries this bundle carries, excluding the narrative itself. Always `[]` for a `:text` bundle."
  @spec entries(t()) :: [String.t()]
  def entries(%__MODULE__{entries: entries}), do: Map.keys(entries)

  @doc "True for a bundle backed by a bare text narrative (no external files possible)."
  @spec text?(t()) :: boolean()
  def text?(%__MODULE__{kind: :text}), do: true
  def text?(%__MODULE__{}), do: false

  @doc "True for a bundle backed by a zip archive."
  @spec zip?(t()) :: boolean()
  def zip?(%__MODULE__{kind: :zip}), do: true
  def zip?(%__MODULE__{}), do: false

  @doc """
  Resolves a named embed's actual content: inline embeds return their
  own captured text directly (working for any bundle kind); external
  references are looked up among the zip's entries, which only exists
  for a `:zip` bundle.
  """
  @spec embed(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def embed(%__MODULE__{document: document} = bundle, name) do
    with {:ok, embed} <- Document.embed(document, name) do
      resolve(bundle, embed)
    end
  end

  defp resolve(_bundle, %Embed{content: {:inline, content}}), do: {:ok, content}

  defp resolve(%__MODULE__{kind: :text}, %Embed{content: {:external, entry_name}}) do
    {:error, {:unresolvable_reference, entry_name}}
  end

  defp resolve(%__MODULE__{kind: :zip, entries: entries}, %Embed{content: {:external, entry_name}}) do
    with :ok <- validate_entry_names([entry_name]) do
      case Map.fetch(entries, entry_name) do
        {:ok, data} -> {:ok, data}
        :error -> {:error, {:missing_entry, entry_name}}
      end
    end
  end

  # ---------------------------------------------------------------------
  # Cross-bundle validation
  # ---------------------------------------------------------------------

  @typedoc "A single issue found by `validate/1`."
  @type validation_issue ::
          {:missing_reference, String.t()}
          | {:orphaned_entry, String.t()}
          | {:malformed_embed_name, String.t()}
          | {:conflicting_embed, String.t()}

  @doc """
  Cross-checks a bundle's narrative against its own entries and its own
  internal consistency. This is a distinct, opt-in step from `open/2` or
  `new_zip/3` (which only ever reject an entry name that is outright
  *unsafe* -- see `validate_entry_names/1`): `validate/1` instead catches
  authoring mistakes that are still perfectly well-formed as far as
  parsing and path-safety go. Every issue found is returned at once,
  rather than stopping at the first:

    - `{:missing_reference, name}` -- an `@name.ext` reference has no
      matching zip entry. For a `:text` bundle this fires for *every*
      external reference, since a bare `.lmml` has no entries at all to
      resolve one against.
    - `{:orphaned_entry, name}` -- a zip entry that no embed in the
      narrative actually mentions.
    - `{:malformed_embed_name, name}` -- an embed name (inline or
      external) that could not safely become a zip entry name (see
      `validate_entry_names/1`). This applies to every embed, not only
      inline ones, since `Lmml.Pack.pack/2` can turn any inline embed
      into a real zip entry later.
    - `{:conflicting_embed, name}` -- two or more embeds share a name but
      disagree on content (including disagreeing on inline-vs-external),
      which is an authoring mistake: a name is meant to identify one
      entity consistently throughout a narrative.

  Returns `:ok` when none of the above apply.
  """
  @spec validate(t()) :: :ok | {:error, [validation_issue()]}
  def validate(%__MODULE__{} = bundle) do
    issues =
      missing_reference_issues(bundle) ++
        orphaned_entry_issues(bundle) ++
        malformed_name_issues(bundle) ++
        conflicting_embed_issues(bundle)

    if issues == [], do: :ok, else: {:error, issues}
  end

  defp missing_reference_issues(%__MODULE__{document: document, entries: entries}) do
    document
    |> Document.external_embeds()
    |> Enum.uniq_by(& &1.name)
    |> Enum.reject(fn %Embed{content: {:external, entry_name}} ->
      Map.has_key?(entries, entry_name)
    end)
    |> Enum.map(fn %Embed{name: name} -> {:missing_reference, name} end)
  end

  defp orphaned_entry_issues(%__MODULE__{document: document, entries: entries}) do
    referenced =
      document
      |> Document.external_embeds()
      |> MapSet.new(fn %Embed{content: {:external, entry_name}} -> entry_name end)

    entries
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(referenced, &1))
    |> Enum.map(&{:orphaned_entry, &1})
  end

  defp malformed_name_issues(%__MODULE__{document: document}) do
    document
    |> Document.embed_names()
    |> Enum.reject(&(validate_entry_names([&1]) == :ok))
    |> Enum.map(&{:malformed_embed_name, &1})
  end

  defp conflicting_embed_issues(%__MODULE__{document: document}) do
    document.embeds
    |> Enum.group_by(& &1.name, & &1.content)
    |> Enum.filter(fn {_name, contents} -> contents |> Enum.uniq() |> length() > 1 end)
    |> Enum.map(fn {name, _contents} -> {:conflicting_embed, name} end)
  end

  # ---------------------------------------------------------------------
  # Naming & path safety
  # ---------------------------------------------------------------------

  # `foo.lmmlz` -> `foo.lmml` (strip exactly one trailing `z`); any other
  # basename (including one that's already `.lmml`, or has no recognized
  # lmml extension at all) is used as-is unless it lacks a `.lmml` suffix
  # entirely, in which case one is appended -- the logical narrative name
  # is always `<basename>.lmml`.
  @spec narrative_name_for(String.t()) :: String.t()
  defp narrative_name_for(basename) do
    cond do
      String.ends_with?(basename, ".lmmlz") -> String.trim_trailing(basename, "z")
      String.ends_with?(basename, ".lmml") -> basename
      true -> basename <> ".lmml"
    end
  end

  @typedoc "Why `validate_entry_names/1` rejected a name."
  @type name_issue ::
          {:unsafe_entry, String.t()}
          | {:ambiguous_entry_name, String.t()}
          | {:duplicate_entry, String.t()}

  @doc """
  Validates that `names` are safe, unambiguous and distinct entry names.
  Used when opening an archive (every entry its directory lists), when
  building one in memory (`new_zip/3`) and when resolving a single
  reference at read time.

  A name is **unsafe** (`{:unsafe_entry, name}`) when resolving it could
  leave the bundle root or is not a plain relative path: it is empty,
  starts with `/`, contains a backslash, or has a `..`, `.` or empty
  segment (so `a//b` and a trailing `/` are rejected too).

  A name is **ambiguous** (`{:ambiguous_entry_name, name}`) when two
  readers could disagree about which entry it denotes or how to display
  it: it is not valid UTF-8, contains a control character, or is not in
  Unicode Normalization Form C. Requiring NFC means a name has exactly
  one byte representation, so a digest bound to it is unambiguous.

  Two names are **duplicates** (`{:duplicate_entry, name}`) when they are
  equal after case folding -- distinct entries that collide on a
  case-insensitive filesystem, or that a reviewer cannot tell apart, are
  an authoring error rather than something to resolve silently.

  The first offending name is reported.
  """
  @spec validate_entry_names([String.t()]) :: :ok | {:error, name_issue()}
  def validate_entry_names(names) do
    with :ok <- each_name_valid(names) do
      duplicates(names)
    end
  end

  defp each_name_valid(names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      cond do
        not safe_entry_name?(name) -> {:halt, {:error, {:unsafe_entry, name}}}
        not unambiguous_entry_name?(name) -> {:halt, {:error, {:ambiguous_entry_name, name}}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp duplicates(names) do
    names
    |> Enum.reduce_while(MapSet.new(), fn name, seen ->
      folded = String.downcase(name)

      if MapSet.member?(seen, folded),
        do: {:halt, {:duplicate, name}},
        else: {:cont, MapSet.put(seen, folded)}
    end)
    |> case do
      {:duplicate, name} -> {:error, {:duplicate_entry, name}}
      _seen -> :ok
    end
  end

  @spec safe_entry_name?(String.t()) :: boolean()
  defp safe_entry_name?(""), do: false

  defp safe_entry_name?(name) do
    not String.starts_with?(name, "/") and
      not String.contains?(name, "\\") and
      name |> String.split("/") |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  @spec unambiguous_entry_name?(String.t()) :: boolean()
  defp unambiguous_entry_name?(name) do
    String.valid?(name) and
      not control_characters?(name) and
      String.normalize(name, :nfc) == name
  end

  defp control_characters?(name) do
    name
    |> String.to_charlist()
    |> Enum.any?(&(&1 < 0x20 or &1 == 0x7F))
  end
end
