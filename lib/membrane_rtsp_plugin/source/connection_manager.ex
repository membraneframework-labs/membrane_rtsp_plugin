defmodule Membrane.RTSP.Source.ConnectionManager do
  @moduledoc false

  use GenServer

  require Membrane.Logger

  alias Membrane.RTSP
  alias Membrane.RTSP.Source.Transport.TCPWrapper

  @content_type_header [{"accept", "application/sdp"}]

  @base_back_off_time Membrane.Time.milliseconds(10) |> Membrane.Time.as_milliseconds(:round)
  @max_back_off_time Membrane.Time.minutes(2) |> Membrane.Time.as_milliseconds(:round)

  @source_ready_timeout Membrane.Time.seconds(5) |> Membrane.Time.as_milliseconds(:round)

  @type media_types :: [:video | :audio | :application]
  @type connection_opts :: %{stream_uri: binary(), allowed_media_types: media_types()}

  @spec start_link(connection_opts()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, Map.put(options, :parent_pid, self()))
  end

  @spec stop(pid()) :: :ok
  def stop(server) do
    GenServer.call(server, :stop)
  end

  @spec transfer_rtsp_socket_control(connection_manager :: pid(), new_controller :: pid()) :: :ok
  def transfer_rtsp_socket_control(connection_manager, new_controller) do
    GenServer.call(connection_manager, {:transfer_rtsp_socket_control, new_controller})
  end

  @impl true
  def init(options) do
    state =
      Map.merge(options, %{
        rtsp_session: nil,
        tracks: [],
        status: :init,
        keep_alive_timer: nil,
        reconnect_attempt: 0
      })

    Process.send_after(self(), :connect, 0)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    state =
      with {:ok, state} <- start_rtsp_connection(state),
           {:ok, state} <- get_rtsp_description(state),
           {:ok, state} <- setup_rtsp_connection(state),
           {:ok, state} <- prepare_source(state) do
        %{
          state
          | keep_alive_timer: Process.send_after(self(), :keep_alive, state.keep_alive_interval)
        }
      else
        {:error, reason, state} -> handle_rtsp_error(reason, state)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:source_ready, state) do
    state =
      case play(state) do
        :ok ->
          %{
            state
            | keep_alive_timer: Process.send_after(self(), :keep_alive, state.keep_alive_interval)
          }

        {:error, reason, state} ->
          handle_rtsp_error(reason, state)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:keep_alive, state) do
    {:noreply, keep_alive(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{rtsp_session: pid} = state) do
    state =
      case state.status do
        :connected ->
          state
          |> notify_parent({:connection_failed, reason})
          |> cancel_keep_alive()
          |> retry()
          |> then(&%{&1 | status: :failed})

        _other ->
          state
      end

    {:noreply, %{state | rtsp_session: nil}}
  end

  @impl true
  def handle_info(message, state) do
    Membrane.Logger.warning("received unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    Membrane.RTSP.close(state.rtsp_session)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_call({:transfer_rtsp_socket_control, new_controller}, _from, state) do
    {:reply, RTSP.transfer_socket_control(state.rtsp_session, new_controller), state}
  end

  defp start_rtsp_connection(state) do
    options = [response_timeout: state.timeout, controlling_process: state.parent_pid]

    case RTSP.start(state.stream_uri, options) do
      {:ok, session} ->
        Process.monitor(session)
        {:ok, %{state | rtsp_session: session}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp get_rtsp_description(%{rtsp_session: rtsp_session} = state, retry \\ true) do
    Membrane.Logger.debug("ConnectionManager: Getting RTSP description")

    case RTSP.describe(rtsp_session, @content_type_header) do
      {:ok, %{status: 200} = response} ->
        tracks = get_tracks(response, state.allowed_media_types)
        {:ok, %{state | tracks: tracks}}

      {:ok, %{status: 401}} ->
        if retry, do: get_rtsp_description(state, false), else: {:error, :unauthorized, state}

      _result ->
        {:error, :getting_rtsp_description_failed, state}
    end
  end

  defp setup_rtsp_connection(%{rtsp_session: rtsp_session} = state) do
    Membrane.Logger.debug("ConnectionManager: Setting up RTSP connection")

    state.tracks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, fn {{control_path, _track}, idx}, {:ok, state} ->
      with {:ok, transport_header} <- build_transport_header(state, idx),
           {:ok, %{status: 200}} <- RTSP.setup(rtsp_session, control_path, transport_header) do
        {:cont, {:ok, state}}
      else
        error ->
          Membrane.Logger.debug(
            "ConnectionManager: Setting up RTSP connection failed: #{inspect(error)}"
          )

          {:halt, {:error, :setting_up_rtsp_connection_failed, state}}
      end
    end)
  end

  defp prepare_source(state) do
    state = %{state | status: :connected, reconnect_attempt: 0}

    transport_info =
      case state.transport do
        :tcp ->
          {:tcp, RTSP.get_socket(state.rtsp_session)}

        {:udp, port_range_start, _port_range_end} ->
          {:udp, port_range_start, port_range_start + map_size(state.tracks) * 2}
      end

    notify_parent(state, %{tracks: Map.values(state.tracks), transport_info: transport_info})

    {:ok, state}
  end

  defp play(%{rtsp_session: rtsp_session, transport: {:udp, _, _}} = state) do
    Membrane.Logger.debug("ConnectionManager: Setting RTSP on play mode")

    case RTSP.play(rtsp_session) do
      {:ok, %{status: 200}} -> :ok
      _error -> {:error, :play_rtsp_failed, state}
    end
  end

  defp play(%{rtsp_session: rtsp_session, transport: :tcp}) do
    Membrane.Logger.debug("ConnectionManager: Setting RTSP on play mode")

    RTSP.play_no_response(rtsp_session)
  end

  defp build_transport_header(%{transport: :tcp} = state, media_id) do
    {:ok, [{"Transport", "RTP/AVP/TCP;unicast;interleaved=#{media_id * 2}-#{media_id * 2 + 1}"}]}
  end

  defp build_transport_header(%{transport: {:udp, port_range_start, port_range_end}}, media_id) do
    rtp_port = port_range_start + media_id * 2

    if rtp_port + 1 > port_range_end do
      {:error, :port_range_exceeded}
    else
      {:ok, [{"Transport", "RTP/AVP/UDP;unicast;client_port=#{rtp_port}-#{rtp_port + 1}"}]}
    end
  end

  defp keep_alive(state) do
    Membrane.Logger.debug("Send GET_PARAMETER to keep session alive")
    RTSP.get_parameter_no_response(state.rtsp_session)

    %{
      state
      | keep_alive_timer: Process.send_after(self(), :keep_alive, state.keep_alive_interval)
    }
  end

  defp handle_rtsp_error(reason, state) do
    Membrane.Logger.error("could not connect to RTSP server due to: #{inspect(reason)}")
    if state.rtsp_session != nil, do: RTSP.close(state.rtsp_session)

    state = notify_parent(state, {:connection_failed, reason}) |> retry()
    %{state | status: :failed}
  end

  defp cancel_keep_alive(state) do
    Process.cancel_timer(state.keep_alive_timer)
    %{state | keep_alive_timer: nil}
  end

  # notify the parent only once on successive failures
  defp notify_parent(%{status: :failed} = state, _msg), do: state

  defp notify_parent(state, msg) do
    send(state.parent_pid, msg)
    state
  end

  defp retry(%{reconnect_attempt: attempt} = state) do
    delay =
      min(
        :math.pow(2, attempt) * @base_back_off_time,
        @max_back_off_time
      )
      |> trunc()

    Membrane.Logger.info("Retry connection in #{delay} ms")
    Process.send_after(self(), :connect, delay)
    %{state | reconnect_attempt: attempt + 1}
  end

  defp get_tracks(%{body: %ExSDP{media: media_list}}, stream_types) do
    media_list
    |> Enum.filter(&(&1.type in stream_types))
    |> Enum.map(fn media ->
      {get_attribute(media, "control", ""),
       %{
         type: media.type,
         rtpmap: get_attribute(media, ExSDP.Attribute.RTPMapping),
         fmtp: get_attribute(media, ExSDP.Attribute.FMTP),
         transport: nil
       }}
    end)
    |> Map.new()
  end

  defp get_attribute(video_attributes, attribute, default \\ nil) do
    case ExSDP.get_attribute(video_attributes, attribute) do
      {^attribute, value} -> value
      %^attribute{} = value -> value
      _other -> default
    end
  end
end
