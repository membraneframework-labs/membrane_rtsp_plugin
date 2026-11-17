defmodule Membrane.RTSP.QuirkyCameraTest do
  @moduledoc """
  End-to-end: `Membrane.RTSP.Source` against a scripted server that shows many
  deviations at once, the way a single camera does. Every one of them used to end the
  connection. The server is a script written for this test, not a recording of a device.
  """
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Membrane.RTSP.{CameraPipeline, MockCamera}

  @h264 File.read!("test/fixtures/in.h264")
  @realm "IP Camera(C1234)"
  @nonce "5f1a9c0e7d"
  @digest_opaque "b7a3"

  # LF-only line ends, a user name with a space in the origin, an experimental and an
  # RTCP bandwidth, the timing repeated inside a media section, a lower-case encoding
  # name, no fmtp for the video (the parameter sets come in the stream), a frame rate
  # that is not a number, G.711 audio without rtpmap, and a metadata track whose
  # payload type nothing describes.
  @sdp """
  v=0
  o=RTSP Session 0 0 IN IP4 0.0.0.0
  s=Media Server
  c=IN IP4 0.0.0.0
  t=0 0
  a=control:*
  a=range:npt=now-
  m=video 0 RTP/AVP 96
  t=0 0
  b=X-AV:100
  b=RR:0
  a=rtpmap:96 h264/90000
  a=framerate:25fps
  a=control:trackID=0
  m=audio 0 RTP/AVP 8
  a=control:trackID=1
  m=application 0 RTP/AVP 107
  a=control:trackID=2
  a=recvonly
  """

  @pcma <<0xD5, 0x55, 0xD5, 0x55>>

  defp md5(data), do: data |> :erlang.md5() |> Base.encode16(case: :lower)

  # Whether the request carries the Digest response for admin / p@ss
  defp authorized?(method, request) do
    with authorization when is_binary(authorization) <- request.headers["authorization"],
         [_match, response] <- Regex.run(~r/response="([0-9a-f]+)"/, authorization),
         true <- authorization =~ ~s(opaque="#{@digest_opaque}") do
      ha1 = md5("admin:#{@realm}:p@ss")
      ha2 = md5("#{method}:#{request.url}")
      response == md5("#{ha1}:#{@nonce}:#{ha2}")
    else
      _other -> false
    end
  end

  # The challenge: Basic comes first, the Digest parameters are not all quoted, and the
  # status line has no reason phrase. Header names are in lower case with no space
  # after the colon.
  defp unauthorized() do
    "RTSP/1.0 401\r\ncseq:{CSEQ}\r\n" <>
      "www-authenticate:Basic realm=\"#{@realm}\"\r\n" <>
      "www-authenticate:digest realm=\"#{@realm}\", nonce=#{@nonce}, opaque=\"#{@digest_opaque}\", stale=FALSE\r\n\r\n"
  end

  defp media() do
    video =
      @h264
      |> MockCamera.h264_rtp_packets(payload_type: 96)
      |> Enum.map(&MockCamera.interleaved(4, &1))

    audio =
      for n <- 0..9 do
        @pcma
        |> MockCamera.rtp_packet(payload_type: 8, sequence_number: n, timestamp: n * 4, ssrc: 0xA)
        |> then(&MockCamera.interleaved(6, &1))
      end

    # an RTCP sender report on the channel next to the video
    sender_report = MockCamera.interleaved(5, <<2::2, 0::6, 200, 6::16, 0x1234ABCD::32, 0::160>>)
    # a frame with nothing in it and one too short to be RTP
    empty_frames = [MockCamera.interleaved(4, <<>>), MockCamera.interleaved(4, <<0x80>>)]
    ping = "OPTIONS rtsp://localhost/ RTSP/1.0\r\nCSeq: 1\r\n\r\n"

    {first_video, rest_video} = Enum.split(video, 10)
    first_video ++ [sender_report, ping] ++ empty_frames ++ audio ++ rest_video
  end

  defp script(base_url) do
    fn
      method, request when method != "OPTIONS" or is_map_key(request.headers, "session") ->
        if authorized?(method, request),
          do: reply(method, request, base_url),
          else: unauthorized()

      "OPTIONS", _request ->
        # no GET_PARAMETER among the methods
        "RTSP/1.0 200 OK\r\nCSeq: {CSEQ}\r\nPublic:OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n\r\n"
    end
  end

  defp reply("OPTIONS", _request, _base_url), do: MockCamera.response()

  defp reply("DESCRIBE", _request, base_url) do
    # the content type has a parameter and odd case, the base is not the URL asked for
    "RTSP/1.0 200 OK\r\nCSeq: {CSEQ}\r\nContent-type: Application/SDP; charset=utf-8\r\n" <>
      "Content-Base: #{base_url}\r\nContent-length: #{byte_size(@sdp)}\r\n\r\n" <> @sdp
  end

  defp reply("SETUP", request, base_url) do
    # only URLs built from Content-Base exist on this server
    if String.starts_with?(request.url, base_url) do
      [_match, first] = Regex.run(~r/interleaved=(\d+)/, request.headers["transport"])
      channel = String.to_integer(first) + 4

      # other channels than asked for, a padded session id and a short timeout
      MockCamera.response("RTSP/1.0 200 OK", [
        "Session:  0a1b2c3d ; timeout=1",
        "Transport: RTP/AVP/TCP;unicast;interleaved=#{channel}-#{channel + 1};ssrc= 4317f;mode=\"PLAY\""
      ])
    else
      MockCamera.response("RTSP/1.0 404 Not Found")
    end
  end

  defp reply("PLAY", _request, _base_url),
    do: [MockCamera.response("RTSP/1.0 200 OK", ["Session: 0a1b2c3d"]) | media()]

  defp reply(_method, _request, _base_url), do: MockCamera.response()

  defp collect_payloads(pipeline, sink, acc \\ []) do
    receive do
      {Membrane.Testing.Pipeline, ^pipeline,
       {:handle_child_notification, {{:buffer, %Membrane.Buffer{payload: payload}}, ^sink}}} ->
        collect_payloads(pipeline, sink, [payload | acc])
    after
      0 -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  test "a stream is received in full from a server with many quirks at once" do
    test_process = self()

    # the base URL holds the port of the server, which is only known once it listens
    camera =
      start_supervised!(%{
        id: :camera,
        start:
          {MockCamera, :start_link,
           [
             fn method, request ->
               [_match, port] = Regex.run(~r/localhost:(\d+)/, request.url)
               script("rtsp://localhost:#{port}/media/video1/").(method, request)
             end,
             test_process
           ]}
      })

    port = MockCamera.port(camera)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pipeline =
          CameraPipeline.start_supervised!(port,
            path: "/live?channel=1",
            userinfo: "admin:p%40ss",
            keep_alive_interval: Membrane.Time.seconds(15)
          )

        assert_pipeline_notified(pipeline, :source, {:set_up_tracks, tracks})

        assert [
                 %{
                   control_path: "trackID=0",
                   type: :video,
                   rtpmap: %{encoding: "h264"},
                   fmtp: nil
                 },
                 %{
                   control_path: "trackID=1",
                   type: :audio,
                   rtpmap: %{encoding: "PCMA", clock_rate: 8000}
                 },
                 %{control_path: "trackID=2", type: :application, rtpmap: nil}
               ] = Enum.sort_by(tracks, & &1.control_path)

        # the request of the server in the middle of the stream is answered
        assert_receive {:mock_camera, :response, "RTSP/1.0 200 OK\r\nCSeq: 1"}, 2_000

        # the session timeout of one second is honoured, with the method the server has
        assert_receive {:mock_camera, :request, "OPTIONS",
                        %{headers: %{"session" => "0a1b2c3d"}}},
                       900

        refute_received {:mock_camera, :request, "GET_PARAMETER", _request}

        MockCamera.close_connection(camera)
        assert_end_of_stream(pipeline, {:sink, "trackID=0"}, :input, 5_000)
        assert_end_of_stream(pipeline, {:sink, "trackID=1"}, :input, 5_000)
        Membrane.Testing.Pipeline.terminate(pipeline)

        # the video comes out complete and parsed, the audio as the server sent it
        assert_sink_stream_format(pipeline, {:sink, "trackID=0"}, %Membrane.H264{alignment: :au})
        assert collect_payloads(pipeline, {:sink, "trackID=0"}) == @h264
        assert collect_payloads(pipeline, {:sink, "trackID=1"}) == String.duplicate(@pcma, 10)
      end)

    # the control URLs were resolved against Content-Base after the first try failed
    assert_received {:mock_camera, :request, "SETUP", %{url: rejected}}
    assert rejected == "rtsp://localhost:#{port}/live/trackID=0"
    assert_received {:mock_camera, :request, "SETUP", %{url: accepted}}
    assert accepted == "rtsp://localhost:#{port}/media/video1/trackID=0"

    # and nothing was tolerated silently
    for deviation <- [
          "o=RTSP Session 0 0 IN IP4 0.0.0.0",
          "b=X-AV:100",
          "t=0 0",
          "framerate:25fps",
          "rejected with status 404",
          "malformed RTP packet"
        ] do
      assert log =~ deviation
    end
  end
end
