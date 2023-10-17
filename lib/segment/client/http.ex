defmodule Segment.HTTP do
  @moduledoc """
  `Segment.HTTP` is the underlying implementation for making calls to the Segment HTTP API.

  The `send/2` and `batch/4` methods can be used for sending events or batches of events to the API.  The sending can be configured with
  ```elixir
  config :segment,
    retry_attempts: 3,
    retry_expiry: 10_000,
    retry_start: 100
  ```
  * `config :segment, :retry_attempts` The number of times to retry sending against the segment API. Default value is 3
  * `config :segment, :retry_expiry` The maximum time (in ms) spent retrying. Default value is 10000 (10 seconds)
  * `config :segment, :retry_start` The time (in ms) to start the first retry. Default value is 100
  * `config :segment, :adapter` Tesla adapter to use. A different Tesla Adapter can be used if you want to use something other than Hackney.

  The retry uses a linear back-off strategy when retrying the Segment API.
  """
  @type client :: Tesla.Client.t()
  @type adapter :: Tesla.Client.adapter()

  require Logger
  use Retry

  alias Segment.Analytics.Context
  alias Segment.Config
  alias Tesla.Adapter.Hackney
  alias Tesla.Middleware

  @doc """
  Create a Tesla client with the Segment Source Write API Key
  """
  @spec client(Keyword.t() | map()) :: client()
  def client(options) do
    api_key = options[:api_key]

    adapter =
      options[:adapter] ||
        Application.get_env(:segment, :tesla)[:adapter] ||
        {Hackney, recv_timeout: 30_000}

    middleware = [
      {Middleware.BaseUrl, options[:api_url] || Segment.Config.api_url()},
      Middleware.JSON,
      {Middleware.BasicAuth, %{username: api_key, password: ""}}
    ]

    Tesla.client(middleware, adapter)
  end

  @doc """
  Send a list of Segment events as a batch
  """
  @spec send(client(), list(Segment.segment_event())) :: :ok | :error
  def send(client, events) when is_list(events), do: batch(client, events)

  @spec send(client(), Segment.segment_event()) :: :ok | :error
  def send(client, event) do
    :telemetry.span([:segment, :send], %{event: event}, fn ->
      tesla_result =
        make_request(client, event.type, prepare_event(event), Config.retry_attempts())

      case process_send_post_result(tesla_result) do
        :ok ->
          {:ok, %{event: event, status: :ok, result: tesla_result}}

        :error ->
          {:error, %{event: event, status: :error, error: tesla_result, result: tesla_result}}
      end
    end)
  end

  defp process_send_post_result(tesla_result) do
    case tesla_result do
      {:ok, %{status: status}} when status == 200 ->
        :ok

      {:ok, %{status: status}} when status == 400 ->
        Logger.error("[Segment] Call Failed. JSON too large or invalid")
        :error

      {:error, err} ->
        Logger.error(
          "[Segment] Call Failed after #{Segment.Config.retry_attempts()} retries. #{inspect(err)}"
        )

        :error

      err ->
        Logger.error("[Segment] Call Failed #{inspect(err)}")
        :error
    end
  end

  @doc """
  Send a list of Segment events as a batch.

  The `batch` function takes optional arguments for context and integrations which can
  be applied to the entire batch of events. See [Segment's docs](https://segment.com/docs/sources/server/http/#batch)
  """
  @spec batch(client(), list(Segment.segment_event()), map() | nil, map() | nil) :: :ok | :error
  def batch(client, events, context \\ nil, integrations \\ nil) do
    :telemetry.span([:segment, :batch], %{events: events}, fn ->
      data =
        %{batch: prepare_events(events)}
        |> add_if(:context, context)
        |> add_if(:integrations, integrations)

      tesla_result = make_request(client, "batch", data, Config.retry_attempts())

      case process_batch_post_result(tesla_result, events) do
        :ok ->
          {:ok, %{events: events, status: :ok, result: tesla_result}}

        :error ->
          {:error, %{events: events, status: :error, error: tesla_result, result: tesla_result}}
      end
    end)
  end

  defp process_batch_post_result(tesla_result, events) do
    case tesla_result do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 400}} ->
        Logger.error(
          "[Segment] Batch call of #{length(events)} events failed. JSON too large or invalid"
        )

        :error

      {:error, err} ->
        Logger.error(
          "[Segment] Batch call of #{length(events)} events failed after #{Segment.Config.retry_attempts()} retries. #{inspect(err)}"
        )

        :error

      err ->
        Logger.error("[Segment] Batch callof #{length(events)} events failed #{inspect(err)}")
        :error
    end
  end

  defp make_request(client, url, data, retries) when retries > 0 do
    retry with:
            Config.retry_start()
            |> linear_backoff(2)
            |> cap(Config.retry_expiry())
            |> Stream.take(retries) do
      Tesla.post(client, url, data)
    after
      result -> result
    else
      error -> error
    end
  end

  defp make_request(client, url, data, _retries) do
    Tesla.post(client, url, data)
  end

  defp prepare_events(items) when is_list(items) do
    Enum.map(items, &prepare_event/1)
  end

  defp prepare_event(item) do
    item
    |> Map.from_struct()
    |> prep_context()
    |> add_sent_at()
    |> drop_nils()
  end

  defp drop_nils(map) do
    map
    |> Enum.filter(fn
      {_, %{} = item} when map_size(item) == 0 -> false
      {_, nil} -> false
      {_, _} -> true
    end)
    |> Enum.into(%{})
  end

  defp prep_context(%{context: nil} = map) do
    %{map | context: map_content(Context.new())}
  end

  defp prep_context(%{context: context} = map) do
    %{map | context: map_content(context)}
  end

  defp prep_context(map) do
    Map.put(map, :context, map_content(Context.new()))
  end

  defp map_content(%Segment.Analytics.Context{} = context), do: Map.from_struct(context)
  defp map_content(context) when is_map(context), do: context

  defp add_sent_at(%{sentAt: %{}} = map), do: map
  defp add_sent_at(map), do: Map.put(map, :sentAt, DateTime.utc_now())

  defp add_if(map, _key, nil), do: map
  defp add_if(map, key, value), do: Map.put_new(map, key, value)
end
