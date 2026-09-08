defmodule Singularity.Storage.Documents.PrepareSourceTest do
  use Singularity.Storage.DataCase, async: false
  @moduletag :integration
  alias Singularity.Core.Error
  alias Singularity.Storage.{Fixtures, MigrationRepo, ScopedRepo}
  alias Singularity.Storage.Documents.PrepareSource
  alias Singularity.Storage.Postgres.DocumentSourceRepository

  setup do
    %{one: raw, two: other} = Fixtures.two_vaults!()

    fixture =
      Map.new(raw, fn {k, v} ->
        {k, if(String.ends_with?(Atom.to_string(k), "_id"), do: Ecto.UUID.load!(v), else: v)}
      end)

    object_id = Ecto.UUID.generate()
    domain_id = Ecto.UUID.generate()
    version_id = Ecto.UUID.generate()
    vault_version_id = Ecto.UUID.generate()

    Fixtures.with_owner(fn ->
      for {sql, params} <- [
            {"INSERT INTO core.vault_key_versions (id,vault_id,generation,state,algorithm,activated_at) VALUES ($1,$2,1,'active','aes_256_gcm',CURRENT_TIMESTAMP)",
             [vault_version_id, fixture.vault_id]},
            {"INSERT INTO core.key_domains (id,vault_id,classification,kind,state) VALUES ($1,$2,'private','content','active')",
             [domain_id, fixture.vault_id]},
            {"INSERT INTO core.domain_key_versions (id,vault_id,key_domain_id,vault_key_version_id,generation,state,algorithm,wrapped_key) VALUES ($1,$2,$3,$4,3,'active','aes_256_gcm',decode(repeat('01',60),'hex'))",
             [version_id, fixture.vault_id, domain_id, vault_version_id]},
            {"INSERT INTO content.asset_objects (id,vault_id,key_domain_id,classification,lookup_digest,ciphertext_hash,plaintext_byte_size,ciphertext_byte_size,storage_ref,format_version,lifecycle,lifecycle_revision) VALUES ($1,$2,$3,'private',decode(repeat('01',32),'hex'),decode(repeat('02',32),'hex'),12,170,'opaque-test-object',1,'available',1)",
             [object_id, fixture.vault_id, domain_id]},
            {"INSERT INTO content.asset_key_envelopes (id,vault_id,asset_object_id,domain_key_version_id,key_domain_id,classification,algorithm,key_generation,wrapped_dek) VALUES ($1,$2,$3,$4,$5,'private','aes_256_gcm',3,decode(repeat('03',60),'hex'))",
             [Ecto.UUID.generate(), fixture.vault_id, object_id, version_id, domain_id]},
            {"UPDATE content.assets SET state='available',state_revision=3,asset_object_id=$2 WHERE id=$1",
             [fixture.asset_id, object_id]},
            {"INSERT INTO content.resource_assets (resource_version_id,asset_id,vault_id,classification) VALUES ($1,$2,$3,'private')",
             [fixture.resource_version_id, fixture.asset_id, fixture.vault_id]},
            {"INSERT INTO content.asset_metadata (id,asset_id,resource_version_id,vault_id,classification,projection_version,original_filename,declared_media_type,detected_media_type,plaintext_byte_size,extraction_state,completed_at) VALUES ($1,$2,$3,$4,'private',1,'test.pdf','application/pdf','application/pdf',12,'completed',CURRENT_TIMESTAMP)",
             [
               Ecto.UUID.generate(),
               fixture.asset_id,
               fixture.resource_version_id,
               fixture.vault_id
             ]}
          ] do
        query!(MigrationRepo, sql, Enum.map(params, &Ecto.UUID.dump!/1))
      end
    end)

    context = %{principal_id: fixture.principal_id, owner_scope_id: fixture.vault_id}
    {:ok, fixture: fixture, context: context, other: other, object_id: object_id}
  end

  test "missing digest dependency fails before even calling a repo" do
    assert {:error, %Error{code: :storage_unavailable, message: nil, details: %{}}} =
             PrepareSource.prepare(%{repo: NoSuchRepo}, %{})
  end

  test "injected contract digest runs outside transaction and produces only immutable evidence",
       c do
    digest = fn context, binding ->
      refute RequestRepo.in_transaction?()
      assert context == c.context
      assert binding.object_generation == 3
      assert binding.resource_version_id == c.fixture.resource_version_id
      {:ok, %{sha256: :binary.copy(<<1>>, 32), byte_size: 12}}
    end

    assert {:ok, prepared} = prepare(c, digest)

    assert %Singularity.Core.DocumentSource{byte_size: 12, media_type: "application/pdf"} =
             prepared.source

    assert {:ok, source} =
             scoped(c, fn repo ->
               DocumentSourceRepository.revalidate(repo, c.context, prepared)
             end)

    assert source == prepared.source
    refute inspect(prepared) =~ "opaque-test-object"
  end

  test "size and media limits reject before callback", c do
    mutate(
      "UPDATE content.asset_objects SET plaintext_byte_size=67108865 WHERE id=$1",
      c.object_id
    )

    mutate(
      "UPDATE content.asset_metadata SET plaintext_byte_size=67108865 WHERE asset_id=$1",
      c.fixture.asset_id
    )

    assert {:error, %Error{code: :upload_too_large}} =
             prepare(c, fn _, _ -> flunk("digest invoked") end)

    mutate("UPDATE content.asset_objects SET plaintext_byte_size=12 WHERE id=$1", c.object_id)

    mutate(
      "UPDATE content.asset_metadata SET plaintext_byte_size=12,detected_media_type='image/png' WHERE asset_id=$1",
      c.fixture.asset_id
    )

    assert {:error, %Error{code: :unsupported_media_type}} =
             prepare(c, fn _, _ -> flunk("digest invoked") end)
  end

  test "wrong owner or principal receives no source", c do
    for context <- [
          Map.put(c.context, :owner_scope_id, Ecto.UUID.load!(c.other.vault_id)),
          Map.put(c.context, :principal_id, Ecto.UUID.load!(c.other.principal_id))
        ] do
      assert {:error, %Error{code: :not_found}} =
               prepare(%{c | context: context}, fn _, _ -> flunk("digest invoked") end)
    end
  end

  test "released association prevents preparation and invalidates prepared evidence", c do
    {:ok, prepared} = prepare(c)

    mutate(
      "UPDATE content.resource_assets SET released_at=CURRENT_TIMESTAMP WHERE asset_id=$1",
      c.fixture.asset_id
    )

    assert {:error, %Error{code: :not_found}} = prepare(c)

    assert {:error, %Error{}} =
             scoped(c, &DocumentSourceRepository.revalidate(&1, c.context, prepared))
  end

  test "generation change invalidates prepared evidence", c do
    {:ok, prepared} = prepare(c)

    mutate(
      "UPDATE content.asset_key_envelopes SET key_generation=4 WHERE asset_object_id=$1",
      c.object_id
    )

    assert {:error, %Error{code: :conflict}} =
             scoped(c, &DocumentSourceRepository.revalidate(&1, c.context, prepared))
  end

  test "missing live association and mismatched metadata fail before digest", c do
    mutate(
      "UPDATE content.asset_metadata SET plaintext_byte_size=13 WHERE asset_id=$1",
      c.fixture.asset_id
    )

    assert {:error, %Error{code: :not_found}} = prepare(c, fn _, _ -> flunk("digest invoked") end)

    mutate(
      "UPDATE content.asset_metadata SET plaintext_byte_size=12 WHERE asset_id=$1",
      c.fixture.asset_id
    )

    mutate("DELETE FROM content.resource_assets WHERE asset_id=$1", c.fixture.asset_id)
    assert {:error, %Error{code: :not_found}} = prepare(c, fn _, _ -> flunk("digest invoked") end)
  end

  test "manufactured source identity cannot pass revalidation", c do
    {:ok, prepared} = prepare(c)
    prepared = %{prepared | source: %{prepared.source | resource_id: Ecto.UUID.generate()}}

    assert {:error, %Error{code: :conflict}} =
             scoped(c, &DocumentSourceRepository.revalidate(&1, c.context, prepared))
  end

  test "deleted state and tombstones prevent acceptance", c do
    {:ok, prepared} = prepare(c)

    mutate(
      "UPDATE content.assets SET state='pending_delete',state_revision=4 WHERE id=$1",
      c.fixture.asset_id
    )

    assert {:error, %Error{}} =
             scoped(c, &DocumentSourceRepository.revalidate(&1, c.context, prepared))

    mutate(
      "UPDATE content.assets SET state='available',state_revision=5 WHERE id=$1",
      c.fixture.asset_id
    )

    Fixtures.with_owner(fn ->
      query!(
        MigrationRepo,
        "INSERT INTO content.tombstones (id,vault_id,asset_id,principal_id,classification,reason,retention_metadata,deleted_at) VALUES ($1,$2,$3,$4,'private','test','{}',CURRENT_TIMESTAMP)",
        Enum.map(
          [Ecto.UUID.generate(), c.fixture.vault_id, c.fixture.asset_id, c.fixture.principal_id],
          &Ecto.UUID.dump!/1
        )
      )
    end)

    assert {:error, %Error{code: :not_found}} = prepare(c)
  end

  test "transaction and context mismatches fail closed", c do
    {:ok, prepared} = prepare(c)
    assert {:error, %Error{code: :invalid}} = scoped(c, fn _ -> prepare(c) end)

    assert {:error, %Error{code: :invalid}} =
             DocumentSourceRepository.revalidate(RequestRepo, c.context, prepared)

    wrong = %{c.context | principal_id: Ecto.UUID.load!(c.other.principal_id)}

    assert {:error, %Error{code: :forbidden}} =
             scoped(c, &DocumentSourceRepository.revalidate(&1, wrong, prepared))
  end

  test "digest failures never expose content or exception details", c do
    for callback <- [
          fn _, _ -> raise "secret plaintext" end,
          fn _, _ ->
            {:error, Error.new(:integrity_failure, message: "secret", details: %{key: "secret"})}
          end,
          fn _, _ -> {:ok, %{sha256: <<1>>, byte_size: 12}} end,
          fn _, _ -> {:ok, %{sha256: :binary.copy(<<1>>, 32), byte_size: 11}} end
        ] do
      assert {:error, %Error{message: nil, details: details}} = prepare(c, callback)
      assert details == %{}
    end
  end

  defp prepare(
         c,
         digest \\ fn _, _ -> {:ok, %{sha256: :binary.copy(<<1>>, 32), byte_size: 12}} end
       ),
       do:
         PrepareSource.prepare(%{repo: RequestRepo, digest_operation: digest}, %{
           context: c.context,
           asset_id: c.fixture.asset_id
         })

  defp scoped(c, fun),
    do:
      ScopedRepo.transact(
        RequestRepo,
        %{principal_id: c.context.principal_id, vault_id: c.context.owner_scope_id},
        fun
      )

  defp mutate(sql, id),
    do: Fixtures.with_owner(fn -> query!(MigrationRepo, sql, [Ecto.UUID.dump!(id)]) end)
end
