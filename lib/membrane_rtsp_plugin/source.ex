defmodule Membrane.RTSP.Source do
  @moduledoc """
  Source bin responsible for connecting to an RTSP server.

  This element connects to an RTSP server, depayloads and parses the received media if possible.
  If there's no suitable depayloader and parser, the raw payload is sent to the subsequent elements in
  the pipeline.

  In case connection can't be established or is severed during streaming this bin will crash.

  The following codecs are depayloaded and parsed:
    * `H264`
    * `H265`
    * `AAC` (if sent according to RFC3640)
    * `Opus`

  When the element finishes setting up all tracks it will send a `t:set_up_tracks/0` notification.
  To receive a track a corresponding `Pad.ref(:output, control_path)` pad has to be connected,
  where each track's control path is provided in the `t:set_up_tracks/0` notification.

  ## Servers that deviate from the specifications

  RTSP servers, those in IP cameras in particular, often deviate from the RFCs in ways
  that do not prevent other clients from playing their streams. The source accepts such
  deviations where it can do so without guessing, and logs a warning for each of them.
  When a track is described too poorly to be depayloaded (for example an AAC track
  without a `config`), its RTP payload is sent on as it comes, like the payload of a codec
  the source does not know. A track for which the description names no usable payload
  type is left out of the `t:set_up_tracks/0` notification.

  The `rtpmap` of a track is `nil` when the description has none and the payload type is
  dynamic. For the static payload types of RFC 3551, such as 0 (PCMU) and 8 (PCMA), the
  mapping that the RFC defines is reported.
  """

  use Membrane.Bin

  require Membrane.Logger

  alias __MODULE__
  alias __MODULE__.ConnectionManager
  alias Membrane.{RTSP, Time}

  @type set_up_tracks_notification :: {:set_up_tracks, [track()]}
  @type track :: %{
          control_path: String.t(),
          type: :video | :audio | :application,
          framerate: ExSDP.Attribute.framerate_value() | nil,
          fmtp: ExSDP.Attribute.FMTP.t() | nil,
          rtpmap: ExSDP.Attribute.RTPMapping.t() | nil
        }

  @type transport ::
          {:udp, port_range_start :: non_neg_integer(), port_range_end :: non_neg_integer()}
          | :tcp

  def_options stream_uri: [
                spec: binary(),
                description: "The RTSP URI of the resource to stream."
              ],
              allowed_media_types: [
                spec: [:video | :audio | :application],
                default: [:video, :audio, :application],
                description: """
                The media type to accept from the RTSP server.
                """
              ],
              transport: [
                spec: transport(),
                default: :tcp,
                description: """
                Transport protocol that will be used in the established RTSP stream. In case of
                UDP a range needs to be provided from which receiving ports will be chosen.
                """
              ],
              timeout: [
                spec: Time.t(),
                default: Time.seconds(15),
                default_inspector: &Time.pretty_duration/1,
                description: "RTSP response timeout"
              ],
              keep_alive_interval: [
                spec: Time.t(),
                default: Time.seconds(15),
                default_inspector: &Time.pretty_duration/1,
                description: """
                Interval of a heartbeat sent to the RTSP server at a regular interval to
                keep the session alive. If the server announces a session timeout that
                is shorter than twice this interval, the heartbeat is sent every half of
                that timeout instead.
                """
              ],
              user_agent: [
                spec: binary() | nil,
                default: nil,
                description: """
                Value of the `User-Agent` header sent with every request, for servers that
                treat clients differently by name. By default it is the one of `Membrane.RTSP`.
                """
              ],
              on_connection_closed: [
                spec: :raise_error | :send_eos,
                default: :raise_error,
                description: """
                Defines the element's behavior if the TCP connection is closed by the RTSP server:
                - `:raise_error` - Raise an error.
                - `:send_eos` - Send an `:end_of_stream` to the output pad.
                """
              ]

  def_output_pad :output,
    accepted_format: _any,
    availability: :on_request

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            stream_uri: binary(),
            allowed_media_types: ConnectionManager.media_types(),
            transport: Source.transport(),
            timeout: Time.t(),
            keep_alive_interval: Time.t(),
            tracks: [ConnectionManager.track()],
            rtsp_session: Membrane.RTSP.t() | nil,
            keep_alive_timer: reference() | nil,
            keep_alive_method: :get_parameter | :options,
            session_timeout: pos_integer() | nil,
            on_connection_closed: :raise_error | :send_eos,
            user_agent: binary() | nil,
            end_of_stream: boolean(),
            play_request_sent: boolean()
          }

    @enforce_keys [
      :stream_uri,
      :allowed_media_types,
      :transport,
      :timeout,
      :keep_alive_interval,
      :on_connection_closed
    ]
    defstruct @enforce_keys ++
                [
                  tracks: [],
                  ssrc_to_track: %{},
                  rtsp_session: nil,
                  user_agent: nil,
                  keep_alive_timer: nil,
                  keep_alive_method: :get_parameter,
                  session_timeout: nil,
                  end_of_stream: false,
                  play_request_sent: false
                ]
  end

  @impl true
  def handle_init(_ctx, options) do
    state = struct(State, Map.from_struct(options))

    {[], state}
  end

  @impl true
  def handle_setup(ctx, state) do
    state = ConnectionManager.establish_connection(ctx.utility_supervisor, state)

    {[spec: create_sources_spec(state), notify_parent: get_set_up_tracks_notification(state)],
     state}
  end

  @impl true
  def handle_child_playing(_child, _ctx, %State{play_request_sent: false} = state) do
    {[], ConnectionManager.play(state)}
  end

  @impl true
  def handle_child_playing(_child, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_child_notification({:request_socket_control, _socket, pid}, :tcp_source, _ctx, state) do
    RTSP.transfer_socket_control(state.rtsp_session, pid)
    {[], state}
  end

  @impl true
  def handle_child_notification(notification, _element, _ctx, state) do
    Membrane.Logger.warning("Ignoring child notification: #{inspect(notification)}")
    {[], state}
  end

  @impl true
  def handle_info(
        {:DOWN, _ref, :process, rtsp_session, reason},
        ctx,
        %State{rtsp_session: rtsp_session} = state
      ) do
    case state.on_connection_closed do
      :send_eos ->
        notify_udp_sources_actions =
          ctx.children
          |> Map.keys()
          |> Enum.filter(&match?({:udp_source, _ref}, &1))
          |> Enum.map(&{:notify_child, {&1, :close_socket}})

        {notify_udp_sources_actions, %{state | end_of_stream: true}}

      :raise_error ->
        {[terminate: {:rtsp_session_crash, reason}], state}
    end
  end

  @impl true
  def handle_info(:keep_alive, _ctx, state) do
    if state.end_of_stream do
      {[], state}
    else
      {[], ConnectionManager.keep_alive(state)}
    end
  end

  @impl true
  def handle_info(message, _ctx, state) do
    Membrane.Logger.warning("Ignoring message: #{inspect(message)}")
    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, control_path) = pad, _ctx, state) do
    track = Enum.find(state.tracks, &(&1.control_path == control_path))

    {demuxer_name, jitter_buffer_latency} =
      case state.transport do
        :tcp ->
          {:rtp_demuxer, 0}

        {:udp, _port_range_start, _port_range_end} ->
          {{:rtp_demuxer, track.control_path}, Time.milliseconds(200)}
      end

    spec =
      get_child(demuxer_name)
      |> via_out(:output,
        options: [
          stream_id: {:payload_type, track.payload_type},
          jitter_buffer_latency: jitter_buffer_latency,
          clock_rate: track.rtpmap && track.rtpmap.clock_rate
        ]
      )
      |> depayloader(track)
      |> parser(track)
      |> bin_output(pad)

    {[spec: spec], state}
  end

  @impl true
  def handle_terminate_request(_ctx, state) do
    {[terminate: :normal], state}
  end

  @spec get_set_up_tracks_notification(State.t()) :: set_up_tracks_notification()
  defp get_set_up_tracks_notification(state) do
    {:set_up_tracks,
     Enum.map(state.tracks, &Map.drop(&1, [:transport, :payload_type, :sdp_rtpmap?]))}
  end

  @spec payload_type_mapping([ConnectionManager.track()]) ::
          Membrane.RTP.PayloadFormat.payload_type_mapping()
  defp payload_type_mapping(tracks) do
    for %{sdp_rtpmap?: true, rtpmap: rtpmap, payload_type: payload_type} <- tracks, into: %{} do
      {payload_type,
       %{encoding_name: encoding_name(rtpmap.encoding), clock_rate: rtpmap.clock_rate}}
    end
  end

  @spec create_sources_spec(State.t()) :: Membrane.ChildrenSpec.t()
  defp create_sources_spec(state) do
    case state.transport do
      :tcp ->
        {:tcp, socket} = List.first(state.tracks).transport

        child(:tcp_source, %Membrane.TCP.Source{
          connection_side: :client,
          local_socket: socket,
          on_connection_closed: state.on_connection_closed
        })
        |> child(:tcp_decapsulator, %RTSP.TCP.Decapsulator{rtsp_session: state.rtsp_session})
        |> child(:rtp_demuxer, %Membrane.RTP.Demuxer{
          payload_type_mapping: payload_type_mapping(state.tracks)
        })

      {:udp, _port_range_start, _port_range_end} ->
        [
          Enum.flat_map(state.tracks, fn track ->
            {:udp, rtp_port, rtcp_port} = track.transport
            payload_type_mapping = payload_type_mapping([track])

            [
              child({:udp_source, rtp_port}, %Membrane.UDP.Source{local_port_no: rtp_port})
              |> child(
                {:rtp_demuxer, track.control_path},
                %Membrane.RTP.Demuxer{payload_type_mapping: payload_type_mapping}
              ),
              child({:udp_source, rtcp_port}, %Membrane.UDP.Source{local_port_no: rtcp_port})
              |> child(
                {:rtcp_demuxer, track.control_path},
                %Membrane.RTP.Demuxer{payload_type_mapping: payload_type_mapping}
              )
            ]
          end)
        ]
    end
  end

  # Encoding names known to `Membrane.RTP.Demuxer`, which uses them to describe the
  # stream it outputs. The name comes from the server, so it is looked up here instead
  # of being turned into an atom, and compared case-insensitively (RFC 4855, section 3).
  @encoding_names %{
    "h264" => :H264,
    "h265" => :H265,
    "vp8" => :VP8,
    "aac" => :AAC,
    "opus" => :opus,
    "mpa" => :MPA
  }

  @spec encoding_name(String.t()) :: atom()
  defp encoding_name(encoding), do: Map.get(@encoding_names, String.downcase(encoding), :unknown)

  @spec encoding(ConnectionManager.track()) :: String.t() | nil
  defp encoding(%{rtpmap: nil}), do: nil
  defp encoding(%{rtpmap: rtpmap}), do: String.downcase(rtpmap.encoding)

  @spec depayloader(ChildrenSpec.builder(), ConnectionManager.track()) :: ChildrenSpec.builder()
  defp depayloader(builder, track) do
    depayloader_definition =
      case {track.type, encoding(track)} do
        {_type, "h264"} ->
          Membrane.RTP.H264.Depayloader

        {_type, "h265"} ->
          Membrane.RTP.H265.Depayloader

        {_type, "opus"} ->
          Membrane.RTP.Opus.Depayloader

        {:audio, "mpeg4-generic"} ->
          case aac_mode(track) do
            nil ->
              Membrane.Logger.warning("""
              Cannot depayload the AAC track #{inspect(track.control_path)}: its fmtp has to \
              give the config and either the mode or sizelength and indexlength, got \
              #{inspect(track.fmtp)}. Passing the RTP payload on as it is.
              """)

              nil

            mode ->
              %Membrane.RTP.AAC.Depayloader{mode: mode}
          end

        {_type, _encoding} ->
          nil
      end

    if depayloader_definition != nil do
      child(builder, {:depayloader, make_ref()}, depayloader_definition)
    else
      builder
    end
  end

  # Without a mode, or with "generic", the lengths of the AU header fields decide:
  # 13 and 3 bits are those of AAC-hbr, 6 and 2 bits those of AAC-lbr.
  @spec aac_mode(ConnectionManager.track()) :: Membrane.RTP.AAC.Utils.mode() | nil
  defp aac_mode(%{fmtp: %ExSDP.Attribute.FMTP{config: config} = fmtp}) when is_binary(config) do
    case fmtp do
      %{mode: :AAC_hbr} -> :hbr
      %{mode: :AAC_lbr} -> :lbr
      %{mode: mode, sizelength: 13, indexlength: 3} when mode in [nil, :generic] -> :hbr
      %{mode: mode, sizelength: 6, indexlength: 2} when mode in [nil, :generic] -> :lbr
      _other -> nil
    end
  end

  defp aac_mode(_track), do: nil

  @spec parser(ChildrenSpec.builder(), ConnectionManager.track()) :: ChildrenSpec.builder()
  defp parser(link_builder, track), do: parser(link_builder, track, encoding(track))

  defp parser(link_builder, track, "h264") do
    sps = track.fmtp && track.fmtp.sprop_parameter_sets && track.fmtp.sprop_parameter_sets.sps
    pps = track.fmtp && track.fmtp.sprop_parameter_sets && track.fmtp.sprop_parameter_sets.pps

    child(link_builder, {:parser, make_ref()}, %Membrane.H264.Parser{
      spss: List.wrap(sps),
      ppss: List.wrap(pps),
      repeat_parameter_sets: true
    })
  end

  defp parser(link_builder, track, "h265") do
    child(link_builder, {:parser, make_ref()}, %Membrane.H265.Parser{
      vpss: List.wrap(track.fmtp && track.fmtp.sprop_vps),
      spss: List.wrap(track.fmtp && track.fmtp.sprop_sps),
      ppss: List.wrap(track.fmtp && track.fmtp.sprop_pps),
      repeat_parameter_sets: true
    })
  end

  defp parser(link_builder, %{type: :audio} = track, "mpeg4-generic") do
    if aac_mode(track) do
      child(link_builder, {:parser, make_ref()}, %Membrane.AAC.Parser{
        audio_specific_config: track.fmtp.config
      })
    else
      link_builder
    end
  end

  defp parser(link_builder, _track, _encoding), do: link_builder
end
