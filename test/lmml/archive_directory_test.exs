defmodule Lmml.ArchiveDirectoryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Lmml.Bundle

  @archive_name "directory.lmmlz"
  @narrative_name "directory.lmml"
  @narrative "A narrative."
  @central_signature 0x02014B50
  @eocd_signature 0x06054B50
  @max16 0xFFFF
  @max32 0xFFFFFFFF

  test "LMML's permission-only Unix writer remains readable" do
    assert {:ok, original} = Bundle.new_zip("directory", @narrative, %{})
    assert {:ok, archive} = Bundle.to_binary(original)
    directory_offset = classic_directory_offset(archive)
    <<creator>> = binary_part(archive, directory_offset + 5, 1)
    <<attributes::little-32>> = binary_part(archive, directory_offset + 38, 4)

    assert creator == 3
    assert Bitwise.bsr(attributes, 16) == 0o644
    assert {:ok, loaded} = Bundle.load(@archive_name, archive)
    assert Bundle.narrative(loaded) == @narrative
    assert Bundle.entries(loaded) == []
  end

  for creator <- [0, 19] do
    test "creator #{creator} retains OTP's regular-file interpretation" do
      archive =
        archive([
          {@narrative_name, @narrative, creator: unquote(creator), mode: 0o120777}
        ])

      assert {:ok, loaded} = Bundle.load(@archive_name, archive)
      assert Bundle.narrative(loaded) == @narrative
      assert Bundle.entries(loaded) == []
    end
  end

  test "an explicitly Unix directory without a trailing slash is refused" do
    archive = archive([{@narrative_name, @narrative, mode: 0o040755}])

    assert {:error, {:non_regular_entry, @narrative_name}} =
             Bundle.load(@archive_name, archive)
  end

  test "sequential records keep their names, extra fields and comments separate" do
    long_name = String.duplicate("a", 73) <> ".bin"
    payload = <<@central_signature::little-32, @eocd_signature::little-32, 0x07064B50::little-32>>
    extra = <<0xCAFE::little-16, 5::little-16, "PK!?!">>
    narrative = "See @#{long_name} and @café.txt."

    archive =
      archive(
        [
          {@narrative_name, narrative, extra: extra, comment: "a file comment"},
          {long_name, payload, extra: extra, comment: "PK\x01\x02"},
          {"café.txt", "unicode bytes", flags: 0x800, comment: "café"}
        ],
        comment: "archive PK\x05\x06 comment"
      )

    assert {:ok, loaded} = Bundle.load(@archive_name, archive)
    assert Bundle.narrative(loaded) == narrative
    assert Enum.sort(Bundle.entries(loaded)) == Enum.sort([long_name, "café.txt"])
    assert Bundle.embed(loaded, long_name) == {:ok, payload}
    assert Bundle.embed(loaded, "café.txt") == {:ok, "unicode bytes"}
  end

  test "legacy unflagged filename bytes bind to OTP's decoded Latin-1 name" do
    archive =
      archive([
        {@narrative_name, "See @café.txt.", []},
        {<<"caf", 0xE9, ".txt">>, "legacy bytes", []}
      ])

    assert {:ok, loaded} = Bundle.load(@archive_name, archive)
    assert Bundle.entries(loaded) == ["café.txt"]
    assert Bundle.embed(loaded, "café.txt") == {:ok, "legacy bytes"}
  end

  test "a later Unix special entry reports its own OTP-decoded name" do
    archive =
      archive([
        {@narrative_name, "See @café.txt.", []},
        {"café.txt", "target", flags: 0x800, mode: 0o120777, comment: "not a filename"}
      ])

    assert {:error, {:non_regular_entry, "café.txt"}} = Bundle.load(@archive_name, archive)
  end

  for comment_size <- [1, 21, 23, 45, 101, 65_535] do
    test "a #{comment_size}-byte archive comment survives the tail search windows" do
      archive =
        archive([{@narrative_name, @narrative, []}],
          comment: :binary.copy("x", unquote(comment_size))
        )

      assert {:ok, loaded} = Bundle.load(@archive_name, archive)
      assert Bundle.narrative(loaded) == @narrative
    end
  end

  test "the final whole-suffix EOCD selects the same directory as OTP" do
    entries = [{@narrative_name, @narrative, []}]
    base = archive(entries)
    original_eocd_position = byte_size(base) - 22
    alternate = central_record({@narrative_name, @narrative, mode: 0o120777}, 0)
    alternate_offset = original_eocd_position + 22
    inner_eocd = eocd(1, byte_size(alternate), alternate_offset, <<>>)
    archive = archive(entries, comment: alternate <> inner_eocd)

    assert {:ok, table} = :zip.table(archive)
    assert [{@narrative_name, info}] = table_files(table)
    assert elem(info, 2) == :regular

    assert {:error, {:non_regular_entry, @narrative_name}} =
             Bundle.load(@archive_name, archive)
  end

  for zip64 <- [true, :size_only] do
    test "ZIP64 directory #{inspect(zip64)} keeps small regular entries readable" do
      archive = archive([{@narrative_name, @narrative, []}], zip64: unquote(zip64))

      assert {:ok, loaded} = Bundle.load(@archive_name, archive)
      assert Bundle.narrative(loaded) == @narrative
      assert Bundle.entries(loaded) == []
    end

    test "ZIP64 directory #{inspect(zip64)} cannot hide a Unix symlink type" do
      archive =
        archive([{@narrative_name, @narrative, mode: 0o120777}], zip64: unquote(zip64))

      assert {:ok, table} = :zip.table(archive)
      assert [{@narrative_name, info}] = table_files(table)
      assert elem(info, 2) == :regular

      assert {:error, {:non_regular_entry, @narrative_name}} =
               Bundle.load(@archive_name, archive)
    end
  end

  test "ZIP64 per-entry sizes and local offsets remain OTP's responsibility" do
    archive =
      archive(
        [
          {@narrative_name, "See @a.bin.", zip64: true},
          {"a.bin", "asset bytes", zip64: true}
        ],
        zip64: true
      )

    assert {:ok, loaded} = Bundle.load(@archive_name, archive)
    assert Bundle.narrative(loaded) == "See @a.bin."
    assert Bundle.embed(loaded, "a.bin") == {:ok, "asset bytes"}
  end

  for directory_size <- [45, 46] do
    test "a directory size of #{directory_size} cannot omit raw entry metadata" do
      archive =
        archive([{@narrative_name, @narrative, []}], directory_size: unquote(directory_size))

      assert {:ok, _table} = :zip.table(archive)

      assert {:error, {:invalid_zip, :bad_central_directory_metadata}} =
               Bundle.load(@archive_name, archive)
    end
  end

  for zip64 <- [false, true] do
    test "the directory cannot overlap its #{if zip64, do: "ZIP64", else: "classic"} end record" do
      entries = [{@narrative_name, @narrative, []}]
      declared_size = byte_size(central_record(hd(entries), 0)) + 1
      archive = archive(entries, directory_size: declared_size, zip64: unquote(zip64))

      assert {:ok, _table} = :zip.table(archive)

      assert {:error, {:invalid_zip, :bad_central_directory_metadata}} =
               Bundle.load(@archive_name, archive)
    end
  end

  test "unsafe names precede malformed metadata and Unix type admission" do
    archive = archive([{"../escape.lmml", @narrative, mode: 0o120777}], directory_size: 45)

    assert {:error, {:unsafe_entry, "../escape.lmml"}} = Bundle.load(@archive_name, archive)
  end

  test "duplicate names precede Unix types and policy errors" do
    archive =
      archive([
        {@narrative_name, @narrative, []},
        {"DIRECTORY.LMML", "target", mode: 0o120777}
      ])

    assert {:error, {:duplicate_entry, "DIRECTORY.LMML"}} =
             Bundle.load(@archive_name, archive, policy: [max_entries: 1])
  end

  test "Unix type admission precedes resource policy" do
    archive = archive([{@narrative_name, @narrative, mode: 0o120777}])

    assert {:error, {:non_regular_entry, @narrative_name}} =
             Bundle.load(@archive_name, archive, policy: [max_entry_bytes: 1])
  end

  test "regular metadata retains the existing resource policy refusal" do
    archive = archive([{@narrative_name, @narrative, []}])

    assert {:error, {:entry_too_large, @narrative_name}} =
             Bundle.load(@archive_name, archive, policy: [max_entry_bytes: 1])
  end

  defp archive(entries, options \\ []) do
    {locals, central, _offset} = Enum.reduce(entries, {[], [], 0}, &append_record/2)
    local_bytes = locals |> Enum.reverse() |> IO.iodata_to_binary()
    directory = central |> Enum.reverse() |> IO.iodata_to_binary()
    footer = footer(length(entries), byte_size(directory), byte_size(local_bytes), options)
    local_bytes <> directory <> footer
  end

  defp append_record(entry, {locals, central, offset}) do
    local = local_record(entry)
    {[local | locals], [central_record(entry, offset) | central], offset + byte_size(local)}
  end

  defp local_record({name, data, options}) do
    flags = Keyword.get(options, :flags, 0)
    extra = Keyword.get(options, :extra, <<>>)
    crc = :erlang.crc32(data)
    size = byte_size(data)

    <<0x04034B50::little-32, 20::little-16, flags::little-16, 0::little-16, 0::little-16,
      33::little-16, crc::little-32, size::little-32, size::little-32, byte_size(name)::little-16,
      byte_size(extra)::little-16>> <> name <> extra <> data
  end

  defp central_record({name, data, options}, offset) do
    creator = Keyword.get(options, :creator, 3)
    flags = Keyword.get(options, :flags, 0)
    attributes = Bitwise.bsl(Keyword.get(options, :mode, 0o100644), 16)
    comment = Keyword.get(options, :comment, <<>>)
    crc = :erlang.crc32(data)
    {size, local_offset, extra, version} = central_sizes(data, offset, options)

    <<@central_signature::little-32, 20, creator, version::little-16, flags::little-16,
      0::little-16, 0::little-16, 33::little-16, crc::little-32, size::little-32, size::little-32,
      byte_size(name)::little-16, byte_size(extra)::little-16, byte_size(comment)::little-16,
      0::little-16, 0::little-16, attributes::little-32, local_offset::little-32>> <>
      name <> extra <> comment
  end

  defp central_sizes(data, offset, options) do
    extra = Keyword.get(options, :extra, <<>>)
    size = byte_size(data)

    if Keyword.get(options, :zip64, false) do
      zip64 = <<1::little-16, 24::little-16, size::little-64, size::little-64, offset::little-64>>
      {@max32, @max32, zip64 <> extra, 45}
    else
      {size, offset, extra, 20}
    end
  end

  defp footer(count, actual_size, offset, options) do
    comment = Keyword.get(options, :comment, <<>>)
    size = Keyword.get(options, :directory_size, actual_size)

    case Keyword.get(options, :zip64, false) do
      false ->
        eocd(count, size, offset, comment)

      zip64 ->
        record = zip64_eocd(count, size, offset)
        record_offset = offset + actual_size

        locator =
          <<0x07064B50::little-32, 0::little-32, record_offset::little-64, 1::little-32>>

        record <> locator <> zip64_sentinel(zip64, count, offset, comment)
    end
  end

  defp zip64_eocd(count, size, offset) do
    <<0x06064B50::little-32, 44::little-64, 45, 3, 45::little-16, 0::little-32, 0::little-32,
      count::little-64, count::little-64, size::little-64, offset::little-64>>
  end

  defp zip64_sentinel(:size_only, count, offset, comment),
    do: eocd(count, @max32, offset, comment)

  defp zip64_sentinel(true, _count, _offset, comment), do: eocd(@max16, @max32, @max32, comment)

  defp eocd(count, size, offset, comment) do
    <<@eocd_signature::little-32, 0::little-16, 0::little-16, count::little-16, count::little-16,
      size::little-32, offset::little-32, byte_size(comment)::little-16>> <> comment
  end

  defp classic_directory_offset(archive) do
    <<_fields::binary-size(16), offset::little-32, 0::little-16>> =
      binary_part(archive, byte_size(archive) - 22, 22)

    offset
  end

  defp table_files(table) do
    for {:zip_file, name, info, _comment, _offset, _compressed_size} <- table,
        do: {to_string(name), info}
  end
end
