defmodule Singularity.Runtime.NoteSourcesTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.{Error, NoteAttachmentReference, NoteCitationReference, NoteSaveResult}
  alias Singularity.Domains.Notes.Command
  alias Singularity.Runtime.Notes.{Create, Merge, MutationFingerprint, Save}
  alias Singularity.Runtime.SessionContext

  @principal_id "00000000-0000-4000-8000-000000004401"
  @owner_id "00000000-0000-4000-8000-000000004402"
  @session_id "00000000-0000-4000-8000-000000004403"
  @note_id "00000000-0000-4000-8000-000000004404"
  @base_id "00000000-0000-4000-8000-000000004405"
  @version_id "00000000-0000-4000-8000-000000004406"
  @competing_id "00000000-0000-4000-8000-000000004407"
  @conflict_id "00000000-0000-4000-8000-000000004408"
  @mutation_id "00000000-0000-4000-8000-000000004409"
  @target_id "00000000-0000-4000-8000-000000004410"
  @target_version_id "00000000-0000-4000-8000-000000004411"
  @attachment_id "00000000-0000-4000-8000-000000004412"
  @citation_id "00000000-0000-4000-8000-000000004413"
  @secret :binary.copy(<<0xD7>>, 32)

  # These units verify Runtime/Domain composition, not live SQL authorization
  # or source proofs. Real canonical/authorization qualification is separate.
  defmodule Scope do
    import ExUnit.Assertions

    def with_shared_request(owner, _runtime, _session, requirement, callback) do
      refute Process.get(:runtime_note_sources_active_scope, false)
      send(owner, {:source_scope, requirement})
      Process.put(:runtime_note_sources_active_scope, true)

      try do
        callback.(:scoped_repo)
      after
        Process.delete(:runtime_note_sources_active_scope)
        send(owner, :source_scope_finished)
      end
    end
  end

  defmodule Fingerprint do
    def compute(owner, secret, %Command{} = command) do
      send(owner, {:source_fingerprint, secret, command})
      MutationFingerprint.compute(secret, command)
    end
  end

  defmodule Authorizer do
    import ExUnit.Assertions

    def check(%{owner: owner} = dependencies, repo, session, requirement) do
      assert Process.get(:runtime_note_sources_active_scope, false)
      send(owner, {:source_authorization, dependencies, repo, session, requirement})
      Process.get(:runtime_note_sources_authorizer_result, :ok)
    end
  end

  defmodule Repository do
    @behaviour Singularity.Domains.Notes.Repository

    for operation <- [:create, :save, :merge] do
      @impl true
      def unquote(operation)(context, intent) do
        send(self(), {:source_repository, unquote(operation), context, intent})

        case context do
          %{repo: :scoped_repo, authorize_new_sources: callback}
          when is_function(callback, 2) and map_size(context) == 2 ->
            result =
              case Process.get(:runtime_note_sources_new_members) do
                nil -> :ok
                members -> callback.(:scoped_repo, members)
              end

            case result do
              :ok -> Process.get(:runtime_note_sources_saved_result)
              other -> other
            end

          _invalid ->
            {:error, Error.new(:invalid)}
        end
      end
    end

    @impl true
    def tombstone(_repo, _intent), do: {:error, Error.new(:invalid)}
    @impl true
    def restore(_repo, _intent), do: {:error, Error.new(:invalid)}

    def get(repo, owner, note_id) do
      send(self(), {:source_reload, repo, owner, note_id})
      {:ok, Process.get(:runtime_note_sources_canonical)}
    end
  end

  # Unit-only membership for the fake canonical reload; no source proof claim.
  defmodule Membership do
    import ExUnit.Assertions

    def read_membership(context, resource, version) do
      assert Process.get(:runtime_note_sources_active_scope, false)

      assert context == %{
               repo: :scoped_repo,
               principal_id: "00000000-0000-4000-8000-000000004401",
               owner_scope_id: "00000000-0000-4000-8000-000000004402"
             }

      %{resource_id: ^resource, resource_version_id: ^version} =
        row = Process.get(:runtime_note_sources_canonical)

      assert row.vault_id == context.owner_scope_id
      {:ok, %{revision: row.revision, attachments: [], citations: []}}
    end
  end

  setup do
    {:ok, saved} =
      NoteSaveResult.saved(%{
        resource_id: @note_id,
        canonical_version_id: @version_id,
        submitted_version_id: @version_id
      })

    Process.put(:runtime_note_sources_saved_result, {:ok, saved})
    Process.put(:runtime_note_sources_canonical, canonical_row())
    :ok
  end

  for operation <- [:create, :save, :merge],
      mode <- [
        :omitted,
        :clear,
        :clear_attachments_only,
        :clear_citations_only,
        :attachments_only,
        :citations_only,
        :both
      ] do
    @operation operation
    @mode mode
    test "#{@operation} forwards #{@mode} source modes through exact Command, HMAC and opaque context" do
      fields = source_fields(@mode)
      attrs = Map.merge(mutation_attrs(@operation), fields)
      assert_success(@operation, run(@operation, attrs))

      assert_received {:source_fingerprint, @secret, %Command{} = command}
      assert command.operation == @operation

      assert {command.principal_id, command.vault_id, command.classification} ==
               {@principal_id, @owner_id, :private}

      default = if @operation == :create, do: [], else: :inherit
      expected_attachments = canonical_attachments(Map.get(fields, :attachments, default))
      expected_citations = canonical_citations(Map.get(fields, :citations, default))
      assert command.snapshot.attachments == expected_attachments
      assert command.snapshot.citations == expected_citations

      assert_received {:source_repository, @operation, context, intent}
      assert Enum.sort(Map.keys(context)) == [:authorize_new_sources, :repo]
      assert context.repo == :scoped_repo
      assert is_function(context.authorize_new_sources, 2)
      assert intent.snapshot == command.snapshot
      assert Enum.sort(Map.keys(intent)) == Enum.sort(intent_keys(@operation))
      assert intent.principal_id == @principal_id
      assert intent.vault_id == @owner_id
      assert intent.classification == :private
      assert intent.correlation_id == command.correlation_id
      assert {:ok, correlation} = Ecto.UUID.cast(command.correlation_id)
      assert correlation == command.correlation_id

      expected_term = literal_fingerprint_term(@operation, @mode)

      expected_hmac =
        :crypto.mac(
          :hmac,
          :sha256,
          @secret,
          :erlang.term_to_binary(expected_term, [:deterministic])
        )

      assert intent.request_fingerprint == expected_hmac
      assert_received {:source_reload, :scoped_repo, @owner_id, @note_id}
      assert_single_scope()
      refute_received {:source_authorization, _, _, _, _}
    end
  end

  test "string-key client sources normalize without entering command or intent as aliases" do
    for operation <- [:create, :save, :merge] do
      fields = %{
        "attachments" => [
          Map.new(attachment(:asset), fn {key, value} ->
            {Atom.to_string(key), value}
          end)
        ],
        "citations" => [
          Map.new(citation(), fn {key, value} ->
            {Atom.to_string(key), value}
          end)
        ]
      }

      attrs =
        mutation_attrs(operation)
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.merge(fields)

      assert_success(operation, run(operation, attrs))
      assert_received {:source_fingerprint, @secret, %Command{} = command}
      assert command.snapshot.attachments == canonical_attachments([attachment(:asset)])
      assert command.snapshot.citations == canonical_citations([citation()])
      assert_received {:source_repository, ^operation, _context, intent}
      assert intent.snapshot == command.snapshot
      assert Enum.sort(Map.keys(intent)) == Enum.sort(intent_keys(operation))
      assert_single_scope()
    end
  end

  for {kind_set, expected} <- [
        {:note_only, ["note.read"]},
        {:asset_document, ["asset.read"]},
        {:citation_only, ["asset.read"]},
        {:mixed, ["asset.read", "note.read"]}
      ] do
    @kind_set kind_set
    @expected_capabilities expected
    test "new #{@kind_set} members require sorted unique existing capabilities in the same scope" do
      Process.put(:runtime_note_sources_new_members, new_members(@kind_set))
      assert_success(:save, run(:save, mutation_attrs(:save)))
      assert_source_authorization(@expected_capabilities, session())
      assert_single_scope()
      assert_received {:source_reload, :scoped_repo, @owner_id, @note_id}
    end
  end

  test "an empty prepared new-member set skips the source authorizer" do
    Process.put(:runtime_note_sources_new_members, %{attachments: [], citations: []})
    Process.put(:runtime_note_sources_authorizer_result, {:error, Error.new(:forbidden)})
    assert_success(:save, run(:save, mutation_attrs(:save)))
    refute_received {:source_authorization, _, _, _, _}
    assert_single_scope()
  end

  test "source check binds the legacy principal epoch fallback and current vault epoch" do
    Process.put(:runtime_note_sources_new_members, new_members(:note_only))
    session = %{session() | principal_authorization_epoch: nil, authorization_epoch: 19}
    assert_success(:save, run(:save, mutation_attrs(:save), session))
    assert_source_authorization(["note.read"], session)
    assert_single_scope()
  end

  for operation <- [:create, :save, :merge] do
    @denied_operation operation
    test "#{@denied_operation} propagates ordinary source denial without reload or initial-denial marker" do
      denial = Error.new(:forbidden)
      Process.put(:runtime_note_sources_new_members, new_members(:mixed))
      Process.put(:runtime_note_sources_authorizer_result, {:error, denial})
      assert {:error, ^denial} = run(@denied_operation, mutation_attrs(@denied_operation))
      assert_source_authorization(["asset.read", "note.read"], session())
      refute_received {:source_reload, _, _, _}
      assert_single_scope()
    end
  end

  test "malformed source authorizer successes and errors cannot permit hydration" do
    Process.put(:runtime_note_sources_new_members, new_members(:note_only))
    invalid = Error.new(:invalid)

    for malformed <- [
          true,
          nil,
          {:ok, :authorized},
          {:error, :forbidden},
          {:error, %{code: :forbidden}},
          {:authorization_denial, Error.new(:forbidden)}
        ] do
      Process.put(:runtime_note_sources_authorizer_result, malformed)
      assert {:error, ^invalid} = run(:save, mutation_attrs(:save))
      assert_source_authorization(["note.read"], session())
      refute_received {:source_reload, _, _, _}
      assert_single_scope()
    end
  end

  test "client source requests cannot inject server context, authority, evidence or version fields" do
    for operation <- [:create, :save, :merge],
        {key, value} <- [
          authorize_new_sources: fn _, _ -> :ok end,
          repo: :scoped_repo,
          repository_context: %{},
          principal_id: @principal_id,
          vault_id: @owner_id,
          owner_scope_id: @owner_id,
          required_capabilities: ["asset.read"],
          classification: :private,
          resource_version_id: @version_id,
          version_id: @version_id,
          retained?: true,
          source_evidence: %{}
        ],
        alias_key <- [key, Atom.to_string(key)] do
      assert {:error, %Error{code: :invalid}} =
               run(operation, Map.put(mutation_attrs(operation), alias_key, value))
    end

    refute_received {:source_scope, _}
    refute_received {:source_fingerprint, _, _}
    refute_received {:source_repository, _, _, _}
    refute_received {:source_authorization, _, _, _, _}
  end

  test "nested owner, containing-version, retained evidence and inherit sentinels are rejected" do
    for operation <- [:create, :save, :merge],
        fields <- [
          %{attachments: :inherit},
          %{citations: :inherit},
          %{attachments: [Map.put(attachment(:asset), :owner_scope_id, @owner_id)]},
          %{attachments: [Map.put(attachment(:asset), :note_resource_version_id, @version_id)]},
          %{attachments: [Map.put(attachment(:asset), :retained?, true)]},
          %{citations: [Map.put(citation(), :source_evidence, %{})]},
          %{citations: [Map.put(citation(), :vault_id, @owner_id)]}
        ] do
      assert {:error, %Error{code: :invalid}} =
               run(operation, Map.merge(mutation_attrs(operation), fields))
    end

    refute_received {:source_fingerprint, _, _}
    refute_received {:source_repository, _, _, _}
    refute_received {:source_authorization, _, _, _, _}
  end

  defp runtime do
    %{
      fingerprint_secret: @secret,
      mutation_fingerprint: {Fingerprint, self()},
      note_repository: Repository,
      knowledge_link_repository: Membership,
      notes: Singularity.Domains.Notes,
      operation_scope: {Scope, self()},
      authorizer: Authorizer,
      authorization: %{owner: self()}
    }
  end

  defp session do
    %SessionContext{
      session_id: @session_id,
      principal_id: @principal_id,
      vault_id: @owner_id,
      expires_at: ~U[2026-12-31 00:00:00.000000Z],
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 3,
      unlocked?: true
    }
  end

  defp run(operation, attrs, session \\ session()) do
    case operation do
      :create -> Create.run(runtime(), session, attrs)
      :save -> Save.run(runtime(), session, @note_id, attrs)
      :merge -> Merge.run(runtime(), session, @note_id, attrs)
    end
  end

  defp mutation_attrs(operation) do
    common = %{mutation_id: @mutation_id, title: "Sources", markdown: "# Sources"}

    case operation do
      :create ->
        common

      :save ->
        Map.put(common, :base_version_id, @base_id)

      :merge ->
        Map.merge(common, %{
          conflict_id: @conflict_id,
          expected_current_version_id: @version_id,
          competing_version_id: @competing_id
        })
    end
  end

  defp source_fields(:omitted), do: %{}
  defp source_fields(:clear), do: %{attachments: [], citations: []}
  defp source_fields(:clear_attachments_only), do: %{attachments: []}
  defp source_fields(:clear_citations_only), do: %{citations: []}
  defp source_fields(:attachments_only), do: %{attachments: [attachment(:asset)]}
  defp source_fields(:citations_only), do: %{citations: [citation()]}
  defp source_fields(:both), do: %{attachments: [attachment(:asset)], citations: [citation()]}

  defp attachment(kind, id \\ @attachment_id) do
    %{
      attachment_id: id,
      target_resource_id: @target_id,
      target_resource_version_id: @target_version_id,
      target_kind: kind,
      role: :source,
      label: "Reference"
    }
  end

  defp citation do
    %{
      citation_id: @citation_id,
      source_resource_id: @competing_id,
      source_resource_version_id: @conflict_id,
      fragment_id: String.duplicate("c", 64),
      locator: %{version: 1, kind: "text", start_line: 1, end_line: 2}
    }
  end

  defp canonical_attachments(:inherit), do: :inherit

  defp canonical_attachments(refs),
    do:
      Enum.map(refs, fn ref ->
        {:ok, canonical} = NoteAttachmentReference.new(ref)
        canonical
      end)

  defp canonical_citations(:inherit), do: :inherit

  defp canonical_citations(refs),
    do:
      Enum.map(refs, fn ref ->
        {:ok, canonical} = NoteCitationReference.new(ref)
        canonical
      end)

  defp new_members(kind_set) do
    attachments =
      case kind_set do
        :note_only ->
          [attachment(:note)]

        :asset_document ->
          [
            attachment(:asset),
            Map.merge(
              attachment(:document, @citation_id),
              %{target_resource_id: @competing_id, target_resource_version_id: @conflict_id}
            )
          ]

        :citation_only ->
          []

        :mixed ->
          [
            attachment(:note),
            Map.merge(
              attachment(:asset, @citation_id),
              %{target_resource_id: @base_id, target_resource_version_id: @version_id}
            ),
            Map.merge(
              attachment(:document, @mutation_id),
              %{target_resource_id: @competing_id, target_resource_version_id: @conflict_id}
            )
          ]
      end

    citations =
      case kind_set do
        :citation_only -> [citation()]
        :mixed -> [citation()]
        _ -> []
      end

    %{attachments: canonical_attachments(attachments), citations: canonical_citations(citations)}
  end

  defp assert_source_authorization(capabilities, session) do
    dependencies = %{owner: self()}

    expected = %{
      vault_id: @owner_id,
      principal_authorization_epoch:
        session.principal_authorization_epoch || session.authorization_epoch,
      vault_authorization_epoch: session.vault_authorization_epoch,
      required_capabilities: capabilities,
      classification: :private,
      requires_unlocked?: true
    }

    assert_received {:source_authorization, ^dependencies, :scoped_repo, ^session, ^expected}
    refute_received {:source_authorization, _, _, _, _}
  end

  defp assert_single_scope do
    expected = %{
      vault_id: @owner_id,
      required_capability: "note.write",
      classification: :private,
      requires_unlocked?: true
    }

    assert_received {:source_scope, ^expected}
    refute_received {:source_scope, _}
    assert_received :source_scope_finished
    refute_received :source_scope_finished
    refute Process.get(:runtime_note_sources_active_scope, false)
  end

  defp assert_success(:create, result) do
    assert {:ok,
            %Singularity.Runtime.DTO.Note{resource_id: @note_id, resource_version_id: @version_id}} =
             result
  end

  defp assert_success(operation, result) when operation in [:save, :merge] do
    assert {:ok,
            %Singularity.Runtime.DTO.NoteSaveResult{
              outcome: :saved,
              canonical: %Singularity.Runtime.DTO.Note{
                resource_id: @note_id,
                resource_version_id: @version_id
              },
              submitted_version_id: @version_id,
              conflict_id: nil
            }} = result
  end

  defp intent_keys(operation) do
    common = [
      :mutation_id,
      :principal_id,
      :vault_id,
      :classification,
      :correlation_id,
      :snapshot,
      :request_fingerprint
    ]

    case operation do
      :create ->
        common

      :save ->
        common ++ [:resource_id, :base_version_id]

      :merge ->
        common ++
          [:resource_id, :conflict_id, :expected_current_version_id, :competing_version_id]
    end
  end

  defp literal_fingerprint_term(operation, mode) do
    term =
      case operation do
        :create ->
          {:note_mutation_v1, :create, @mutation_id, "Sources", "# Sources"}

        :save ->
          {:note_mutation_v1, :save, @mutation_id, @note_id, @base_id, "Sources", "# Sources"}

        :merge ->
          {:note_mutation_v1, :merge, @mutation_id, @note_id, @conflict_id, @version_id,
           @competing_id, "Sources", "# Sources"}
      end

    if mode == :omitted or
         (mode in [:clear, :clear_attachments_only, :clear_citations_only] and
            operation == :create) do
      term
    else
      default = if operation == :create, do: {:replace, []}, else: :inherit
      attachment = {@attachment_id, @target_id, @target_version_id, :asset, :source, "Reference"}

      locator =
        <<1::unsigned-big-integer-size(64), "1", 4::unsigned-big-integer-size(64), "text",
          1::unsigned-big-integer-size(64), "1", 1::unsigned-big-integer-size(64), "2">>

      citation = {@citation_id, @competing_id, @conflict_id, String.duplicate("c", 64), locator}

      attachments =
        cond do
          mode in [:clear, :clear_attachments_only] -> {:replace, []}
          mode in [:attachments_only, :both] -> {:replace, [attachment]}
          true -> default
        end

      citations =
        cond do
          mode in [:clear, :clear_citations_only] -> {:replace, []}
          mode in [:citations_only, :both] -> {:replace, [citation]}
          true -> default
        end

      term
      |> put_elem(0, :note_mutation_v2)
      |> :erlang.append_element(attachments)
      |> :erlang.append_element(citations)
    end
  end

  defp canonical_row do
    %{
      resource_id: @note_id,
      resource_version_id: @version_id,
      vault_id: @owner_id,
      classification: :private,
      title: "Canonical",
      markdown: "# Canonical",
      revision: 1,
      updated_at: ~U[2026-10-11 00:00:00.000000Z],
      deleted_at: nil,
      deleted?: false,
      created_by_principal_id: @principal_id,
      inserted_at: ~U[2026-10-11 00:00:00.000000Z],
      parent_version_id: @base_id,
      merge_parent_version_id: nil,
      canonical?: true,
      open_conflict_count: 0
    }
  end
end
