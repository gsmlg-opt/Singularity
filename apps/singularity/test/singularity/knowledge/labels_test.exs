defmodule Singularity.Knowledge.LabelsTest do
  use ExUnit.Case, async: true

  alias Singularity.Knowledge.Labels

  test "derives language, topic, trending and archived labels" do
    attributes = %{"language" => "Elixir", "topics" => ["web", "Phoenix"], "archived" => true}

    assert Labels.auto_labels(attributes, ["daily", "weekly"]) == [
             "lang:elixir",
             "topic:web",
             "topic:phoenix",
             "trending:daily",
             "trending:weekly",
             "archived"
           ]
  end

  test "skips missing and blank values and removes duplicates" do
    assert Labels.auto_labels(%{"language" => nil, "topics" => nil, "archived" => false}, []) ==
             []

    assert Labels.auto_labels(%{}, ["daily", "daily", "", nil]) == ["trending:daily"]
    assert Labels.auto_labels(%{"language" => " ", "topics" => ["", "x"]}, []) == ["topic:x"]
  end

  test "keeps a multi-word language as one label" do
    assert Labels.auto_labels(%{"language" => "Jupyter Notebook"}, []) == [
             "lang:jupyter notebook"
           ]
  end
end
