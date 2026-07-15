defmodule Singularity.Retrieval.FakeVectorStoreContractTest do
  use Singularity.Core.TestSupport.Contracts.VectorStoreContract,
    adapter: Singularity.Core.TestSupport.Fake.VectorStore,
    start_context: {Singularity.Core.TestSupport.Fake.VectorStore, :start_link, [[]]}
end
