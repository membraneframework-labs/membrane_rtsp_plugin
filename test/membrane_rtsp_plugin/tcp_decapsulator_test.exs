defmodule Membrane.RTSP.DecapsulatorTest do
  use ExUnit.Case

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.RTSP.TCP.Decapsulator
  alias Membrane.Testing.{Pipeline, Sink, Source}

  @header_length 4

  defp encapsulate_rtp_packets(rtp_packets) do
    Enum.map(rtp_packets, &<<"$", 0, byte_size(&1)::size(16), &1::binary>>)
  end

  defp create_tcp_segments(encapsulated_rtp_packets, tcp_segments_lengths) do
    assert Enum.sum(tcp_segments_lengths) ==
             Enum.sum(Enum.map(encapsulated_rtp_packets, &byte_size(&1)))

    encaplsulated_rtp_packets_binary = Enum.join(encapsulated_rtp_packets)

    {tcp_segments, _length} =
      Enum.map_reduce(tcp_segments_lengths, 0, fn len, pos ->
        {:binary.part(encaplsulated_rtp_packets_binary, pos, len), pos + len}
      end)

    tcp_segments
  end

  defp perform_standard_test(rtp_packets_lengths, tcp_segments_lengths) do
    rtp_packets = Enum.map(rtp_packets_lengths, &<<0::size(&1)-unit(8)>>)

    tcp_segments =
      rtp_packets |> encapsulate_rtp_packets() |> create_tcp_segments(tcp_segments_lengths)

    pipeline =
      Pipeline.start_link_supervised!(
        spec:
          child(:source, %Source{
            output: tcp_segments
          })
          |> child(:decapsulator, %Decapsulator{rtsp_session: self()})
          |> child(:sink, Sink)
      )

    Enum.each(rtp_packets, fn packet ->
      assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^packet})
    end)

    Pipeline.terminate(pipeline)
  end

  describe "RTSP Decapsulator decapsulates correctly" do
    test "when one tcp segment is one rtp packet" do
      rtp_packets_lengths = 10..20
      tcp_segments_lengths = Enum.map(rtp_packets_lengths, &(&1 + @header_length))

      perform_standard_test(rtp_packets_lengths, tcp_segments_lengths)
    end

    test "when there are multiple (3) rtp packets in one tcp segment" do
      rtp_packets_lengths = 10..40

      tcp_segments_lengths =
        rtp_packets_lengths
        |> Enum.chunk_every(3)
        |> Enum.map(&(Enum.sum(&1) + length(&1) * @header_length))

      perform_standard_test(rtp_packets_lengths, tcp_segments_lengths)
    end

    test "when rtp packets are spread across multiple (3) tcp segments" do
      rtp_packets_lengths = 11..41//3

      tcp_segments_lengths =
        Enum.flat_map(rtp_packets_lengths, fn len ->
          tcp_segment_base_length = div(len + @header_length, 3)
          [tcp_segment_base_length - 1, tcp_segment_base_length, tcp_segment_base_length + 1]
        end)

      perform_standard_test(rtp_packets_lengths, tcp_segments_lengths)
    end
  end

  describe "RTSP Decapsulator keeps the packets in order" do
    test "when an RTSP response ends the tcp segment that they came in" do
      packets = Enum.map(1..3, fn n -> <<n, n, n>> end)
      response = "RTSP/1.0 200 OK\r\nCSeq: 5\r\n\r\n"
      tcp_segment = Enum.join(encapsulate_rtp_packets(packets)) <> response

      pipeline =
        Pipeline.start_link_supervised!(
          spec:
            child(:source, %Source{output: [tcp_segment]})
            |> child(:decapsulator, %Decapsulator{rtsp_session: self()})
            |> child(:sink, Sink)
        )

      Enum.each(packets, fn packet ->
        assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: payload})
        assert payload == packet
      end)

      assert_receive {:raw_response, ^response}
      Pipeline.terminate(pipeline)
    end
  end

  describe "RTSP Decapsulator passes a request of the server to the session" do
    test "wherever the tcp segments cut it" do
      request = "GET_PARAMETER rtsp://localhost/stream RTSP/1.0\r\nCSeq: 7\r\n\r\n"
      packet = <<1, 2, 3>>
      [frame] = encapsulate_rtp_packets([packet])

      Enum.each(1..(byte_size(request) - 1), fn cut ->
        {request_start, request_end} = String.split_at(request, cut)

        pipeline =
          Pipeline.start_link_supervised!(
            spec:
              child(:source, %Source{output: [frame <> request_start, request_end <> frame]})
              |> child(:decapsulator, %Decapsulator{rtsp_session: self()})
              |> child(:sink, Sink)
          )

        assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^packet})
        assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^packet})
        assert_receive {:raw_response, ^request}
        Pipeline.terminate(pipeline)
      end)
    end
  end

  describe "RTSP Decapsulator skips an empty line after an RTSP message" do
    test "wherever the tcp segments cut it" do
      response = "RTSP/1.0 200 OK\r\nCSeq: 5\r\n\r\n"
      packet = <<1, 2, 3>>
      [frame] = encapsulate_rtp_packets([packet])

      Enum.each(0..2, fn cut ->
        {empty_line_start, empty_line_end} = String.split_at("\r\n", cut)
        tcp_segments = [frame <> response <> empty_line_start, empty_line_end <> frame]

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            pipeline =
              Pipeline.start_link_supervised!(
                spec:
                  child(:source, %Source{output: tcp_segments})
                  |> child(:decapsulator, %Decapsulator{rtsp_session: self()})
                  |> child(:sink, Sink)
              )

            assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^packet})
            assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^packet})
            assert_receive {:raw_response, ^response}
            Pipeline.terminate(pipeline)
          end)

        assert log =~ "Skipping an empty line"
      end)
    end
  end

  describe "RTSP Decapsulator skips data that is neither an interleaved packet nor an RTSP message" do
    test "wherever the tcp segments cut it" do
      unknown_data = <<0, 255, 1, 2, 3, 4, 5, 6, 7, 8>>
      packet = <<1, 2, 3>>
      [frame] = encapsulate_rtp_packets([packet])

      Enum.each(0..byte_size(unknown_data), fn cut ->
        {unknown_data_start, unknown_data_end} = :erlang.split_binary(unknown_data, cut)
        tcp_segments = [frame <> unknown_data_start, unknown_data_end <> frame]

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            pipeline =
              Pipeline.start_link_supervised!(
                spec:
                  child(:source, %Source{output: tcp_segments})
                  |> child(:decapsulator, %Decapsulator{rtsp_session: self()})
                  |> child(:sink, Sink)
              )

            assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^packet})
            assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{payload: ^packet})
            assert_end_of_stream(pipeline, :sink)
            refute_sink_buffer(pipeline, :sink, _buffer, 0)
            Pipeline.terminate(pipeline)
          end)

        assert log =~ "bytes that are neither an interleaved RTP packet nor an RTSP message"
      end)
    end
  end
end
