defmodule Segment.Batcher do
  @moduledoc """
  The `Segment.Batcher` module is the default service implementation for the library which uses the
  [Segment Batch HTTP API](https://segment.com/docs/sources/server/http/#batch) to put events in a FIFO queue and
  send on a regular basis.

  The `Segment.Batcher` can be configured with
  ```elixir
  config :segment,
    max_batch_size: 100,
    batch_every_ms: 5000
  ```

  * `config :segment, :max_batch_size` The maximum batch size of messages that will be sent to Segment at one time. Default value is 100.
  * `config :segment, :batch_every_ms` The time (in ms) between every batch request. Default value is 2000 (2 seconds)

  The Segment Batch API does have limits on the batch size "There is a maximum of 500KB per batch request and 32KB per call.". While
  the library doesn't check the size of the batch, if this becomes a problem you can change `max_batch_size` to a lower number and probably want
  to change `batch_every_ms` to run more frequently. The Segment API asks you to limit calls to under 50 a second, so even if you have no other
  Segment calls going on, don't go under 20ms!
  """

  use GenServer
  alias Segment.Analytics.{Alias, Group, Identify, Page, Screen, Track}
  require Logger

  @doc """
  Start the `Segment.Batcher` GenServer with an Segment HTTP Source API Write Key
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__, spawn_opt: [priority: :high])
  end

  @doc """
  Make a call to Segment with an event. Should be of type `Track, Identify, Screen, Alias, Group or Page`.
  This event will be queued and sent later in a batch.
  """
  @spec call(Segment.segment_event()) :: :ok
  def call(%mod{} = event) when mod in [Track, Identify, Screen, Alias, Group, Page] do
    GenServer.cast(__MODULE__, {:enqueue, event})
  end

  @doc """
  Force the batcher to flush the queue and send all the events as a big batch (warning could exceed batch size)
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  ### GenServer Callbacks

  def init(options) do
    options = Map.new(options)
    client = Segment.HTTP.client(options)

    timeout = options[:timeout] || Segment.Config.batch_every_ms()
    max_batch_size = options[:max_batch_size] || Segment.Config.max_batch_size()

    batches_limit =
      trunc((options[:events_hard_limit] || Segment.Config.events_hard_limit()) / max_batch_size) +
        1

    state =
      %{
        batch: [],
        batches: PersistentQueue.new(storage: options.storage, limit: batches_limit),
        client: client,
        current_batch_size: 0,
        max_batch_size: max_batch_size,
        size: 0,
        timeout: timeout,
        timer: nil
      }
      |> schedule_batch_send(timeout)

    {:ok, state}
  end

  def handle_cast({:enqueue, event}, %{size: size, batches: batches, batch: batch} = state) do
    case state do
      %{max_batch_size: max, current_batch_size: current} when current < max ->
        state = %{state | batch: [event | batch], current_batch_size: current + 1, size: size + 1}
        {:noreply, state}

      _ ->
        batch = Enum.reverse(batch)
        batches = PersistentQueue.enqueue(batches, batch)
        state = schedule_batch_send(state, 0)
        state = %{state | batches: batches, batch: [event], current_batch_size: 1, size: size + 1}
        {:noreply, state}
    end
  end

  def handle_call(:flush, _from, %{batches: batches, batch: batch, client: client} = state) do
    {batches, empty_queue} =
      batches
      |> PersistentQueue.enqueue(Enum.reverse(batch))
      |> PersistentQueue.dequeue_n(batches.size + 1)

    items = Enum.concat(batches)

    if items != [], do: Segment.HTTP.batch(client, items)
    {:reply, :ok, %{state | batches: empty_queue, batch: []}}
  end

  def handle_info(:tick, %{batches: batches, batch: batch, client: client} = state) do
    case PersistentQueue.dequeue(batches) do
      {{:value, batch_to_send}, batches} ->
        Segment.HTTP.batch(client, batch_to_send)
        state = schedule_batch_send(state, 0)
        {:noreply, %{state | batches: batches}}

      {:empty, _} ->
        case batch do
          [] ->
            state = schedule_batch_send(state, state.timeout)
            {:noreply, state}

          batch_to_send ->
            Segment.HTTP.batch(client, batch_to_send)
            state = schedule_batch_send(state, state.timeout)
            {:noreply, %{state | batch: []}}
        end
    end
  end

  def handle_info(unexpected_message, state) do
    Logger.warning(
      "#{inspect(__MODULE__)} Recevied unexpected_message #{inspect(unexpected_message)}"
    )

    {:noreply, state}
  end

  ### Helpers

  defp schedule_batch_send(%{timer: timer} = state, 0) do
    timer && Process.cancel_timer(timer)
    send(self(), :tick)
    %{state | timer: nil}
  end

  defp schedule_batch_send(%{timer: timer} = state, timeout) do
    timer && Process.cancel_timer(timer)
    timer = Process.send_after(self(), :tick, timeout)
    %{state | timer: timer}
  end
end
