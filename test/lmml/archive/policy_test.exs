defmodule Lmml.Archive.PolicyTest do
  use ExUnit.Case, async: true

  alias Lmml.Archive.Policy

  defp entry(name, size, compressed \\ nil) do
    %{name: name, size: size, compressed_size: compressed || size}
  end

  describe "new/1" do
    test "defaults are the documented conservative limits" do
      policy = Policy.default()

      assert policy.max_entries == 1024
      assert policy.max_entry_bytes == 16 * 1024 * 1024
      assert policy.max_total_bytes == 64 * 1024 * 1024
      assert policy.max_compression_ratio == 100
      assert policy.max_name_bytes == 2048
    end

    test "keyword overrides replace individual limits" do
      policy = Policy.new(max_entries: 3, max_entry_bytes: 10)

      assert policy.max_entries == 3
      assert policy.max_entry_bytes == 10
      assert policy.max_total_bytes == Policy.default().max_total_bytes
    end

    test "a policy struct passes through unchanged" do
      policy = Policy.new(max_entries: 1)
      assert Policy.new(policy) == policy
    end

    test "a non-positive or non-integer limit is a programming error" do
      assert_raise ArgumentError, ~r/max_entries must be a positive integer/, fn ->
        Policy.new(max_entries: 0)
      end

      assert_raise ArgumentError, ~r/max_total_bytes must be a positive integer/, fn ->
        Policy.new(max_total_bytes: "lots")
      end
    end

    test "an unknown option is a programming error" do
      assert_raise ArgumentError, ~r/unknown archive policy option :max_files/, fn ->
        Policy.new(max_files: 3)
      end
    end
  end

  describe "check_table/2" do
    test "an archive within every limit passes" do
      policy = Policy.new(max_entries: 2, max_entry_bytes: 100, max_total_bytes: 150)

      assert :ok = Policy.check_table(policy, [entry("a.lmml", 50), entry("b.png", 100, 40)])
    end

    test "too many entries is reported with the count" do
      policy = Policy.new(max_entries: 1)

      assert {:error, {:too_many_entries, 2}} =
               Policy.check_table(policy, [entry("a.lmml", 1), entry("b.png", 1)])
    end

    test "a single oversized entry names the entry" do
      policy = Policy.new(max_entry_bytes: 10)

      assert {:error, {:entry_too_large, "big.bin"}} =
               Policy.check_table(policy, [entry("a.lmml", 1), entry("big.bin", 11)])
    end

    test "the total declared size is bounded even when each entry fits" do
      policy = Policy.new(max_entry_bytes: 10, max_total_bytes: 15)

      assert {:error, {:archive_too_large, 20}} =
               Policy.check_table(policy, [entry("a.lmml", 10), entry("b.txt", 10)])
    end

    test "a compression ratio past the limit is a zip bomb" do
      policy = Policy.new(max_compression_ratio: 100)

      assert :ok = Policy.check_table(policy, [entry("ok.bin", 1000, 10)])

      assert {:error, {:compression_ratio_exceeded, "bomb.bin"}} =
               Policy.check_table(policy, [entry("bomb.bin", 1001, 10)])
    end

    test "a non-empty entry declaring zero compressed bytes has an infinite ratio" do
      assert {:error, {:compression_ratio_exceeded, "weird.bin"}} =
               Policy.check_table(Policy.default(), [entry("weird.bin", 1, 0)])
    end

    test "an empty entry never exceeds a ratio" do
      assert :ok = Policy.check_table(Policy.default(), [entry("empty.txt", 0, 0)])
    end

    test "an entry name longer than the limit is rejected before its bytes matter" do
      policy = Policy.new(max_name_bytes: 8)
      long = String.duplicate("n", 9)

      assert {:error, {:entry_name_too_long, ^long}} =
               Policy.check_table(policy, [entry(long, 1)])
    end
  end
end
