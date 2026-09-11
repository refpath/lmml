defmodule Lmml.DigestTest do
  use ExUnit.Case, async: true

  alias Lmml.Digest

  @empty_sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  @abc_sha256 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  test "sha256/1 matches the published test vectors as lowercase hex" do
    assert Digest.sha256("") == @empty_sha256
    assert Digest.sha256("abc") == @abc_sha256
  end

  test "the algorithm name is what manifests record" do
    assert Digest.algorithm() == "sha256"
  end

  test "valid?/1 accepts only 64 lowercase hex characters" do
    assert Digest.valid?(@abc_sha256)
    refute Digest.valid?(String.upcase(@abc_sha256))
    refute Digest.valid?(String.slice(@abc_sha256, 0, 63))
    refute Digest.valid?(@abc_sha256 <> "0")
    refute Digest.valid?(nil)
    refute Digest.valid?(123)
  end

  test "verify/2 distinguishes a mismatch from a malformed expectation" do
    assert :ok = Digest.verify("abc", @abc_sha256)
    assert {:error, {:digest_mismatch, @abc_sha256}} = Digest.verify("abc", @empty_sha256)
    assert {:error, :malformed_digest} = Digest.verify("abc", String.upcase(@abc_sha256))
    assert {:error, :malformed_digest} = Digest.verify("abc", "sha256:" <> @abc_sha256)
  end
end
