defmodule Lmml.Canonical do
  @moduledoc """
  Canonical JSON: one byte sequence per logical value, so a digest or a
  signature over a JSON document is meaningful.

  `encode/1` produces JSON with object members sorted by the UTF-8 bytes
  of their keys, no insignificant whitespace, strings escaped by OTP's
  `:json` encoder and numbers in their shortest round-trip form. Two maps
  with the same members always encode to identical bytes regardless of
  how they were built, which is what `Lmml.Manifest` relies on to bind a
  manifest to a digest.

  Only plain JSON-shaped terms are accepted: maps with string or atom
  keys, lists, binaries, integers, floats, booleans and `nil`. Anything
  else (a tuple, a struct, a PID) is rejected with
  `{:error, {:not_json, term}}` rather than encoded in a form another
  implementation could not reproduce.
  """

  @typedoc "A JSON-shaped Elixir term."
  @type json ::
          nil
          | boolean()
          | number()
          | binary()
          | [json()]
          | %{optional(binary() | atom()) => json()}

  @doc """
  Encodes `term` as canonical JSON.

  Returns `{:error, {:not_json, offending}}` when `term` (or anything
  nested in it) is not a JSON-shaped value, and `{:error, {:duplicate_key,
  key}}` when a map holds both an atom and a string spelling of the same
  key, since the two would collide once canonicalized.
  """
  @spec encode(json()) :: {:ok, binary()} | {:error, term()}
  def encode(term) do
    with :ok <- validate(term) do
      {:ok, term |> :json.encode(&encoder/2) |> IO.iodata_to_binary()}
    end
  end

  @doc "Same as `encode/1`, but raises `ArgumentError` on failure."
  @spec encode!(json()) :: binary()
  def encode!(term) do
    case encode(term) do
      {:ok, binary} -> binary
      {:error, reason} -> raise ArgumentError, "cannot canonicalize: #{inspect(reason)}"
    end
  end

  @doc """
  Decodes JSON text into plain maps, lists, binaries, numbers, booleans
  and `nil`. This is `:json.decode/1` wrapped in a tagged tuple; decoding
  is not canonicalization -- re-encode the result with `encode/1` to
  obtain canonical bytes.
  """
  @spec decode(binary()) :: {:ok, json()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case :json.decode(binary, :ok, %{null: nil}) do
      {term, :ok, ""} -> {:ok, term}
      {_term, :ok, rest} -> {:error, {:invalid_json, {:trailing_data, rest}}}
    end
  rescue
    e -> {:error, {:invalid_json, Exception.message(e)}}
  catch
    _, reason -> {:error, {:invalid_json, inspect(reason)}}
  end

  # ---------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------

  # Erlang's encoder spells JSON null as the atom `null`; Elixir spells it `nil`.
  defp encoder(nil, _encode), do: "null"

  defp encoder(map, encode) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key_to_string(key), value} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> :json.encode_key_value_list(encode)
  end

  defp encoder(other, encode), do: :json.encode_value(other, encode)

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)

  # ---------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------

  defp validate(nil), do: :ok
  defp validate(value) when is_boolean(value), do: :ok
  defp validate(value) when is_integer(value), do: :ok
  defp validate(value) when is_binary(value), do: :ok

  defp validate(value) when is_float(value) do
    # Infinity and NaN are not representable as floats on the BEAM, so any
    # float here has a finite shortest representation.
    :ok
  end

  defp validate(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case validate(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate(%_struct{} = struct), do: {:error, {:not_json, struct}}

  defp validate(map) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {key, value}, {:ok, seen} ->
      with {:ok, string_key} <- validate_key(key),
           :ok <- unique_key(string_key, seen),
           :ok <- validate(value) do
        {:cont, {:ok, MapSet.put(seen, string_key)}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      error -> error
    end
  end

  defp validate(other), do: {:error, {:not_json, other}}

  defp validate_key(key) when is_binary(key), do: {:ok, key}
  defp validate_key(key) when is_atom(key) and not is_nil(key), do: {:ok, Atom.to_string(key)}
  defp validate_key(key), do: {:error, {:not_json, key}}

  defp unique_key(key, seen) do
    if MapSet.member?(seen, key), do: {:error, {:duplicate_key, key}}, else: :ok
  end
end
