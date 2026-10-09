defmodule Lmml.ReaderAdmissionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Lmml.Bundle
  alias Lmml.Manifest

  @central_directory_signature <<0x50, 0x4B, 0x01, 0x02>>
  @archive_name "types.lmmlz"
  @entry_name "types.lmml"
  @entry_content "target"

  describe "explicit manifest version admission" do
    test "version 1 verifies through the loaded and explicitly supplied public APIs" do
      manifest = %Manifest{data: %{"lmml_version" => "1", "entries" => %{}}}
      bundle = bundle_with_manifest(manifest)

      assert Manifest.supported_versions() == ["1"]
      assert Manifest.load(bundle) == {:ok, manifest}
      assert Manifest.verify(bundle) == :ok
      assert Manifest.verify(bundle, manifest) == :ok
    end

    test "an absent version loads as legacy metadata but never verifies" do
      manifest = %Manifest{data: %{"entries" => %{}}}
      bundle = bundle_with_manifest(manifest)

      assert Manifest.load(bundle) == {:ok, manifest}
      assert Manifest.verify(bundle) == {:error, [:unversioned_manifest]}
      assert Manifest.verify(bundle, manifest) == {:error, [:unversioned_manifest]}
    end

    for version <- ["2", "0", 1, true, ["1"], %{}, nil] do
      test "explicit #{inspect(version)} is refused consistently with manifest loading" do
        version = unquote(Macro.escape(version))
        manifest = %Manifest{data: %{"lmml_version" => version, "entries" => %{}}}
        bundle = bundle_with_manifest(manifest)
        reason = {:unsupported_version, version}

        assert Manifest.load(bundle) == {:error, reason}
        assert Manifest.verify(bundle) == {:error, [{:invalid_manifest, reason}]}
        assert Manifest.verify(bundle, manifest) == {:error, [{:invalid_manifest, reason}]}
      end
    end
  end

  describe "Unix central-directory entry type admission" do
    test "an explicitly regular Unix entry remains a readable tiny archive" do
      mode = 0o100600
      archive = archive_with_unix_mode(mode)

      assert_unix_metadata(archive, mode)
      assert elem(zip_entry_info(archive), 2) == :regular
      assert {:ok, bundle} = Bundle.load(@archive_name, archive)
      assert Bundle.name(bundle) == @entry_name
      assert Bundle.narrative(bundle) == @entry_content
      assert Bundle.entries(bundle) == []
      assert Bundle.validate(bundle) == :ok
    end

    for {type, mode} <- [
          {:symlink, 0o120777},
          {:character_device, 0o020600},
          {:block_device, 0o060600},
          {:fifo, 0o010600},
          {:socket, 0o140600}
        ] do
      test "a Unix #{type} is refused even when OTP reports a regular file" do
        mode = unquote(mode)
        archive = archive_with_unix_mode(mode)

        assert_unix_metadata(archive, mode)
        assert elem(zip_entry_info(archive), 2) == :regular

        assert Bundle.load(@archive_name, archive) ==
                 {:error, {:non_regular_entry, @entry_name}}
      end
    end
  end

  defp bundle_with_manifest(manifest) do
    {:ok, bundle} = Bundle.new_text("versions", "A narrative without external embeds.")
    {:ok, attached} = Manifest.attach(bundle, manifest)
    attached
  end

  defp archive_with_unix_mode(mode) do
    {:ok, {_name, archive}} =
      :zip.create(
        String.to_charlist(@archive_name),
        [{String.to_charlist(@entry_name), @entry_content}],
        [:memory]
      )

    {position, 4} = :binary.match(archive, @central_directory_signature)

    <<prefix::binary-size(^position), signature::binary-size(4), _made_by::little-16,
      fields::binary-size(32), _attributes::little-32, rest::binary>> = archive

    # ZIP's creator field is version 2.0 on Unix; its external attributes
    # carry the complete Unix mode in the upper 16 bits. No filesystem entry
    # is created, and the payload, CRC and size fields remain unchanged.
    prefix <>
      signature <>
      <<0x0314::little-16>> <>
      fields <>
      <<Bitwise.bsl(mode, 16)::little-32>> <> rest
  end

  defp assert_unix_metadata(archive, mode) do
    assert byte_size(archive) < 512
    assert [{position, 4}] = :binary.matches(archive, @central_directory_signature)
    made_by_offset = position + 4
    attributes_offset = position + 38

    <<made_by::little-16>> = binary_part(archive, made_by_offset, 2)
    <<attributes::little-32>> = binary_part(archive, attributes_offset, 4)

    assert Bitwise.bsr(made_by, 8) == 3
    assert Bitwise.bsr(attributes, 16) == mode
    assert binary_part(archive, position + 46, byte_size(@entry_name)) == @entry_name
  end

  defp zip_entry_info(archive) do
    {:ok, table} = :zip.table(archive)
    entries = for {:zip_file, name, info, _, _, _} <- table, do: {to_string(name), info}
    assert [{@entry_name, info}] = entries
    info
  end
end
