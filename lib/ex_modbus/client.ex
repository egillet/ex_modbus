defmodule ExModbus.Client do
  @moduledoc """
  ModbusTCP client to manage communication with a device
  """

  use Connection
  require Logger

  @read_timeout 4000

  # Public Interface

  def start_link(args, opts \\ [])

  def start_link(ip = {_a, _b, _c, _d}, opts) do
    start_link(%{ip: ip}, opts)
  end
  def start_link(args = %{ip: _ip}, opts) do
    Connection.start_link(__MODULE__, args, opts)
  end

  def read_data(pid, unit_id, start_address, count) do
    Connection.call(pid, {:read_holding_registers, %{unit_id: unit_id, start_address: start_address, count: count}})
  end

  def read_coils(pid, unit_id, start_address, count) do
    Connection.call(pid, {:read_coils, %{unit_id: unit_id, start_address: start_address, count: count}})
  end

  @doc """
  Write a single coil at address. Possible states are `:on` and `:off`.
  """
  def write_single_coil(pid, unit_id, address, state) do
    Connection.call(pid, {:write_single_coil, %{unit_id: unit_id, start_address: address, state: state}})
  end


  def write_single_register(pid, unit_id, address, data) do
    Connection.call(pid, {:write_single_register, %{unit_id: unit_id, start_address: address, state: data}})
  end


  def write_multiple_registers(pid, unit_id, address, data) do
    Connection.call(pid, {:write_multiple_registers, %{unit_id: unit_id, start_address: address, state: data}})
  end


  def generic_call(pid, unit_id, {call, address, count, transform}) do
    %{data: {_type, data}} = Connection.call(pid, {call, %{unit_id: unit_id, start_address: address, count: count}})
    transform.(data)
  end

  ## Connection Callbacks

  def send(conn, data), do: Connection.call(conn, {:send, data})

  def recv(conn, bytes, timeout \\ 3000) do
    Connection.call(conn, {:recv, bytes, timeout})
  end

  def close(conn), do: Connection.call(conn, :close)

  def init({host, port, opts, timeout}) do
    s = %{host: host, port: port, opts: opts, timeout: timeout, socket: nil}
    {:connect, :init, s}
  end

  def init(%{ip: ip}) do
    {:connect, :init, %{socket: nil, host: ip}}
  end

  def connect(_, %{socket: nil, host: host} = s) do
    Logger.debug "Connecting to #{inspect(host)}"
    case :gen_tcp.connect(host, Modbus.Tcp.port, [:binary, {:active, false}], @read_timeout) do
      {:ok, socket} ->
        Logger.debug "Connected to #{inspect(host)}"
        {:ok, %{s | socket: socket}}
      {:error, _} ->
        {:backoff, 1000, s}
    end
  end

  def disconnect(info, %{socket: nil} = s), do: {:connect, :reconnect, s}
  def disconnect(info, %{socket: socket} = s) do
    :ok = :gen_tcp.close(socket)
    case info do
      {:close, from} ->
        Connection.reply(from, :ok)
      {:error, :closed} ->
        :error_logger.format("Connection closed~n", [])
      {:error, reason} ->
        reason = :inet.format_error(reason)
        :error_logger.format("Connection error: ~s~n", [reason])
    end
    {:connect, :reconnect, %{s | socket: nil}}
  end

  # Connection Callbacks

  def handle_call({:read_coils, %{unit_id: unit_id, start_address: address, count: count}}, _from, state) do
    # limits the number of coils returned to the number `count` from the request
    limit_to_count = fn msg ->
                        {:read_coils, lst} = msg.data
                        {_, elems} = Enum.split(lst, -count)
                        %{msg | data: {:read_coils, elems}}
    end
    response = Modbus.Packet.read_coils(address, count)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_packet(state)

    response = case response do
      {:reply, device_response} ->
        {:reply, limit_to_count.(device_response)}
      _ -> response
    end
    Tuple.append response, state
  end

  def handle_call({:read_holding_registers, %{unit_id: unit_id, start_address: address, count: count}}, _from, state) do
    response = Modbus.Packet.read_holding_registers(address, count)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_packet(state)
    Tuple.append response, state
  end

  def handle_call({:write_single_coil, %{unit_id: unit_id, start_address: address, state: data}}, _from, state) do
    response = Modbus.Packet.write_single_coil(address, data)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_packet(state)
    Tuple.append response, state
  end

  def handle_call({:write_single_register, %{unit_id: unit_id, start_address: address, state: data}}, _from, state) do
    response = Modbus.Packet.write_single_register(address,data)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_packet(state)
    Tuple.append response, state
  end

  def handle_call({:write_multiple_registers, %{unit_id: unit_id, start_address: address, state: data}}, _from, state) do
    response = Modbus.Packet.write_multiple_registers(address, data)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_packet(state)
    Tuple.append response, state
  end

  def handle_call(:close, from, s) do
    {:disconnect, {:close, from}, s}
  end

  def handle_call(msg, _from, state) do
    Logger.info "Unknown handle_call msg: #{inspect msg}"
    {:reply, "unknown call message", state}
  end

  def handle_call(_, %{socket: nil} = s) do
    {:reply, {:error, :closed}, s}
  end
  defp send_and_rcv_packet(_, %{socket: nil}) do
    {:disconnect, :closed, :closed}
  end

  defp send_and_rcv_packet(msg, %{socket: socket}) do
    case :gen_tcp.send(socket, msg) do
      :ok ->
        case :gen_tcp.recv(socket, 0, @read_timeout) do
          {:ok, packet} ->
            unwrapped = Modbus.Tcp.unwrap_packet(packet)
            {:ok, data} = Modbus.Packet.parse_response_packet(unwrapped.packet)
            {:reply, %{unit_id: unwrapped.unit_id, transaction_id: unwrapped.transaction_id, data: data}}
          {:error, :timeout} = timeout ->
            {:reply, timeout}
          {:error, _} = error ->
            {:disconnect, error, error}
        end
      {:error, _} = error ->
        {:disconnect,  error, error}
    end
  end

end
