# Membrane RTSP Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_rtsp_plugin.svg)](https://hex.pm/packages/membrane_rtsp_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_rtsp_plugin)

Plugin that simplifies connecting to RTSP servers.

## Installation

Add the following line to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_rtsp_plugin, "~> 0.2.0"}
  ]
end
```

## Usage

The following pipeline reads only video from a local RTSP server using `TCP` transport

```elixir
defmodule RtspPipeline do
  @moduledoc false

  use Membrane.Pipeline

  def start() do
    Pipeline.start(__MODULE__, options)
  end

  @impl true
  def handle_init(_ctx, _opts) do
    spec = [
      child(:source, %Membrane.RTSP.Source{
        transport: :tcp,
        allowed_media_types: [:video],
        stream_uri: "rtsp://localhost:8554/mystream"
      })
    ]

    {[spec: spec], %{}}
  end

  @impl true
  def handle_child_notification({:new_track, ssrc, _track}, _element, _ctx, state) do
    spec = [
      get_child(:source)
      |> via_out(Pad.ref(:output, ssrc))
      |> child(:funnel, Membrane.Funnel)
      |> child(:sink, , %Membrane.File.Source{
        location: "video.h264"
      })
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(_message, _element, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_child_pad_removed(:source, _pad, _ctx, state) do
    {[], state}
  end
end
```