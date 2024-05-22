defmodule Tortoise.Transport.Websocket.MixProject do
  use Mix.Project

  def project do
    [
      app: :tortoise_transport_websocket,
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Tortoise.Transport.Websocket.Application, []}
    ]
  end

  defp deps do
    [
      {:gen_state_machine, "~> 2.0"},
      {:gun, "~> 1.3"},
      {:socket, "~> 0.3"},
    ]
  end

end
