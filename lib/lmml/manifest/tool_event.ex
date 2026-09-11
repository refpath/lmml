defmodule Lmml.Manifest.ToolEvent do
  @moduledoc """
  The `tool_events` member of a manifest: how a narrative records that a
  model asked for a tool call and what came back, without flattening the
  call's arguments or result into prose a reader could mistake for
  instructions.

  Each event is a JSON object:

  | key | required | meaning |
  |---|---|---|
  | `call_id` | yes | a stable identifier unique within the manifest |
  | `tool` | yes | the tool's name as the caller knows it |
  | `status` | yes | `"ok"` or `"error"` |
  | `arguments` | no | the name of the embed carrying the call's arguments |
  | `result` | no | the name of the embed carrying the tool's output |
  | `error_class` | no | a short machine-readable class when `status` is `"error"` |
  | `provenance` | no | an opaque object describing where the result came from |

  `arguments` and `result` name *embeds*, so their bytes are bound by the
  manifest's `entries` digests like any other content. A tool result is
  data the tool observed, never operator authority: a renderer that turns
  a narrative into messages keeps the `:tool` turn (see
  `Lmml.Narrative.Segment`) distinct from `:system` and `:user` ones, and
  a host deciding what a model may do reads the event, not the prose.
  """

  alias Lmml.Bundle
  alias Lmml.Manifest

  @statuses ["ok", "error"]

  @typedoc "One decoded tool event."
  @type t :: %{required(String.t()) => term()}

  @doc "The values `status` may take."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The manifest's `tool_events` list, or `[]` when there are none."
  @spec list(Manifest.t()) :: [t()]
  def list(%Manifest{data: data}) do
    case Map.get(data, "tool_events") do
      events when is_list(events) -> events
      _ -> []
    end
  end

  @doc """
  Builds a well-formed event. `opts` may carry `:arguments`, `:result`,
  `:error_class` and `:provenance`; `status` must be one of `statuses/0`.
  """
  @spec new(String.t(), String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(call_id, tool, status, opts \\ [])

  def new(call_id, tool, status, opts)
      when is_binary(call_id) and is_binary(tool) and status in @statuses do
    event =
      %{"call_id" => call_id, "tool" => tool, "status" => status}
      |> put_opt("arguments", Keyword.get(opts, :arguments))
      |> put_opt("result", Keyword.get(opts, :result))
      |> put_opt("error_class", Keyword.get(opts, :error_class))
      |> put_opt("provenance", Keyword.get(opts, :provenance))

    if well_formed?(event), do: {:ok, event}, else: {:error, {:malformed_tool_event, event}}
  end

  def new(_call_id, _tool, status, _opts), do: {:error, {:unknown_status, status}}

  defp put_opt(event, _key, nil), do: event
  defp put_opt(event, key, value), do: Map.put(event, key, value)

  @doc "True when `event` has the required members with the right shapes."
  @spec well_formed?(term()) :: boolean()
  def well_formed?(%{"call_id" => call_id, "tool" => tool, "status" => status} = event)
      when is_binary(call_id) and is_binary(tool) and status in @statuses do
    optional_string?(event, "arguments") and
      optional_string?(event, "result") and
      optional_string?(event, "error_class") and
      optional_map?(event, "provenance")
  end

  def well_formed?(_other), do: false

  defp optional_string?(event, key) do
    case Map.fetch(event, key) do
      :error -> true
      {:ok, value} -> is_binary(value)
    end
  end

  defp optional_map?(event, key) do
    case Map.fetch(event, key) do
      :error -> true
      {:ok, value} -> is_map(value)
    end
  end

  @doc false
  # The issues `Lmml.Manifest.verify/2` reports for `tool_events`: the member
  # must be a list of well-formed events with distinct call ids, and every
  # `arguments`/`result` name must be an entry the manifest binds.
  @spec issues(Manifest.t(), Bundle.t()) :: [Manifest.issue()]
  def issues(%Manifest{data: data} = manifest, _bundle) do
    case Map.fetch(data, "tool_events") do
      :error -> []
      {:ok, events} when is_list(events) -> event_issues(events, Manifest.entries(manifest))
      {:ok, other} -> [{:malformed_tool_events, other}]
    end
  end

  defp event_issues(events, entries) do
    {issues, _seen} =
      events
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {event, index}, {issues, seen} ->
        {found, seen} = one_event_issues(event, index, entries, seen)
        {Enum.reverse(found, issues), seen}
      end)

    Enum.reverse(issues)
  end

  defp one_event_issues(event, index, entries, seen) do
    if well_formed?(event) do
      call_id = event["call_id"]
      duplicate = if MapSet.member?(seen, call_id), do: [{:duplicate_call_id, call_id}], else: []

      {duplicate ++ missing_embeds(event, entries), MapSet.put(seen, call_id)}
    else
      {[{:malformed_tool_event, index}], seen}
    end
  end

  defp missing_embeds(event, entries) do
    for key <- ["arguments", "result"],
        {:ok, name} <- [Map.fetch(event, key)],
        not Map.has_key?(entries, name) do
      {:missing_tool_embed, {event["call_id"], name}}
    end
  end
end
