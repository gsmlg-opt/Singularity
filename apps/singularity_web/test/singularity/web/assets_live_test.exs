defmodule Singularity.Web.AssetsLiveTest do
  use Singularity.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  @asset_id "019f9f0f-f384-78ef-8934-2d798944bcd1"
  @version_id "019f9f0f-f384-78ef-8934-2d798944bcd2"
  @grant_id "019f9f0f-f384-78ef-8934-2d798944bcd3"
  @other_vault_id "019f9f0f-f384-78ef-8934-2d798944bcd4"
  @csrf_canary "CANARY_CSRF_1eb21f"
  @session_canary "CANARY_SESSION_fbe5e0"
  @opaque_key_canary "CANARY_KEY_88c17a"
  @initial_params %{q: "", state: nil, media_type: nil, limit: 50}

  test "renders one ignored workspace node with exact secret-free version-1 props", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = %{session(true) | session_id: @session_canary}

    initial_summary =
      summary(
        progress: %{kind: :bytes, sent: 7, total: 42},
        failure: %{
          code: "extractor_timeout",
          retryable: true,
          operation: "extract_metadata",
          attempt: 2
        }
      )

    {:ok, view, html} =
      open_assets(conn, runtime_api, current_session, page([initial_summary]))

    [{"div", attributes, []}] =
      html
      |> Floki.parse_document!()
      |> Floki.find("#asset-workspace")

    assert {"phx-hook", "MountAssetWorkspace"} in attributes
    assert {"phx-update", "ignore"} in attributes

    props =
      attributes
      |> attribute!("data-props")
      |> JSON.decode!()

    assert props == %{
             "version" => 1,
             "vault" => %{
               "ref" => current_session.vault_id,
               "locked" => false,
               "expiresAt" => DateTime.to_iso8601(current_session.expires_at)
             },
             "assets" => %{
               "items" => [browser_summary(initial_summary)],
               "nextCursor" => nil
             },
             "filters" => %{
               "q" => "",
               "state" => nil,
               "mediaType" => nil
             },
             "upload" => %{
               "maxBytes" => 536_870_912,
               "acceptedTypes" => [
                 "application/pdf",
                 "image/jpeg",
                 "image/png"
               ]
             }
           }

    refute Map.has_key?(props, "sequence")
    refute_secret_canaries(props)

    snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{
        items: [browser_summary_atoms(initial_summary)],
        nextCursor: nil
      }
    }

    assert_push_event(view, "asset:snapshot", ^snapshot)
    refute_secret_canaries(snapshot)

    assert [
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:list_assets, ^current_session, @initial_params}
           ] = asset_calls(runtime_api)
  end

  test "each connected server mount establishes a fresh snapshot sequence epoch", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    first_dead = summary(title: "Disconnected stale one", state_revision: 1)
    first_canonical = summary(title: "Canonical one", state_revision: 2)
    second_dead = summary(title: "Disconnected stale two", state_revision: 3)
    second_canonical = summary(title: "Canonical two", state_revision: 4)

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    TestRuntimeApi.put_sequence(runtime_api, :assets, [
      {:ok, page([first_dead])},
      {:ok, page([first_canonical])},
      {:ok, page([second_dead])},
      {:ok, page([second_canonical])}
    ])

    conn = put_session_id(conn, "opaque-session")

    {:ok, first, first_html} = live(conn, "/assets")

    first_snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{
        items: [browser_summary_atoms(first_canonical)],
        nextCursor: nil
      }
    }

    assert_push_event(first, "asset:snapshot", ^first_snapshot)
    refute first_html =~ "Disconnected stale one"
    assert first_html =~ "Canonical one"
    refute_secret_canaries(first_snapshot)

    # A persistent JS hook must reset or establish its client sequence epoch on
    # disconnected/reconnect before accepting this fresh sequence-1 snapshot.
    # That client requirement belongs to, and is enforced by, the blocked JS slice.
    {:ok, second, second_html} = live(conn, "/assets")

    second_snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{
        items: [browser_summary_atoms(second_canonical)],
        nextCursor: nil
      }
    }

    assert_push_event(second, "asset:snapshot", ^second_snapshot)
    refute second_html =~ "Disconnected stale two"
    assert second_html =~ "Canonical two"
    refute_secret_canaries(second_snapshot)

    assert [
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:list_assets, ^current_session, @initial_params},
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:list_assets, ^current_session, @initial_params}
           ] = asset_calls(runtime_api)
  end

  test "a failed subscription retries subscription and canonical list before snapshot", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    disconnected = summary(title: "Disconnected stale", state_revision: 1)
    canonical = summary(title: "Recovered canonical", state_revision: 2)

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    TestRuntimeApi.put_sequence(runtime_api, :assets, [
      {:ok, page([disconnected])},
      {:ok, page([canonical])}
    ])

    TestRuntimeApi.put_sequence(runtime_api, :subscribe_assets, [
      {:error, :storage_unavailable},
      :ok
    ])

    TestRuntimeApi.put(runtime_api, :asset_summary, {:ok, summary()})

    {:ok, view, _html} =
      conn
      |> put_session_id("opaque-session")
      |> live("/assets")

    generation = snapshot_generation(view)

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    _html = render(view)
    refute {:asset_summary, current_session, @asset_id} in TestRuntimeApi.calls(runtime_api)

    send(view.pid, {:asset_workspace_recover_snapshot, generation, 2})

    snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{items: [browser_summary_atoms(canonical)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^snapshot)
    refute_push_event(view, "asset:update", %{})

    assert [
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:subscribe_assets, ^current_session},
             {:list_assets, ^current_session, @initial_params}
           ] = asset_calls(runtime_api)
  end

  test "a failed canonical list retries before canonical lifecycle snapshots", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    canonical = summary(title: "Recovered canonical", state_revision: 4)
    updated = summary(title: "Lifecycle update", state_revision: 5)

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    TestRuntimeApi.put_sequence(runtime_api, :assets, [
      {:ok, page([])},
      {:error, :storage_unavailable},
      {:ok, page([canonical])}
    ])

    {:ok, view, _html} =
      conn
      |> put_session_id("opaque-session")
      |> live("/assets")

    generation = snapshot_generation(view)

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    _html = render(view)
    refute {:asset_summary, current_session, @asset_id} in TestRuntimeApi.calls(runtime_api)

    send(view.pid, {:asset_workspace_recover_snapshot, generation, 2})

    snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{items: [browser_summary_atoms(canonical)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^snapshot)

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([updated])})

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    update = %{
      version: 1,
      sequence: 2,
      assets: %{items: [browser_summary_atoms(updated)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^update)
    refute_push_event(view, "asset:update", %{})

    assert [
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:list_assets, ^current_session, @initial_params},
             {:list_assets, ^current_session, @initial_params}
           ] = asset_calls(runtime_api)
  end

  test "search and page fail before parsing or runtime work until the snapshot is ready", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    canonical = summary(title: "Recovered after gated event", state_revision: 6)

    events = [
      {"asset:search",
       %{
         "version" => 1,
         "q" => "report",
         "state" => nil,
         "mediaType" => nil
       }},
      {"asset:page",
       %{
         "version" => 1,
         "cursor" => "cursor",
         "q" => "",
         "state" => nil,
         "mediaType" => nil
       }}
    ]

    for {event, valid_payload} <- events do
      TestRuntimeApi.put(runtime_api, :sessions, %{
        "opaque-session" => {:ok, current_session}
      })

      TestRuntimeApi.put(runtime_api, :subscribe_assets, :ok)

      TestRuntimeApi.put_sequence(runtime_api, :assets, [
        {:ok, page([])},
        {:error, :storage_unavailable},
        {:ok, page([canonical])}
      ])

      {:ok, view, _html} =
        conn
        |> put_session_id("opaque-session")
        |> live("/assets")

      generation = snapshot_generation(view)
      calls_before_events = asset_calls(runtime_api)
      unavailable = %{ok: false, error: %{code: "storage_unavailable"}}

      hook_reply(
        view,
        event,
        %{"version" => 2, "extra" => @opaque_key_canary},
        unavailable
      )

      hook_reply(view, event, valid_payload, unavailable)

      assert asset_calls(runtime_api) == calls_before_events

      send(view.pid, {:asset_workspace_recover_snapshot, generation, 2})

      snapshot = %{
        version: 1,
        sequence: 1,
        assets: %{items: [browser_summary_atoms(canonical)], nextCursor: nil}
      }

      assert_push_event(view, "asset:snapshot", ^snapshot)
    end
  end

  test "snapshot recovery is bounded to three subscription attempts", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([])})

    TestRuntimeApi.put_sequence(runtime_api, :subscribe_assets, [
      {:error, :storage_unavailable},
      {:error, :storage_unavailable},
      {:error, :storage_unavailable}
    ])

    {:ok, view, _html} =
      conn
      |> put_session_id("opaque-session")
      |> live("/assets")

    generation = snapshot_generation(view)
    stale_generation = make_ref()

    send(view.pid, {:asset_workspace_recover_snapshot, stale_generation, 2})
    send(view.pid, {:asset_workspace_recover_snapshot, generation, 2})
    send(view.pid, {:asset_workspace_recover_snapshot, generation, 2})
    send(view.pid, {:asset_workspace_recover_snapshot, generation, 3})
    send(view.pid, {:asset_workspace_recover_snapshot, generation, 4})
    _html = render(view)

    refute_push_event(view, "asset:snapshot", %{})
    refute_push_event(view, "asset:update", %{})

    assert [
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:subscribe_assets, ^current_session},
             {:subscribe_assets, ^current_session}
           ] = asset_calls(runtime_api)
  end

  test "terminal snapshot failures do not retry or rearm", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = %{session(true) | session_id: @session_canary}

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([])})
    TestRuntimeApi.put(runtime_api, :subscribe_assets, {:error, :forbidden})

    {:ok, view, _html} =
      conn
      |> put_session_id("opaque-session")
      |> live("/assets")

    generation = snapshot_generation(view)

    send(view.pid, {:asset_workspace_recover_snapshot, generation, 2})
    send(view.pid, {:asset_workspace_recover_snapshot, generation, 3})
    send(view.pid, {:asset_workspace_rearm_snapshot, generation})
    html = render(view)

    assert [
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session}
           ] = asset_calls(runtime_api)

    refute_push_event(view, "asset:snapshot", %{})
    refute_push_event(view, "asset:update", %{})

    assert [_alert] = Floki.find(Floki.parse_document!(html), "[role=alert]")
    assert html =~ "Asset workspace is unavailable."
    refute html =~ "forbidden"
    refute html =~ ~s(id="asset-workspace")
    refute_secret_canaries(html)
  end

  test "a guarded rearm starts a later bounded recovery round", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    canonical = summary(title: "Later recovered canonical", state_revision: 7)
    updated = summary(title: "Later lifecycle update", state_revision: 8)

    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    TestRuntimeApi.put_sequence(runtime_api, :assets, [
      {:ok, page([])},
      {:ok, page([canonical])}
    ])

    TestRuntimeApi.put_sequence(runtime_api, :subscribe_assets, [
      {:error, :storage_unavailable},
      {:error, :storage_unavailable},
      {:error, :storage_unavailable},
      {:error, :storage_unavailable},
      :ok
    ])

    {:ok, view, _html} =
      conn
      |> put_session_id("opaque-session")
      |> live("/assets")

    first_generation = snapshot_generation(view)

    send(view.pid, {:asset_workspace_recover_snapshot, first_generation, 2})
    _html = render(view)
    send(view.pid, {:asset_workspace_recover_snapshot, first_generation, 3})
    _html = render(view)
    send(view.pid, {:asset_workspace_recover_snapshot, first_generation, 4})
    _html = render(view)

    assert [
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:subscribe_assets, ^current_session},
             {:subscribe_assets, ^current_session}
           ] = asset_calls(runtime_api)

    send(view.pid, {:asset_workspace_rearm_snapshot, make_ref()})
    _html = render(view)

    assert length(asset_calls(runtime_api)) == 4

    send(view.pid, {:asset_workspace_rearm_snapshot, first_generation})
    second_generation = snapshot_generation(view)

    refute second_generation == first_generation

    calls_after_rearm = asset_calls(runtime_api)
    assert length(calls_after_rearm) == 5

    send(view.pid, {:asset_workspace_rearm_snapshot, first_generation})
    send(view.pid, {:asset_workspace_recover_snapshot, first_generation, 2})
    send(view.pid, {:asset_workspace_recover_snapshot, second_generation, 4})
    _html = render(view)
    assert asset_calls(runtime_api) == calls_after_rearm

    send(view.pid, {:asset_workspace_recover_snapshot, second_generation, 2})

    snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{items: [browser_summary_atoms(canonical)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^snapshot)

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([updated])})

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    update = %{
      version: 1,
      sequence: 2,
      assets: %{items: [browser_summary_atoms(updated)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^update)
    refute_push_event(view, "asset:update", %{})

    assert [
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:subscribe_assets, ^current_session},
             {:subscribe_assets, ^current_session},
             {:subscribe_assets, ^current_session},
             {:subscribe_assets, ^current_session},
             {:list_assets, ^current_session, @initial_params},
             {:list_assets, ^current_session, @initial_params}
           ] = asset_calls(runtime_api)
  end

  test "only matching valid lifecycle hints push canonical default-page membership and order", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)

    {:ok, view, _html} =
      open_assets(conn, runtime_api, current_session, page([summary()]))

    initial_snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{items: [browser_summary_atoms(summary())], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^initial_snapshot)

    off_page =
      summary(
        title: "Hinted asset is off page",
        state: :ready,
        state_revision: 4,
        progress: %{kind: :complete},
        updated_at: ~U[2026-07-29 02:03:04Z]
      )

    first =
      summary(
        id: "019f9f0f-f384-78ef-8934-2d798944bce1",
        resource_version_id: "019f9f0f-f384-78ef-8934-2d798944bce2",
        title: "Canonical first",
        state_revision: 6
      )

    second =
      summary(
        id: "019f9f0f-f384-78ef-8934-2d798944bcf1",
        resource_version_id: "019f9f0f-f384-78ef-8934-2d798944bcf2",
        title: "Canonical second",
        state_revision: 5
      )

    TestRuntimeApi.put(runtime_api, :asset_summary, {:ok, off_page})

    send(
      view.pid,
      {:asset_changed, %{vault_id: @other_vault_id, asset_id: @asset_id}}
    )

    send(view.pid, {:asset_changed, %{vault_id: current_session.vault_id}})
    _html = render(view)

    refute Enum.any?(TestRuntimeApi.calls(runtime_api), &match?({:asset_summary, _, _}, &1))
    refute_push_event(view, "asset:update", %{})
    refute_push_event(view, "asset:snapshot", %{})

    TestRuntimeApi.put(
      runtime_api,
      :assets,
      {:ok, page([first, second], "canonical-cursor")}
    )

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    snapshot = %{
      version: 1,
      sequence: 2,
      assets: %{
        items: [browser_summary_atoms(first), browser_summary_atoms(second)],
        nextCursor: "canonical-cursor"
      }
    }

    assert_push_event(view, "asset:snapshot", ^snapshot)
    refute_push_event(view, "asset:update", %{})
    refute_secret_canaries(snapshot)

    refute {:asset_summary, current_session, @asset_id} in TestRuntimeApi.calls(runtime_api)
  end

  test "a transient default-page refresh retries to success without a second hint", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    initial = summary(title: "Report before transient refresh", state_revision: 7)

    backfill =
      summary(
        id: "019f9f0f-f384-78ef-8934-2d798944bce1",
        resource_version_id: "019f9f0f-f384-78ef-8934-2d798944bce2",
        title: "Backfilled report",
        state_revision: 1
      )

    {:ok, view, _html} =
      open_assets(conn, runtime_api, current_session, page([initial]))

    initial_snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{items: [browser_summary_atoms(initial)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^initial_snapshot)

    TestRuntimeApi.put_sequence(runtime_api, :assets, [
      {:error, :storage_unavailable},
      {:ok, page([backfill])}
    ])

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    _html = render(view)
    generation = refresh_generation(view)

    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    assert assigns.sequence == 1
    assert assigns.filters == %{q: "", state: nil, mediaType: nil}

    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 2})

    snapshot = %{
      version: 1,
      sequence: 2,
      assets: %{items: [browser_summary_atoms(backfill)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^snapshot)
    refute_push_event(view, "asset:update", %{})

    calls_after_success = asset_calls(runtime_api)
    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 2})
    _html = render(view)
    assert asset_calls(runtime_api) == calls_after_success

    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    assert assigns.sequence == 2
    assert assigns.refresh_attempt == 0
    refute assigns.refresh_retry_enabled

    assert [
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:list_assets, ^current_session, @initial_params},
             {:list_assets, ^current_session, @initial_params},
             {:list_assets, ^current_session, @initial_params}
           ] = asset_calls(runtime_api)
  end

  test "background refresh retries reject stale duplicate and out-of-range messages and stop at three",
       %{
         conn: conn,
         runtime_api: runtime_api
       } do
    current_session = session(true)
    initial = summary(title: "Report before bounded refresh", state_revision: 7)

    {:ok, view, _html} =
      open_assets(conn, runtime_api, current_session, page([initial]))

    initial_snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{items: [browser_summary_atoms(initial)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^initial_snapshot)

    TestRuntimeApi.put_sequence(runtime_api, :assets, [
      {:error, :storage_unavailable},
      {:error, :storage_unavailable},
      {:error, :storage_unavailable}
    ])

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    _html = render(view)
    generation = refresh_generation(view)
    calls_after_first = asset_calls(runtime_api)

    send(view.pid, {:asset_workspace_refresh_snapshot, make_ref(), 2})
    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 1})
    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 4})
    _html = render(view)
    assert asset_calls(runtime_api) == calls_after_first

    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 2})
    _html = render(view)
    calls_after_second = asset_calls(runtime_api)

    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 2})
    send(view.pid, {:asset_workspace_refresh_snapshot, make_ref(), 3})
    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 4})
    _html = render(view)
    assert asset_calls(runtime_api) == calls_after_second

    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 3})
    html = render(view)
    calls_after_third = asset_calls(runtime_api)

    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 3})
    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 4})

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    _html = render(view)
    assert asset_calls(runtime_api) == calls_after_third

    assert [_alert] = Floki.find(Floki.parse_document!(html), "[role=alert]")
    assert html =~ "Asset workspace is unavailable."
    refute html =~ ~s(id="asset-workspace")
    refute html =~ "storage_unavailable"
    refute_push_event(view, "asset:snapshot", %{})
    refute_push_event(view, "asset:update", %{})

    assert [
             {:list_assets, ^current_session, @initial_params},
             {:subscribe_assets, ^current_session},
             {:list_assets, ^current_session, @initial_params},
             {:list_assets, ^current_session, @initial_params},
             {:list_assets, ^current_session, @initial_params},
             {:list_assets, ^current_session, @initial_params}
           ] = calls_after_third
  end

  test "terminal background refresh errors disable the workspace without retry or leakage", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = %{session(true) | session_id: @session_canary}

    initial = summary()

    {:ok, view, _html} =
      open_assets(conn, runtime_api, current_session, page([initial]))

    initial_snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{items: [browser_summary_atoms(initial)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^initial_snapshot)

    TestRuntimeApi.put(runtime_api, :assets, {:error, :forbidden})

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    html = render(view)
    generation = refresh_generation(view)
    calls_after_terminal = asset_calls(runtime_api)

    send(view.pid, {:asset_workspace_refresh_snapshot, generation, 2})
    send(view.pid, {:asset_workspace_rearm_snapshot, snapshot_generation(view)})

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    _html = render(view)

    assert asset_calls(runtime_api) == calls_after_terminal
    assert [_alert] = Floki.find(Floki.parse_document!(html), "[role=alert]")
    assert html =~ "Asset workspace is unavailable."
    refute html =~ "forbidden"
    refute html =~ ~s(id="asset-workspace")
    refute_secret_canaries(html)
    refute_push_event(view, "asset:snapshot", %{})
    refute_push_event(view, "asset:update", %{})
  end

  test "filtered lifecycle hints replace membership from the canonical filtered page", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    initial = summary(title: "Report retained before change", state: :ready, state_revision: 7)

    {:ok, view, _html} =
      open_assets(conn, runtime_api, current_session, page([initial]))

    initial_snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{items: [browser_summary_atoms(initial)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^initial_snapshot)

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([initial], "filtered-cursor")})

    hook_reply(
      view,
      "asset:search",
      %{
        "version" => 1,
        "q" => "report",
        "state" => "ready",
        "mediaType" => "application/pdf"
      },
      %{
        ok: true,
        sequence: 2,
        filters: %{q: "report", state: "ready", mediaType: "application/pdf"},
        assets: %{
          items: [browser_summary_atoms(initial)],
          nextCursor: "filtered-cursor"
        }
      }
    )

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([])})

    TestRuntimeApi.put(
      runtime_api,
      :asset_summary,
      {:ok, summary(title: "Nonmatching lifecycle update", state: :processing, state_revision: 8)}
    )

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    snapshot = %{
      version: 1,
      sequence: 3,
      assets: %{items: [], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^snapshot)
    refute_push_event(view, "asset:update", %{})
    refute {:asset_summary, current_session, @asset_id} in TestRuntimeApi.calls(runtime_api)

    assert {:list_assets, current_session,
            %{
              q: "report",
              state: :ready,
              media_type: "application/pdf",
              limit: 50
            }} in TestRuntimeApi.calls(runtime_api)
  end

  test "a new filtered lifecycle hint supersedes the older retry generation", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    initial = summary(title: "Report remains on refresh error", state: :ready, state_revision: 7)

    {:ok, view, _html} =
      open_assets(conn, runtime_api, current_session, page([initial]))

    initial_snapshot = %{
      version: 1,
      sequence: 1,
      assets: %{items: [browser_summary_atoms(initial)], nextCursor: nil}
    }

    assert_push_event(view, "asset:snapshot", ^initial_snapshot)

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([initial], "filtered-cursor")})

    hook_reply(
      view,
      "asset:search",
      %{
        "version" => 1,
        "q" => "report",
        "state" => "ready",
        "mediaType" => "application/pdf"
      },
      %{
        ok: true,
        sequence: 2,
        filters: %{q: "report", state: "ready", mediaType: "application/pdf"},
        assets: %{
          items: [browser_summary_atoms(initial)],
          nextCursor: "filtered-cursor"
        }
      }
    )

    TestRuntimeApi.put(runtime_api, :assets, {:error, :storage_unavailable})

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    _html = render(view)
    first_generation = refresh_generation(view)

    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    assert assigns.sequence == 2
    assert assigns.filters == %{q: "report", state: "ready", mediaType: "application/pdf"}

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([])})

    send(
      view.pid,
      {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
    )

    assert_push_event(view, "asset:snapshot", %{
      version: 1,
      sequence: 3,
      assets: %{items: [], nextCursor: nil}
    })

    calls_after_new_hint = asset_calls(runtime_api)
    send(view.pid, {:asset_workspace_refresh_snapshot, first_generation, 2})
    _html = render(view)

    assert asset_calls(runtime_api) == calls_after_new_hint
    refute_push_event(view, "asset:snapshot", %{})
    refute_push_event(view, "asset:update", %{})
  end

  test "search replacement and page replies have exact schemas, params, and sequence", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    {:ok, view, _html} = open_assets(conn, runtime_api, current_session, page([]))

    searched = summary(state: :ready, state_revision: 7)
    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([searched], "cursor-next")})

    expected_search_reply = %{
      ok: true,
      sequence: 2,
      filters: %{
        q: "report",
        state: "ready",
        mediaType: "text/plain"
      },
      assets: %{
        items: [browser_summary_atoms(searched)],
        nextCursor: "cursor-next"
      }
    }

    search_reply =
      hook_reply(
        view,
        "asset:search",
        %{
          "version" => 1,
          "q" => "report",
          "state" => "ready",
          "mediaType" => "text/plain"
        },
        expected_search_reply
      )

    refute_secret_canaries(search_reply)

    assert {:list_assets, current_session,
            %{
              q: "report",
              state: :ready,
              media_type: "text/plain",
              limit: 50
            }} in TestRuntimeApi.calls(runtime_api)

    paged =
      summary(
        id: "019f9f0f-f384-78ef-8934-2d798944bce1",
        resource_version_id: "019f9f0f-f384-78ef-8934-2d798944bce2",
        title: "Second report"
      )

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([paged])})

    expected_page_reply = %{
      ok: true,
      sequence: 3,
      assets: %{
        items: [browser_summary_atoms(paged)],
        nextCursor: nil
      }
    }

    page_reply =
      hook_reply(
        view,
        "asset:page",
        %{
          "version" => 1,
          "cursor" => "cursor-next",
          "q" => "report",
          "state" => "ready",
          "mediaType" => "text/plain"
        },
        expected_page_reply
      )

    refute_secret_canaries(page_reply)

    assert {:list_assets, current_session,
            %{
              q: "report",
              state: :ready,
              media_type: "text/plain",
              cursor: "cursor-next",
              limit: 50
            }} in TestRuntimeApi.calls(runtime_api)
  end

  test "a delayed page for replaced filters is rejected before a runtime call", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    {:ok, view, _html} = open_assets(conn, runtime_api, current_session, page([]))

    assert_push_event(view, "asset:snapshot", %{
      version: 1,
      sequence: 1,
      assets: %{items: [], nextCursor: nil}
    })

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([], "cursor-a")})

    hook_reply(
      view,
      "asset:search",
      %{
        "version" => 1,
        "q" => "  alpha  ",
        "state" => nil,
        "mediaType" => nil
      },
      %{
        ok: true,
        sequence: 2,
        filters: %{q: "alpha", state: nil, mediaType: nil},
        assets: %{items: [], nextCursor: "cursor-a"}
      }
    )

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([], "cursor-b")})

    hook_reply(
      view,
      "asset:search",
      %{
        "version" => 1,
        "q" => "  beta  ",
        "state" => nil,
        "mediaType" => nil
      },
      %{
        ok: true,
        sequence: 3,
        filters: %{q: "beta", state: nil, mediaType: nil},
        assets: %{items: [], nextCursor: "cursor-b"}
      }
    )

    calls_before_delayed_page = asset_calls(runtime_api)

    reply =
      assert_invalid_reply(
        view,
        "asset:page",
        %{
          "version" => 1,
          "cursor" => "cursor-a",
          "q" => " alpha ",
          "state" => nil,
          "mediaType" => nil
        }
      )

    refute_secret_canaries(reply)
    assert asset_calls(runtime_api) == calls_before_delayed_page

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page([])})

    hook_reply(
      view,
      "asset:page",
      %{
        "version" => 1,
        "cursor" => "cursor-b",
        "q" => " beta ",
        "state" => nil,
        "mediaType" => nil
      },
      %{
        ok: true,
        sequence: 4,
        assets: %{items: [], nextCursor: nil}
      }
    )

    assert List.last(asset_calls(runtime_api)) ==
             {:list_assets, current_session,
              %{
                q: "beta",
                state: nil,
                media_type: nil,
                cursor: "cursor-b",
                limit: 50
              }}
  end

  test "upload grant uses the exact browser request and connected server CSRF", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = %{session(true) | session_id: @session_canary}

    expires_at = DateTime.add(DateTime.utc_now(), 300, :second)

    grant = %UploadGrant{
      grant_id: @grant_id,
      asset_id: @asset_id,
      filename: "report.pdf",
      byte_size: 42,
      declared_media_type: "application/pdf",
      classification: :private,
      expires_at: expires_at
    }

    TestRuntimeApi.put(
      runtime_api,
      :create_upload_grant,
      {:ok, "required-upload-token", grant}
    )

    conn = authenticated_conn(conn, runtime_api, current_session, page([]))

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"_csrf_token" => @csrf_canary})
      |> live("/assets")

    expected_reply = %{
      ok: true,
      grantId: @grant_id,
      uploadToken: "required-upload-token",
      uploadUrl: "/api/v1/uploads/#{@grant_id}",
      expiresAt: DateTime.to_iso8601(expires_at)
    }

    reply =
      hook_reply(
        view,
        "upload:grant",
        %{
          "version" => 1,
          "filename" => "report.pdf",
          "size" => 42,
          "mediaType" => "application/pdf",
          "idempotencyKey" => "browser-attempt-1"
        },
        expected_reply
      )

    assert {:create_upload_grant, current_session,
            %{
              filename: "report.pdf",
              size: 42,
              declared_media_type: "application/pdf",
              idempotency_key: "browser-attempt-1"
            }, @csrf_canary} in TestRuntimeApi.calls(runtime_api)

    refute_secret_canaries(reply)
    refute serialized(reply) =~ @asset_id
    refute serialized(reply) =~ "private"

    %{socket: %{assigns: tracked_assigns}} = :sys.get_state(view.pid)
    assert tracked_assigns.pending_upload_grant == @grant_id

    TestRuntimeApi.put(runtime_api, :cancel_upload_grant, {:ok, true})

    cancel_reply =
      hook_reply(
        view,
        "upload:cancel",
        %{"version" => 1, "grantId" => @grant_id},
        %{ok: true, accepted: true}
      )

    assert {:cancel_upload_grant, current_session, @grant_id} in TestRuntimeApi.calls(runtime_api)

    %{socket: %{assigns: cancelled_assigns}} = :sys.get_state(view.pid)
    assert is_nil(cancelled_assigns.pending_upload_grant)
    refute_secret_canaries(cancel_reply)

    calls_before_untracked = TestRuntimeApi.calls(runtime_api)

    assert_invalid_reply(
      view,
      "upload:cancel",
      %{"version" => 1, "grantId" => @grant_id}
    )

    assert TestRuntimeApi.calls(runtime_api) == calls_before_untracked
  end

  test "the bounded grant timer cancels before clearing and retries transient failure", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)

    grant = %UploadGrant{
      grant_id: @grant_id,
      asset_id: @asset_id,
      filename: "timer.pdf",
      byte_size: 5,
      declared_media_type: "application/pdf",
      classification: :private,
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }

    TestRuntimeApi.put(runtime_api, :create_upload_grant, {:ok, "timer-token", grant})

    conn = authenticated_conn(conn, runtime_api, current_session, page([]))

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"_csrf_token" => @csrf_canary})
      |> live("/assets")

    hook_reply(
      view,
      "upload:grant",
      %{
        "version" => 1,
        "filename" => "timer.pdf",
        "size" => 5,
        "mediaType" => "application/pdf",
        "idempotencyKey" => "timer-attempt"
      },
      %{
        ok: true,
        grantId: @grant_id,
        uploadToken: "timer-token",
        uploadUrl: "/api/v1/uploads/#{@grant_id}",
        expiresAt: DateTime.to_iso8601(grant.expires_at)
      }
    )

    TestRuntimeApi.put(runtime_api, :cancel_upload_grant, {:error, :storage_unavailable})
    send(view.pid, {:asset_workspace_expire_upload_grant, @grant_id, 1})
    _html = render(view)

    %{socket: %{assigns: failed_assigns}} = :sys.get_state(view.pid)
    assert failed_assigns.pending_upload_grant == @grant_id

    TestRuntimeApi.put(runtime_api, :cancel_upload_grant, {:ok, true})
    send(view.pid, {:asset_workspace_expire_upload_grant, @grant_id, 2})
    _html = render(view)

    %{socket: %{assigns: retired_assigns}} = :sys.get_state(view.pid)
    assert is_nil(retired_assigns.pending_upload_grant)

    assert 2 ==
             runtime_api
             |> TestRuntimeApi.calls()
             |> Enum.count(&match?({:cancel_upload_grant, ^current_session, @grant_id}, &1))

    send(view.pid, {:asset_workspace_expire_upload_grant, @grant_id, 2})
    _html = render(view)

    assert 2 ==
             runtime_api
             |> TestRuntimeApi.calls()
             |> Enum.count(&match?({:cancel_upload_grant, ^current_session, @grant_id}, &1))

    bounded_grant_id = "019f9f0f-f384-78ef-8934-2d798944bce3"

    bounded_grant = %UploadGrant{
      grant_id: bounded_grant_id,
      asset_id: "019f9f0f-f384-78ef-8934-2d798944bce1",
      filename: "bounded.pdf",
      byte_size: 7,
      declared_media_type: "application/pdf",
      classification: :private,
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }

    TestRuntimeApi.put(
      runtime_api,
      :create_upload_grant,
      {:ok, "bounded-token", bounded_grant}
    )

    hook_reply(
      view,
      "upload:grant",
      %{
        "version" => 1,
        "filename" => "bounded.pdf",
        "size" => 7,
        "mediaType" => "application/pdf",
        "idempotencyKey" => "bounded-attempt"
      },
      %{
        ok: true,
        grantId: bounded_grant_id,
        uploadToken: "bounded-token",
        uploadUrl: "/api/v1/uploads/#{bounded_grant_id}",
        expiresAt: DateTime.to_iso8601(bounded_grant.expires_at)
      }
    )

    TestRuntimeApi.put(runtime_api, :cancel_upload_grant, {:error, :storage_unavailable})
    send(view.pid, {:asset_workspace_expire_upload_grant, bounded_grant_id, 3})
    _html = render(view)

    assert 1 ==
             runtime_api
             |> TestRuntimeApi.calls()
             |> Enum.count(
               &match?({:cancel_upload_grant, ^current_session, ^bounded_grant_id}, &1)
             )

    Process.sleep(350)

    assert 1 ==
             runtime_api
             |> TestRuntimeApi.calls()
             |> Enum.count(
               &match?({:cancel_upload_grant, ^current_session, ^bounded_grant_id}, &1)
             )

    %{socket: %{assigns: bounded_assigns}} = :sys.get_state(view.pid)
    assert bounded_assigns.pending_upload_grant == bounded_grant_id
  end

  test "a new grant retires the one bounded pending tracker before replacing it", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    second_grant_id = "019f9f0f-f384-78ef-8934-2d798944bce3"

    first = %UploadGrant{
      grant_id: @grant_id,
      asset_id: @asset_id,
      filename: "first.pdf",
      byte_size: 5,
      declared_media_type: "application/pdf",
      classification: :private,
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }

    second = %UploadGrant{
      grant_id: second_grant_id,
      asset_id: "019f9f0f-f384-78ef-8934-2d798944bce1",
      filename: "second.pdf",
      byte_size: 6,
      declared_media_type: "application/pdf",
      classification: :private,
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }

    TestRuntimeApi.put(runtime_api, :create_upload_grant, {:ok, "first-token", first})

    conn = authenticated_conn(conn, runtime_api, current_session, page([]))

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"_csrf_token" => @csrf_canary})
      |> live("/assets")

    hook_reply(
      view,
      "upload:grant",
      %{
        "version" => 1,
        "filename" => "first.pdf",
        "size" => 5,
        "mediaType" => "application/pdf",
        "idempotencyKey" => "first-attempt"
      },
      %{
        ok: true,
        grantId: @grant_id,
        uploadToken: "first-token",
        uploadUrl: "/api/v1/uploads/#{@grant_id}",
        expiresAt: DateTime.to_iso8601(first.expires_at)
      }
    )

    TestRuntimeApi.put(runtime_api, :cancel_upload_grant, {:ok, true})
    TestRuntimeApi.put(runtime_api, :create_upload_grant, {:ok, "second-token", second})

    hook_reply(
      view,
      "upload:grant",
      %{
        "version" => 1,
        "filename" => "second.pdf",
        "size" => 6,
        "mediaType" => "application/pdf",
        "idempotencyKey" => "second-attempt"
      },
      %{
        ok: true,
        grantId: second_grant_id,
        uploadToken: "second-token",
        uploadUrl: "/api/v1/uploads/#{second_grant_id}",
        expiresAt: DateTime.to_iso8601(second.expires_at)
      }
    )

    relevant_calls =
      Enum.filter(TestRuntimeApi.calls(runtime_api), fn
        {:create_upload_grant, _, _, _} -> true
        {:cancel_upload_grant, _, _} -> true
        _other -> false
      end)

    assert [
             {:create_upload_grant, ^current_session, _, @csrf_canary},
             {:cancel_upload_grant, ^current_session, @grant_id},
             {:create_upload_grant, ^current_session, _, @csrf_canary}
           ] = relevant_calls

    %{socket: %{assigns: assigns} = socket} = :sys.get_state(view.pid)
    assert assigns.pending_upload_grant == second_grant_id

    assert :ok = Singularity.Web.AssetsLive.terminate(:shutdown, socket)

    assert List.last(TestRuntimeApi.calls(runtime_api)) ==
             {:cancel_upload_grant, current_session, second_grant_id}
  end

  test "malformed grant expiry fails closed without crashing or leaking", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    conn = authenticated_conn(conn, runtime_api, current_session, page([]))

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"_csrf_token" => @csrf_canary})
      |> live("/assets")

    for expires_at <- malformed_datetimes() do
      grant = %UploadGrant{
        grant_id: @grant_id,
        asset_id: @asset_id,
        filename: "report.pdf",
        byte_size: 42,
        declared_media_type: "application/pdf",
        classification: :private,
        expires_at: expires_at
      }

      TestRuntimeApi.put(
        runtime_api,
        :create_upload_grant,
        {:ok, "required-upload-token", grant}
      )

      reply =
        assert_invalid_reply(
          view,
          "upload:grant",
          %{
            "version" => 1,
            "filename" => "report.pdf",
            "size" => 42,
            "mediaType" => "application/pdf",
            "idempotencyKey" => "browser-attempt-1"
          }
        )

      refute_secret_canaries(reply)
    end
  end

  test "malformed canonical timestamps terminate a lifecycle refresh without leaking", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)

    for updated_at <- malformed_datetimes() do
      {:ok, view, _html} = open_assets(conn, runtime_api, current_session, page([]))

      assert_push_event(view, "asset:snapshot", %{
        version: 1,
        sequence: 1,
        assets: %{items: [], nextCursor: nil}
      })

      TestRuntimeApi.put(
        runtime_api,
        :assets,
        {:ok, page([summary(updated_at: updated_at)])}
      )

      send(
        view.pid,
        {:asset_changed, %{vault_id: current_session.vault_id, asset_id: @asset_id}}
      )

      html = render(view)
      assert [_alert] = Floki.find(Floki.parse_document!(html), "[role=alert]")
      refute html =~ ~s(id="asset-workspace")
      refute_push_event(view, "asset:update", %{})
      refute_push_event(view, "asset:snapshot", %{})
      refute_secret_canaries(html)
    end
  end

  test "malformed session expiry is exposed as nil without crashing or leaking", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    for expires_at <- malformed_datetimes() do
      current_session = %{session(true) | expires_at: expires_at}

      {:ok, view, html} =
        open_assets(conn, runtime_api, current_session, page([]))

      [{"div", attributes, []}] =
        html
        |> Floki.parse_document!()
        |> Floki.find("#asset-workspace")

      props =
        attributes
        |> attribute!("data-props")
        |> JSON.decode!()

      assert get_in(props, ["vault", "expiresAt"]) == nil
      refute_secret_canaries(props)

      assert_push_event(view, "asset:snapshot", %{
        version: 1,
        sequence: 1,
        assets: %{items: [], nextCursor: nil}
      })
    end
  end

  test "retry and delete require a valid UUID and current nonnegative revision", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    {:ok, view, _html} = open_assets(conn, runtime_api, current_session, page([]))

    TestRuntimeApi.put(runtime_api, :retry_asset, {:ok, true})
    TestRuntimeApi.put(runtime_api, :delete_asset, {:ok, false})

    retry_reply =
      hook_reply(
        view,
        "asset:retry",
        %{
          "version" => 1,
          "assetId" => @asset_id,
          "stateRevision" => 8
        },
        %{ok: true, accepted: true}
      )

    delete_reply =
      hook_reply(
        view,
        "asset:delete",
        %{
          "version" => 1,
          "assetId" => @asset_id,
          "stateRevision" => 9
        },
        %{ok: true, accepted: false}
      )

    refute_secret_canaries(retry_reply)
    refute_secret_canaries(delete_reply)

    assert {:retry_asset, current_session, @asset_id, 8} in TestRuntimeApi.calls(runtime_api)

    assert {:delete_asset, current_session, @asset_id, 9} in TestRuntimeApi.calls(runtime_api)
  end

  test "navigation accepts every exact allow-listed path and rejects lookalikes", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)

    {:ok, rejected_view, _html} =
      open_assets(conn, runtime_api, current_session, page([]))

    for path <- [
          "/admin",
          "/assets/",
          "/activity?tab=all",
          "/Assets",
          "https://example.com/assets",
          "//example.com",
          ""
        ] do
      reply =
        assert_invalid_reply(
          rejected_view,
          "navigate",
          %{"version" => 1, "to" => path}
        )

      refute_secret_canaries(reply)
    end

    for path <- ["/assets", "/activity", "/audit", "/backups", "/settings"] do
      {:ok, view, _html} =
        open_assets(conn, runtime_api, current_session, page([]))

      reply =
        hook_reply(
          view,
          "navigate",
          %{"version" => 1, "to" => path},
          %{ok: true}
        )

      refute_secret_canaries(reply)
      assert_redirect(view, path)
    end
  end

  test "bridge rejects extra, missing, wrong, and non-v1 fields without runtime calls", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = session(true)
    {:ok, view, _html} = open_assets(conn, runtime_api, current_session, page([]))

    contracts = [
      {"asset:search", %{"version" => 1, "q" => "", "state" => nil, "mediaType" => nil}, "q",
       [
         %{"version" => 1, "q" => 42, "state" => nil, "mediaType" => nil},
         %{"version" => 1, "q" => "", "state" => "unknown", "mediaType" => nil},
         %{"version" => 1, "q" => "", "state" => nil, "mediaType" => 42}
       ]},
      {"asset:page",
       %{
         "version" => 1,
         "cursor" => "cursor",
         "q" => "",
         "state" => nil,
         "mediaType" => nil
       }, "cursor",
       [
         %{
           "version" => 1,
           "cursor" => "",
           "q" => "",
           "state" => nil,
           "mediaType" => nil
         },
         %{
           "version" => 1,
           "cursor" => 42,
           "q" => "",
           "state" => nil,
           "mediaType" => nil
         }
       ]},
      {"upload:grant",
       %{
         "version" => 1,
         "filename" => "report.pdf",
         "size" => 42,
         "mediaType" => "application/pdf",
         "idempotencyKey" => "attempt-1"
       }, "filename",
       [
         %{
           "version" => 1,
           "filename" => "report.pdf",
           "size" => -1,
           "mediaType" => "application/pdf",
           "idempotencyKey" => "attempt-1"
         },
         %{
           "version" => 1,
           "filename" => "report.pdf",
           "size" => 42,
           "mediaType" => "text/plain",
           "idempotencyKey" => "attempt-1"
         },
         %{
           "version" => 1,
           "filename" => "report.pdf",
           "size" => 42,
           "mediaType" => "application/pdf",
           "idempotencyKey" => ""
         }
       ]},
      {"upload:cancel", %{"version" => 1, "grantId" => @grant_id}, "grantId",
       [
         %{"version" => 1, "grantId" => "not-a-uuid"},
         %{"version" => 1, "grantId" => 42}
       ]},
      {"asset:retry", %{"version" => 1, "assetId" => @asset_id, "stateRevision" => 1}, "assetId",
       [
         %{"version" => 1, "assetId" => "asset-1", "stateRevision" => 1},
         %{"version" => 1, "assetId" => @asset_id, "stateRevision" => -1}
       ]},
      {"asset:delete", %{"version" => 1, "assetId" => @asset_id, "stateRevision" => 1},
       "stateRevision",
       [
         %{"version" => 1, "assetId" => "asset-1", "stateRevision" => 1},
         %{"version" => 1, "assetId" => @asset_id, "stateRevision" => "1"}
       ]},
      {"navigate", %{"version" => 1, "to" => "/activity"}, "to", [%{"version" => 1, "to" => 42}]}
    ]

    before = asset_calls(runtime_api)

    for {event, payload, required_key, wrong_payloads} <- contracts do
      invalid_payloads = [
        Map.put(payload, "extra", @opaque_key_canary),
        Map.delete(payload, required_key),
        Map.put(payload, "version", 2)
      ]

      for invalid_payload <- invalid_payloads ++ wrong_payloads do
        reply = assert_invalid_reply(view, event, invalid_payload)
        refute_secret_canaries(reply)
      end
    end

    assert_invalid_reply(view, "asset:unknown", %{"version" => 1})
    assert asset_calls(runtime_api) == before
  end

  test "runtime errors fail closed without serializing secret canaries", %{
    conn: conn,
    runtime_api: runtime_api
  } do
    current_session = %{session(true) | session_id: @session_canary}
    {:ok, view, html} = open_assets(conn, runtime_api, current_session, page([]))

    TestRuntimeApi.put(
      runtime_api,
      :assets,
      {:error, {:credential, @opaque_key_canary}}
    )

    search_reply =
      assert_invalid_reply(
        view,
        "asset:search",
        %{
          "version" => 1,
          "q" => "",
          "state" => nil,
          "mediaType" => nil
        }
      )

    TestRuntimeApi.put(
      runtime_api,
      :retry_asset,
      {:error, {:credential, @opaque_key_canary}}
    )

    retry_reply =
      assert_invalid_reply(
        view,
        "asset:retry",
        %{
          "version" => 1,
          "assetId" => @asset_id,
          "stateRevision" => 1
        }
      )

    refute_secret_canaries([html, search_reply, retry_reply])
  end

  defp open_assets(conn, runtime_api, current_session, page) do
    conn = authenticated_conn(conn, runtime_api, current_session, page)
    live(conn, "/assets")
  end

  defp authenticated_conn(conn, runtime_api, current_session, page) do
    TestRuntimeApi.put(runtime_api, :sessions, %{
      "opaque-session" => {:ok, current_session}
    })

    TestRuntimeApi.put(runtime_api, :assets, {:ok, page})
    put_session_id(conn, "opaque-session")
  end

  defp page(items, next_cursor \\ nil),
    do: %SearchPage{items: items, next_cursor: next_cursor}

  defp summary(overrides \\ []) do
    defaults = %{
      id: @asset_id,
      resource_version_id: @version_id,
      title: "Annual report",
      original_filename: "report.pdf",
      detected_media_type: "application/pdf",
      state: :available,
      state_revision: 3,
      label: "private",
      progress: %{kind: :indeterminate},
      failure: nil,
      updated_at: ~U[2026-07-29 01:02:03Z]
    }

    struct!(AssetSummary, Map.merge(defaults, Map.new(overrides)))
  end

  defp malformed_datetimes do
    datetime = ~U[2026-07-29 01:02:03Z]

    [
      %{datetime | year: @opaque_key_canary},
      %{datetime | month: 13},
      %{datetime | utc_offset: 999_999}
    ]
  end

  defp browser_summary(summary) do
    summary
    |> browser_summary_atoms()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), stringify_keys(value)} end)
  end

  defp browser_summary_atoms(summary) do
    %{
      id: summary.id,
      resourceVersionId: summary.resource_version_id,
      title: summary.title,
      originalFilename: summary.original_filename,
      detectedMediaType: summary.detected_media_type,
      state: Atom.to_string(summary.state),
      stateRevision: summary.state_revision,
      label: summary.label,
      progress: stringify_atom_values(summary.progress),
      failure: stringify_atom_values(summary.failure),
      updatedAt: DateTime.to_iso8601(summary.updated_at)
    }
  end

  defp stringify_atom_values(nil), do: nil

  defp stringify_atom_values(map) do
    Map.new(map, fn
      {:kind, value} when is_atom(value) -> {:kind, Atom.to_string(value)}
      pair -> pair
    end)
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {Atom.to_string(key), stringify_keys(nested)}
    end)
  end

  defp stringify_keys(nil), do: nil
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp attribute!(attributes, key),
    do: attributes |> Map.new() |> Map.fetch!(key)

  defp snapshot_generation(view) do
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    generation = Map.fetch!(assigns, :snapshot_generation)
    assert is_reference(generation)
    generation
  end

  defp refresh_generation(view) do
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    generation = Map.fetch!(assigns, :refresh_generation)
    assert is_reference(generation)
    generation
  end

  defp serialized(value), do: JSON.encode!(value)

  defp assert_invalid_reply(view, event, payload) do
    hook_reply(view, event, payload, %{ok: false, error: %{code: "invalid"}})
  end

  defp hook_reply(view, event, payload, expected) do
    _html = render_hook(view, event, payload)
    %{proxy: {ref, _topic, _target}} = view
    assert_receive {^ref, {:reply, ^expected}}
    expected
  end

  defp refute_secret_canaries(value) do
    surface = if is_binary(value), do: value, else: serialized(value)
    refute surface =~ @session_canary
    refute surface =~ @csrf_canary
    refute surface =~ @opaque_key_canary
  end

  defp asset_calls(runtime_api) do
    Enum.filter(TestRuntimeApi.calls(runtime_api), fn
      {name, _session, _params}
      when name in [:list_assets, :asset_summary] ->
        true

      {:subscribe_assets, _session} ->
        true

      {name, _session, _asset_id, _revision}
      when name in [:retry_asset, :delete_asset] ->
        true

      {:create_upload_grant, _session, _attrs, _csrf_token} ->
        true

      {:cancel_upload_grant, _session, _grant_id} ->
        true

      _other ->
        false
    end)
  end
end
