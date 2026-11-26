defmodule Membrane.RTSP.CameraQuirksTest do
  @moduledoc """
  Tests of `Membrane.RTSP.Source` against a scripted server. The responses are written by
  hand; none was captured from a device.
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

  describe "H264 stream" do
    test "is set up, parsed and ended when the server closes the connection" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=video 0 RTP/AVP 96
      a=rtpmap:96 H264/90000
      a=control:trackID=0
      """

      {camera, port} = start_camera(MockCamera.script(sdp, h264_media(96)))
      pipeline = CameraPipeline.start_supervised!(port)

      assert_pipeline_notified(
        pipeline,
        :source,
        {:set_up_tracks, [%{control_path: "trackID=0"}]}
      )

      assert_sink_stream_format(pipeline, {:sink, "trackID=0"}, %Membrane.H264{alignment: :au})
      assert_sink_buffer(pipeline, {:sink, "trackID=0"}, %Membrane.Buffer{})

      MockCamera.close_connection(camera)
      assert_end_of_stream(pipeline, {:sink, "trackID=0"}, :input, 5_000)
    end
  end

  describe "encoding name" do
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
      Enum.map(0..4, fn sequence_number ->
        @pcma_packet
        |> MockCamera.rtp_packet(
          payload_type: payload_type,
          sequence_number: sequence_number,
          timestamp: sequence_number * 8,
          ssrc: 0xA0D10
        )
        |> then(&MockCamera.interleaved(channel, &1))
      end)
    end

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

      assert_sink_buffer(pipeline, {:sink, "trackID=1"}, %Membrane.Buffer{payload: @pcma_packet})
      assert_sink_buffer(pipeline, {:sink, "trackID=0"}, %Membrane.Buffer{})

      MockCamera.close_connection(camera)
      assert_end_of_stream(pipeline, {:sink, "trackID=1"}, :input, 5_000)
    end

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

    test "without rtpmap for a dynamic payload type is set up and passed on unparsed" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=application 0 RTP/AVP 96
      a=control:trackID=2
      """

      {camera, port} = start_camera(MockCamera.script(sdp, audio_media(96, 0)))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pipeline = CameraPipeline.start_supervised!(port)

          assert_pipeline_notified(
            pipeline,
            :source,
            {:set_up_tracks, [%{rtpmap: nil, type: :application}]}
          )

          assert_sink_stream_format(pipeline, {:sink, "trackID=2"}, %Membrane.RTP{
            payload_format: nil
          })

          assert_sink_buffer(pipeline, {:sink, "trackID=2"}, %Membrane.Buffer{
            payload: @pcma_packet,
            pts: nil
          })

          MockCamera.close_connection(camera)
          assert_end_of_stream(pipeline, {:sink, "trackID=2"}, :input, 5_000)
        end)

      assert log =~ "The application media has no rtpmap for its payload type 96"
    end

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

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pipeline = CameraPipeline.start_supervised!(port)

          assert_pipeline_notified(pipeline, :source, {:set_up_tracks, [track]})
          assert %{rtpmap: %{payload_type: 98, encoding: "TP-LINK"}} = track

          assert_sink_buffer(pipeline, {:sink, "trackID=3"}, %Membrane.Buffer{
            payload: @pcma_packet
          })

          MockCamera.close_connection(camera)
          assert_end_of_stream(pipeline, {:sink, "trackID=3"}, :input, 5_000)
        end)

      assert log =~
               ~s(The format "smart/1/90000" of the application media is not an RTP payload type)
    end

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

    test "with the transport RTP/AVP/TCP is set up by its format" do
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

    test "whose only fmtp names another payload type is set up with that fmtp" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=audio 0 RTP/AVP 104
      a=rtpmap:104 MPEG4-GENERIC/16000/1
      a=fmtp:97 mode=AAC-hbr;config=1408;sizelength=13;indexlength=3;indexdeltalength=3
      a=control:trackID=1
      """

      frame = <<0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C>>

      media =
        Enum.map(0..2, fn n ->
          <<16::16, byte_size(frame)::13, 0::3, frame::binary>>
          |> MockCamera.rtp_packet(payload_type: 104, sequence_number: n, timestamp: n * 1024)
          |> then(&MockCamera.interleaved(0, &1))
        end)

      {camera, port} = start_camera(MockCamera.script(sdp, media))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pipeline = CameraPipeline.start_supervised!(port)

          assert_sink_stream_format(pipeline, {:sink, "trackID=1"}, %Membrane.AAC{
            sample_rate: 16_000
          })

          assert_sink_buffer(pipeline, {:sink, "trackID=1"}, %Membrane.Buffer{})

          MockCamera.close_connection(camera)
          assert_end_of_stream(pipeline, {:sink, "trackID=1"}, :input, 5_000)
        end)

      assert log =~
               "The fmtp of the audio media is given for payload type 97, using it for payload type 104"
    end

    test "that shares its payload type with another one is received over UDP" do
      sdp = """
      v=0
      o=- 0 0 IN IP4 127.0.0.1
      s=Stream
      t=0 0
      m=video 0 RTP/AVP 96
      a=rtpmap:96 H264/90000
      a=control:trackID=0
      m=audio 0 RTP/AVP 96
      a=rtpmap:96 opus/48000/2
      a=control:trackID=1
      """

      {_camera, port} = start_camera(MockCamera.script(sdp))
      pipeline = CameraPipeline.start_supervised!(port, transport: {:udp, 22_000, 22_020})

      assert_pipeline_notified(pipeline, :source, {:set_up_tracks, [_video, _audio]})

      assert_receive {:mock_camera, :request, "SETUP",
                      %{url: video_url, headers: %{"transport" => transport}}},
                     2_000

      assert video_url =~ "trackID=0"
      [_match, rtp_port] = Regex.run(~r/client_port=(\d+)-/, transport)
      assert_receive {:mock_camera, :request, "PLAY", _request}, 2_000

      {:ok, socket} = :gen_udp.open(0)

      Enum.each(
        MockCamera.h264_rtp_packets(@h264, payload_type: 96, max_payload_size: 1400),
        fn packet ->
          :ok = :gen_udp.send(socket, ~c"localhost", String.to_integer(rtp_port), packet)
        end
      )

      assert_sink_stream_format(
        pipeline,
        {:sink, "trackID=0"},
        %Membrane.H264{alignment: :au},
        5_000
      )

      assert_sink_buffer(pipeline, {:sink, "trackID=0"}, %Membrane.Buffer{}, 5_000)
      :gen_udp.close(socket)
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

      assert connection_failure(MockCamera.script("v=0\ns=Stream\n")) =~
               "the session description has no media"
    end
  end

  describe "request sent by the server" do
    test "between the RTP packets of an interleaved stream is answered and the stream goes on" do
      [first | rest] = h264_media(96)
      {second, rest} = Enum.split(rest, 20)

      ping =
        "GET_PARAMETER rtsp://localhost/stream RTSP/1.0\r\nCSeq: 7\r\nSession: 12345678\r\n\r\n"

      {ping_start, ping_end} = String.split_at("OPTIONS * RTSP/1.0\r\nCSeq: 8\r\n\r\n", 12)

      media = [[first, ping, second, ping_start], [ping_end | rest]]

      {camera, port} = start_camera(MockCamera.script(@video_sdp, media))
      pipeline = CameraPipeline.start_supervised!(port)

      assert_receive {:mock_camera, :response, "RTSP/1.0 200 OK\r\nCSeq: 7\r\nSession: 12345678"},
                     2_000

      assert_receive {:mock_camera, :response, "RTSP/1.0 200 OK\r\nCSeq: 8"}, 2_000

      MockCamera.close_connection(camera)
      assert_end_of_stream(pipeline, {:sink, "trackID=0"}, :input, 5_000)

      Membrane.Testing.Pipeline.terminate(pipeline)
      assert count_buffers(pipeline, {:sink, "trackID=0"}) == count_access_units()
    end

    defp count_buffers(pipeline, sink, count \\ 0) do
      receive do
        {Membrane.Testing.Pipeline, ^pipeline,
         {:handle_child_notification, {{:buffer, _buffer}, ^sink}}} ->
          count_buffers(pipeline, sink, count + 1)
      after
        0 -> count
      end
    end

    # access units of the fixture: each starts with a parameter set or SEI that follows a slice
    defp count_access_units() do
      @h264
      |> MockCamera.h264_rtp_packets(payload_type: 96)
      |> Enum.map(fn <<_header::binary-size(4), timestamp::32, _rest::binary>> -> timestamp end)
      |> Enum.uniq()
      |> length()
    end
  end
end
