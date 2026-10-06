defmodule SymphonyElixir.DashboardObservabilityTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias SymphonyElixirWeb.{DashboardLive, Presenter, ObservabilityPubSub}
  @endpoint SymphonyElixirWeb.Endpoint

  defmodule Snapshot do
    use GenServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot, name: __MODULE__)
    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  defp snapshot do
    common = %{
      issue_id: "fixture-running",
      identifier: "GH-101",
      issue_url: "https://github.com/example/repo/issues/101",
      state: "Running",
      session_id: "thread-fixture/turn-1",
      started_at: ~U[2026-01-01 00:00:00Z],
      turn_count: 3,
      last_codex_event: :turn_completed,
      last_codex_message: "Finished <unsafe> & checked",
      last_codex_timestamp: ~U[2026-01-01 00:01:00Z],
      codex_input_tokens: 1200,
      codex_output_tokens: 300,
      codex_total_tokens: 1500,
      workspace_path: "/isolated/fixture",
      worker_host: nil
    }

    %{
      running: [common],
      retrying: [
        %{
          issue_id: "fixture-retry",
          identifier: "GH-102",
          issue_url: nil,
          attempt: 4,
          due_in_ms: 60000,
          error: "retry <error>"
        }
      ],
      blocked: [
        Map.merge(common, %{
          issue_id: "fixture-blocked",
          identifier: "GH-103",
          state: "Blocked",
          session_id: "blocked-fixture/turn-2",
          blocked_at: ~U[2026-01-01 00:02:00Z],
          error: "approval required"
        })
      ],
      codex_totals: %{
        input_tokens: 2200,
        output_tokens: 800,
        total_tokens: 3000,
        seconds_running: 30
      },
      rate_limits: nil
    }
  end

  setup do
    config = Application.get_env(:symphony_elixir, @endpoint, [])
    on_exit(fn -> Application.put_env(:symphony_elixir, @endpoint, config) end)
    pid = start_supervised!({Snapshot, snapshot()})

    Application.put_env(
      :symphony_elixir,
      @endpoint,
      Keyword.merge(config,
        server: false,
        secret_key_base: String.duplicate("s", 64),
        orchestrator: Snapshot
      )
    )

    start_supervised!({@endpoint, []})
    %{snapshot_pid: pid}
  end

  test "Presenter derives counts and preserves running, retry and blocked details" do
    payload = Presenter.state_payload(Snapshot, 1000)
    assert payload.counts == %{running: 1, retrying: 1, blocked: 1}

    assert hd(payload.running).tokens == %{
             input_tokens: 1200,
             output_tokens: 300,
             total_tokens: 1500
           }

    assert hd(payload.running).turn_count == 3
    assert hd(payload.retrying).attempt == 4
    {:ok, due, 0} = DateTime.from_iso8601(hd(payload.retrying).due_at)
    assert DateTime.diff(due, DateTime.utc_now()) in 58..60
    assert hd(payload.blocked).blocked_at == "2026-01-01T00:02:00Z"

    assert payload.codex_totals.total_tokens ==
             payload.codex_totals.input_tokens + payload.codex_totals.output_tokens
  end

  test "nonempty tables render runtime turns token totals and escaped messages" do
    payload = Presenter.state_payload(Snapshot, 1000)

    rendered =
      render_component(&DashboardLive.render/1, payload: payload, now: ~U[2026-01-01 00:02:05Z])

    assert rendered =~ "2m 5s / 3"
    assert rendered =~ "2m 35s"
    assert rendered =~ "Total: 1,500"
    assert rendered =~ "In 1,200 / Out 300"
    assert rendered =~ "3,000"
    assert rendered =~ "In 2,200 / Out 800"
    assert rendered =~ "retry &lt;error&gt;"
    assert rendered =~ "approval required"
    assert rendered =~ "2026-01-01T00:02:00Z"
    assert rendered =~ "&lt;unsafe&gt;"
    refute rendered =~ "No blocked sessions."
    refute rendered =~ "No issues are currently backing off."

    if path = System.get_env("VERIFY_DASHBOARD_FIXTURE") do
      css = File.read!("priv/static/dashboard.css")

      File.write!(
        path,
        "<!doctype html><meta charset=\"utf-8\"><style>#{css}</style><div data-phx-main class=\"phx-connected\">#{rendered}</div>"
      )
    end
  end

  test "missing optional row values render safe fallbacks", %{snapshot_pid: pid} do
    :sys.replace_state(pid, fn s ->
      %{
        s
        | running: [
            Map.merge(hd(s.running), %{
              session_id: nil,
              started_at: nil,
              turn_count: 0,
              last_codex_message: nil,
              last_codex_event: nil,
              last_codex_timestamp: nil
            })
          ],
          retrying: [Map.merge(hd(s.retrying), %{due_in_ms: nil, error: nil})],
          blocked: [
            Map.merge(hd(s.blocked), %{
              state: nil,
              session_id: nil,
              blocked_at: nil,
              error: nil,
              last_codex_message: nil,
              last_codex_event: nil,
              last_codex_timestamp: nil
            })
          ]
      }
    end)

    {:ok, view, rendered} = live(build_conn(), "/")
    refute has_element?(view, "button[data-copy]")
    assert rendered =~ "0m 0s"
    assert rendered =~ "n/a"
    assert has_element?(view, ".state-badge", "Blocked")
    assert has_element?(view, ".metric-card:nth-child(1) .metric-value", "1")
    assert has_element?(view, ".metric-card:nth-child(2) .metric-value", "1")
    assert has_element?(view, ".metric-card:nth-child(3) .metric-value", "1")
  end

  test "all JSON detail links resolve through the API with matching issue status" do
    {:ok, view, _} = live(build_conn(), "/")

    for {identifier, status} <- [
          {"GH-101", "running"},
          {"GH-102", "retrying"},
          {"GH-103", "blocked"}
        ] do
      assert has_element?(view, "a[href='/api/v1/#{identifier}']", "JSON details")
      result = build_conn() |> get("/api/v1/#{identifier}") |> json_response(200)
      assert result["issue_identifier"] == identifier
      assert result["status"] == status
    end

    result = build_conn() |> get("/api/v1/GH-404") |> json_response(404)
    assert result["error"]["code"] == "issue_not_found"
    assert has_element?(view, "a.issue-id-link[target='_blank'][rel='noopener noreferrer']")
    refute has_element?(view, "a.issue-id-link", "GH-102")
  end

  test "unsafe tracker URLs never become navigable links", %{snapshot_pid: pid} do
    for url <- ["javascript:alert(1)", "data:text/html,unsafe", "https:///", "//example.com"] do
      :sys.replace_state(pid, fn s ->
        %{s | running: [Map.put(hd(s.running), :issue_url, url)]}
      end)

      {:ok, view, _} = live(build_conn(), "/")
      refute has_element?(view, "a.issue-id-link", "GH-101")
      assert has_element?(view, "span.issue-id", "GH-101")
    end
  end

  test "pubsub refresh updates all counts and queue rows", %{snapshot_pid: pid} do
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "table tbody tr", "GH-103")
    :sys.replace_state(pid, fn s -> %{s | running: [], retrying: [], blocked: []} end)
    ObservabilityPubSub.broadcast_update()
    rendered = render(view)
    assert rendered =~ "No active sessions."
    assert rendered =~ "No blocked sessions."
    assert rendered =~ "No issues are currently backing off."

    assert Enum.all?(:sys.get_state(view.pid).socket.assigns.payload.counts, fn {_key, value} ->
             value == 0
           end)
  end

  test "unavailable snapshot shows error and connected view recovers" do
    {:ok, view, _} = live(build_conn(), "/")
    stop_supervised!(Snapshot)
    send(view.pid, :observability_updated)
    assert render(view) =~ "snapshot_unavailable"
    assert render(view) =~ "Snapshot unavailable"
    start_supervised!({Snapshot, snapshot()}, id: :replacement_snapshot)
    send(view.pid, :observability_updated)
    assert has_element?(view, "table tbody tr", "GH-101")
    refute render(view) =~ "error-card"
  end
end
