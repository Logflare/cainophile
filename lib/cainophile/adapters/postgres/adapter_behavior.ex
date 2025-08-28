defmodule Cainophile.Adapters.Postgres.AdapterBehaviour do
  @callback init(config :: term) ::
              {:ok, %Cainophile.Adapters.Postgres.State{}} | {:stop, reason :: binary}

  @callback acknowledge_lsn(connection :: pid, {xlog :: integer, offset :: integer}) :: :ok

  @callback fetch_current_wal_lsn(config :: term) ::
              {:ok, {xlog :: integer, offset :: integer}} | {:error, term}

  @callback cleanup(connection :: pid) :: :ok
end
