defmodule SingularityWeb.Layouts do
  @moduledoc """
  The root layout and the app shell, following backplane_admin: a sticky
  primary appbar with the four sections, a sticky per-section `dm_left_menu`,
  and content in `max-w-7xl`.
  """
  use SingularityWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the app shell.

      <Layouts.app flash={@flash} socket={@socket} section={:knowledge} active="knowledge-all">
        <h1>…</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true
  attr :socket, Phoenix.LiveView.Socket, required: true
  attr :section, :atom, required: true, values: [:overview, :knowledge, :source, :system]
  attr :active, :string, default: "", doc: "id of the active left-menu item"

  attr :labels, :list,
    default: [],
    doc: "top labels as {name, count}, listed in the Knowledge menu"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-full bg-surface text-on-surface">
      <header class="appbar appbar-sticky appbar-primary">
        <.link navigate="/" class="appbar-brand no-underline">
          <.dm_mdi name="bookshelf" class="h-8 w-8" />
          <span class="appbar-title">Singularity</span>
        </.link>
        <nav class="appbar-actions ml-auto" aria-label={gettext("Main navigation")}>
          <.link
            :for={item <- top_nav_items()}
            id={"top-nav-#{item.section}"}
            navigate={item.to}
            class={[
              "appbar-action rounded-md whitespace-nowrap no-underline",
              item.section == @section && "bg-primary-container text-on-primary-container"
            ]}
            aria-current={item.section == @section && "page"}
          >
            {item.label}
          </.link>
        </nav>
      </header>
      <div class="min-h-[calc(100vh-4rem)] bg-surface-container-low lg:flex">
        <.dm_left_menu
          id="section-menu"
          sticky
          socket={@socket}
          groups={left_menu_groups(@section, @labels)}
          active={@active}
          nav_label={gettext("Section navigation")}
          expand_label={gettext("Expand navigation")}
          collapse_label={gettext("Collapse navigation")}
          class="sticky top-16 h-[calc(100dvh-4rem)]"
        />
        <main class="min-w-0 flex-1">
          <div class="mx-auto w-full max-w-7xl space-y-6 px-4 py-6 sm:px-6 lg:px-8">
            <.dm_flash_group flash={@flash} />
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>
    """
  end

  @doc "The appbar's top-level sections."
  def top_nav_items do
    [
      %{section: :overview, label: gettext("Overview"), to: "/"},
      %{section: :knowledge, label: gettext("Knowledge"), to: "/knowledge"},
      %{section: :source, label: gettext("Source"), to: "/source/sources"},
      %{section: :system, label: gettext("System"), to: "/system/github"}
    ]
  end

  @doc "Left-menu groups of a section, in the data shape `dm_left_menu` expects."
  def left_menu_groups(:overview, _labels) do
    [
      %{
        id: "overview",
        label: gettext("Overview"),
        items: [
          %{
            id: "overview-home",
            label: gettext("Overview"),
            to: "/",
            icon: "view-dashboard-outline"
          },
          %{
            id: "overview-activity",
            label: gettext("Activity"),
            to: "/overview/activity",
            icon: "timeline-clock-outline"
          }
        ]
      }
    ]
  end

  def left_menu_groups(:knowledge, labels) do
    browse = %{
      id: "browse",
      label: gettext("Browse"),
      items: [
        %{
          id: "knowledge-all",
          label: gettext("All knowledge"),
          to: "/knowledge",
          icon: "bookshelf"
        },
        %{
          id: "knowledge-projects",
          label: gettext("Software projects"),
          to: "/knowledge/projects",
          icon: "source-repository"
        }
      ]
    }

    if labels == [],
      do: [browse],
      else: [browse, %{id: "labels", label: gettext("Top labels"), items: label_items(labels)}]
  end

  def left_menu_groups(:source, _labels) do
    [
      %{
        id: "source",
        label: gettext("Source"),
        items: [
          %{id: "source-sources", label: gettext("Sources"), to: "/source/sources", icon: "rss"},
          %{
            id: "source-add",
            label: gettext("Add project"),
            to: "/source/add",
            icon: "plus-box-outline"
          },
          %{
            id: "source-runs",
            label: gettext("Collection runs"),
            to: "/source/runs",
            icon: "history"
          }
        ]
      }
    ]
  end

  def left_menu_groups(:system, _labels) do
    [
      %{
        id: "system",
        label: gettext("System"),
        items: [
          %{id: "system-github", label: gettext("GitHub"), to: "/system/github", icon: "github"},
          %{
            id: "system-status",
            label: gettext("System status"),
            to: "/system/status",
            icon: "server"
          }
        ]
      }
    ]
  end

  @doc "The left-menu item id of a top label, or nil when the label is not listed."
  def label_menu_id(labels, name) do
    labels
    |> Enum.with_index(1)
    |> Enum.find_value(fn {{label, _count}, index} ->
      if label == name, do: "menu-label-#{index}"
    end)
  end

  defp label_items(labels) do
    labels
    |> Enum.with_index(1)
    |> Enum.map(fn {{name, _count}, index} ->
      %{
        id: "menu-label-#{index}",
        label: name,
        to: "/knowledge?" <> URI.encode_query(%{"label" => name}),
        icon: "tag-outline"
      }
    end)
  end
end
