defmodule Lmml.Archive.UnixTypes do
  @moduledoc false

  import Bitwise, only: [band: 2, bsr: 2]

  @eocd_signature 0x06054B50
  @zip64_locator_signature 0x07064B50
  @zip64_eocd_signature 0x06064B50
  @central_signature 0x02014B50
  @eocd_size 22
  # OTP's search allowance excludes the locator's four-byte signature.
  @locator_search_size 16
  @zip64_fixed_size 44
  @central_size 46
  @max16 0xFFFF
  @max32 0xFFFFFFFF

  @type table_entry :: {String.t(), tuple(), non_neg_integer()}
  @type issue ::
          {:invalid_zip, :bad_central_directory_metadata}
          | {:non_regular_entry, String.t()}

  @doc false
  @spec check(binary(), [table_entry()]) :: :ok | {:error, issue()}
  def check(content, table) do
    limit = min(byte_size(content), @max16 + @eocd_size + @locator_search_size)

    with {:ok, directory} <- end_directory(content, min(@eocd_size, limit), limit),
         :ok <- validate_directory(directory, length(table)) do
      bytes = binary_part(content, directory.offset, directory.size)
      check_entries(bytes, table, nil)
    end
  end

  # Match OTP's tail windows and forward, whole-suffix record selection.
  # A signature in entry bytes or a partial record in a comment is not an EOCD.
  defp end_directory(content, window, limit) do
    start = byte_size(content) - window

    case find_eocd(binary_part(content, start, window), start) do
      :none when window == limit ->
        invalid_metadata()

      :none ->
        end_directory(content, min(window + window, limit), limit)

      {:classic, directory, position} ->
        {:ok, Map.put(directory, :limit, position)}

      {:zip64, offset, position} ->
        zip64_directory(content, offset, position)
    end
  end

  defp find_eocd(
         <<@zip64_locator_signature::little-32, _locator_disk::little-32, zip64_offset::little-64,
           _locator_disks::little-32, @eocd_signature::little-32, disk::little-16,
           start_disk::little-16, disk_count::little-16, count::little-16, size::little-32,
           offset::little-32, comment_size::little-16, _comment::binary-size(comment_size)>>,
         position
       ) do
    if zip64_locator_required?(disk, start_disk, disk_count, count, size, offset) do
      {:zip64, zip64_offset, position}
    else
      :none
    end
  end

  defp find_eocd(
         <<@eocd_signature::little-32, disk::little-16, start_disk::little-16,
           disk_count::little-16, count::little-16, size::little-32, offset::little-32,
           comment_size::little-16, _comment::binary-size(comment_size)>>,
         position
       ) do
    if classic_sentinel?(disk, start_disk, disk_count, count, size, offset) do
      :none
    else
      {:classic, %{disk: disk, count: count, size: size, offset: offset}, position}
    end
  end

  defp find_eocd(<<_byte, rest::binary>>, position) when byte_size(rest) > @eocd_size - 4 do
    find_eocd(rest, position + 1)
  end

  defp find_eocd(_bytes, _position), do: :none

  defp zip64_locator_required?(disk, start_disk, disk_count, count, size, offset) do
    disk == @max16 or start_disk == @max16 or
      (disk_count == @max16 and count == @max16) or size == @max32 or offset == @max32
  end

  defp classic_sentinel?(disk, start_disk, disk_count, count, size, offset) do
    disk == @max16 or start_disk == @max16 or disk_count == @max16 or
      count == @max16 or size == @max32 or offset == @max32
  end

  defp zip64_directory(content, offset, locator_position) do
    with true <- offset + 12 <= locator_position,
         <<@zip64_eocd_signature::little-32, record_size::little-64>> <-
           binary_part(content, offset, 12),
         true <- record_size >= @zip64_fixed_size,
         true <- offset + 12 + record_size <= locator_position do
      <<_creator_version::little-16, _required_version::little-16, disk::little-32,
        _start_disk::little-32, _disk_count::little-64, count::little-64, size::little-64,
        directory_offset::little-64>> = binary_part(content, offset + 12, @zip64_fixed_size)

      {:ok, %{disk: disk, count: count, size: size, offset: directory_offset, limit: offset}}
    else
      _invalid -> invalid_metadata()
    end
  end

  defp validate_directory(directory, table_count) do
    if directory.disk == 0 and directory.offset + directory.size <= directory.limit and
         directory.count == table_count and directory.count <= div(directory.size, @central_size) do
      :ok
    else
      invalid_metadata()
    end
  end

  # Every OTP table entry must bind to one sequential raw record. Directory
  # bytes after those records remain OTP's concern (for example a signature).
  defp check_entries(_remaining, [], nil), do: :ok

  defp check_entries(_remaining, [], name), do: {:error, {:non_regular_entry, name}}

  defp check_entries(bytes, [{name, _info, _compressed_size} | table], non_regular) do
    with {:ok, raw_name, creator, flags, attributes, rest} <- central_entry(bytes),
         true <- same_name?(raw_name, flags, name) do
      rejected_name = rejected_name(non_regular, creator, attributes, name)
      check_entries(rest, table, rejected_name)
    else
      _invalid -> invalid_metadata()
    end
  end

  defp central_entry(
         <<@central_signature::little-32, _creator_version, creator, _required_version::little-16,
           flags::little-16, _fields::binary-size(18), name_size::little-16,
           extra_size::little-16, comment_size::little-16, _disk::little-16,
           _internal_attributes::little-16, attributes::little-32, _local_offset::little-32,
           rest::binary>>
       ) do
    variable_size = name_size + extra_size + comment_size

    if variable_size <= byte_size(rest) do
      raw_name = binary_part(rest, 0, name_size)
      tail = binary_part(rest, variable_size, byte_size(rest) - variable_size)
      {:ok, raw_name, creator, flags, attributes, tail}
    else
      invalid_metadata()
    end
  end

  defp central_entry(_bytes), do: invalid_metadata()

  defp same_name?(raw_name, flags, name) do
    if band(flags, 0x800) == 0 do
      raw_name == :unicode.characters_to_binary(name, :utf8, :latin1)
    else
      raw_name == name
    end
  end

  defp rejected_name(nil, 3, attributes, name) do
    if band(bsr(attributes, 16), 0xF000) in [0, 0x8000], do: nil, else: name
  end

  defp rejected_name(previous, _creator, _attributes, _name), do: previous

  defp invalid_metadata, do: {:error, {:invalid_zip, :bad_central_directory_metadata}}
end
