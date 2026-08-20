defmodule Singularity.Web.NoteExportController do
  use Singularity.Web, :controller

  alias Singularity.Runtime.DTO.NoteExport
  alias Singularity.Web.Auth

  @status_by_error %{
    invalid: 400,
    unauthenticated: 401,
    forbidden: 403,
    vault_locked: 403,
    not_found: 404,
    conflict: 409,
    storage_unavailable: 503
  }
  @unsafe ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}\/\\";]/u
  @ascii ~r/\A[\x20-\x7E]+\z/

  def show(conn, %{"resource_id" => resource_id}) do
    case safe_runtime(conn.assigns.current_session, resource_id) do
      {:ok, %NoteExport{resource_id: ^resource_id} = export} -> send_export(conn, export)
      {:error, code} when is_atom(code) -> error(conn, code)
      _invalid -> error(conn, :storage_unavailable)
    end
  end

  defp safe_runtime(session, resource_id) do
    Auth.call_runtime(:export_note, [session, resource_id])
  rescue
    _error -> {:error, :storage_unavailable}
  catch
    _kind, _reason -> {:error, :storage_unavailable}
  end

  defp send_export(conn, %NoteExport{media_type: "text/markdown; charset=utf-8"} = export) do
    filename = safe_filename(export.filename)
    fallback = ascii_filename(filename)
    encoded = URI.encode(filename, &URI.char_unreserved?/1)

    conn
    |> put_resp_content_type("text/markdown", "utf-8")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{fallback}"; filename*=UTF-8''#{encoded})
    )
    |> send_resp(200, export.markdown)
  end

  defp send_export(conn, _export), do: error(conn, :storage_unavailable)

  defp safe_filename(filename) when is_binary(filename) do
    if byte_size(filename) in 1..258 and String.valid?(filename) and
         String.ends_with?(filename, ".md") and filename != ".md" and
         not Regex.match?(@unsafe, filename),
       do: filename,
       else: "note.md"
  end

  defp safe_filename(_filename), do: "note.md"

  defp ascii_filename(filename) do
    if Regex.match?(@ascii, filename) and not Regex.match?(@unsafe, filename),
      do: filename,
      else: "note.md"
  end

  defp error(conn, code) do
    code = if Map.has_key?(@status_by_error, code), do: code, else: :storage_unavailable
    status = Map.get(@status_by_error, code, 503)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{error: %{code: Atom.to_string(code)}}))
  end
end
