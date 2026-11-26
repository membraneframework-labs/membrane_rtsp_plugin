defmodule Membrane.RTSP.MockCamera do
  @moduledoc false
  # A scripted RTSP server. The script is a function `(method, request) -> reply`: the
  # reply goes on the wire byte for byte, with `{CSEQ}` replaced by the CSeq of the
  # request, and `:close` closes the connection. Messages from the client are forwarded
  # to the owner as `{:mock_camera, :request, method, request}` or
  # `{:mock_camera, :response, raw}`.

  use GenServer

  @type request :: %{url: binary(), headers: %{binary() => binary()}, raw: binary()}

  @spec start_link((binary(), request() -> iodata() | [iodata()] | :close), pid()) ::
          GenServer.on_start()
  def start_link(script, owner \\ self()), do: GenServer.start_link(__MODULE__, {script, owner})

  @spec port(pid()) :: :inet.port_number()
  def port(camera), do: GenServer.call(camera, :port)

  @spec close_connection(pid()) :: :ok
  def close_connection(camera), do: GenServer.call(camera, :close_connection)

  @spec response(binary(), [binary()], binary()) :: binary()
  def response(status_line \\ "RTSP/1.0 200 OK", headers \\ [], body \\ "") do
    Enum.join([status_line, "CSeq: {CSEQ}" | headers], "\r\n") <> "\r\n\r\n" <> body
  end

  @spec describe_response(binary(), [binary()]) :: binary()
  def describe_response(sdp, headers \\ ["Content-Type: application/sdp"]) do
    sdp = sdp |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n")
    response("RTSP/1.0 200 OK", headers ++ ["Content-Length: #{byte_size(sdp)}"], sdp)
  end

  @spec script(binary(), [iodata()], %{binary() => (request() -> iodata() | [iodata()] | :close)}) ::
          (binary(), request() -> iodata() | [iodata()] | :close)
  def script(sdp, media \\ [], overrides \\ %{}) do
    fn method, request ->
      case overrides do
        %{^method => override} -> override.(request)
        _no_override -> default_reply(method, request, sdp, media)
      end
    end
  end

  defp default_reply("OPTIONS", _request, _sdp, _media),
    do:
      response("RTSP/1.0 200 OK", [
        "Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER"
      ])

  defp default_reply("DESCRIBE", _request, sdp, _media), do: describe_response(sdp)

  defp default_reply("SETUP", request, _sdp, _media) do
    response("RTSP/1.0 200 OK", [
      "Session: 12345678;timeout=60",
      "Transport: " <> request.headers["transport"]
    ])
  end

  defp default_reply("PLAY", _request, _sdp, media),
    do: [response("RTSP/1.0 200 OK", ["Session: 12345678"]) | media]

  defp default_reply(_method, _request, _sdp, _media), do: response()

  @spec interleaved(0..255, binary()) :: binary()
  def interleaved(channel, packet), do: <<"$", channel, byte_size(packet)::16, packet::binary>>

  @spec rtp_packet(binary(), keyword()) :: binary()
  def rtp_packet(payload, opts) do
    marker = if opts[:marker], do: 1, else: 0

    <<2::2, 0::1, 0::1, 0::4, marker::1, Keyword.fetch!(opts, :payload_type)::7,
      Keyword.fetch!(opts, :sequence_number)::16, Keyword.fetch!(opts, :timestamp)::32,
      Keyword.get(opts, :ssrc, 0x1234ABCD)::32, payload::binary>>
  end

  @spec h264_rtp_packets(binary(), keyword()) :: [binary()]
  def h264_rtp_packets(annexb, opts) do
    {max_payload_size, opts} = Keyword.pop(opts, :max_payload_size, :infinity)

    nalus =
      annexb
      |> :binary.split(<<0, 0, 0, 1>>, [:global])
      |> Enum.reject(fn nalu -> nalu == <<>> end)

    {payloads, _acc} =
      Enum.flat_map_reduce(nalus, {0, false}, fn nalu, {timestamp, after_vcl?} ->
        <<_header::3, type::5, _rest::binary>> = nalu
        vcl? = type in [1, 5]
        timestamp = if after_vcl? and not vcl?, do: timestamp + 3000, else: timestamp

        {Enum.map(fragment(nalu, max_payload_size), &{&1, timestamp}), {timestamp, vcl?}}
      end)

    payloads
    |> Enum.with_index()
    |> Enum.map(fn {{payload, timestamp}, sequence_number} ->
      rtp_packet(payload, opts ++ [sequence_number: sequence_number, timestamp: timestamp])
    end)
  end

  # FU-A fragments of a NAL unit that does not fit (RFC 6184, section 5.8)
  defp fragment(nalu, max_payload_size) when byte_size(nalu) <= max_payload_size, do: [nalu]

  defp fragment(<<forbidden::1, nri::2, type::5, body::binary>>, max_payload_size) do
    chunks = chunks(body, max_payload_size - 2)
    last = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      start_bit = if index == 0, do: 1, else: 0
      end_bit = if index == last, do: 1, else: 0
      <<forbidden::1, nri::2, 28::5, start_bit::1, end_bit::1, 0::1, type::5, chunk::binary>>
    end)
  end

  defp chunks(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunks(binary, size) do
    {chunk, rest} = :erlang.split_binary(binary, size)
    [chunk | chunks(rest, size)]
  end

  @impl true
  def init({script, owner}) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)
    send(self(), :accept)

    {:ok,
     %{
       script: script,
       owner: owner,
       listen_socket: listen_socket,
       port: port,
       socket: nil,
       buffer: <<>>
     }}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:close_connection, _from, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    {:reply, :ok, %{state | socket: nil}}
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, 100) do
      {:ok, socket} ->
        :inet.setopts(socket, active: true)
        {:noreply, %{state | socket: socket, buffer: <<>>}}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, _closed} ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    {:noreply, handle_messages(%{state | buffer: state.buffer <> data})}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    send(state.owner, {:mock_camera, :closed})
    send(self(), :accept)
    {:noreply, %{state | socket: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_messages(state) do
    case String.split(state.buffer, "\r\n\r\n", parts: 2) do
      [message, rest] -> handle_messages(handle_message(message, %{state | buffer: rest}))
      [_incomplete] -> state
    end
  end

  defp handle_message("RTSP/" <> _rest = response, state) do
    send(state.owner, {:mock_camera, :response, response})
    state
  end

  defp handle_message(raw, state) do
    [request_line | header_lines] = String.split(raw, "\r\n")
    [method, url, _version] = String.split(request_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    request = %{url: url, headers: headers, raw: raw}
    send(state.owner, {:mock_camera, :request, method, request})

    case state.script.(method, request) do
      :close ->
        :gen_tcp.close(state.socket)
        %{state | socket: nil}

      reply ->
        reply
        |> List.wrap()
        |> Enum.each(fn part ->
          part = part |> IO.iodata_to_binary() |> :binary.replace("{CSEQ}", headers["cseq"] || "")
          :gen_tcp.send(state.socket, part)
        end)

        state
    end
  end
end
