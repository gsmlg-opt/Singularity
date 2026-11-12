defmodule Singularity.Knowledge.ChangesTest do
  use ExUnit.Case, async: true

  alias Singularity.Knowledge.Changes

  @before %{
    title: "Old title",
    url: "https://example.test/1",
    summary: nil,
    published_at: ~U[2018-08-01 00:00:00Z],
    attributes: %{"status" => "DRAFT", "obsoleted_by" => [], "gone" => 1}
  }

  test "equal values have no changes" do
    assert Changes.fields(@before, @before) == %{}
  end

  test "whole fields, including from nil, and attributes key by key" do
    after_ = %{
      @before
      | title: "New title",
        summary: "Now has an abstract",
        published_at: ~U[2018-09-01 00:00:00Z],
        attributes: %{"status" => "DRAFT", "obsoleted_by" => ["rfc9846"], "new" => true}
    }

    assert Changes.fields(@before, after_) == %{
             "title" => %{"old" => "Old title", "new" => "New title"},
             "summary" => %{"old" => nil, "new" => "Now has an abstract"},
             "published_at" => %{
               "old" => "2018-08-01T00:00:00Z",
               "new" => "2018-09-01T00:00:00Z"
             },
             "attributes.obsoleted_by" => %{"old" => [], "new" => ["rfc9846"]},
             "attributes.gone" => %{"old" => 1, "new" => nil},
             "attributes.new" => %{"old" => nil, "new" => true}
           }
  end
end
