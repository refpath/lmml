defmodule Lmml.CanonicalTest do
  use ExUnit.Case, async: true

  alias Lmml.Canonical

  describe "encode/1" do
    test "object members are sorted by key bytes with no whitespace" do
      assert {:ok, ~s({"a":1,"b":[true,null,"x"],"z":{"m":2,"n":3}})} =
               Canonical.encode(%{
                 "z" => %{"n" => 3, "m" => 2},
                 "b" => [true, nil, "x"],
                 "a" => 1
               })
    end

    test "the same members encode identically however the map was built" do
      one = Map.new([{"k1", 1}, {"k2", 2}, {"k3", 3}])
      two = %{"k3" => 3} |> Map.put("k1", 1) |> Map.put("k2", 2)

      assert Canonical.encode(one) == Canonical.encode(two)
    end

    test "atom keys are encoded as strings and sorted with the rest" do
      assert {:ok, ~s({"a":1,"b":2})} = Canonical.encode(%{"a" => 1, b: 2})
    end

    test "keys sort by UTF-8 bytes, not by locale" do
      assert {:ok, ~s({"B":1,"a":2,"é":3})} = Canonical.encode(%{"a" => 2, "B" => 1, "é" => 3})
    end

    test "strings are escaped and numbers use their shortest form" do
      assert {:ok, ~s(["a\\"b",1,1.5,-0.25])} = Canonical.encode(["a\"b", 1, 1.5, -0.25])
    end

    test "an atom and string spelling of the same key is a collision, not a silent overwrite" do
      assert {:error, {:duplicate_key, "a"}} = Canonical.encode(%{"a" => 2, a: 1})
    end

    test "a term that is not JSON-shaped is rejected" do
      assert {:error, {:not_json, {:tuple, 1}}} = Canonical.encode(%{"a" => {:tuple, 1}})
      assert {:error, {:not_json, %URI{}}} = Canonical.encode([%URI{}])
      assert {:error, {:not_json, 1}} = Canonical.encode(%{1 => "numeric key"})
    end

    test "encode!/1 raises with the reason" do
      assert_raise ArgumentError, ~r/not_json/, fn -> Canonical.encode!(self()) end
    end
  end

  describe "decode/1" do
    test "round-trips canonical output" do
      term = %{"a" => [1, 2.5, "x", nil, true], "b" => %{"c" => "d"}}
      {:ok, encoded} = Canonical.encode(term)

      assert {:ok, ^term} = Canonical.decode(encoded)
    end

    test "invalid JSON is a clean error" do
      assert {:error, {:invalid_json, _}} = Canonical.decode("{")
    end

    test "trailing bytes after the document are rejected" do
      assert {:error, {:invalid_json, {:trailing_data, "x"}}} = Canonical.decode("{}x")
    end

    test "JSON null decodes to nil" do
      assert {:ok, %{"a" => nil}} = Canonical.decode(~s({"a":null}))
    end
  end
end
