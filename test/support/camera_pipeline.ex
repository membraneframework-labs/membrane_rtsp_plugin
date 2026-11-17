defmodule Membrane.RTSP.CameraPipeline do
  @moduledoc false
  # Connects Membrane.RTSP.Source to a server and links every track it sets up to a
  # Membrane.Testing.Sink named `{:sink, control_path}`.

  use Membrane.Pipeline

  @spec start_supervised!(:inet.port_number(), keyword()) :: pid()
  def start_supervised!(port, source_options \\ []) do
    Membrane.Testing.Pipeline.start_link_supervised!(
      module: __MODULE__,
      custom_args: %{port: port, source_options: source_options}
    )
  end

  @impl true
  def handle_init(_ctx, %{port: port, source_options: source_options}) do
    {path, source_options} = Keyword.pop(source_options, :path, "/stream")
    {userinfo, source_options} = Keyword.pop(source_options, :userinfo)
    authority = if userinfo, do: "#{userinfo}@localhost:#{port}", else: "localhost:#{port}"

    source =
      struct!(
        Membrane.RTSP.Source,
        [stream_uri: "rtsp://#{authority}#{path}", on_connection_closed: :send_eos] ++
          source_options
      )

    {[spec: child(:source, source)], %{}}
  end

  @impl true
  def handle_child_notification({:set_up_tracks, tracks}, :source, _ctx, state) do
    spec =
      Enum.map(tracks, fn track ->
        get_child(:source)
        |> via_out(Pad.ref(:output, track.control_path))
        |> child({:sink, track.control_path}, Membrane.Testing.Sink)
      end)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

  @impl true
  def handle_child_pad_removed(_child, _pad, _ctx, state), do: {[], state}
end
