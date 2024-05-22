defmodule Tortoise.Transport.Websocket do
  @moduledoc false

  @behaviour Tortoise.Transport

  alias Tortoise.Transport
  alias Tortoise.Transport.Websocket.Client

  @impl true
  def new(opts) do
    {host, opts} = Keyword.pop(opts, :host)
    {port, opts} = Keyword.pop(opts, :port, 8883)
    host = coerce_host(host)
    %Transport{type: __MODULE__, host: host, port: port, opts: opts}
  end

  defp coerce_host(host) when is_binary(host) do
    String.to_charlist(host)
  end

  defp coerce_host(host) when is_tuple(host) do
    :inet.ntoa(host)
  end

  defp coerce_host(otherwise) do
    otherwise
  end

  @impl true
  def connect(host, port, opts, timeout) do
    opts =
      Enum.map(opts, fn
        {:tls, true} -> {:transport, :tls}
        {:tls, false} -> {:transport, :tcp}
        opt -> opt
      end)

    Client.connect(host, port, opts, timeout)
  end

  @impl true
  def recv(socket, length, timeout) do
    Client.recv(socket, length, timeout)
  end

  @impl true
  def send(socket, data) do
    data =
      cond do
        is_list(data) -> :erlang.list_to_binary(data)
        true -> data
      end

    case socket do
      %Client.Socket{} -> Client.send(socket, data)
      %Socket.Web{} -> Socket.Web.send(socket, {:binary, data})
    end
  end

  @impl true
  def setopts(socket, opts) do
    case socket do
      %Client.Socket{} ->
        active = Keyword.get(opts, :active, false)
        Client.set_active(socket, active)

      %Socket.Web{socket: socket} ->
        opts =
          Enum.map(opts, fn
            :binary -> {:as, :binary}
            {:active, false} -> {:mode, :passive}
            {:active, true} -> {:mode, :active}
            {:active, :once} -> {:mode, :once}
            opt -> opt
          end)

        Socket.TCP.options(socket, opts)
    end
  end

  @impl true
  def getopts(_socket, _opts) do
    throw("Not implemented")
  end

  @impl true
  def getstat(_socket) do
    throw("Not implemented")
  end

  @impl true
  def getstat(_socket, _opt_names) do
    throw("Not implemented")
  end

  @impl true
  def controlling_process(socket, pid) do
    Client.controlling_process(socket, pid)
  end

  @impl true
  def peername(%Socket.Web{socket: socket}) do
    :inet.peername(socket)
  end

  @impl true
  def sockname(%Socket.Web{socket: socket}) do
    :inet.sockname(socket)
  end

  @impl true
  def shutdown(_socket, _mode) do
    throw("Not implemented")
  end

  @impl true
  def close(socket) do
    case socket do
      %Client.Socket{} -> Client.close(socket)
      %Socket.Web{} -> Socket.Web.close(socket)
    end
  end

  @impl true
  def listen(opts) do
    opts =
      Enum.map(opts, fn
        :binary -> {:as, :binary}
        {:active, false} -> {:mode, :passive}
        {:active, true} -> {:mode, :active}
        {:active, :once} -> {:mode, :once}
        opt -> opt
      end)

    Socket.Web.listen(0, opts)
  end

  @impl true
  def accept(listen_socket, _timeout) do
    {:ok, client} = Socket.Web.accept(listen_socket)
    Socket.Web.accept!(client)
    {:ok, client}
  end

  @impl true
  def accept_ack(_socket, _timeout) do
    :ok
  end
end
