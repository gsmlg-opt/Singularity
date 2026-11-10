defmodule SingularityWeb.NavigationTest do
  use SingularityWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @top [
    {"/", "Overview"},
    {"/knowledge", "Knowledge"},
    {"/source/sources", "Source"},
    {"/system/github", "System"}
  ]

  @sections [
    {"/", "overview", "overview-home", [{"/", "Overview"}, {"/overview/activity", "Activity"}]},
    {"/knowledge", "knowledge", "knowledge-all",
     [{"/knowledge", "All knowledge"}, {"/knowledge/projects", "Software projects"}]},
    {"/source/sources", "source", "source-sources",
     [
       {"/source/sources", "Sources"},
       {"/source/add", "Add project"},
       {"/source/runs", "Collection runs"}
     ]},
    {"/system/github", "system", "system-github",
     [{"/system/github", "GitHub"}, {"/system/status", "System status"}]}
  ]

  test "the appbar has four sections, each with its own left menu", %{conn: conn} do
    for {path, section, active, items} <- @sections do
      {:ok, view, _html} = live(conn, path)

      for {top_path, label} <- @top do
        assert has_element?(view, "header.appbar a[href='#{top_path}']", label)
      end

      assert has_element?(view, "#top-nav-#{section}[aria-current='page']")
      assert has_element?(view, "#section-menu-navigation[data-active-nav='#{active}']")

      for {item_path, label} <- items do
        assert has_element?(view, "#section-menu a[href='#{item_path}'][aria-label='#{label}']")
      end
    end
  end
end
