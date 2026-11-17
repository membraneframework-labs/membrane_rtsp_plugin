defmodule Membrane.RTSP.Source.ConnectionManager do
  @moduledoc false

  require Membrane.Logger
  require Membrane.Pad

  alias Membrane.{RTP, RTSP}
  alias Membrane.RTSP.Source.State

  @content_type_header [{"accept", "application/sdp"}]

  @type t() :: pid()
  @type media_types :: [:video | :audio | :application]
  @type connection_opts :: %{stream_uri: binary(), allowed_media_types: media_types()}
  @type track_transport ::
          {:tcp, :gen_tcp.socket()}
          | {:udp, rtp_port :: :inet.port_number(), rtcp_port :: :inet.port_number()}
  @type track :: %{
          control_path: String.t(),
          type: :video | :audio | :application,
          framerate: ExSDP.Attribute.framerate_value() | nil,
          fmtp: ExSDP.Attribute.FMTP.t() | nil,
          rtpmap: ExSDP.Attribute.RTPMapping.t() | nil,
          payload_type: RTP.payload_type(),
          sdp_rtpmap?: boolean(),
          transport: track_transport()
        }

  @typep connection_establishment_phase_return() ::
           {:ok, State.t()} | {:error, reason :: term(), State.t()}

  @spec transfer_rtsp_socket_control(RTSP.t(), pid()) :: :ok
  def transfer_rtsp_socket_control(rtsp_session, new_controller) do
    RTSP.transfer_socket_control(rtsp_session, new_controller)
  end

  @spec establish_connection(Membrane.UtilitySupervisor.t(), State.t()) :: State.t()
  def establish_connection(utility_supervisor, state) do
    state =
      with {:ok, state} <- start_rtsp_connection(utility_supervisor, state),
           {:ok, state} <- get_rtsp_description(state),
           {:ok, state} <- setup_rtsp_connection(state) do
        state
      else
        {:error, reason, state} -> handle_rtsp_error(reason, state)
      end

    state
  end

  @spec play(State.t()) :: State.t()
  def play(state) do
    Membrane.Logger.debug("ConnectionManager: Setting RTSP on play mode")

    case RTSP.play(state.rtsp_session) do
      {:ok, %{status: 200}} ->
        %{state | keep_alive_timer: start_keep_alive_timer(state), play_request_sent: true}

      _error ->
        handle_rtsp_error(:play_rtsp_failed, state)
    end
  end

  @spec keep_alive(State.t()) :: State.t()
  def keep_alive(state) do
    Membrane.Logger.debug("Send GET_PARAMETER to keep session alive")

    {:ok, %{status: 200}} = RTSP.get_parameter(state.rtsp_session)

    %{state | keep_alive_timer: start_keep_alive_timer(state)}
  end

  @spec start_rtsp_connection(Membrane.UtilitySupervisor.t(), State.t()) ::
          connection_establishment_phase_return()
  defp start_rtsp_connection(utility_supervisor, state) do
    rtsp_session_child_spec = %{
      id: RTSP,
      start:
        {RTSP, :start_link,
         [
           state.stream_uri,
           [response_timeout: Membrane.Time.as_milliseconds(state.timeout, :round)]
         ]}
    }

    case Membrane.UtilitySupervisor.start_child(utility_supervisor, rtsp_session_child_spec) do
      {:ok, session} ->
        Process.monitor(session)
        {:ok, %{state | rtsp_session: session}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @spec get_rtsp_description(State.t()) :: connection_establishment_phase_return()
  defp get_rtsp_description(%{rtsp_session: rtsp_session} = state) do
    Membrane.Logger.debug("ConnectionManager: Getting RTSP description")

    case RTSP.describe(rtsp_session, @content_type_header) do
      {:ok, %{status: 200} = response} ->
        tracks = get_tracks(response, state.allowed_media_types)
        {:ok, %{state | tracks: tracks}}

      _result ->
        {:error, :getting_rtsp_description_failed, state}
    end
  end

  @spec setup_rtsp_connection(State.t()) :: connection_establishment_phase_return()
  defp setup_rtsp_connection(%{transport: :tcp} = state) do
    case setup_rtsp_connection_with_tcp(state.rtsp_session, state.tracks) do
      {:ok, tracks} -> {:ok, %{state | tracks: tracks}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp setup_rtsp_connection(%{transport: {:udp, min_port, max_port}} = state) do
    case setup_rtsp_connection_with_udp(state.rtsp_session, min_port, max_port, state.tracks) do
      {:ok, tracks} -> {:ok, %{state | tracks: tracks}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec start_keep_alive_timer(State.t()) :: reference()
  defp start_keep_alive_timer(%{keep_alive_interval: interval}) do
    Process.send_after(self(), :keep_alive, interval |> Membrane.Time.as_milliseconds(:round))
  end

  @spec setup_rtsp_connection_with_tcp(RTSP.t(), [track()]) ::
          {:ok, tracks :: [track()]} | {:error, reason :: term()}
  defp setup_rtsp_connection_with_tcp(rtsp_session, tracks) do
    socket = RTSP.get_socket(rtsp_session)

    tracks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {track, idx}, {:ok, set_up_tracks} ->
      transport_header =
        [{"Transport", "RTP/AVP/TCP;unicast;interleaved=#{idx * 2}-#{idx * 2 + 1}"}]

      case RTSP.setup(rtsp_session, track.control_path, transport_header) do
        {:ok, %{status: 200}} ->
          {:cont, {:ok, [%{track | transport: {:tcp, socket}} | set_up_tracks]}}

        error ->
          Membrane.Logger.debug(
            "ConnectionManager: Setting up RTSP connection failed: #{inspect(error)}"
          )

          {:halt, {:error, :setting_up_rtsp_connection_failed}}
      end
    end)
  end

  @spec setup_rtsp_connection_with_udp(
          RTSP.t(),
          :inet.port_number(),
          :inet.port_number(),
          [track()],
          [track()]
        ) :: {:ok, tracks :: [track()]} | {:error, reason :: term()}
  defp setup_rtsp_connection_with_udp(
         rtsp_session,
         port,
         max_port,
         tracks,
         set_up_tracks \\ []
       )

  defp setup_rtsp_connection_with_udp(_rtsp_session, _port, _max_port, [], set_up_tracks) do
    {:ok, Enum.reverse(set_up_tracks)}
  end

  defp setup_rtsp_connection_with_udp(_rtsp_session, max_port, max_port, _tracks, _set_up_tracks) do
    # when current port is equal to max_port the range is already exceeded, because port + 1 is also required.
    {:error, :port_range_exceeded}
  end

  defp setup_rtsp_connection_with_udp(rtsp_session, port, max_port, tracks, set_up_tracks) do
    if port_taken?(port) or port_taken?(port + 1) do
      setup_rtsp_connection_with_udp(rtsp_session, port + 1, max_port, tracks, set_up_tracks)
    else
      transport_header = [{"Transport", "RTP/AVP/UDP;unicast;client_port=#{port}-#{port + 1}"}]
      [track | rest_tracks] = tracks

      case RTSP.setup(rtsp_session, track.control_path, transport_header) do
        {:ok, %{status: 200}} ->
          set_up_tracks = [%{track | transport: {:udp, port, port + 1}} | set_up_tracks]

          setup_rtsp_connection_with_udp(
            rtsp_session,
            port + 2,
            max_port,
            rest_tracks,
            set_up_tracks
          )

        _other ->
          {:error, :setup_failed}
      end
    end
  end

  @spec port_taken?(:inet.port_number()) :: boolean()
  defp port_taken?(port) do
    case :gen_udp.open(port, reuseaddr: true) do
      {:ok, socket} ->
        :inet.close(socket)
        false

      _error ->
        true
    end
  end

  @spec handle_rtsp_error(term(), State.t()) :: no_return()
  defp handle_rtsp_error(reason, state) do
    Membrane.Logger.error("could not connect to RTSP server due to: #{inspect(reason)}")
    if state.rtsp_session != nil, do: RTSP.close(state.rtsp_session)

    raise "RTSP connection failed, reason: #{inspect(reason)}"
  end

  @spec get_tracks(RTSP.Response.t(), media_types()) :: [track()]
  defp get_tracks(%{body: %ExSDP{media: media_list}}, stream_types) do
    media_list
    |> Enum.filter(&(&1.type in stream_types))
    |> Enum.flat_map(fn media ->
      control_path = get_attribute(media, "control", "")

      case get_payload_format(media) do
        {:ok, payload_type, rtpmap, sdp_rtpmap?} ->
          [
            %{
              control_path: control_path,
              framerate: get_attribute(media, :framerate, nil),
              type: media.type,
              rtpmap: rtpmap,
              fmtp: get_fmtp(media, payload_type),
              payload_type: payload_type,
              sdp_rtpmap?: sdp_rtpmap?,
              transport: nil
            }
          ]

        {:error, reason} ->
          Membrane.Logger.warning(
            "Leaving out the #{media.type} track #{inspect(control_path)}: #{reason}"
          )

          []
      end
    end)
  end

  # Encoding names, clock rates and channel counts that RFC 3551 (tables 4 and 5)
  # assigns to static payload types. A media section does not need an rtpmap for them.
  @static_payload_types %{
    0 => {"PCMU", 8_000, 1},
    3 => {"GSM", 8_000, 1},
    4 => {"G723", 8_000, 1},
    5 => {"DVI4", 8_000, 1},
    6 => {"DVI4", 16_000, 1},
    7 => {"LPC", 8_000, 1},
    8 => {"PCMA", 8_000, 1},
    9 => {"G722", 8_000, 1},
    10 => {"L16", 44_100, 2},
    11 => {"L16", 44_100, 1},
    12 => {"QCELP", 8_000, 1},
    13 => {"CN", 8_000, 1},
    14 => {"MPA", 90_000, 1},
    15 => {"G728", 8_000, 1},
    16 => {"DVI4", 11_025, 1},
    17 => {"DVI4", 22_050, 1},
    18 => {"G729", 8_000, 1},
    25 => {"CelB", 90_000, nil},
    26 => {"JPEG", 90_000, nil},
    28 => {"nv", 90_000, nil},
    31 => {"H261", 90_000, nil},
    32 => {"MPV", 90_000, nil},
    33 => {"MP2T", 90_000, nil},
    34 => {"H263", 90_000, nil}
  }

  # Tells which RTP payload type the media will be sent with and how it is encoded.
  #
  # The payload type is the first format of the media line, the one that libavformat
  # and live555 use as well, and the rtpmap is the one given for that payload type,
  # wherever it stands among the attributes. Returns whether the rtpmap came from the
  # description or from the static assignments of RFC 3551.
  @spec get_payload_format(ExSDP.Media.t()) ::
          {:ok, RTP.payload_type(), ExSDP.Attribute.RTPMapping.t() | nil, boolean()}
          | {:error, String.t()}
  defp get_payload_format(%ExSDP.Media{fmt: [payload_type | _rest]} = media)
       when is_integer(payload_type) do
    get_payload_format(media, payload_type)
  end

  defp get_payload_format(%ExSDP.Media{fmt: fmt} = media) when is_binary(fmt) do
    case fmt |> String.split() |> List.first("") |> Integer.parse() do
      # The parser leaves the formats unparsed for a transport that it does not know
      # to be RTP, such as "RTP/AVP/TCP", and when something follows them.
      {payload_type, ""} when payload_type in 0..127 ->
        get_payload_format(media, payload_type)

      # The formats are not payload types. Some servers put another token there and
      # name the payload type only in the rtpmap, which then decides.
      _not_a_payload_type ->
        case ExSDP.get_attributes(media, :rtpmap) do
          [%ExSDP.Attribute.RTPMapping{payload_type: payload_type} | _rest] ->
            Membrane.Logger.warning(
              "The format #{inspect(fmt)} of the #{media.type} media is not an RTP payload " <>
                "type, using payload type #{payload_type} of its rtpmap"
            )

            get_payload_format(media, payload_type)

          [] ->
            {:error, "its format #{inspect(fmt)} is not an RTP payload type and it has no rtpmap"}
        end
    end
  end

  @spec get_payload_format(ExSDP.Media.t(), RTP.payload_type()) ::
          {:ok, RTP.payload_type(), ExSDP.Attribute.RTPMapping.t() | nil, boolean()}
          | {:error, String.t()}
  # Membrane.RTP.Demuxer tells RTCP from RTP by these payload types (RFC 5761), so the
  # packets of such a track would never come out of it.
  defp get_payload_format(_media, payload_type) when payload_type in 64..95 do
    {:error,
     "payload type #{payload_type} is in the range that is taken for RTCP, " <>
       "so its packets cannot be told apart from RTCP"}
  end

  defp get_payload_format(media, payload_type) do
    rtpmaps = ExSDP.get_attributes(media, :rtpmap)

    case Enum.find(rtpmaps, &(&1.payload_type == payload_type)) do
      %ExSDP.Attribute.RTPMapping{} = rtpmap ->
        {:ok, payload_type, rtpmap, true}

      nil when is_map_key(@static_payload_types, payload_type) ->
        {encoding, clock_rate, channels} = Map.fetch!(@static_payload_types, payload_type)

        rtpmap = %ExSDP.Attribute.RTPMapping{
          payload_type: payload_type,
          encoding: encoding,
          clock_rate: clock_rate,
          params: channels
        }

        {:ok, payload_type, rtpmap, false}

      nil when payload_type >= 96 ->
        # nothing says what the payload is, so it can only be passed on as it comes
        {:ok, payload_type, nil, false}

      nil ->
        {:error,
         "payload type #{payload_type} has no rtpmap and RFC 3551 assigns no encoding to it"}
    end
  end

  # The fmtp of the payload type in use. When the only fmtp names another payload type,
  # it is still used, as it always was: it cannot describe anything but this stream.
  @spec get_fmtp(ExSDP.Media.t(), RTP.payload_type()) :: ExSDP.Attribute.FMTP.t() | nil
  defp get_fmtp(media, payload_type) do
    case ExSDP.get_attributes(media, :fmtp) do
      [] ->
        nil

      fmtps ->
        Enum.find(fmtps, &(&1.pt == payload_type)) || lone_fmtp(media, fmtps, payload_type)
    end
  end

  defp lone_fmtp(media, [fmtp], payload_type)
       when is_binary(media.fmt) or length(media.fmt) == 1 do
    Membrane.Logger.warning(
      "The fmtp of the #{media.type} media is given for payload type #{fmtp.pt}, " <>
        "using it for payload type #{payload_type}"
    )

    fmtp
  end

  defp lone_fmtp(_media, _fmtps, _payload_type), do: nil

  @spec get_attribute(ExSDP.Media.t(), ExSDP.Attribute.key(), default) ::
          ExSDP.Attribute.t() | default
        when default: var
  defp get_attribute(video_attributes, attribute, default) do
    case ExSDP.get_attribute(video_attributes, attribute) do
      {^attribute, value} -> value
      %^attribute{} = value -> value
      _other -> default
    end
  end
end
