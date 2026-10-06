defmodule SymphonyElixir.DashboardRateLimitsTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.DashboardLive
  @endpoint SymphonyElixirWeb.Endpoint

  defmodule Snapshot do
    use GenServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot, name: __MODULE__)
    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  defp payload(limits) do
    %{
      counts: %{running: 0, retrying: 0, blocked: 0},
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: limits
    }
  end

  defp html(limits, now \\ ~U[2026-01-01 00:00:00Z]) do
    render_component(&DashboardLive.render/1, payload: payload(limits), now: now)
  end

  test "camelCase windows render accessible percentages, real durations and UTC resets" do
    rendered = html(%{"primary" => %{"usedPercent" => 25, "windowDurationMins" => 300, "resetsAt" => 1_767_225_661}, "secondary" => %{"usedPercent" => 60, "windowDurationMins" => 10080}})
    assert rendered =~ "5-hour limit"
    assert rendered =~ "Weekly limit"
    assert rendered =~ "25% used · 75% remaining"
    assert rendered =~ ~s(role="progressbar")
    assert rendered =~ ~s(aria-valuenow="25")
    assert rendered =~ "Jan 01, 2026 at 00:01:01 UTC"
    assert rendered =~ "in 0d 0h 1m 1s"
    refute rendered =~ "usedPercent"
    refute rendered =~ "<pre"
    assert html(%{primary: %{used_percent: 0, window_duration_mins: 120, resets_at: 1_767_225_661}}) =~ "2-hour limit"
    assert html(%{primary: %{usedPercent: 100, windowDurationMins: 45}}) =~ "45-minute limit"
    assert html(%{"primary" => %{"used_percent" => 12.5}}) =~ "87.5% remaining"
  end

  test "missing null malformed and out-of-range values are safe" do
    for limits <- [nil, %{}, %{"primary" => nil}, "invalid"] do
      assert html(limits) =~ "Rate-limit information unavailable."
    end

    for window <- [%{}, %{used_percent: nil, resets_at: nil}, %{usedPercent: "bad", resetsAt: 999_999_999_999_999_999}] do
      rendered = html(%{primary: window})
      assert rendered =~ "Usage unavailable."
      assert rendered =~ "Reset time unavailable."
      refute rendered =~ ~s(role="progressbar")
    end

    assert html(%{primary: %{used_percent: -10}}) =~ "0% used · 100% remaining"
    assert html(%{primary: %{used_percent: 150}}) =~ "100% used · 0% remaining"
    assert html(%{primary: %{resets_at: 0}}) =~ "reset due"
  end

  test "countdown follows now without changing the snapshot" do
    limits = %{primary: %{used_percent: 25, resets_at: 1_767_225_661}}
    assert html(limits) =~ "in 0d 0h 1m 1s"
    assert html(limits, ~U[2026-01-01 00:00:01Z]) =~ "in 0d 0h 1m 0s"
  end

  test "connected LiveView refreshes rate windows over pubsub and runtime ticks" do
    config = Application.get_env(:symphony_elixir, @endpoint, [])
    on_exit(fn -> Application.put_env(:symphony_elixir, @endpoint, config) end)
    snapshot = Map.drop(payload(%{primary: %{usedPercent: 25, windowDurationMins: 300, resetsAt: DateTime.to_unix(DateTime.utc_now()) + 3600}}), [:counts])
    pid = start_supervised!({Snapshot, snapshot})
    Application.put_env(:symphony_elixir, @endpoint, Keyword.merge(config, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: Snapshot))
    start_supervised!({@endpoint, []})
    {:ok, view, rendered} = live(build_conn(), "/")
    assert rendered =~ "25% used"
    before = render(view)
    Process.sleep(1100)
    send(view.pid, :runtime_tick)
    refute render(view) == before
    :sys.replace_state(pid, &Map.put(&1, :rate_limits, %{secondary: %{used_percent: 70, window_duration_mins: 10080}}))
    send(view.pid, :observability_updated)
    assert render(view) =~ "70% used · 30% remaining"
    assert has_element?(view, ~s([role="progressbar"][aria-label="Weekly limit usage"]))
    refute render(view) =~ "25% used"
  end
end
