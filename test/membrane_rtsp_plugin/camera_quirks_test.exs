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
end
