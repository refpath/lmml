defmodule Lmml.Archive.Policy do
  @moduledoc """
  Resource limits an `.lmmlz` archive must satisfy *before* any of its
  entries are inflated into memory.

  A zip archive is a list of compressed entries plus a central directory
  that declares each entry's name, compressed size and uncompressed size.
  Everything in this policy is checked against that directory (see
  `check_table/2`) so a hostile archive -- a "zip bomb" with a few bytes
  that inflate to gigabytes, an archive with a million tiny entries, an
  entry whose name is longer than a path can be -- is rejected with a
  clean error before `:zip.unzip/2` allocates anything for it. After
  inflation `Lmml.Bundle` additionally checks that every entry's actual
  byte size matches what the directory declared, so a lying header
  cannot bypass the limits either.

  The defaults are deliberately conservative and are *defaults*, not a
  guarantee that your own host can absorb them: a service that opens
  untrusted archives should size them for its own memory budget via
  `new/1`.

  | Limit | Default | Meaning |
  |---|---|---|
  | `max_entries` | 1024 | entries in the central directory, narrative included |
  | `max_entry_bytes` | 16 MiB | declared uncompressed size of any single entry |
  | `max_total_bytes` | 64 MiB | sum of declared uncompressed sizes |
  | `max_compression_ratio` | 100 | uncompressed / compressed per entry |
  | `max_name_bytes` | 2048 | byte length of an entry name |

  Every limit is a positive integer. `check_table/2` reports the first
  violation it finds as one of:

    - `{:too_many_entries, count}`
    - `{:entry_too_large, name}`
    - `{:archive_too_large, total_bytes}`
    - `{:compression_ratio_exceeded, name}`
    - `{:entry_name_too_long, name}`
  """

  @mib 1024 * 1024

  defstruct max_entries: 1024,
            max_entry_bytes: 16 * @mib,
            max_total_bytes: 64 * @mib,
            max_compression_ratio: 100,
            max_name_bytes: 2048

  @type t :: %__MODULE__{
          max_entries: pos_integer(),
          max_entry_bytes: pos_integer(),
          max_total_bytes: pos_integer(),
          max_compression_ratio: pos_integer(),
          max_name_bytes: pos_integer()
        }

  @typedoc "One central-directory entry as `check_table/2` sees it."
  @type table_entry :: %{
          name: String.t(),
          size: non_neg_integer(),
          compressed_size: non_neg_integer()
        }

  @type violation ::
          {:too_many_entries, non_neg_integer()}
          | {:entry_too_large, String.t()}
          | {:archive_too_large, non_neg_integer()}
          | {:compression_ratio_exceeded, String.t()}
          | {:entry_name_too_long, String.t()}

  @limits [
    :max_entries,
    :max_entry_bytes,
    :max_total_bytes,
    :max_compression_ratio,
    :max_name_bytes
  ]

  @doc "The default policy (see the moduledoc table)."
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Builds a policy from keyword overrides of the defaults, or returns a
  `t()` unchanged. Raises `ArgumentError` for an unknown key or a value
  that is not a positive integer, since a misconfigured limit is a
  programming error rather than a runtime condition to recover from.
  """
  @spec new(t() | keyword()) :: t()
  def new(%__MODULE__{} = policy), do: policy

  def new(opts) when is_list(opts) do
    Enum.reduce(opts, %__MODULE__{}, fn
      {key, value}, policy when key in @limits and is_integer(value) and value > 0 ->
        Map.put(policy, key, value)

      {key, value}, _policy when key in @limits ->
        raise ArgumentError,
              "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"

      {key, _value}, _policy ->
        raise ArgumentError, "unknown archive policy option #{inspect(key)}"
    end)
  end

  @doc """
  Checks a list of central-directory entries against `policy` without
  touching any entry's bytes. Returns `:ok` or the first `violation/0`
  found, in the order entry count, name length, per-entry size,
  compression ratio, total size.
  """
  @spec check_table(t(), [table_entry()]) :: :ok | {:error, violation()}
  def check_table(%__MODULE__{} = policy, entries) when is_list(entries) do
    with :ok <- check_count(policy, entries),
         :ok <- check_each(policy, entries) do
      check_total(policy, entries)
    end
  end

  defp check_count(%{max_entries: max}, entries) do
    count = length(entries)
    if count > max, do: {:error, {:too_many_entries, count}}, else: :ok
  end

  defp check_each(policy, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case check_entry(policy, entry) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_entry(policy, %{name: name, size: size, compressed_size: compressed}) do
    cond do
      byte_size(name) > policy.max_name_bytes ->
        {:error, {:entry_name_too_long, name}}

      size > policy.max_entry_bytes ->
        {:error, {:entry_too_large, name}}

      ratio_exceeded?(size, compressed, policy.max_compression_ratio) ->
        {:error, {:compression_ratio_exceeded, name}}

      true ->
        :ok
    end
  end

  # A non-empty entry that claims zero compressed bytes has an undefined
  # (infinite) ratio and is treated as exceeding any finite limit.
  defp ratio_exceeded?(0, _compressed, _max), do: false
  defp ratio_exceeded?(_size, 0, _max), do: true
  defp ratio_exceeded?(size, compressed, max), do: size > compressed * max

  defp check_total(%{max_total_bytes: max}, entries) do
    total = Enum.reduce(entries, 0, fn %{size: size}, acc -> acc + size end)
    if total > max, do: {:error, {:archive_too_large, total}}, else: :ok
  end
end
