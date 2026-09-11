defmodule Mix.Tasks.Lmml.Verify do
  use Mix.Task

  @shortdoc "Verifies a bundle's manifest digests and archive safety offline"

  @moduledoc """
  Opens a bundle under the archive policy, cross-checks its narrative
  against its entries (`Lmml.Bundle.validate/1`) and verifies every embed
  against the digests its manifest declares (`Lmml.Manifest.verify/1`),
  printing every issue found.

      mix lmml.verify SOURCE [--max-entries N] [--max-entry-bytes N]
                             [--max-total-bytes N] [--max-compression-ratio N]
                             [--allow-missing-manifest]

  Nothing here touches the network: a bundle either verifies from its own
  bytes or it does not. Exits with a non-zero status (via `Mix.raise/1`)
  when the archive is refused or any issue is found, so this can run as a
  CI check on a bundle before anything consumes it.

  Options override the corresponding `Lmml.Archive.Policy` limit. With
  `--allow-missing-manifest`, a bundle that carries no manifest at all
  passes on structural validation alone (it is reported, not failed);
  without it, a missing manifest is a failure, since there is nothing to
  verify content against.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          max_entries: :integer,
          max_entry_bytes: :integer,
          max_total_bytes: :integer,
          max_compression_ratio: :integer,
          allow_missing_manifest: :boolean
        ]
      )

    case {positional, invalid} do
      {[source], []} -> do_verify(source, opts)
      _ -> Mix.raise("Usage: mix lmml.verify SOURCE [--max-entries N] [--allow-missing-manifest]")
    end
  end

  defp do_verify(source, opts) do
    {allow_missing, policy_opts} = Keyword.pop(opts, :allow_missing_manifest, false)

    bundle =
      case Lmml.Bundle.open(source, policy: policy_opts) do
        {:ok, bundle} -> bundle
        {:error, reason} -> Mix.raise("#{source}: refused: #{format_reason(reason)}")
      end

    issues = structural_issues(source, bundle) ++ manifest_issues(source, bundle, allow_missing)

    case issues do
      [] ->
        Mix.shell().info("#{source}: OK")

      _ ->
        Enum.each(issues, &Mix.shell().error("#{source}: " <> &1))
        Mix.raise("#{source}: #{length(issues)} issue(s) found")
    end
  end

  defp structural_issues(_source, bundle) do
    case Lmml.Bundle.validate(bundle) do
      :ok -> []
      {:error, issues} -> Enum.map(issues, &format_issue/1)
    end
  end

  defp manifest_issues(source, bundle, allow_missing) do
    case Lmml.Manifest.verify(bundle) do
      :ok ->
        []

      {:error, [:no_manifest]} when allow_missing ->
        Mix.shell().info("#{source}: no manifest; content digests not verified")
        []

      {:error, issues} ->
        Enum.map(issues, &format_issue/1)
    end
  end

  defp format_issue(:no_manifest), do: "no manifest.json to verify content against"
  defp format_issue(:unversioned_manifest), do: "manifest declares no lmml_version"
  defp format_issue({:missing_reference, name}), do: "missing reference: @#{name}"
  defp format_issue({:orphaned_entry, name}), do: "orphaned zip entry: #{name}"
  defp format_issue({:malformed_embed_name, name}), do: "malformed embed name: #{name}"
  defp format_issue({:conflicting_embed, name}), do: "conflicting embed: #{name}"
  defp format_issue({:missing_entry, name}), do: "manifest has no entry for embed #{name}"

  defp format_issue({:unknown_entry, name}),
    do: "manifest entry names nothing in the bundle: #{name}"

  defp format_issue({:digest_mismatch, name}), do: "digest mismatch: #{name}"
  defp format_issue({:size_mismatch, name}), do: "size mismatch: #{name}"
  defp format_issue({:unresolvable_embed, name}), do: "unresolvable embed: #{name}"
  defp format_issue({:unknown_trust, name}), do: "unknown trust value on entry #{name}"
  defp format_issue({:malformed_entry, name}), do: "malformed manifest entry: #{name}"
  defp format_issue({:malformed_entries, _}), do: "manifest entries is not an object"
  defp format_issue({:malformed_extensions, _}), do: "manifest extensions is malformed"
  defp format_issue({:malformed_tool_events, _}), do: "manifest tool_events is not a list"
  defp format_issue({:malformed_tool_event, index}), do: "malformed tool event at index #{index}"
  defp format_issue({:duplicate_call_id, id}), do: "duplicate tool call id: #{id}"

  defp format_issue({:missing_tool_embed, {call_id, name}}),
    do: "tool event #{call_id} names unbound embed #{name}"

  defp format_issue({:invalid_manifest, reason}), do: "invalid manifest: #{format_reason(reason)}"
  defp format_issue(other), do: inspect(other)

  defp format_reason({tag, detail}) when is_atom(tag), do: "#{tag}: #{inspect(detail)}"
  defp format_reason(other), do: inspect(other)
end
