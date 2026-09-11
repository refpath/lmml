defmodule Lmml.HostileArchiveTest do
  @moduledoc """
  Archives an attacker could hand a host. Every case must be rejected
  with a clean error *before* the offending entry is inflated, or -- for
  a forged size header -- immediately after inflation, before the bytes
  reach a caller.
  """
  use ExUnit.Case, async: true

  alias Lmml.Archive.Policy
  alias Lmml.Bundle

  # Builds raw archive bytes straight through OTP's zip so the test can
  # produce shapes `Bundle.new_zip/3` would refuse to build (duplicate or
  # directory entries), exactly as a foreign tool could.
  defp raw_zip(entries) do
    {:ok, {_name, binary}} =
      :zip.create(
        ~c"hostile.lmmlz",
        Enum.map(entries, fn {n, d} -> {String.to_charlist(n), d} end),
        [
          :memory
        ]
      )

    binary
  end

  describe "resource limits are enforced on the central directory" do
    test "a zip bomb is rejected by compression ratio before inflation" do
      bomb =
        raw_zip([{"hostile.lmml", "See @big.bin."}, {"big.bin", :binary.copy(<<0>>, 2_000_000)}])

      assert {:error, {:compression_ratio_exceeded, "big.bin"}} =
               Bundle.load("hostile.lmmlz", bomb)
    end

    test "too many entries is rejected with the count" do
      entries = for i <- 1..5, do: {"e#{i}.txt", "x"}
      archive = raw_zip([{"hostile.lmml", "text"} | entries])

      assert {:error, {:too_many_entries, 6}} =
               Bundle.load("hostile.lmmlz", archive, policy: [max_entries: 5])
    end

    test "an entry larger than the per-entry limit is rejected by declared size" do
      archive =
        raw_zip([{"hostile.lmml", "See @a.bin."}, {"a.bin", :crypto.strong_rand_bytes(64)}])

      assert {:error, {:entry_too_large, "a.bin"}} =
               Bundle.load("hostile.lmmlz", archive, policy: [max_entry_bytes: 63])
    end

    test "the total declared size is bounded" do
      archive =
        raw_zip([
          {"hostile.lmml", "See @a.bin and @b.bin."},
          {"a.bin", :crypto.strong_rand_bytes(40)},
          {"b.bin", :crypto.strong_rand_bytes(40)}
        ])

      assert {:error, {:archive_too_large, _}} =
               Bundle.load("hostile.lmmlz", archive,
                 policy: [max_entry_bytes: 50, max_total_bytes: 100]
               )
    end

    test "the policy can be passed as a struct" do
      archive = raw_zip([{"hostile.lmml", "text"}])
      policy = Policy.new(max_entries: 1)

      assert {:ok, _bundle} = Bundle.load("hostile.lmmlz", archive, policy: policy)
    end
  end

  describe "forged headers" do
    test "an entry whose inflated size differs from its declared size is rejected" do
      archive = raw_zip([{"hostile.lmml", "hello world"}])
      {pos, 4} = :binary.match(archive, <<0x50, 0x4B, 0x01, 0x02>>)

      # The central-directory header's uncompressed-size field sits 24 bytes
      # past its signature; declare 5 bytes for an 11-byte entry.
      prefix_size = pos + 24
      <<prefix::binary-size(^prefix_size), _declared::little-32, rest::binary>> = archive
      forged = prefix <> <<5::little-32>> <> rest

      assert {:error, {:size_mismatch, "hostile.lmml"}} = Bundle.load("hostile.lmmlz", forged)
    end
  end

  describe "entry identity" do
    test "two entries with the same name are rejected rather than letting the last one win" do
      archive = raw_zip([{"hostile.lmml", "See @a.txt."}, {"a.txt", "one"}, {"a.txt", "two"}])

      assert {:error, {:duplicate_entry, "a.txt"}} = Bundle.load("hostile.lmmlz", archive)
    end

    test "two entries differing only by case are rejected" do
      archive = raw_zip([{"hostile.lmml", "See @a.txt."}, {"a.txt", "one"}, {"A.TXT", "two"}])

      assert {:error, {:duplicate_entry, "A.TXT"}} = Bundle.load("hostile.lmmlz", archive)
    end

    test "a directory entry is not a regular file" do
      archive = raw_zip([{"hostile.lmml", "text"}, {"dir/", ""}])

      assert {:error, reason} = Bundle.load("hostile.lmmlz", archive)
      assert reason in [{:unsafe_entry, "dir/"}, {:non_regular_entry, "dir/"}]
    end

    test "a traversal entry is rejected" do
      archive = raw_zip([{"hostile.lmml", "text"}, {"../escape.txt", "nope"}])

      assert {:error, {:unsafe_entry, "../escape.txt"}} = Bundle.load("hostile.lmmlz", archive)
    end

    test "an empty or dot path segment is rejected" do
      assert {:error, {:unsafe_entry, "a//b.txt"}} = Bundle.new_zip("x", "t", %{"a//b.txt" => ""})
      assert {:error, {:unsafe_entry, "./b.txt"}} = Bundle.new_zip("x", "t", %{"./b.txt" => ""})
      assert {:error, {:unsafe_entry, ""}} = Bundle.new_zip("x", "t", %{"" => ""})
    end

    test "a name that is not Unicode NFC is ambiguous" do
      decomposed = "é.png"
      refute String.normalize(decomposed, :nfc) == decomposed

      assert {:error, {:ambiguous_entry_name, ^decomposed}} =
               Bundle.new_zip("x", "t", %{decomposed => ""})

      composed = String.normalize(decomposed, :nfc)
      assert {:ok, _} = Bundle.new_zip("x", "t", %{composed => ""})
    end

    test "a name with a control character is ambiguous" do
      assert {:error, {:ambiguous_entry_name, "a\nb.txt"}} =
               Bundle.new_zip("x", "t", %{"a\nb.txt" => ""})

      assert {:error, {:ambiguous_entry_name, "a\x7Fb.txt"}} =
               Bundle.new_zip("x", "t", %{"a\x7Fb.txt" => ""})
    end

    test "a name that is not valid UTF-8 is ambiguous" do
      assert {:error, {:ambiguous_entry_name, <<0xFF, 0xFE>>}} =
               Bundle.new_zip("x", "t", %{<<0xFF, 0xFE>> => ""})
    end

    test "an external entry colliding with the narrative name is a duplicate" do
      assert {:error, {:duplicate_entry, "x.lmml"}} =
               Bundle.new_zip("x", "t", %{"x.lmml" => "shadow"})
    end
  end

  describe "load/3 from memory" do
    test "bare text loads without a policy and normalizes the name" do
      assert {:ok, bundle} = Bundle.load("notes", "Hello @a.png")
      assert Bundle.text?(bundle)
      assert Bundle.name(bundle) == "notes.lmml"
    end

    test "an archive loads by content sniffing regardless of the name's extension" do
      archive = raw_zip([{"convo.lmml", "See @a.png."}, {"a.png", "bytes"}])

      assert {:ok, bundle} = Bundle.load("convo", archive)
      assert Bundle.zip?(bundle)
      assert {:ok, "bytes"} = Bundle.embed(bundle, "a.png")
    end

    test "corrupt bytes that merely start with the zip magic are a clean error" do
      assert {:error, {:invalid_zip, _}} =
               Bundle.load("x.lmmlz", <<0x50, 0x4B, 0x03, 0x04, 1, 2, 3>>)
    end
  end
end
