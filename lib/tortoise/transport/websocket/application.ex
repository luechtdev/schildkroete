defmodule Tortoise.Transport.Websocket.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      Tortoise.Transport.Websocket.Client.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Tortoise.Transport.Websocket.Client.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
