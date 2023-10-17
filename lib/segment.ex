defmodule Segment do
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @type segment_event ::
          Segment.Analytics.Track.t()
          | Segment.Analytics.Identify.t()
          | Segment.Analytics.Screen.t()
          | Segment.Analytics.Alias.t()
          | Segment.Analytics.Group.t()
          | Segment.Analytics.Page.t()

  alias Segment.Batcher

  @doc """
  Start the configured GenServer for handling Segment events with the Segment HTTP Source API Write Key

  By default if nothing is configured it will start `Segment.Batcher`
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) do
    Batcher.start_link(options)
  end

  @spec child_spec(map()) :: map()
  def child_spec(opts) do
    Batcher.child_spec(opts)
  end
end
