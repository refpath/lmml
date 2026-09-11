defmodule Lmml.ConformanceTest do
  @moduledoc """
  Fixture-driven conformance: every narrative under `test/fixtures/conformance`
  is parsed, validated and (where a `.digest` sidecar exists) checked against
  its golden manifest digest, so a change to canonical encoding or to the
  digest recipe is caught here before it ships. Round-trip invariants use
  seeded random bundles rather than a property-testing dependency.
  """
  use ExUnit.Case, async: true

  alias Lmml.Bundle
  alias Lmml.Manifest
  alias Lmml.Pack

  @fixtures Path.expand("../fixtures/conformance", __DIR__)

  describe "valid fixtures" do
    for path <- Path.wildcard(Path.join(@fixtures, "valid/*.lmml")) do
      @path path
      test "#{Path.basename(path)} parses, validates and matches its golden manifest digest" do
        {:ok, bundle} = Bundle.open(@path)
        assert :ok = Bundle.validate(bundle)

        {:ok, manifest} = Manifest.build(bundle)
        {:ok, digest} = Manifest.digest(manifest)

        golden = String.trim(File.read!(@path <> ".digest"))
        assert digest == golden, "manifest digest for #{Path.basename(@path)} drifted from golden"
      end
    end
  end

  describe "invalid fixtures" do
    for path <- Path.wildcard(Path.join(@fixtures, "invalid/*.lmml")) do
      @path path
      test "#{Path.basename(path)} is rejected as its sidecar expects" do
        expected = @path |> Kernel.<>(".expected") |> File.read!() |> String.trim()
        {:ok, bundle} = Bundle.open(@path)

        outcome =
          case {Bundle.validate(bundle), Manifest.verify(bundle)} do
            {{:error, issues}, _} -> issues |> hd() |> elem(0) |> Atom.to_string()
            {:ok, {:error, [issue | _]}} -> issue |> issue_tag() |> Atom.to_string()
            {:ok, :ok} -> "ok"
          end

        assert outcome == expected
      end
    end
  end

  defp issue_tag(issue) when is_atom(issue), do: issue
  defp issue_tag(issue) when is_tuple(issue), do: elem(issue, 0)

  describe "round-trip invariants" do
    test "pack -> verify -> inline -> pack is stable at the logical level" do
      for seed <- 1..25 do
        :rand.seed(:exsss, {seed, seed, seed})
        {narrative, entries} = random_text_bundle()

        {:ok, text} = Bundle.new_text("case-#{seed}", narrative)
        {:ok, packed} = Pack.pack(text)
        {:ok, manifest} = Manifest.build(packed)
        {:ok, with_manifest} = Manifest.attach(packed, manifest)
        assert :ok = Manifest.verify(with_manifest)

        {:ok, bytes} = Bundle.to_binary(with_manifest)
        {:ok, reloaded} = Bundle.load("case-#{seed}.lmmlz", bytes)
        assert :ok = Manifest.verify(reloaded)

        {:ok, inlined} = Pack.inline(reloaded)
        {:ok, repacked} = Pack.pack(inlined)
        {:ok, manifest_again} = Manifest.build(repacked)

        # Prose identity is not part of the contract (inlining de-sigils
        # in-prose references); the logical model -- every embed's name and
        # bytes -- is.
        assert Manifest.entries(manifest_again) == Manifest.entries(manifest),
               "entries changed across the round trip for seed #{seed}: #{inspect(entries)}"

        assert Map.keys(repacked.entries) |> Enum.sort() ==
                 Map.keys(packed.entries) |> Enum.sort()

        assert repacked.entries == packed.entries
      end
    end

    test "the manifest digest is invariant under entry insertion order and formatting" do
      for seed <- 1..25 do
        :rand.seed(:exsss, {seed, seed, seed})
        {narrative, entries} = random_text_bundle()
        {:ok, bundle} = Bundle.new_text("case", narrative)
        {:ok, manifest} = Manifest.build(bundle)

        shuffled = %Manifest{data: manifest.data |> Map.to_list() |> Enum.shuffle() |> Map.new()}
        assert Manifest.digest(shuffled) == Manifest.digest(manifest)

        {:ok, encoded} = Manifest.encode(manifest)
        pretty = encoded |> String.replace(",", ",\n") |> String.replace(":", ": ")
        {:ok, decoded} = Lmml.Canonical.decode(pretty)
        assert Manifest.digest(%Manifest{data: decoded}) == Manifest.digest(manifest)

        _ = entries
      end
    end
  end

  # A random bare narrative with between one and six inline text embeds whose
  # names are safe, NFC and distinct after case folding.
  defp random_text_bundle do
    count = :rand.uniform(6)

    entries =
      for i <- 1..count, into: %{} do
        {"embed-#{i}-#{:rand.uniform(1000)}.txt", random_text()}
      end

    blocks = Enum.map_join(entries, "\n\n", fn {name, body} -> "@@@#{name}\n#{body}\n@@@" end)

    prose =
      "Random narrative #{:rand.uniform(10_000)} mentioning " <>
        Enum.join(Map.keys(entries), ", ") <> ".\n\n"

    {prose <> blocks, entries}
  end

  defp random_text do
    length = :rand.uniform(64)
    for _ <- 1..length, into: "", do: <<Enum.random(Enum.concat([?a..?z, [?\s, ?., ?-]]))>>
  end
end
