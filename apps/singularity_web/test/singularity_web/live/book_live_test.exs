defmodule SingularityWeb.BookLiveTest do
  use SingularityWeb.ConnCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  import Phoenix.LiveViewTest

  alias Singularity.Knowledge.BookMetadataWorker
  alias Singularity.Knowledge.BookImportWorker

  test "uploads an EPUB from Source and makes it searchable and downloadable in Knowledge", %{
    conn: conn
  } do
    {:ok, index, _html} = live(conn, "/knowledge/books")
    assert has_element?(index, "#section-menu-navigation[data-active-nav='knowledge-books']")
    assert has_element?(index, "#books-empty")
    refute has_element?(index, "#add-book")

    {:ok, manual, _html} = live(conn, "/source/manual")

    {:ok, form, _html} =
      manual
      |> element("#add-book")
      |> render_click()
      |> follow_redirect(conn, "/source/manual/books/new")

    assert has_element?(form, "#section-menu-navigation[data-active-nav='source-manual']")
    assert has_element?(form, "#book-form a[href='/source/manual']", "Cancel")
    assert has_element?(form, "#epub-hint", "1000 MiB")

    epub = epub_file()
    digest = Base.encode16(:crypto.hash(:sha256, epub), case: :lower)

    on_exit(fn ->
      File.rm(Path.join([Singularity.DataDir.root(), "published-books", digest <> ".epub"]))
    end)

    assert upload(form, "Manual Title.epub", epub) =~ "Manual Title.epub"
    form |> form("#book-form") |> render_submit()
    {path, _flash} = assert_redirect(form)
    assert "/knowledge/books/" <> id = path

    {:ok, detail, _html} = live(conn, path)
    assert has_element?(detail, "h1", "Manual Title")
    assert has_element?(detail, "#book-metadata-status", "Extracting book details")

    assert_enqueued(worker: BookMetadataWorker, args: %{item_id: String.to_integer(id)})
    assert :ok = perform_job(BookMetadataWorker, %{item_id: String.to_integer(id)})
    assert has_element?(detail, "h1", "Extracted Book Title")
    assert has_element?(detail, "dd", "Extracted Author")

    download = get(conn, path <> "/download")
    assert response(download, 200) == epub
    assert ["application/epub+zip"] = get_resp_header(download, "content-type")
    assert ["attachment;" <> _] = get_resp_header(download, "content-disposition")

    {:ok, index, _html} = live(conn, "/knowledge/books")
    assert has_element?(index, "#books a[href='#{path}']", "Extracted Book Title")

    {:ok, search, _html} = live(conn, "/knowledge?q=Extracted+Book")
    assert has_element?(search, "#knowledge-results a[href='#{path}']")
    assert has_element?(search, "#knowledge-results td", "Book")

    {:ok, form, _html} = live(conn, "/source/manual/books/new")
    upload(form, "Another name.epub", epub)
    form |> form("#book-form") |> render_submit()

    assert {^path, %{"info" => "This EPUB is already in your knowledge base."}} =
             assert_redirect(form)
  end

  test "rejects a non-EPUB upload with an EPUB extension", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/source/manual/books/new")
    upload(view, "Invalid.epub", "invalid bytes")
    view |> form("#book-form") |> render_submit()

    assert has_element?(view, "#book-upload-error", "This file is not a valid EPUB.")
    refute_enqueued(worker: BookMetadataWorker)
  end

  test "queues an SSH directory from Source and shows the import after reopening", %{conn: conn} do
    {:ok, manual, _html} = live(conn, ~p"/source/manual")

    {:ok, view, _html} =
      manual
      |> element("#import-books")
      |> render_click()
      |> follow_redirect(conn, ~p"/source/manual/books/import")

    location = "reader@books.example:/Calibre Library"
    view |> form("#book-ssh-form", location: location) |> render_submit()

    assert_enqueued(worker: BookImportWorker, args: %{location: location})
    assert has_element?(view, "#book-imports td", "Queued")

    {:ok, reopened, _html} = live(conn, ~p"/source/manual/books/import")
    assert has_element?(reopened, "#book-imports td", location)
  end

  defp upload(view, name, content) do
    view
    |> file_input("#book-form", :epub, [
      %{name: name, content: content, type: "application/epub+zip"}
    ])
    |> render_upload(name)
  end

  defp epub_file do
    {:ok, {_name, epub}} =
      :zip.create(
        ~c"book.epub",
        [
          {~c"mimetype", "application/epub+zip"},
          {~c"META-INF/container.xml",
           "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>"},
          {~c"content.opf",
           "<package id=\"#{System.unique_integer([:positive])}\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Extracted Book Title</dc:title><dc:creator>Extracted Author</dc:creator></metadata></package>"}
        ],
        [:memory, {:compress, []}, {:extra, []}]
      )

    epub
  end
end
