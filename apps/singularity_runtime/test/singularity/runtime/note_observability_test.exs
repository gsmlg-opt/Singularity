defmodule Singularity.Runtime.NoteObservabilityTest do
  use ExUnit.Case, async: true

  alias Singularity.Runtime.DTO.Note
  alias Singularity.Runtime.DTO.NoteExport
  alias Singularity.Runtime.Observability.Redactor
  alias Singularity.Runtime.Observability.Telemetry

  @resource_id "00000000-0000-4000-8000-000000002101"
  @version_id "00000000-0000-4000-8000-000000002102"
  @canaries %{
    mutation_fingerprint_secret: "CANARY_MUTATION_SECRET_f901",
    title: "CANARY_TITLE_01aa",
    note_title: "CANARY_NOTE_TITLE_01ab",
    markdown: "CANARY_MARKDOWN_31cd",
    raw_search_query: "CANARY_RAW_QUERY_51ef",
    rendered_html: "CANARY_RENDERED_HTML_71aa",
    export_bytes: "CANARY_EXPORT_BYTES_91bb"
  }

  test "supported structured logs and telemetry redact every note content category" do
    expected = Map.new(@canaries, fn {key, _value} -> {key, "[REDACTED]"} end)
    assert Redactor.redact(@canaries) == expected

    event = [:singularity, :note, :mutation, :stop]
    handler_id = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn name, measurements, metadata, _config ->
          send(owner, {:telemetry, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Telemetry.execute([:note, :mutation, :stop], %{count: 1}, @canaries)
    assert_receive {:telemetry, ^event, %{count: 1}, ^expected}

    for canary <- Map.values(@canaries) do
      refute inspect(expected, limit: :infinity, printable_limit: :infinity) =~ canary
    end
  end

  test "authorized Note and NoteExport DTOs retain exact content while identifier effects do not" do
    title = @canaries.note_title
    markdown = @canaries.markdown

    assert {:ok, note} =
             Note.new(%{
               resource_id: @resource_id,
               resource_version_id: @version_id,
               title: title,
               revision: 0,
               display_version: 1,
               updated_at: ~U[2026-08-18 09:00:00.000000Z],
               deleted?: false,
               open_conflict_count: 0,
               markdown: markdown
             })

    assert {:ok, export} =
             NoteExport.new(%{
               resource_id: @resource_id,
               resource_version_id: @version_id,
               filename: "note.md",
               media_type: "text/markdown; charset=utf-8",
               markdown: @canaries.export_bytes
             })

    assert note.title == title
    assert note.markdown == markdown
    assert export.markdown == @canaries.export_bytes

    identifier_only = %{
      event_type: "note.current_changed",
      payload: %{"resource_id" => @resource_id},
      receipt: %{resource_id: @resource_id, version_id: @version_id}
    }

    for canary <- Map.values(@canaries) do
      refute inspect(identifier_only, limit: :infinity, printable_limit: :infinity) =~ canary
    end
  end
end
