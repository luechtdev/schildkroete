defmodule Tortoise.App do
  @moduledoc false

  use Application
  alias Tortoise.Transport.Websocket

  @impl true
  def start(type, _args) do
    # read configuration and start connections
    # start with client_id, and handler from config

    # Start websocket app
    Application.start(Websocket.Application, type)

    children = [
      {Registry, [keys: :unique, name: Tortoise.Registry]},
      {Registry, [keys: :duplicate, name: Tortoise.Events]},
      {Tortoise.Supervisor, [strategy: :one_for_one]}
    ]

    opts = [strategy: :one_for_one, name: Tortoise]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    # Propagate stop message to websocket app
    Application.stop(Websocket.Application)
    :ok
  end

end
