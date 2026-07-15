defmodule Singularity.Store.FakeKnowledgeStoreContractTest do
  use Singularity.Core.TestSupport.Contracts.KnowledgeStoreContract,
    adapter: Singularity.Core.TestSupport.Fake.KnowledgeStore,
    start_context: {Singularity.Core.TestSupport.Fake.KnowledgeStore, :start_link, [[]]}
end

defmodule Singularity.Store.FakeBlobStoreContractTest do
  use Singularity.Core.TestSupport.Contracts.BlobStoreContract,
    adapter: Singularity.Core.TestSupport.Fake.BlobStore,
    start_context: {Singularity.Core.TestSupport.Fake.BlobStore, :start_link, [[]]}
end
