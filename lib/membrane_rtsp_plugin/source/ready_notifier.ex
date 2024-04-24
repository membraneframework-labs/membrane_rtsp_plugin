defmodule Membrane.RTSP.Source.ReadyNotifier do
  use Membrane.Source

  def handle_playing(_ctx, state) do
    {[notify_parent: :ready], state}
  end
end
