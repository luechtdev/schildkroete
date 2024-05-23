defmodule Tortoise.Transport.Websocket.Client do
  @moduledoc ~S"""
  A Websocket client with a API similar to `:gen_tcp`.

  Example of usage where a client is started and connected, then it is used to send and receive
  data:
      iex> {:ok, socket} = Tortoise.Transport.Websocket.Client.connect('example.com', 80, [])
      iex> :ok = Tortoise.Transport.Websocket.Client.send(socket, "data")
      iex> {:ok, data} = Tortoise.Transport.Websocket.Client.recv(socket, 100)

  When the client has the option `:active` set to `true` or `:once` it will send to the process
  that started the client or the controlling process defined with `controlling_process/2` function
  messages with the format `{:websocket, socket, data}`, where `socket` is the client socket struct
  and `data` is a binary with the data received from the websocket server. If the the `:active`
  option was set to `:once` the client will set it to `false` after sending data once. When the
  option is set to `false`, the `recv/3` function must be used to retrieve data or the option needs
  to be set back to `true` or `:once` using the `set_active/2` function.

  When the connection is lost unexpectedly a message is sent with the format
  `{:websocket_closed, socket}`.

  To close the client connection to the websocket server the function `close/1` can be used, the
  connection to the websocket will be closed and the client process will be stopped.
  """

  use GenStateMachine, restart: :transient
  alias __MODULE__, as: Data
  alias __MODULE__.Socket
  alias :gun, as: Gun
  require Logger

  defstruct host: nil,
            port: nil,
            timeout: nil,
            owner: nil,
            owner_monitor_ref: nil,
            transport: nil,
            path: nil,
            headers: nil,
            ws_opts: nil,
            active: nil,
            caller: nil,
            socket: nil,
            buffer: "",
            tls_opts: [verify: :verify_peer],
            recv_queue: :queue.new()

  @type reason() :: any()
  @type opts() :: Keyword.t()

  def start_link(args) do
    GenStateMachine.start_link(__MODULE__, args)
  end

  @doc """
  Starts and connects a client to the websocket server.

  The `opts` paramameter is a Keyword list that expects the follwing optional entries:

  * `:transport - An atom with the transport protocol, either `:tcp` or `:tls`, defaults to `:tcp`
  * `:path` - A string with the websocket server path, defaults to `"/"`
  * `:headers` - A list of tuples with the HTTP headers to send to the server, defaults to `[]`
  * `:active` - A boolean or atom to indicate if the client should send back any received data, it
  can be `true`, `false` and `:once`, defaults to `false`
  * `:compress` - A boolean to indicate if the data should be compressed, defaults to `true`
  """
  @spec connect(charlist(), :inet.port_number(), opts(), timeout()) ::
          {:ok, Socket.t()} | {:error, reason()}
  def connect(host, port, opts \\ [], timeout \\ 5_000)
      when (is_list(host) or is_atom(host) or is_tuple(host)) and (is_integer(port) and port > 0) and
             is_list(opts) and is_integer(timeout) and timeout > 0 do
    case Tortoise.Transport.Websocket.Client.Supervisor.start_child({self(), host, port, opts, timeout}) do
      {:ok, pid} -> GenStateMachine.call(pid, :connect)
      error -> error
    end
  end

  @doc """
  Sends data to the websocket server.

  Data must be a binary or a list of binaries.
  """
  @spec send(Socket.t(), iodata()) :: :ok | {:error, reason()}
  def send(%Socket{pid: pid}, data) when is_binary(data) or is_list(data) do
    GenStateMachine.call(pid, {:send, data})
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc """
  When the client has the option `:active` set to `false`, the `recv/3` function can be used to
  retrieve any data sent by the server.

  If the provided length is `0`, it returns immediately with all data present in the client, even if
  there is none. If the timeout expires it returns `{:error, :timeout}`.
  """
  @spec recv(Socket.t(), non_neg_integer(), timeout()) :: {:ok, any()} | {:error, reason()}
  def recv(%Socket{pid: pid}, length, timeout \\ 5_000)
      when is_integer(length) and length >= 0 and is_integer(timeout) and timeout > 0 do
    GenStateMachine.call(pid, {:recv, length, timeout})
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc """
  Defines the process to which the data received by the client is sent to, when the client option
  `:active` is set to `true` or `:once`.
  """
  @spec controlling_process(Socket.t(), pid()) :: :ok | {:error, reason()}
  def controlling_process(%Socket{pid: pid}, new_owner_pid) when is_pid(new_owner_pid) do
    GenStateMachine.call(pid, {:owner, new_owner_pid})
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc """
  Closes the client connection to the websocket server and stops the client. Any data retained by
  the client will be lost.
  """
  @spec close(Socket.t()) :: :ok
  def close(%Socket{pid: pid}) do
    GenStateMachine.call(pid, :close)
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc """
  It defines the client `:active` option.

  The possible values for the `:active` options are `true`, `false` or `:once`. When the `:active`
  option is set to `:once`, the client will send back the first received frame of data and set the
  `:active` option to `false`.
  """
  @spec set_active(Socket.t(), boolean | :once) :: :ok | {:error, reason()}
  def set_active(%Socket{pid: pid}, active) when is_boolean(active) or active == :once do
    GenStateMachine.call(pid, {:set_active, active})
  catch
    :exit, _ -> {:error, :closed}
  end

  def init({owner, host, port, opts, timeout}) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)

    {compress, opts} = Keyword.pop(opts, :compress, true)
    ws_opts = %{compress: compress, protocols: [{"mqtt", :gun_ws_h}]}

    args =
      opts
      |> Keyword.put(:host, host)
      |> Keyword.put(:port, port)
      |> Keyword.put(:timeout, timeout)
      |> Keyword.put(:owner, owner)
      |> Keyword.put(:owner_monitor_ref, ref)
      |> Keyword.put_new(:transport, :tcp)
      |> Keyword.put_new(:path, "/")
      |> Keyword.put_new(:headers, [])
      |> Keyword.put_new(:active, false)
      |> Keyword.put(:ws_opts, ws_opts)

    {:ok, :disconnected, struct(Data, args)}
  end

  def handle_event(
        {:call, from},
        :connect,
        :disconnected,
        %Data{
          host: host,
          port: port,
          timeout: timeout,
          transport: transport,
          path: path,
          headers: headers,
          ws_opts: ws_opts,
          tls_opts: tls_opts
        } = data
      ) do
    Logger.debug("[tortoise_websocket] Opening connection")

    with start_time <- DateTime.utc_now(),
         {:ok, socket} <-
           Gun.open(host, port, %{
             transport: transport,
             connect_timeout: timeout,
             protocols: [:http],
             retry: 0,
             tls_opts: tls_opts
           }),
         timeout <- remaining_timeout(timeout, start_time),
         {:ok, _} <- Gun.await_up(socket, timeout) do
      Logger.debug("[tortoise_websocket] Upgrading connection")
      Gun.ws_upgrade(socket, path, headers, ws_opts)

      {:keep_state, %Data{data | caller: from},
       {:state_timeout, remaining_timeout(timeout, start_time), {:upgrade_timeout, socket, from}}}
    else
      {:error, {:shutdown, :econnrefused}} ->
        Logger.debug(
          "[tortoise_websocket] It was not possible to connect to host #{inspect(host)} on port #{
            port
          }"
        )

        error = {:error, :econnrefused}
        {:stop_and_reply, {:shutdown, error}, {:reply, from, error}}

      {:error, {:shutdown, :closed}} ->
        Logger.debug(
          "[tortoise_websocket] It was not possible to connect to host #{inspect(host)} on port #{
            port
          }"
        )

        error = {:error, :closed}
        {:stop_and_reply, {:shutdown, error}, {:reply, from, error}}

      {:error, {:shutdown, :nxdomain}} ->
        Logger.debug("[tortoise_websocket] Host #{host} not found")

        error = {:error, :nxdomain}
        {:stop_and_reply, {:shutdown, error}, {:reply, from, error}}

      {:error, {:shutdown, :timeout}} ->
        Logger.debug("[tortoise_websocket] Timeout while trying to connect")

        error = {:error, :timeout}
        {:stop_and_reply, {:shutdown, error}, {:reply, from, error}}

      error ->
        Logger.debug(
          "[tortoise_websocket] There was an error while trying to connect: #{inspect(error)}"
        )

        {:stop_and_reply, {:shutdown, error}, {:reply, from, error}}
    end
  end

  def handle_event({:call, from}, {:send, data}, {:connected, socket}, _) do
    Gun.ws_send(socket, {:binary, data})
    {:keep_state_and_data, {:reply, from, :ok}}
  end

  def handle_event(
        {:call, from},
        {:recv, length, timeout},
        {:connected, _},
        %Data{buffer: buffer, recv_queue: recv_queue} = data
      ) do
    cond do
      length == 0 ->
        {:keep_state, %Data{data | buffer: ""}, {:reply, from, {:ok, buffer}}}

      byte_size(buffer) >= length ->
        <<package::binary-size(length), rest::binary>> = buffer
        {:keep_state, %Data{data | buffer: rest}, {:reply, from, {:ok, package}}}

      true ->
        {:keep_state, %Data{data | recv_queue: :queue.in({from, length}, recv_queue)},
         {:timeout, timeout, {:recv_timeout, {from, length}}}}
    end
  end

  def handle_event(
        {:call, from},
        {:owner, new_owner},
        {:connected, _},
        %Data{owner_monitor_ref: owner_monitor_ref} = data
      ) do
    Process.demonitor(owner_monitor_ref)
    ref = Process.monitor(new_owner)
    {:keep_state, %Data{data | owner: new_owner, owner_monitor_ref: ref}, {:reply, from, :ok}}
  end

  def handle_event({:call, from}, :close, state, _) do
    case state do
      {:connected, socket} -> Gun.close(socket)
      _ -> :ok
    end

    {:stop_and_reply, :normal, {:reply, from, :ok}}
  end

  def handle_event({:call, from}, {:set_active, active}, {:connected, _}, data) do
    {:keep_state, %Data{data | active: active}, {:reply, from, :ok}}
  end

  def handle_event({:call, from}, _, :disconnected, _) do
    {:keep_state_and_data, {:reply, from, {:error, :not_connected}}}
  end

  def handle_event({:call, from}, _, _, _) do
    {:keep_state_and_data, {:reply, from, {:error, :unexpected_command}}}
  end

  def handle_event(:cast, _, _, _) do
    :keep_state_and_data
  end

  def handle_event(
        :info,
        {:gun_upgrade, socket, _, ["websocket"], _},
        :disconnected,
        %Data{caller: caller} = data
      ) do
    Logger.debug("[tortoise_websocket] Connection upgraded")

    client_socket = %Socket{pid: self()}

    {:next_state, {:connected, socket}, %Data{data | caller: nil, socket: client_socket},
     {:reply, caller, {:ok, client_socket}}}
  end

  def handle_event(
        :info,
        {:gun_response, socket, _, _, status, _},
        :disconnected,
        %Data{caller: caller}
      ) do
    Logger.debug(
      "[tortoise_websocket] It was not possible to upgrade connection, response status: #{
        inspect(status)
      }"
    )

    Gun.close(socket)
    error = {:error, {:ws_upgrade_failed, "Response status: #{status}"}}
    {:stop_and_reply, {:shutdown, error}, {:reply, caller, error}}
  end

  def handle_event(
        :info,
        {:gun_error, socket, _, reason},
        :disconnected,
        %Data{caller: caller}
      ) do
    Logger.debug(
      "[tortoise_websocket] Error while trying to upgrade connection, reason: #{inspect(reason)}"
    )

    Gun.close(socket)
    error = {:error, {:ws_upgrade_error, "Reason: #{inspect(reason)}"}}
    {:stop_and_reply, {:shutdown, error}, {:reply, caller, error}}
  end

  def handle_event(
        :info,
        {:gun_down, socket, _, reason, _, _},
        {:connected, socket},
        %Data{owner: owner, socket: client_socket}
      ) do
    Logger.debug("[tortoise_websocket] Connection went down, reason: #{inspect(reason)}")
    Kernel.send(owner, {:websocket_closed, client_socket})
    {:stop, {:shutdown, {:error, :down}}}
  end

  def handle_event(
        :info,
        {:gun_ws, socket, _, :close},
        {:connected, socket},
        %Data{owner: owner, socket: client_socket}
      ) do
    Logger.debug("[tortoise_websocket] Server closed connection")
    Kernel.send(owner, {:websocket_closed, client_socket})
    {:stop, {:shutdown, {:error, :closed}}}
  end

  def handle_event(
        :info,
        {:gun_ws, _, _, {:binary, frame}},
        {:connected, _},
        %Data{
          owner: owner,
          active: active,
          socket: socket,
          buffer: buffer,
          recv_queue: recv_queue
        } = data
      ) do
    buffer = <<buffer::binary, frame::binary>>

    {buffer, recv_queue} = satisfy_queued_recv(buffer, recv_queue)

    case active do
      true ->
        Kernel.send(owner, {:websocket, socket, buffer})
        {:keep_state, %Data{data | buffer: "", recv_queue: recv_queue}}

      :once ->
        Kernel.send(owner, {:websocket, socket, buffer})
        {:keep_state, %Data{data | active: false, buffer: "", recv_queue: recv_queue}}

      false ->
        {:keep_state, %Data{data | buffer: buffer, recv_queue: recv_queue}}
    end
  end

  def handle_event(:info, {:DOWN, owner_monitor_ref, :process, owner, _}, state, %Data{
        owner: owner,
        owner_monitor_ref: owner_monitor_ref
      }) do
    case state do
      {:connected, socket} -> Gun.close(socket)
      _ -> :ok
    end

    :stop
  end

  def handle_event(:info, msg, _, _) do
    Logger.debug("[tortoise_websocket] Received unexpected message: #{inspect(msg)}")
    :keep_state_and_data
  end

  def handle_event(:state_timeout, {:upgrade_timeout, socket, caller}, :disconnected, _) do
    Logger.debug("[tortoise_websocket] Timeout while trying to upgrade connection")
    Gun.close(socket)
    error = {:error, :timeout}
    {:stop_and_reply, {:shutdown, error}, {:reply, caller, error}}
  end

  def handle_event(
        :timeout,
        {:recv_timeout, {caller, length} = queued_recv},
        {:connected, _},
        %Data{recv_queue: recv_queue} = data
      ) do
    Logger.debug("[tortoise_websocket] Timeout while trying to receive data with #{length} bytes")
    recv_queue = :queue.filter(&(&1 != queued_recv), recv_queue)
    {:keep_state, %Data{data | recv_queue: recv_queue}, {:reply, caller, {:error, :timeout}}}
  end

  defp remaining_timeout(current_timeout, start_time),
    do: max(current_timeout - time_since(start_time), 0)

  defp time_since(datetime), do: DateTime.utc_now() |> DateTime.diff(datetime, :millisecond)

  defp satisfy_queued_recv(buffer, recv_queue) do
    recv_list = :queue.to_list(recv_queue)
    {buffer, recv_remaining} = satisfy_recv_items(buffer, recv_list)
    {buffer, :queue.from_list(recv_remaining)}
  end

  defp satisfy_recv_items(buffer, []), do: {buffer, []}

  defp satisfy_recv_items(buffer, [{caller, 0} | remaining_items]) do
    GenStateMachine.reply(caller, {:ok, buffer})
    {"", remaining_items}
  end

  defp satisfy_recv_items(buffer, [{_, length} | _] = items) when byte_size(buffer) < length,
    do: {buffer, items}

  defp satisfy_recv_items(buffer, [{caller, length} | remaining_items]) do
    <<data::binary-size(length), remaining_buffer::binary>> = buffer
    GenStateMachine.reply(caller, {:ok, data})
    satisfy_recv_items(remaining_buffer, remaining_items)
  end
end
