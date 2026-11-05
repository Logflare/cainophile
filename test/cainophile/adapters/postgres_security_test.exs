defmodule Cainophile.Adapters.PostgresSecurityTest do
  use ExUnit.Case, async: true

  @behaviour Cainophile.Adapters.Postgres.AdapterBehaviour

  import ExUnit.CaptureLog

  alias Cainophile.Adapters.Postgres
  alias Cainophile.Adapters.Postgres.State

  @password "cainophile-dummy-password"

  @impl true
  def init(config) do
    {:ok, %State{config: config, connection: Keyword.fetch!(config, :cleanup_receiver)}}
  end

  @impl true
  def cleanup(receiver) do
    send(receiver, :connection_cleaned_up)
    :ok
  end

  @impl true
  def acknowledge_lsn(_connection, _lsn), do: :ok

  test "static passwords are hidden before the GenServer stores its configuration" do
    pid = start_postgres(%{password: @password})
    state = :sys.get_state(pid)
    password = state.config[:epgsql].password

    assert is_function(password, 0)
    assert password.() == @password
    refute inspect(state) =~ @password
    refute inspect(:sys.get_status(pid)) =~ @password
  end

  test "existing password callbacks are preserved and are not evaluated at startup" do
    receiver = self()

    password = fn ->
      send(receiver, :password_requested)
      @password
    end

    pid = start_postgres(%{password: password})
    state = :sys.get_state(pid)

    assert state.config[:epgsql].password == password
    refute_received :password_requested
  end

  test "EXIT from the connection drops it without cleanup and keeps the exit reason" do
    state = %State{
      config: [postgres_adapter: __MODULE__, epgsql: %{password: @password, username: "dummy"}],
      connection: self()
    }

    assert {:stop, :econnreset, stopped_state} =
             Postgres.handle_info({:EXIT, self(), :econnreset}, state)

    assert stopped_state.connection == nil
    Postgres.terminate(:econnreset, stopped_state)
    refute_received :connection_cleaned_up
  end

  test "EXIT from another linked process stops, and terminate cleans up the connection once" do
    other = spawn(fn -> :ok end)
    state = %State{config: [postgres_adapter: __MODULE__], connection: self()}

    assert {:stop, :killed, stopped_state} = Postgres.handle_info({:EXIT, other, :killed}, state)
    refute_received :connection_cleaned_up

    Postgres.terminate(:killed, stopped_state)
    assert_received :connection_cleaned_up
    refute_received :connection_cleaned_up
  end

  test "EXIT handling keeps a configuration without epgsql options unchanged" do
    state = %State{config: [postgres_adapter: __MODULE__]}

    assert {:stop, :normal, stopped_state} =
             Postgres.handle_info({:EXIT, self(), :normal}, state)

    assert stopped_state.config == [postgres_adapter: __MODULE__]

    assert Postgres.format_status(:terminate, [[], state]).config == [
             postgres_adapter: __MODULE__
           ]
  end

  test "status formatting redacts raw passwords without mutating live state" do
    state = %State{config: [epgsql: %{password: @password, username: "dummy"}]}

    for reason <- [:normal, :terminate] do
      refute inspect(Postgres.format_status(reason, [[], state])) =~ @password
    end

    assert state.config[:epgsql].password == @password
  end

  test "status formatting returns the redacted state itself for terminate" do
    state = %State{config: [epgsql: %{password: @password, username: "dummy"}]}

    assert %State{config: [epgsql: %{username: "dummy"}]} =
             Postgres.format_status(:terminate, [[], state])

    assert [data: [{"State", %State{}}]] = Postgres.format_status(:normal, [[], state])
  end

  test "proplist passwords are hidden at startup and redacted in status" do
    pid = start_postgres(password: @password, username: "dummy")
    state = :sys.get_state(pid)
    password = :proplists.get_value(:password, state.config[:epgsql])

    assert is_function(password, 0)
    assert password.() == @password
    assert :proplists.get_value(:username, state.config[:epgsql]) == "dummy"
    refute inspect(:sys.get_status(pid)) =~ @password
  end

  test "child_spec/1 hides map and proplist passwords in the start arguments" do
    for epgsql <- [%{password: @password}, [password: @password]] do
      %{start: {Postgres, :start_link, [config]}} =
        Postgres.child_spec(postgres_adapter: __MODULE__, epgsql: epgsql)

      refute inspect(config) =~ @password
    end
  end

  test "unexpected callback crashes do not log the password" do
    pid = start_postgres(%{password: @password})
    ref = Process.monitor(pid)

    commit_without_begin =
      <<67, 0, 0, 0, 0, 2, 167, 249, 2, 56, 0, 0, 0, 2, 167, 249, 2, 104, 0, 2, 49, 12, 168, 58,
        245, 78>>

    log =
      capture_log(fn ->
        send(pid, {:epgsql, self(), {:x_log_data, 0, 0, commit_without_begin}})
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end)

    assert log =~ "terminating"
    refute log =~ @password
    assert_received :connection_cleaned_up
  end

  defp start_postgres(epgsql) do
    start_supervised!(
      {Postgres, postgres_adapter: __MODULE__, epgsql: epgsql, cleanup_receiver: self()},
      restart: :temporary
    )
  end
end
