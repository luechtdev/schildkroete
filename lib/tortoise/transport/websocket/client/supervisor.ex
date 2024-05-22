defmodule Tortoise.Transport.Websocket.Client.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(_) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_child(args) do
    child_spec = Tortoise.Transport.Websocket.Client.child_spec(args)
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
