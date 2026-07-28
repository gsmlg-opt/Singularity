defmodule Singularity.Web.TestRuntimeApi do
  @moduledoc false

  def put(agent, key, value), do: Agent.update(agent, &Map.put(&1, key, value))
  def calls(agent), do: Agent.get(agent, &Enum.reverse(&1.calls))

  def resolve_session(agent, opaque_id) do
    call(agent, {:resolve_session, opaque_id}, fn state ->
      Map.get(state.sessions, opaque_id, {:error, :unauthenticated})
    end)
  end

  def login(agent, attrs),
    do: call(agent, {:login, attrs}, &Map.get(&1, :login, {:error, :unauthenticated}))

  def unlock(agent, session, password),
    do: call(agent, {:unlock, session, password}, &Map.get(&1, :unlock, {:error, :forbidden}))

  def logout(agent, session),
    do: call(agent, {:logout, session}, &Map.get(&1, :logout, :ok))

  def list_assets(agent, session, params),
    do: call(agent, {:list_assets, session, params}, &Map.get(&1, :assets, {:ok, []}))

  def begin_upload(agent, session, grant_id, request, owner) do
    call(
      agent,
      {:begin_upload, session, grant_id, request, owner},
      &Map.get(&1, :begin_upload, {:ok, make_ref()})
    )
  end

  def append_upload(agent, handle, chunk) do
    call(
      agent,
      {:append_upload, handle, chunk},
      &Map.get(&1, :append_upload, :ok)
    )
  end

  def finish_upload(agent, handle, final_chunk) do
    call(
      agent,
      {:finish_upload, handle, final_chunk},
      &Map.get(&1, :finish_upload, {
        :ok,
        %{
          asset_id: "asset-1",
          state: "uploaded",
          state_revision: 1
        }
      })
    )
  end

  def abandon_upload(agent, handle, reason) do
    call(
      agent,
      {:abandon_upload, handle, reason},
      &Map.get(&1, :abandon_upload, :ok)
    )
  end

  def end_upload(agent, handle),
    do: call(agent, {:end_upload, handle}, &Map.get(&1, :end_upload, :ok))

  def download(agent, session, asset_id, range_header) do
    call(
      agent,
      {:download, session, asset_id, range_header},
      &Map.get(&1, :download, {:error, :not_found})
    )
  end

  defp call(agent, invocation, result) do
    Agent.get_and_update(agent, fn state ->
      {result.(state), Map.update!(state, :calls, &[invocation | &1])}
    end)
  end
end

defmodule Singularity.Web.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Singularity.Web.Endpoint

      use Singularity.Web, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Singularity.Web.ConnCase

      alias Singularity.Runtime.DTO.AssetSummary
      alias Singularity.Runtime.DTO.SearchPage
      alias Singularity.Runtime.DTO.Session
      alias Singularity.Runtime.DTO.UploadGrant
      alias Singularity.Web.TestRuntimeApi
    end
  end

  setup _tags do
    previous_api = Application.get_env(:singularity_web, :runtime_api)

    {:ok, runtime_api} =
      Agent.start_link(fn ->
        %{
          calls: [],
          sessions: %{}
        }
      end)

    Application.put_env(
      :singularity_web,
      :runtime_api,
      {Singularity.Web.TestRuntimeApi, runtime_api}
    )

    on_exit(fn ->
      if previous_api do
        Application.put_env(:singularity_web, :runtime_api, previous_api)
      else
        Application.delete_env(:singularity_web, :runtime_api)
      end
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn(), runtime_api: runtime_api}
  end

  def put_session_id(conn, opaque_id) do
    Phoenix.ConnTest.init_test_session(conn, %{"session_id" => opaque_id})
  end

  def put_issued_csrf(conn) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()
    csrf_state = Plug.CSRFProtection.dump_state()

    conn =
      Phoenix.ConnTest.init_test_session(
        conn,
        Map.put(Plug.Conn.get_session(conn), "_csrf_token", csrf_state)
      )

    {conn, csrf_token}
  end

  def session(unlocked?) do
    %Singularity.Runtime.DTO.Session{
      session_id: "019f9f0f-f384-78ef-8934-2d798944bcc1",
      account_id: "019f9f0f-f384-78ef-8934-2d798944bcc4",
      principal_id: "019f9f0f-f384-78ef-8934-2d798944bcc2",
      vault_id: "019f9f0f-f384-78ef-8934-2d798944bcc3",
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second),
      principal_authorization_epoch: 7,
      vault_authorization_epoch: 11,
      authorization_epoch: 7,
      unlocked?: unlocked?
    }
  end
end
