defmodule Membrane.RTSP.CameraQuirksTest do
  @moduledoc """
  Each test runs `Membrane.RTSP.Source` against a scripted server that reproduces, at
  the wire level, one way in which real RTSP servers deviate from what the source used
  to expect. The responses are written by hand after the behaviour that libavformat,
  GStreamer and gortsplib document or work around; none was captured from a device.
  """
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Membrane.RTSP.{CameraPipeline, MockCamera}

  @h264 File.read!("test/fixtures/in.h264")

  defp h264_media(payload_type, channel \\ 0) do
    @h264
    |> MockCamera.h264_rtp_packets(payload_type: payload_type)
    |> Enum.map(&MockCamera.interleaved(channel, &1))
  end

  defp start_camera(script) do
    camera =
      start_supervised!(%{id: make_ref(), start: {MockCamera, :start_link, [script, self()]}})

    {camera, MockCamera.port(camera)}
  end

  describe "encoding name" do
    # RFC 4855 makes the names of media subtypes case-insensitive
    test "written in lower case still gets the stream parsed" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=video 0 RTP/AVP 96
      a=rtpmap:96 h264/90000
      a=control:trackID=0
      """

      {camera, port} = start_camera(MockCamera.script(sdp, h264_media(96)))
      pipeline = CameraPipeline.start_supervised!(port)

      assert_pipeline_notified(
        pipeline,
        :source,
        {:set_up_tracks, [%{control_path: "trackID=0"}]}
      )

      # the parser, not only the depayloader, is in place: it is what knows the resolution
      assert_sink_stream_format(pipeline, {:sink, "trackID=0"}, %Membrane.H264{
        alignment: :au,
        width: width,
        height: height
      })

      assert is_integer(width) and is_integer(height)
      assert_sink_buffer(pipeline, {:sink, "trackID=0"}, %Membrane.Buffer{})

      MockCamera.close_connection(camera)
      assert_end_of_stream(pipeline, {:sink, "trackID=0"}, :input, 5_000)
    end
  end

  describe "media section" do
    @pcma_packet <<0xD5, 0x55, 0xD5, 0x55, 0xD5, 0x55, 0xD5, 0x55>>

    defp audio_media(payload_type, channel) do
      for sequence_number <- 0..4 do
        @pcma_packet
        |> MockCamera.rtp_packet(
          payload_type: payload_type,
          sequence_number: sequence_number,
          timestamp: sequence_number * 8,
          ssrc: 0xA0D10
        )
        |> then(&MockCamera.interleaved(channel, &1))
      end
    end

    # RFC 3551 assigns payload types 0-34 statically, so that a description does not
    # have to carry an rtpmap for them (RFC 4566, section 6), and cameras leave it out
    test "without rtpmap for a static payload type is set up with the RFC 3551 mapping" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=video 0 RTP/AVP 96
      a=rtpmap:96 H264/90000
      a=control:trackID=0
      m=audio 0 RTP/AVP 8
      a=control:trackID=1
      """

      {camera, port} = start_camera(MockCamera.script(sdp, h264_media(96) ++ audio_media(8, 2)))
      pipeline = CameraPipeline.start_supervised!(port)

      assert_pipeline_notified(pipeline, :source, {:set_up_tracks, tracks})

      assert [
               %{control_path: "trackID=0", type: :video, rtpmap: %{encoding: "H264"}},
               %{
                 control_path: "trackID=1",
                 type: :audio,
                 fmtp: nil,
                 rtpmap: %ExSDP.Attribute.RTPMapping{
                   payload_type: 8,
                   encoding: "PCMA",
                   clock_rate: 8000,
                   params: 1
                 }
               }
             ] = Enum.sort_by(tracks, & &1.control_path)

      # there is no depayloader for G.711, the RTP payload is passed on as it is
      assert_sink_buffer(pipeline, {:sink, "trackID=1"}, %Membrane.Buffer{payload: @pcma_packet})
      assert_sink_buffer(pipeline, {:sink, "trackID=0"}, %Membrane.Buffer{})

      MockCamera.close_connection(camera)
      assert_end_of_stream(pipeline, {:sink, "trackID=1"}, :input, 5_000)
    end

    # libavformat and live555 take the first format of the media line
    test "with several formats is set up for the first one, whatever the order of the attributes" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=audio 0 RTP/AVP 97 101
      a=rtpmap:101 telephone-event/8000
      a=fmtp:101 0-15
      a=rtpmap:97 PCMA/16000
      a=control:trackID=1
      """

      {camera, port} = start_camera(MockCamera.script(sdp, audio_media(97, 0)))
      pipeline = CameraPipeline.start_supervised!(port)

      assert_pipeline_notified(pipeline, :source, {:set_up_tracks, [track]})

      assert %{rtpmap: %{payload_type: 97, encoding: "PCMA", clock_rate: 16_000}, fmtp: nil} =
               track

      assert_sink_buffer(pipeline, {:sink, "trackID=1"}, %Membrane.Buffer{payload: @pcma_packet})
      MockCamera.close_connection(camera)
      assert_end_of_stream(pipeline, {:sink, "trackID=1"}, :input, 5_000)
    end

    # gortsplib "application without clock rate": metadata tracks come like this
    test "without rtpmap for a dynamic payload type is set up and passed on unparsed" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=application 0 RTP/AVP 107
      a=control:trackID=2
      """

      {camera, port} = start_camera(MockCamera.script(sdp, audio_media(107, 0)))
      pipeline = CameraPipeline.start_supervised!(port)

      assert_pipeline_notified(
        pipeline,
        :source,
        {:set_up_tracks, [%{rtpmap: nil, type: :application}]}
      )

      assert_sink_buffer(pipeline, {:sink, "trackID=2"}, %Membrane.Buffer{payload: @pcma_packet})

      MockCamera.close_connection(camera)
      assert_end_of_stream(pipeline, {:sink, "trackID=2"}, :input, 5_000)
    end

    # gortsplib#509, mediamtx#1267: the format is "smart/1/90000" and the payload type
    # is only named by the rtpmap
    test "whose format is not a payload type is set up through the payload type of its rtpmap" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=application 0 RTP/AVP smart/1/90000
      a=rtpmap:98 TP-LINK/90000
      a=control:trackID=3
      """

      {camera, port} = start_camera(MockCamera.script(sdp, audio_media(98, 0)))

      ExUnit.CaptureLog.capture_log(fn ->
        pipeline = CameraPipeline.start_supervised!(port)

        assert_pipeline_notified(pipeline, :source, {:set_up_tracks, [track]})
        assert %{rtpmap: %{payload_type: 98, encoding: "TP-LINK"}} = track

        assert_sink_buffer(pipeline, {:sink, "trackID=3"}, %Membrane.Buffer{payload: @pcma_packet})

        MockCamera.close_connection(camera)
        assert_end_of_stream(pipeline, {:sink, "trackID=3"}, :input, 5_000)
      end)
    end

    # The cameras of gortsplib#509 name payload type 95 there. Membrane.RTP.Demuxer
    # takes payload types 64-95 for RTCP, so the packets of such a track would never
    # be delivered; it is left out, with a warning, rather than set up to stay silent.
    test "with a payload type that cannot be told apart from RTCP is left out" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=video 0 RTP/AVP 96
      a=rtpmap:96 H264/90000
      a=control:trackID=0
      m=application 0 RTP/AVP smart/1/90000
      a=rtpmap:95 TP-LINK/90000
      a=control:trackID=3
      """

      {camera, port} = start_camera(MockCamera.script(sdp, h264_media(96)))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pipeline = CameraPipeline.start_supervised!(port)

          assert_pipeline_notified(
            pipeline,
            :source,
            {:set_up_tracks, [%{control_path: "trackID=0"}]}
          )

          assert_sink_buffer(pipeline, {:sink, "trackID=0"}, %Membrane.Buffer{})

          MockCamera.close_connection(camera)
          assert_end_of_stream(pipeline, {:sink, "trackID=0"}, :input, 5_000)
        end)

      assert log =~ ~s(Leaving out the application track "trackID=3": payload type 95)
    end

    # gortsplib lists TCP among the transport tokens it accepts in a media line
    test "with a transport that the SDP parser does not know to be RTP is set up by its format" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=audio 0 RTP/AVP/TCP 8
      a=control:trackID=1
      """

      {camera, port} = start_camera(MockCamera.script(sdp, audio_media(8, 0)))
      pipeline = CameraPipeline.start_supervised!(port)

      assert_pipeline_notified(pipeline, :source, {:set_up_tracks, [track]})
      assert %{rtpmap: %{payload_type: 8, encoding: "PCMA"}} = track
      assert_sink_buffer(pipeline, {:sink, "trackID=1"}, %Membrane.Buffer{payload: @pcma_packet})

      MockCamera.close_connection(camera)
      assert_end_of_stream(pipeline, {:sink, "trackID=1"}, :input, 5_000)
    end

    test "that names no usable payload type is left out, and the others are set up" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=audio 0 RTP/AVP 8
      a=control:trackID=1
      m=application 0 RTP/AVP 77
      a=control:trackID=2
      m=application 0 udp wb
      a=control:trackID=3
      """

      {camera, port} = start_camera(MockCamera.script(sdp, audio_media(8, 0)))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pipeline = CameraPipeline.start_supervised!(port)

          assert_pipeline_notified(
            pipeline,
            :source,
            {:set_up_tracks, [%{control_path: "trackID=1"}]}
          )

          assert_sink_buffer(pipeline, {:sink, "trackID=1"}, %Membrane.Buffer{})

          MockCamera.close_connection(camera)
          assert_end_of_stream(pipeline, {:sink, "trackID=1"}, :input, 5_000)
        end)

      assert log =~ "trackID=2"
      assert log =~ "trackID=3"
      assert_received {:mock_camera, :request, "SETUP", %{url: setup_url}}
      assert setup_url =~ "trackID=1"
      refute_received {:mock_camera, :request, "SETUP", _request}
    end
  end

  describe "AAC track" do
    @aac_frame <<0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C>>

    defp aac_packet(sequence_number, payload) do
      payload
      |> MockCamera.rtp_packet(
        payload_type: 97,
        sequence_number: sequence_number,
        timestamp: sequence_number * 1024,
        marker: true,
        ssrc: 0xAAC
      )
      |> then(&MockCamera.interleaved(0, &1))
    end

    # one access unit, AAC-hbr: 16 bits of headers, 13 bits of size, 3 bits of index
    defp aac_hbr_payload(frame), do: <<16::16, byte_size(frame)::13, 0::3, frame::binary>>

    defp aac_sdp(fmtp_line) do
      """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=audio 0 RTP/AVP 97
      a=rtpmap:97 MPEG4-GENERIC/16000/1
      #{fmtp_line}
      a=control:trackID=1
      """
    end

    # RFC 3640 writes the names in mixed case in its examples; libavformat reads the
    # lengths and never looks at the mode
    test "without a mode is depayloaded according to sizelength and indexlength" do
      sdp =
        aac_sdp(
          "a=fmtp:97 streamtype=5; profile-level-id=15; config=1408; SizeLength=13; IndexLength=3; IndexDeltaLength=3;"
        )

      media = for n <- 0..3, do: aac_packet(n, aac_hbr_payload(@aac_frame))
      {camera, port} = start_camera(MockCamera.script(sdp, media))
      pipeline = CameraPipeline.start_supervised!(port)

      assert_sink_stream_format(pipeline, {:sink, "trackID=1"}, %Membrane.AAC{
        sample_rate: 16_000,
        channels: 1
      })

      assert_sink_buffer(pipeline, {:sink, "trackID=1"}, %Membrane.Buffer{payload: payload})
      assert String.ends_with?(payload, @aac_frame)

      MockCamera.close_connection(camera)
      assert_end_of_stream(pipeline, {:sink, "trackID=1"}, :input, 5_000)
    end

    test "with a packet that cannot be depayloaded loses that packet only" do
      sdp =
        aac_sdp(
          "a=fmtp:97 mode=AAC-hbr;config=1408;sizelength=13;indexlength=3;indexdeltalength=3"
        )

      media = [
        aac_packet(0, aac_hbr_payload(@aac_frame)),
        # declares more AU headers than the packet holds
        aac_packet(1, <<4000::16, 1, 2, 3>>),
        aac_packet(2, aac_hbr_payload(<<0x21, 0x99>>))
      ]

      {camera, port} = start_camera(MockCamera.script(sdp, media))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pipeline = CameraPipeline.start_supervised!(port)

          assert_sink_buffer(pipeline, {:sink, "trackID=1"}, %Membrane.Buffer{payload: first})
          assert_sink_buffer(pipeline, {:sink, "trackID=1"}, %Membrane.Buffer{payload: second})
          assert String.ends_with?(first, @aac_frame)
          assert String.ends_with?(second, <<0x21, 0x99>>)

          MockCamera.close_connection(camera)
          assert_end_of_stream(pipeline, {:sink, "trackID=1"}, :input, 5_000)
        end)

      assert log =~ "Dropping an RTP packet"
    end

    # without them nothing can tell how the payload is laid out or what the decoder
    # needs, so the payload is passed on untouched rather than guessed at
    for {description, fmtp_line} <- [
          {"without fmtp", "a=recvonly"},
          {"without a config", "a=fmtp:97 mode=AAC-hbr;sizelength=13;indexlength=3"},
          {"with neither a mode nor lengths", "a=fmtp:97 config=1408"}
        ] do
      test "#{description} is passed on as RTP payload" do
        payload = aac_hbr_payload(@aac_frame)
        media = [aac_packet(0, payload)]
        {camera, port} = start_camera(MockCamera.script(aac_sdp(unquote(fmtp_line)), media))

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            pipeline = CameraPipeline.start_supervised!(port)

            assert_sink_stream_format(pipeline, {:sink, "trackID=1"}, %Membrane.RTP{})

            assert_sink_buffer(pipeline, {:sink, "trackID=1"}, %Membrane.Buffer{payload: ^payload})

            MockCamera.close_connection(camera)
            assert_end_of_stream(pipeline, {:sink, "trackID=1"}, :input, 5_000)
          end)

        assert log =~ "trackID=1"
        assert log =~ "AAC"
      end
    end
  end

  describe "H264 parameter sets in the description" do
    # gortsplib "video h264 annexb" (gortsplib#402): the sets are base64 of the NAL
    # units with their Annex B start code. The comment on a camera model that appends
    # a start code was already in the source for H265.
    for {description, wrap} <- [
          {"that start with a start code", quote(do: fn set -> <<0, 0, 0, 1>> <> set end)},
          {"that end with a start code", quote(do: fn set -> set <> <<0, 0, 0, 1>> end)}
        ] do
      test "#{description} are used without it" do
        [sps, pps | _rest] =
          :binary.split(@h264, <<0, 0, 0, 1>>, [:global]) |> Enum.reject(&(&1 == ""))

        wrap = unquote(wrap)
        sprop = Enum.map_join([sps, pps], ",", &Base.encode64(wrap.(&1)))

        sdp = """
        v=0
        o=- 0 0 IN IP4 127.0.0.1
        s=Stream
        t=0 0
        m=video 0 RTP/AVP 96
        a=rtpmap:96 H264/90000
        a=fmtp:96 packetization-mode=1;sprop-parameter-sets=#{sprop}
        a=control:trackID=0
        """

        # the stream itself carries no parameter sets, they are only in the description
        media =
          @h264
          |> MockCamera.h264_rtp_packets(payload_type: 96)
          |> Enum.reject(fn <<_rtp_header::binary-size(12), _nal_header::3, type::5,
                              _rest::binary>> ->
            type in [7, 8]
          end)
          |> Enum.map(&MockCamera.interleaved(0, &1))

        {camera, port} = start_camera(MockCamera.script(sdp, media))
        pipeline = CameraPipeline.start_supervised!(port)

        assert_sink_stream_format(pipeline, {:sink, "trackID=0"}, %Membrane.H264{width: width})
        assert is_integer(width)
        assert_sink_buffer(pipeline, {:sink, "trackID=0"}, %Membrane.Buffer{payload: payload})
        # the parser puts the sets from the description in front of the first keyframe
        assert payload =~ sps
        refute payload =~ <<0, 0, 0, 1, 0, 0, 0, 1>>

        MockCamera.close_connection(camera)
        assert_end_of_stream(pipeline, {:sink, "trackID=0"}, :input, 5_000)
      end
    end
  end

  describe "status code" do
    @video_sdp """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=Stream
    t=0 0
    m=video 0 RTP/AVP 96
    a=rtpmap:96 H264/90000
    a=control:trackID=0
    """

    # RFC 2326 section 7.1.1 takes the classes of status codes from HTTP: every 2xx is
    # a success, and a client treats one it does not know as it treats 200
    test "of the 2xx class other than 200 is a success" do
      script =
        MockCamera.script(@video_sdp, [], %{
          "DESCRIBE" => fn _request ->
            MockCamera.describe_response(@video_sdp)
            |> String.replace("RTSP/1.0 200 OK", "RTSP/1.0 203 Non-Authoritative Information")
          end,
          "SETUP" => fn request ->
            MockCamera.response("RTSP/1.0 201 Created", [
              "Session: 1",
              "Transport: " <> request.headers["transport"]
            ])
          end,
          "PLAY" => fn _request ->
            [
              MockCamera.response("RTSP/1.0 250 Low on Storage Space", ["Session: 1"])
              | h264_media(96)
            ]
          end
        })

      {camera, port} = start_camera(script)
      pipeline = CameraPipeline.start_supervised!(port)

      assert_sink_buffer(pipeline, {:sink, "trackID=0"}, %Membrane.Buffer{})
      MockCamera.close_connection(camera)
      assert_end_of_stream(pipeline, {:sink, "trackID=0"}, :input, 5_000)
    end

    defp connection_failure(script) do
      {_camera, port} = start_camera(script)

      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _supervisor, pipeline} =
          Membrane.Testing.Pipeline.start(
            module: CameraPipeline,
            custom_args: %{port: port, source_options: []}
          )

        monitor = Process.monitor(pipeline)

        assert_receive {:DOWN, ^monitor, :process, ^pipeline,
                        {:membrane_child_crash, :source,
                         {%RuntimeError{message: message}, _stack}}},
                       5_000

        send(self(), {:failure, message})
      end)

      assert_received {:failure, message}
      message
    end

    test "that refuses a request is named in the error" do
      not_found = fn _request -> MockCamera.response("RTSP/1.0 404 Stream Not Found") end

      assert connection_failure(MockCamera.script(@video_sdp, [], %{"DESCRIBE" => not_found})) ==
               "RTSP connection failed, reason: :getting_rtsp_description_failed " <>
                 "(DESCRIBE was answered with status 404)"

      unsupported = fn _request -> MockCamera.response("RTSP/1.0 461 Unsupported Transport") end

      assert connection_failure(MockCamera.script(@video_sdp, [], %{"SETUP" => unsupported})) ==
               "RTSP connection failed, reason: :setting_up_rtsp_connection_failed " <>
                 "(SETUP of \"trackID=0\" was answered with status 461)"

      unavailable = fn _request -> MockCamera.response("RTSP/1.0 503 Service Unavailable") end

      assert connection_failure(MockCamera.script(@video_sdp, [], %{"PLAY" => unavailable})) ==
               "RTSP connection failed, reason: :play_rtsp_failed (PLAY was answered with status 503)"
    end

    test "200 for a description that cannot be used says what is wrong with it" do
      no_sdp = fn _request ->
        MockCamera.response("RTSP/1.0 200 OK", ["Content-Type: text/plain"])
      end

      assert connection_failure(MockCamera.script(@video_sdp, [], %{"DESCRIBE" => no_sdp})) =~
               "the reply to DESCRIBE carried no session description"

      audio_only = """
      v=0
      s=Stream
      m=text 0 RTP/AVP 98
      a=control:trackID=5
      """

      assert connection_failure(MockCamera.script(audio_only)) =~
               "none of the media in the session description can be received: text"
    end
  end

  describe "keep-alive" do
    defp keep_alive_methods(count) do
      for _n <- 1..count do
        assert_receive {:mock_camera, :request, method, _request}
                       when method in ["OPTIONS", "GET_PARAMETER"],
                       2_000

        method
      end
    end

    defp start_playing(script, source_options) do
      {camera, port} = start_camera(script)
      pipeline = CameraPipeline.start_supervised!(port, source_options)
      assert_receive {:mock_camera, :request, "PLAY", _request}, 2_000
      # the OPTIONS request sent while connecting is not a keep-alive
      assert_received {:mock_camera, :request, "OPTIONS", _request}
      {camera, pipeline}
    end

    @fast [keep_alive_interval: Membrane.Time.milliseconds(50)]

    test "is GET_PARAMETER when the server lists it among its methods" do
      start_playing(MockCamera.script(@video_sdp), @fast)

      assert keep_alive_methods(2) == ["GET_PARAMETER", "GET_PARAMETER"]
    end

    # libavformat, GStreamer and gortsplib all read the Public header of the reply to
    # OPTIONS and keep the session alive with OPTIONS when GET_PARAMETER is not in it
    test "is OPTIONS when the server does not list GET_PARAMETER among its methods" do
      options = fn _request ->
        MockCamera.response("RTSP/1.0 200 OK", ["public: DESCRIBE , SETUP,PLAY, TEARDOWN,options"])
      end

      {_camera, pipeline} =
        start_playing(MockCamera.script(@video_sdp, [], %{"OPTIONS" => options}), @fast)

      assert keep_alive_methods(3) == ["OPTIONS", "OPTIONS", "OPTIONS"]
      assert Process.alive?(pipeline)
    end

    # GStreamer names a camera that answers "551 Option not supported" for a method it
    # advertised, and treats 405, 406, 501 and 551 alike
    test "falls back to OPTIONS when the server refuses the GET_PARAMETER it advertised" do
      refuse = fn _request -> MockCamera.response("RTSP/1.0 551 Option not supported") end
      script = MockCamera.script(@video_sdp, [], %{"GET_PARAMETER" => refuse})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_camera, pipeline} = start_playing(script, @fast)

          assert keep_alive_methods(4) == ["GET_PARAMETER", "OPTIONS", "OPTIONS", "OPTIONS"]
          assert Process.alive?(pipeline)
        end)

      assert log =~ "551"
    end

    test "that the server refuses for another reason still ends the stream" do
      gone = fn _request -> MockCamera.response("RTSP/1.0 454 Session Not Found") end

      {_camera, port} =
        start_camera(MockCamera.script(@video_sdp, [], %{"GET_PARAMETER" => gone}))

      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _supervisor, pipeline} =
          Membrane.Testing.Pipeline.start(
            module: CameraPipeline,
            custom_args: %{port: port, source_options: @fast}
          )

        monitor = Process.monitor(pipeline)

        assert_receive {:DOWN, ^monitor, :process, ^pipeline,
                        {:membrane_child_crash, :source,
                         {%RuntimeError{message: message}, _stack}}},
                       5_000

        assert message == "RTSP keep-alive failed: GET_PARAMETER was answered with status 454"
      end)

      refute_received {:mock_camera, :request, "OPTIONS", %{headers: %{"session" => _session}}}
    end

    # gortsplib tolerates 404 here ("not implemented by every RTSP server"), GStreamer
    # 405, 406, 501 and 551
    test "works when the server refuses the OPTIONS request sent while connecting" do
      refused = fn request ->
        if request.headers["session"],
          do: MockCamera.response(),
          else: MockCamera.response("RTSP/1.0 405 Method Not Allowed")
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_camera, pipeline} =
            start_playing(MockCamera.script(@video_sdp, [], %{"OPTIONS" => refused}), @fast)

          # nothing is known about the server, so it is asked what it always was
          assert keep_alive_methods(2) == ["GET_PARAMETER", "GET_PARAMETER"]
          assert Process.alive?(pipeline)
        end)

      assert log =~ "405"
    end

    # RFC 2326 section 12.37: the server may close a session that it has not heard
    # from for the timeout it announced. libavformat sends a request every half of it.
    test "is sent within the timeout that the server announces for the session" do
      setup = fn request ->
        MockCamera.response("RTSP/1.0 200 OK", [
          "Session: 12345678 ; timeout=1",
          "Transport: " <> request.headers["transport"]
        ])
      end

      start_playing(MockCamera.script(@video_sdp, [], %{"SETUP" => setup}),
        keep_alive_interval: Membrane.Time.seconds(15)
      )

      assert_receive {:mock_camera, :request, "GET_PARAMETER", _request}, 900
    end
  end
end
