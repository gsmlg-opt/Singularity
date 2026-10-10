defmodule Singularity.Runtime.OrganizationAuthorizerTest do
  use ExUnit.Case, async: true

  alias Singularity.Core.Error
  alias Singularity.Runtime.SessionContext

  @wrapper Singularity.Runtime.Organization.Authorizer
  @principal "00000000-0000-4000-8000-00000000a001"
  @owner "00000000-0000-4000-8000-00000000a002"
  @other "00000000-0000-4000-8000-00000000a003"

  # This observer tests composition of returned outcomes only. It neither
  # reproduces nor qualifies live IdentityRepository/custody/lock behavior.
  defmodule Delegate do
    def check(observer, dependencies, repo, session, requirement) do
      send(observer, {:organization_delegated, dependencies, repo, session, requirement})

      case Process.get({__MODULE__, requirement.required_capability}, :ok) do
        function when is_function(function, 0) -> function.()
        result -> result
      end
    end
  end

  for mode <- [:read, :write] do
    @mode mode

    test "#{@mode} delegates one complete Note requirement without wrapper keys or recursion" do
      assert check(@mode) == :ok
      assert_delegated("note.#{@mode}", true)
      refute_received {:organization_delegated, _, _, _, _}
    end

    test "#{@mode} canonical forbidden or Note-lock denial permits independent Asset authorization" do
      for denial <- [Error.new(:forbidden), Error.new(:vault_locked)] do
        put("note.#{@mode}", {:error, denial})
        assert check(@mode) == :ok
        assert_delegated("note.#{@mode}", true)
        assert_delegated("asset.#{@mode}", false)
        refute_received {:organization_delegated, _, _, _, _}
      end
    end

    test "#{@mode} two denied alternatives stay denied and expose no private delegate error data" do
      put("note.#{@mode}", {:error, contaminated(:forbidden)})
      put("asset.#{@mode}", {:error, contaminated(:forbidden)})
      assert check(@mode) == {:error, Error.new(:forbidden)}
      assert_delegated("note.#{@mode}", true)
      assert_delegated("asset.#{@mode}", false)
      refute_received {:organization_delegated, _, _, _, _}
    end

    test "#{@mode} exposed operational unauthenticated and retryable outcomes abort without fallback" do
      for error <- [
            Error.new(:unauthenticated),
            Error.new(:storage_unavailable, retryable?: true),
            Error.new(:not_found),
            Error.new(:invalid),
            Error.new(:forbidden, retryable?: true),
            Error.new(:vault_locked, retryable?: true)
          ] do
        put(
          "note.#{@mode}",
          {:error, %{error | message: "PRIVATE_ERROR", details: %{body: "PRIVATE_BODY"}}}
        )

        assert check(@mode) == {:error, Error.new(error.code, retryable?: error.retryable?)}
        assert_delegated("note.#{@mode}", true)
        refute_received {:organization_delegated, _, _, _, _}
      end
    end

    test "#{@mode} malformed replies cannot masquerade as a canonical alternative denial" do
      for reply <- [
            nil,
            true,
            {:ok, :ok},
            {:error, :forbidden},
            {:error, %{code: :forbidden}},
            {:error, %{Error.new(:forbidden) | code: :unknown}},
            {:error, %{Error.new(:forbidden) | retryable?: :no}},
            {:error, Map.put(Error.new(:forbidden), :extra, "PRIVATE")}
          ] do
        put("note.#{@mode}", reply)
        assert check(@mode) == unavailable()
        assert_delegated("note.#{@mode}", true)
        refute_received {:organization_delegated, _, _, _, _}
      end
    end

    test "#{@mode} escaping delegate raise throw or exit is unavailable and never falls back" do
      for failure <- [:raise, :throw, :exit] do
        put("note.#{@mode}", fn ->
          case failure do
            :raise -> raise "PRIVATE_AUTHORITY"
            :throw -> throw("PRIVATE_AUTHORITY")
            :exit -> exit("PRIVATE_AUTHORITY")
          end
        end)

        assert check(@mode) == unavailable()
        assert_delegated("note.#{@mode}", true)
        refute_received {:organization_delegated, _, _, _, _}
      end
    end

    test "#{@mode} second alternative performs a complete check and exposed Asset lock stays a denial" do
      put("note.#{@mode}", {:error, Error.new(:forbidden)})
      put("asset.#{@mode}", {:error, contaminated(:vault_locked)})
      assert check(@mode) == {:error, Error.new(:vault_locked)}
      assert_delegated("note.#{@mode}", true)
      assert_delegated("asset.#{@mode}", false)
      refute_received {:organization_delegated, _, _, _, _}
    end
  end

  test "legacy principal epoch fallback binds explicitly and preserves the original session" do
    legacy = %{session() | principal_authorization_epoch: nil}
    assert check(:read, legacy) == :ok
    assert_delegated("note.read", true, legacy)
  end

  test "invalid trusted access owner classification and epoch bindings fail before delegation" do
    base = requirement(:read)

    for requirement <- [
          Map.delete(base, :organization_access),
          %{base | organization_access: :all},
          %{base | organization_access: "read"},
          %{base | vault_id: @other},
          %{base | classification: :sensitive},
          %{base | principal_authorization_epoch: 8},
          %{base | vault_authorization_epoch: 8},
          Map.put(base, :required_capability, "maintenance.run"),
          Map.put(base, :required_capabilities, []),
          Map.put(base, :owner_scope_id, @owner)
        ] do
      assert invoke({Delegate, self()}, session(), requirement) == {:error, Error.new(:invalid)}
      refute_received {:organization_delegated, _, _, _, _}
    end
  end

  test "a missing malformed or recursively wrapped delegate fails closed" do
    for delegate <- [nil, false, "delegate", {@wrapper, nil}, @wrapper] do
      assert invoke(delegate, session(), requirement(:read)) == {:error, Error.new(:invalid)}
      refute_received {:organization_delegated, _, _, _, _}
    end
  end

  # A forbidden returned by existing Authorize may conceal its internally
  # rescued dependency fault. Treat that opaque returned denial like any other
  # canonical forbidden, without claiming to distinguish its internal cause.
  test "opaque canonical forbidden may admit an independently successful alternative only" do
    put("note.read", {:error, Error.new(:forbidden)})
    put("asset.read", :ok)
    assert check(:read) == :ok
    assert_delegated("note.read", true)
    assert_delegated("asset.read", false)
  end

  defp check(mode, session_value \\ session()),
    do: invoke({Delegate, self()}, session_value, requirement(mode))

  defp invoke(delegate, session_value, requirement),
    do:
      apply(@wrapper, :check, [
        delegate,
        :authorization_dependencies,
        :scoped_repo,
        session_value,
        requirement
      ])

  defp put(capability, reply), do: Process.put({Delegate, capability}, reply)

  defp contaminated(code),
    do: Error.new(code, message: "PRIVATE_AUTHORITY", details: %{title: "PRIVATE_TITLE"})

  defp unavailable, do: {:error, Error.new(:storage_unavailable, retryable?: true)}

  defp assert_delegated(capability, unlocked?, session_value \\ session()) do
    expected = %{
      vault_id: @owner,
      classification: :private,
      requires_unlocked?: unlocked?,
      principal_authorization_epoch: 3,
      vault_authorization_epoch: 5,
      required_capability: capability
    }

    assert_received {:organization_delegated, :authorization_dependencies, :scoped_repo,
                     ^session_value, ^expected}
  end

  defp requirement(mode),
    do: %{
      organization_access: mode,
      vault_id: @owner,
      classification: :private,
      requires_unlocked?: true,
      principal_authorization_epoch: 3,
      vault_authorization_epoch: 5
    }

  defp session,
    do: %SessionContext{
      session_id: "00000000-0000-4000-8000-00000000a004",
      account_id: "00000000-0000-4000-8000-00000000a005",
      principal_id: @principal,
      vault_id: @owner,
      expires_at: ~U[2026-10-11 12:30:00Z],
      principal_authorization_epoch: 3,
      vault_authorization_epoch: 5,
      authorization_epoch: 3,
      unlocked?: true
    }
end
