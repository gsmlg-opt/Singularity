defmodule Singularity.Runtime.UploadSessionSupervisorTest do
  use ExUnit.Case, async: false

  alias Singularity.Core.Error
  alias Singularity.Runtime.UploadSessionSupervisor

  defmodule Session do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner) do
      send(owner, {:started, self()})
      {:ok, owner}
    end
  end

  defmodule ReadySession do
    use GenServer

    def start_link(options), do: GenServer.start_link(__MODULE__, options)

    def await_ready(session) do
      GenServer.call(session, :await_ready)
    end

    @impl true
    def init(options) do
      send(options[:owner], {:begin_upload_started, self(), options})
      {:ok, options}
    end

    @impl true
    def handle_call(:await_ready, _from, options) do
      send(options[:owner], {:begin_upload_ready, self()})
      {:reply, {:ok, self()}, options}
    end
  end

  test "rejects excess upload sessions with storage unavailable" do
    supervisor =
      start_supervised!({UploadSessionSupervisor, name: nil, max_children: 1})

    first = %{
      id: make_ref(),
      start: {Session, :start_link, [self()]},
      restart: :temporary
    }

    second = %{first | id: make_ref()}

    assert {:ok, first_session} =
             UploadSessionSupervisor.start_upload(supervisor, first)

    assert_receive {:started, ^first_session}

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             UploadSessionSupervisor.start_upload(supervisor, second)

    assert Process.alive?(first_session)
  end

  test "uses the configured default capacity when no override is supplied" do
    previous =
      Application.get_env(:singularity_runtime, :max_concurrent_uploads)

    Application.put_env(:singularity_runtime, :max_concurrent_uploads, 3)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(
          :singularity_runtime,
          :max_concurrent_uploads
        )
      else
        Application.put_env(
          :singularity_runtime,
          :max_concurrent_uploads,
          previous
        )
      end
    end)

    supervisor =
      start_supervised!({UploadSessionSupervisor, name: nil})

    for _index <- 1..3 do
      assert {:ok, _session} =
               UploadSessionSupervisor.start_upload(
                 supervisor,
                 session_spec(self())
               )
    end

    assert {:error, %Error{code: :storage_unavailable}} =
             UploadSessionSupervisor.start_upload(
               supervisor,
               session_spec(self())
             )
  end

  test "begin_upload is the bounded pre-body entry seam and waits for durable readiness" do
    supervisor =
      start_supervised!({UploadSessionSupervisor, name: nil, max_children: 1})

    runtime = %{
      upload_session: ReadySession,
      upload_session_supervisor: supervisor
    }

    session = %{session_id: "session"}
    grant = %{grant_id: "grant"}

    assert {:ok, upload} =
             UploadSessionSupervisor.begin_upload(
               runtime,
               session,
               grant,
               self()
             )

    assert_receive {:begin_upload_started, ^upload, options}
    assert options[:runtime] == runtime
    assert options[:session] == session
    assert options[:grant] == grant
    assert options[:owner] == self()
    assert_receive {:begin_upload_ready, ^upload}

    assert {:error, %Error{code: :storage_unavailable, retryable?: true}} =
             UploadSessionSupervisor.begin_upload(
               runtime,
               session,
               grant,
               self()
             )

    refute_receive {:begin_upload_started, _other, _options}
  end

  defp session_spec(owner) do
    %{
      id: make_ref(),
      start: {Session, :start_link, [owner]},
      restart: :temporary
    }
  end
end
