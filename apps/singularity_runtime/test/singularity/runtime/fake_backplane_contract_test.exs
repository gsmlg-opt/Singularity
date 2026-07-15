defmodule Singularity.Runtime.FakeEmbedderContractTest do
  use Singularity.Core.TestSupport.Contracts.EmbedderContract,
    adapter: Singularity.Core.TestSupport.Fake.Backplane,
    start_context: {Singularity.Core.TestSupport.Fake.Backplane, :start_link, [[]]}
end

defmodule Singularity.Runtime.FakeGeneratorContractTest do
  use Singularity.Core.TestSupport.Contracts.GeneratorContract,
    adapter: Singularity.Core.TestSupport.Fake.Backplane,
    start_context: {Singularity.Core.TestSupport.Fake.Backplane, :start_link, [[]]}
end
