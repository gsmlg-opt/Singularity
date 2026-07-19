defmodule Singularity.Ingest.UploadCheckpointTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Ingest.UploadCheckpoint

  test "advances only through durable upload checkpoints" do
    checkpoint = UploadCheckpoint.new("grant-1")

    assert %UploadCheckpoint{state: :granted, revision: 0} = checkpoint
    assert {:ok, consumed} = UploadCheckpoint.advance(checkpoint, :consumed)
    assert {:ok, open} = UploadCheckpoint.advance(consumed, :open)
    assert {:ok, sealed} = UploadCheckpoint.advance(open, :sealed)
    assert {:ok, uploaded} = UploadCheckpoint.advance(sealed, :uploaded)
    assert uploaded.revision == 4
    assert UploadCheckpoint.terminal?(uploaded)
  end

  test "abandonment is terminal and idempotent" do
    checkpoint = UploadCheckpoint.new("grant-1")
    assert {:ok, abandoned} = UploadCheckpoint.abandon(checkpoint, :owner_exit)
    assert {:ok, ^abandoned} = UploadCheckpoint.abandon(abandoned, :owner_exit)
    assert UploadCheckpoint.terminal?(abandoned)

    assert {:error, %Error{code: :conflict}} =
             UploadCheckpoint.advance(abandoned, :consumed)
  end

  test "rejects skipped and stale transitions" do
    checkpoint = UploadCheckpoint.new("grant-1")

    assert {:error, %Error{code: :conflict}} =
             UploadCheckpoint.advance(checkpoint, :sealed)

    assert {:error, %Error{code: :invalid}} =
             UploadCheckpoint.advance(checkpoint, :unknown)
  end
end
