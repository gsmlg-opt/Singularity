defmodule Singularity.Collector.Entry do
  @moduledoc """
  One collected object as reported by a collector. `period` overrides the
  result's period for this entry's observation; `details` are GitHub details
  already in hand, stored as freshly fetched instead of queueing a fetch.
  `content_path` is a file whose text becomes the item's Markdown content;
  `labels`, when a list, is the item's complete set of automatic labels.
  """

  @enforce_keys [:item_kind, :external_id, :title, :url]
  defstruct [
    :item_kind,
    :external_id,
    :title,
    :url,
    :summary,
    :published_at,
    :rank,
    :period,
    :details,
    :content_path,
    :labels,
    item_attributes: %{},
    observation_attributes: %{},
    raw: %{}
  ]

  @type t :: %__MODULE__{
          item_kind: String.t(),
          external_id: String.t(),
          title: String.t(),
          url: String.t(),
          summary: String.t() | nil,
          published_at: DateTime.t() | nil,
          rank: pos_integer() | nil,
          period: String.t() | nil,
          details: Singularity.GitHub.details() | nil,
          content_path: Path.t() | nil,
          labels: [String.t()] | nil,
          item_attributes: map(),
          observation_attributes: map(),
          raw: map()
        }
end
