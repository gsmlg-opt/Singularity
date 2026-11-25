defmodule Singularity.KnowledgeBookImportTest do
  use Singularity.DataCase, async: true
  use Styx.Testing, repo: Singularity.Repo

  alias Singularity.Knowledge
  alias Singularity.Knowledge.{BookFiles, BookImportWorker, Epub}
  alias Singularity.Test.FakeBookImportSSH

  @location "reader@books.example:/Calibre Library"

  test "imports nested EPUBs, counts duplicates and continues after an invalid file" do
    epub = epub_bytes()
    digest = Base.encode16(:crypto.hash(:sha256, epub), case: :lower)

    on_exit(fn ->
      File.rm(Path.join([Singularity.DataDir.root(), "published-books", digest <> ".epub"]))
    end)

    Process.put(FakeBookImportSSH, %{
      "/Calibre Library/A/invalid.epub" => "invalid bytes",
      "/Calibre Library/B/Book [1].epub" => epub,
      "/Calibre Library/C/Second copy.EPUB" => epub
    })

    assert {:ok, job} = Knowledge.queue_book_import(@location)
    assert {:ok, %{id: id}} = Knowledge.queue_book_import(@location)
    assert id == job.id
    assert :ok = BookImportWorker.perform(Repo.get!(Styx.Job, job.id))

    assert [
             %{
               meta: %{
                 "book_import" => %{
                   "imported" => 1,
                   "duplicates" => 1,
                   "failed" => 1,
                   "total" => 3
                 }
               }
             }
           ] =
             Knowledge.list_book_imports()

    assert {[%{title: "Book [1]"} = book], false} = Knowledge.list_books(1, 30)
    assert {:ok, path, "Book [1].epub"} = Knowledge.book_file(book)
    assert File.read!(path) == epub

    assert {:ok, %{"title" => "EPUB metadata", "author" => "Example author"}} =
             Epub.metadata(path)
  end

  test "checks the server allowlist and format before queueing" do
    assert {:error, :ssh_host_not_allowed} = Knowledge.queue_book_import("unknown:/books")

    assert {:error, :invalid_location} =
             Knowledge.queue_book_import("reader@books.example:relative")

    assert {:error, :invalid_location} = Knowledge.queue_book_import("-oProxyCommand:anywhere")
    refute_enqueued(worker: BookImportWorker)
  end

  @tag :tmp_dir
  test "the web limit is enforced independently of staged import", %{tmp_dir: tmp_dir} do
    assert Knowledge.book_upload_limit() == 1000 * 1024 * 1024
    path = Path.join(tmp_dir, "large.epub")
    {:ok, file} = :file.open(path, [:write, :binary])
    {:ok, _offset} = :file.position(file, Knowledge.book_upload_limit() + 1)
    :ok = :file.truncate(file)
    :ok = :file.close(file)

    assert {:error, :too_large} = BookFiles.prepare(path, "large.epub", :upload)
    assert {:error, :invalid_epub} = BookFiles.prepare(path, "large.epub", :staged)
  end

  defp epub_bytes do
    {:ok, {_name, bytes}} =
      :zip.create(
        ~c"book.epub",
        [
          {~c"META-INF/container.xml",
           "<container><rootfile full-path=\"content.opf\"/></container>"},
          {~c"mimetype", "application/epub+zip"},
          {~c"content.opf",
           "<package data-test=\"#{System.unique_integer([:positive])}\"><metadata><dc:title>EPUB metadata</dc:title><dc:creator>Example author</dc:creator></metadata></package>"}
        ],
        [:memory, {:compress, :all}]
      )

    bytes
  end
end
