defmodule Fake.DocumentRepository do
  def create_pending({owner, result} = context, command) do
    send(owner, {:create_pending, context, command})
    result
  end
end
