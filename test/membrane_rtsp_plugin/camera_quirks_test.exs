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
    end
  end
end
