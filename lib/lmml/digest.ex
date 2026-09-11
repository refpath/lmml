defmodule Lmml.Digest do
  @moduledoc """
  Content digests as `lmml` records and compares them: SHA-256 over the
  exact bytes, rendered as 64 lowercase hexadecimal characters.

  A digest names *bytes*, never a file path or an embed name, so the same
  content carried inline in one bundle and as an archive entry in another
  has the same digest, and renaming an entry does not change it. Every
  comparison goes through `verify/2` so a caller never has to remember
  which side is the expected value.
  """

  @algorithm :sha256
  @hex_length 64

  @typedoc "A lowercase hexadecimal SHA-256 digest."
  @type t :: <<_::512>>

  @doc "The digest algorithm name as it appears in manifests."
  @spec algorithm() :: String.t()
  def algorithm, do: Atom.to_string(@algorithm)

  @doc "The SHA-256 digest of `bytes` as lowercase hex."
  @spec sha256(binary()) :: t()
  def sha256(bytes) when is_binary(bytes) do
    @algorithm |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end

  @doc """
  True when `value` is syntactically a digest this module could have
  produced: exactly #{@hex_length} lowercase hexadecimal characters.
  """
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) and byte_size(value) == @hex_length do
    String.match?(value, ~r/\A[0-9a-f]+\z/)
  end

  def valid?(_other), do: false

  @doc """
  Checks `bytes` against `expected`. Returns `:ok` on a match,
  `{:error, :malformed_digest}` when `expected` is not a well-formed
  digest (so a truncated or uppercase value is never silently accepted),
  and `{:error, {:digest_mismatch, actual}}` otherwise.
  """
  @spec verify(binary(), term()) :: :ok | {:error, :malformed_digest | {:digest_mismatch, t()}}
  def verify(bytes, expected) when is_binary(bytes) do
    if valid?(expected) do
      actual = sha256(bytes)
      if secure_equal?(actual, expected), do: :ok, else: {:error, {:digest_mismatch, actual}}
    else
      {:error, :malformed_digest}
    end
  end

  # Constant-time comparison; both sides are the same length once `valid?/1`
  # has passed, so a timing difference cannot leak how much of the digest
  # matched.
  defp secure_equal?(a, b), do: :crypto.hash_equals(a, b)
end
