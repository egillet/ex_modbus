defmodule ExModbus.Client do
  @moduledoc """
  ModbusTCP client to manage communication with a device
  """

  use Connection
  require Logger

  @read_timeout 4000
  @backoff_initial 1000
  @backoff_max 30_000

  # Public Interface

  def start_link(args, opts \\ [])

  def start_link(ip = {_a, _b, _c, _d}, opts) do
    start_link(%{ip: ip}, opts)
  end
  def start_link(args = %{ip: ip, port: port, name: name}, opts) do
    Connection.start_link(__MODULE__, {ip, port, opts, Map.get(args, :timeout, @read_timeout), Map.get(args, :from)}, name: name)
  end
  def start_link(args = %{ip: ip, port: port}, opts) do
    Connection.start_link(__MODULE__, {ip, port, opts, Map.get(args, :timeout, @read_timeout), Map.get(args, :from) })
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

  def read_discrete_inputs(pid, unit_id, start_address, count) do
    Connection.call(pid, {:read_discrete_inputs, %{unit_id: unit_id, start_address: start_address, count: count}})
  end
  
  def read_input_registers(pid, unit_id, start_address, count) do
    Connection.call(pid, {:read_input_registers, %{unit_id: unit_id, start_address: start_address, count: count}})
  end
  
  def read_holding_registers(pid, unit_id, start_address, count) do
    Connection.call(pid, {:read_holding_registers, %{unit_id: unit_id, start_address: start_address, count: count}})
  end
  

  @doc """
  Write a single coil at address. Possible states are `:on` and `:off`.
  """
  def write_single_coil(pid, unit_id, address, state) do
    Connection.call(pid, {:write_single_coil, %{unit_id: unit_id, start_address: address, state: state}})
  end

  def write_multiple_coils(pid, unit_id, address, state) do
    Connection.call(pid, {:write_multiple_coils, %{unit_id: unit_id, start_address: address, state: state}})
  end

  def write_single_register(pid, unit_id, address, data) do
    Connection.call(pid, {:write_single_register, %{unit_id: unit_id, start_address: address, state: data}})
  end


  def write_multiple_registers(pid, unit_id, address, data) do
    Connection.call(pid, {:write_multiple_registers, %{unit_id: unit_id, start_address: address, state: data}})
  end

  def generic_call(pid, unit_id, args, retry \\ 1), do: generic_call_retry(pid, unit_id, args, retry)
  
  def generic_call_retry(pid, unit_id, {call, address, data}, retry) do
      case Connection.call(pid, {call, %{unit_id: unit_id, start_address: address, state: data}}) do
          :closed -> 
            if retry > 1 do
              generic_call_retry(pid, unit_id, {call, address, data}, retry-1)
            else
              :closed
            end
          %{data: {_type, res}} -> 
            res
          {:error, err} -> 
             if retry > 1 do
               generic_call_retry(pid, unit_id, {call, address, data}, retry-1)
             else
               err
             end
      end
  end

  def generic_call_retry(pid, unit_id, {call, address, count, transform}, retry) do
      case Connection.call(pid, {call, %{unit_id: unit_id, start_address: address, count: count}}) do
          :closed -> 
            if retry > 1 do
              generic_call_retry(pid, unit_id, {call, address, count, transform}, retry-1)
            else
              :closed
            end
          %{data: {_type, data}} -> 
            transform.(data)
          {:error, err} -> 
            if retry > 1 do
              generic_call_retry(pid, unit_id, {call, address, count, transform}, retry-1)
            else
              err
            end
      end
  end

  ## Connection Callbacks

  def send(conn, data), do: Connection.call(conn, {:send, data})

  def recv(conn, bytes, timeout \\ 3000) do
    Connection.call(conn, {:recv, bytes, timeout})
  end

  def close(conn), do: Connection.call(conn, :close)

  def init({host, port, opts, timeout, from}) do
    s = %{
          socket: nil,
          host: host, 
          port: port, 
          opts: opts, 
          timeout: timeout || @read_timeout,
          backoff_delay: @backoff_initial, 
          from: from
        }
    {:connect, :init, s}
  end

  def init(%{ip: ip}=args) do
    {
      :connect, 
      :init, 
      %{
          socket: nil, 
          host: ip, 
          port: Map.get(args, :port,  Modbus.Tcp.port),
          opts:  Map.get(args, :opts, []),
          timeout:  Map.get(args, :timeout) || @read_timeout,
          backoff_delay: @backoff_initial, 
          from: Map.get(args, :from)
       }
    }
  end

  def connect(arg, %{socket: nil, host: host, port: port, timeout: timeout, backoff_delay: backoff_delay, from: from}=s) do
    Logger.debug "Connecting whith arg: #{inspect arg} to #{inspect(s)}"
    case :gen_tcp.connect(host, port, [:binary, {:active, false}], timeout) do
      {:ok, socket} ->
        Logger.debug "Connected to #{inspect(host)}"
        unless is_nil(from) do
          Kernel.send(from, :socket_connected)
        end
        {:ok, %{s | socket: socket, backoff_delay: @backoff_initial}}
      {:error, _} ->
        backoff_delay = case arg do
          :backoff -> 
            min(@backoff_max, round(backoff_delay * 1.3))
          _ -> 
            backoff_delay
        end
        {:backoff, backoff_delay, %{s | backoff_delay: backoff_delay}}
    end
  end

  def disconnect(_info, %{socket: nil} = s), do: {:connect, :reconnect, s}
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
    unless is_nil(s.from) do
      Kernel.send(s.from, :socket_disconnected)
    end
    {:connect, :reconnect, %{s | socket: nil}}
  end

  # Connection Callbacks

  def handle_call({:read_coils, %{unit_id: unit_id, start_address: address, count: count}}, _from, state) do
    # limits the number of coils returned to the number `count` from the request
    limit_to_count = fn msg ->
                        {:read_coils, lst} = msg.data
                        %{msg | data: {:read_coils, Enum.take(lst, count)}}
    end
    response = Modbus.Packet.read_coils(address, count)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_packet(state)

    response = case response do
      {:reply, %{data: {:read_coils, _}} = device_response} ->
        {:reply, limit_to_count.(device_response)}
      _ -> response
    end
    Tuple.append response, state
  end

  def handle_call({:read_discrete_inputs, %{unit_id: unit_id, start_address: address, count: count}}, _from, state) do
    # limits the number of digits returned to the number `count` from the request
    limit_to_count = fn msg ->
                        {:read_discrete_inputs, lst} = msg.data
                        %{msg | data: {:read_discrete_inputs, Enum.take(lst, count)}}
    end
    response = Modbus.Packet.read_discrete_inputs(address, count)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_packet(state)
    response = case response do
      {:reply, %{data: {:read_discrete_inputs, _}} = device_response} ->
          {:reply, limit_to_count.(device_response)}
      _ -> response
    end
    Tuple.append response, state
  end

  def handle_call({:read_input_registers, %{unit_id: unit_id, start_address: address, count: count}}, _from, state) do
    response = Modbus.Packet.read_input_registers(address, count)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_packet(state)
    Tuple.append response, state
  end

  def handle_call({:read_holding_registers, %{unit_id: unit_id, start_address: address, count: count}}, _from, state) do
    response = Modbus.Packet.read_holding_registers(address, count)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_packet(state)
    Tuple.append response, state
  end


  def handle_call({:read_binary_coils, %{unit_id: unit_id, start_address: address, count: count}}, _from, state) do
    response = Modbus.Packet.read_coils(address, count)
              |> Modbus.Tcp.wrap_packet(unit_id)
              |> send_and_rcv_binary_packet(state)
    Tuple.append response, state
  end

  def handle_call({:read_binary_discrete_inputs, %{unit_id: unit_id, start_address: address, count: count}}, _from, state) do
    response = Modbus.Packet.read_discrete_inputs(address, count)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_binary_packet(state)
    Tuple.append response, state
  end

  def handle_call({:read_binary_input_registers, %{unit_id: unit_id, start_address: address, count: count}}, _from, state) do
    response = Modbus.Packet.read_input_registers(address, count)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_binary_packet(state)
    Tuple.append response, state
  end

  def handle_call({:read_binary_holding_registers, %{unit_id: unit_id, start_address: address, count: count}}, _from, state) do
    response = Modbus.Packet.read_holding_registers(address, count)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_binary_packet(state)
    Tuple.append response, state
  end


  def handle_call({:write_single_coil, %{unit_id: unit_id, start_address: address, state: data}}, _from, state) do
    response = Modbus.Packet.write_single_coil(address, data)
               |> Modbus.Tcp.wrap_packet(unit_id)
               |> send_and_rcv_packet(state)
    Tuple.append response, state
  end

  def handle_call({:write_multiple_coils, %{unit_id: unit_id, start_address: address, state: data}}, _from, state) do
    response = Modbus.Packet.write_multiple_coils(address, data)
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
  
  defp send_and_rcv_packet(_, %{socket: nil}), do: {:disconnect, :closed, :closed}
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

  defp send_and_rcv_binary_packet(_msg, %{socket: nil}), do: {:disconnect, :closed, :closed}
  defp send_and_rcv_binary_packet(msg, %{socket: socket}) do
    case :gen_tcp.send(socket, msg) do
      :ok ->
        case :gen_tcp.recv(socket, 0, @read_timeout) do
          {:ok, packet} ->
            unwrapped = Modbus.Tcp.unwrap_packet(packet)
            {:ok, data} = Modbus.Packet.parse_binary_response_packet(unwrapped.packet)
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
