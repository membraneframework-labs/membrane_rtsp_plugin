defmodule Membrane.RTSP.Source.ConnectionManager do
  @moduledoc false

  require Membrane.Logger

  alias Membrane.{RTP, RTSP}
  alias Membrane.RTSP.Source.State

  @content_type_header [{"accept", "application/sdp"}]
  # Method Not Allowed, Not Acceptable, Not Implemented, Option not supported
  @not_implemented_statuses [405, 406, 501, 551]

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
           {:ok, state} <- choose_keep_alive_method(state),
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
      {:ok, %RTSP.Response{status: status}} when status in 200..299 ->
        %{state | keep_alive_timer: start_keep_alive_timer(state), play_request_sent: true}

      result ->
        handle_rtsp_error({:play_rtsp_failed, describe_failure("PLAY", result)}, state)
    end
  end

  @spec keep_alive(State.t()) :: State.t()
  def keep_alive(%{keep_alive_method: method} = state) do
    Membrane.Logger.debug("Send #{keep_alive_request(method)} to keep session alive")

    result =
      case method do
        :get_parameter -> RTSP.get_parameter(state.rtsp_session)
        :options -> RTSP.options(state.rtsp_session)
      end

    case result do
      {:ok, %RTSP.Response{status: status}} when status in 200..299 ->
        %{state | keep_alive_timer: start_keep_alive_timer(state)}

      {:ok, %RTSP.Response{status: status}}
      when method == :get_parameter and status in @not_implemented_statuses ->
        Membrane.Logger.warning(
          "GET_PARAMETER sent to keep the session alive was answered with status " <>
            "#{status}, using OPTIONS from now on"
        )

        keep_alive(%{state | keep_alive_method: :options})

      other ->
        raise "RTSP keep-alive failed: #{describe_failure(keep_alive_request(method), other)}"
    end
  end

  defp keep_alive_request(:get_parameter), do: "GET_PARAMETER"
  defp keep_alive_request(:options), do: "OPTIONS"

  @spec choose_keep_alive_method(State.t()) :: connection_establishment_phase_return()
  defp choose_keep_alive_method(state) do
    case RTSP.options(state.rtsp_session) do
      {:ok, %RTSP.Response{status: status} = response} when status in 200..299 ->
        {:ok, %{state | keep_alive_method: keep_alive_method(response)}}

      {:ok, %RTSP.Response{}} = refused ->
        Membrane.Logger.warning(
          "#{describe_failure("OPTIONS", refused)}, carrying on without knowing the " <>
            "methods of the server"
        )

        {:ok, state}

      # going on could let a late answer be taken for the one to the next request
      {:error, _reason} = failed ->
        {:error, {:getting_rtsp_options_failed, describe_failure("OPTIONS", failed)}, state}
    end
  end

  @spec keep_alive_method(RTSP.Response.t()) :: :get_parameter | :options
  defp keep_alive_method(options_response) do
    case RTSP.Response.get_header(options_response, "Public") do
      {:ok, public} ->
        methods =
          public
          |> String.split(",")
          |> Enum.map(fn method -> method |> String.trim() |> String.upcase() end)

        if "GET_PARAMETER" not in methods do
          Membrane.Logger.debug(
            "The server does not list GET_PARAMETER among its methods (#{public}), " <>
              "the session will be kept alive with OPTIONS"
          )
        end

        if "GET_PARAMETER" in methods, do: :get_parameter, else: :options

      {:error, :no_such_header} ->
        :get_parameter
    end
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
      {:ok, %RTSP.Response{status: status, body: %ExSDP{} = sdp} = response}
      when status in 200..299 ->
        tracks = get_tracks(response, state.allowed_media_types)

        if tracks == [],
          do: {:error, {:no_tracks, describe_lack_of_tracks(sdp)}, state},
          else: {:ok, %{state | tracks: tracks}}

      {:ok, %RTSP.Response{status: status}} when status in 200..299 ->
        {:error,
         {:getting_rtsp_description_failed,
          "the reply to DESCRIBE carried no session description"}, state}

      result ->
        {:error, {:getting_rtsp_description_failed, describe_failure("DESCRIBE", result)}, state}
    end
  end

  @spec setup_rtsp_connection(State.t()) :: connection_establishment_phase_return()
  defp setup_rtsp_connection(%{transport: :tcp} = state) do
    case setup_rtsp_connection_with_tcp(state.rtsp_session, state.tracks) do
      {:ok, tracks, responses} -> {:ok, tracks_set_up(state, tracks, responses)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp setup_rtsp_connection(%{transport: {:udp, min_port, max_port}} = state) do
    case setup_rtsp_connection_with_udp(state.rtsp_session, min_port, max_port, state.tracks) do
      {:ok, tracks, responses} -> {:ok, tracks_set_up(state, tracks, responses)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @spec tracks_set_up(State.t(), [track()], [RTSP.Response.t()]) :: State.t()
  defp tracks_set_up(state, tracks, responses) do
    Enum.reduce(responses, %{state | tracks: tracks}, fn response, state ->
      store_session_timeout(state, response)
    end)
  end

  @spec start_keep_alive_timer(State.t()) :: reference()
  defp start_keep_alive_timer(state) do
    interval = state |> keep_alive_interval() |> Membrane.Time.as_milliseconds(:round)
    Process.send_after(self(), :keep_alive, interval)
  end

  # The server may close a session idle for the timeout it announced (RFC 2326,
  # section 12.37), so the interval is at most half of that timeout.
  @spec keep_alive_interval(State.t()) :: Membrane.Time.t()
  defp keep_alive_interval(%{session_timeout: nil, keep_alive_interval: interval}), do: interval

  defp keep_alive_interval(%{session_timeout: timeout, keep_alive_interval: interval}),
    do: min(interval, div(Membrane.Time.seconds(timeout), 2))

  @spec store_session_timeout(State.t(), RTSP.Response.t()) :: State.t()
  defp store_session_timeout(state, response) do
    case RTSP.Response.parse_session_header(response) do
      {:ok, %{timeout: timeout}} when is_integer(timeout) ->
        state = %{state | session_timeout: timeout}

        if keep_alive_interval(state) < state.keep_alive_interval do
          Membrane.Logger.debug(
            "The server closes sessions idle for #{timeout} s, keep-alive requests will " <>
              "be sent every #{Membrane.Time.pretty_duration(keep_alive_interval(state))}"
          )
        end

        state

      _no_timeout ->
        state
    end
  end

  @spec setup_rtsp_connection_with_tcp(RTSP.t(), [track()]) ::
          {:ok, tracks :: [track()], responses :: [RTSP.Response.t()]}
          | {:error, reason :: term()}
  defp setup_rtsp_connection_with_tcp(rtsp_session, tracks) do
    socket = RTSP.get_socket(rtsp_session)

    tracks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {track, idx}, {:ok, set_up_tracks, responses} ->
      transport_header =
        [{"Transport", "RTP/AVP/TCP;unicast;interleaved=#{idx * 2}-#{idx * 2 + 1}"}]

      case RTSP.setup(rtsp_session, track.control_path, transport_header) do
        {:ok, %RTSP.Response{status: status} = response} when status in 200..299 ->
          warn_unless_interleaved(response, track)
          track = %{track | transport: {:tcp, socket}}
          {:cont, {:ok, [track | set_up_tracks], [response | responses]}}

        error ->
          Membrane.Logger.debug(
            "ConnectionManager: Setting up RTSP connection failed: #{inspect(error)}"
          )

          request = "SETUP of #{inspect(track.control_path)}"

          {:halt,
           {:error, {:setting_up_rtsp_connection_failed, describe_failure(request, error)}}}
      end
    end)
  end

  @spec warn_unless_interleaved(RTSP.Response.t(), track()) :: :ok
  defp warn_unless_interleaved(response, track) do
    case RTSP.Response.get_header(response, "Transport") do
      {:ok, transport} ->
        interleaved? = transport |> String.downcase() |> String.contains?(["tcp", "interleaved"])

        if not interleaved? do
          Membrane.Logger.warning(
            "The server answered the request for interleaved transport of the track " <>
              "#{inspect(track.control_path)} with Transport: #{transport}. " <>
              "If no media arrives, it is sending the media another way."
          )
        end

        :ok

      {:error, :no_such_header} ->
        :ok
    end
  end

  @spec setup_rtsp_connection_with_udp(
          RTSP.t(),
          :inet.port_number(),
          :inet.port_number(),
          [track()],
          [track()],
          [RTSP.Response.t()]
        ) ::
          {:ok, tracks :: [track()], responses :: [RTSP.Response.t()]}
          | {:error, reason :: term()}
  defp setup_rtsp_connection_with_udp(
         rtsp_session,
         port,
         max_port,
         tracks,
         set_up_tracks \\ [],
         responses \\ []
       )

  defp setup_rtsp_connection_with_udp(_session, _port, _max_port, [], set_up_tracks, responses) do
    {:ok, Enum.reverse(set_up_tracks), responses}
  end

  defp setup_rtsp_connection_with_udp(_session, max_port, max_port, _tracks, _set_up, _responses) do
    # when current port is equal to max_port the range is already exceeded, because port + 1 is also required.
    {:error, :port_range_exceeded}
  end

  defp setup_rtsp_connection_with_udp(
         rtsp_session,
         port,
         max_port,
         tracks,
         set_up_tracks,
         responses
       ) do
    if port_taken?(port) or port_taken?(port + 1) do
      setup_rtsp_connection_with_udp(
        rtsp_session,
        port + 1,
        max_port,
        tracks,
        set_up_tracks,
        responses
      )
    else
      transport_header = [{"Transport", "RTP/AVP/UDP;unicast;client_port=#{port}-#{port + 1}"}]
      [track | rest_tracks] = tracks

      case RTSP.setup(rtsp_session, track.control_path, transport_header) do
        {:ok, %RTSP.Response{status: status} = response} when status in 200..299 ->
          set_up_tracks = [%{track | transport: {:udp, port, port + 1}} | set_up_tracks]

          setup_rtsp_connection_with_udp(
            rtsp_session,
            port + 2,
            max_port,
            rest_tracks,
            set_up_tracks,
            [response | responses]
          )

        other ->
          request = "SETUP of #{inspect(track.control_path)}"
          {:error, {:setup_failed, describe_failure(request, other)}}
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

  @spec describe_lack_of_tracks(ExSDP.t()) :: String.t()
  defp describe_lack_of_tracks(%ExSDP{media: []}), do: "the session description has no media"

  defp describe_lack_of_tracks(%ExSDP{media: media}) do
    types = Enum.map_join(media, ", ", &to_string(&1.type))
    "none of the media in the session description can be received: #{types}"
  end

  @spec describe_failure(String.t(), RTSP.Response.result()) :: String.t()
  defp describe_failure(request, {:ok, %RTSP.Response{status: status}}),
    do: "#{request} was answered with status #{status}"

  defp describe_failure(request, {:error, reason}),
    do: "#{request} failed with #{inspect(reason)}"

  @spec handle_rtsp_error(term(), State.t()) :: no_return()
  defp handle_rtsp_error(reason, state) do
    message =
      case reason do
        {reason, description} when is_binary(description) -> "#{inspect(reason)} (#{description})"
        reason -> inspect(reason)
      end

    Membrane.Logger.error("could not connect to RTSP server due to: #{message}")
    if state.rtsp_session != nil, do: RTSP.close(state.rtsp_session)

    raise "RTSP connection failed, reason: #{message}"
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
  # The channel count of MPA is carried in its payload.
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
    14 => {"MPA", 90_000, nil},
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

  # The first format of the media line decides.
  @spec get_payload_format(ExSDP.Media.t()) ::
          {:ok, RTP.payload_type(), ExSDP.Attribute.RTPMapping.t() | nil, boolean()}
          | {:error, String.t()}
  defp get_payload_format(%ExSDP.Media{fmt: [payload_type | _rest]} = media)
       when is_integer(payload_type) do
    get_payload_format(media, payload_type)
  end

  defp get_payload_format(%ExSDP.Media{fmt: fmt} = media) do
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

  @spec get_payload_format(ExSDP.Media.t(), RTP.payload_type()) ::
          {:ok, RTP.payload_type(), ExSDP.Attribute.RTPMapping.t() | nil, boolean()}
          | {:error, String.t()}
  # Membrane.RTP.Demuxer takes packets with these payload types for RTCP (RFC 5761)
  defp get_payload_format(_media, payload_type) when payload_type in 64..95 do
    {:error,
     "payload type #{payload_type} is in the range that is taken for RTCP, " <>
       "so its packets cannot be told apart from RTCP"}
  end

  defp get_payload_format(media, payload_type) do
    rtpmaps = ExSDP.get_attributes(media, :rtpmap)

    case Enum.find(rtpmaps, fn rtpmap -> rtpmap.payload_type == payload_type end) do
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
        Membrane.Logger.warning(
          "The #{media.type} media has no rtpmap for its payload type #{payload_type}, " <>
            "its RTP payload will be passed on as it comes"
        )

        {:ok, payload_type, nil, false}

      nil ->
        {:error,
         "payload type #{payload_type} has no rtpmap and RFC 3551 assigns no encoding to it"}
    end
  end

  @spec get_fmtp(ExSDP.Media.t(), RTP.payload_type()) :: ExSDP.Attribute.FMTP.t() | nil
  defp get_fmtp(media, payload_type) do
    fmtps = ExSDP.get_attributes(media, :fmtp)

    Enum.find(fmtps, fn fmtp -> fmtp.pt == payload_type end) ||
      lone_fmtp(media, fmtps, payload_type)
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

  @spec get_attribute(ExSDP.Media.t(), atom() | binary(), default) :: term() | default
        when default: var
  defp get_attribute(media, attribute, default) do
    case ExSDP.get_attribute(media, attribute) do
      {^attribute, value} -> value
      _other -> default
    end
  end
end
