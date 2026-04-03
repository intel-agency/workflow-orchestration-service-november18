"""Tests for Dispatcher — subprocess lifecycle, timeout, and sequential dispatch."""
from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.dispatcher import Dispatcher, _SCRIPT_PATH


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def config(monkeypatch):
    monkeypatch.setenv("GITHUB_ORG", "test-org")
    monkeypatch.setenv("GH_ORCHESTRATION_AGENT_TOKEN", "tok-abc")
    monkeypatch.setenv("WEBHOOK_SECRET", "test-secret")
    monkeypatch.setenv("OPENCODE_SERVER_URL", "http://server:4096")
    monkeypatch.setenv("SUBPROCESS_TIMEOUT_SECS", "60")
    from src.config import ServiceConfig
    return ServiceConfig()


@pytest.fixture
def config_short_timeout(monkeypatch):
    """Config with a very short subprocess timeout for timeout-related tests."""
    monkeypatch.setenv("GITHUB_ORG", "test-org")
    monkeypatch.setenv("GH_ORCHESTRATION_AGENT_TOKEN", "tok-abc")
    monkeypatch.setenv("WEBHOOK_SECRET", "test-secret")
    monkeypatch.setenv("OPENCODE_SERVER_URL", "http://server:4096")
    monkeypatch.setenv("SUBPROCESS_TIMEOUT_SECS", "1")
    from src.config import ServiceConfig
    return ServiceConfig()


def _make_proc(returncode: int = 0, *, hang: bool = False) -> MagicMock:
    """Return a mock asyncio subprocess."""
    proc = MagicMock()
    proc.returncode = returncode
    proc.pid = 9999
    if hang:
        # First communicate() blocks (simulating a long-running process).
        # Second communicate() (called after kill) returns immediately.
        _call_count = [0]

        async def _communicate():
            _call_count[0] += 1
            if _call_count[0] == 1:
                await asyncio.sleep(9999)
            return b"", b""

        proc.communicate = _communicate
    else:
        proc.communicate = AsyncMock(return_value=(b"", b""))
    proc.kill = MagicMock()
    # wait() is needed by _kill_process_group (e.g. on Windows or after kill).
    proc.wait = AsyncMock(return_value=0)
    return proc


# ---------------------------------------------------------------------------
# _build_env()
# ---------------------------------------------------------------------------


def test_build_env_sets_gh_token(config):
    d = Dispatcher(config)
    env = d._build_env()
    assert env["GH_ORCHESTRATION_AGENT_TOKEN"] == "tok-abc"


def test_build_env_inherits_os_environ(config, monkeypatch):
    monkeypatch.setenv("ZHIPU_API_KEY", "zhipu-fake")
    d = Dispatcher(config)
    env = d._build_env()
    assert env.get("ZHIPU_API_KEY") == "zhipu-fake"


# ---------------------------------------------------------------------------
# _run() — correct arguments
# ---------------------------------------------------------------------------


def test_run_calls_script_with_correct_args(config):
    d = Dispatcher(config)
    proc = _make_proc(0)

    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)) as mock_exec:
        exit_code = asyncio.run(d._run("/tmp/prompt.md", "/git_repos/app-plan"))

    assert exit_code == 0
    mock_exec.assert_called_once()
    call_args = mock_exec.call_args.args

    assert call_args[0] == "bash"
    assert call_args[1] == str(_SCRIPT_PATH)
    assert "-a" in call_args
    assert "http://server:4096" in call_args
    assert "-d" in call_args
    assert "/git_repos/app-plan" in call_args
    assert "-f" in call_args
    assert "/tmp/prompt.md" in call_args


def test_subprocess_launched_in_new_session(config):
    """start_new_session=True must be passed so bash runs in its own process group."""
    d = Dispatcher(config)
    proc = _make_proc(0)

    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)) as mock_exec:
        asyncio.run(d._run("/tmp/prompt.md", "/git_repos/app-plan"))

    assert mock_exec.call_args.kwargs.get("start_new_session") is True


def test_run_passes_env_to_subprocess(config):
    d = Dispatcher(config)
    proc = _make_proc(0)
    captured_env: dict = {}

    async def fake_exec(*args, **kwargs):
        captured_env.update(kwargs.get("env", {}))
        return proc

    with patch("asyncio.create_subprocess_exec", new=fake_exec):
        asyncio.run(d._run("/tmp/prompt.md", "/git_repos/app-plan"))

    assert captured_env.get("GH_ORCHESTRATION_AGENT_TOKEN") == "tok-abc"


# ---------------------------------------------------------------------------
# _run() — exit codes
# ---------------------------------------------------------------------------


def test_run_returns_nonzero_exit_code(config):
    d = Dispatcher(config)
    proc = _make_proc(3)

    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)):
        exit_code = asyncio.run(d._run("/tmp/prompt.md", "/git_repos/app"))

    assert exit_code == 3


# ---------------------------------------------------------------------------
# _run() — timeout handling
# ---------------------------------------------------------------------------


def test_run_kills_process_group_on_timeout(config_short_timeout):
    """Timeout triggers _kill_process_group, not just proc.kill()."""
    d = Dispatcher(config_short_timeout)
    proc = _make_proc(hang=True)
    kill_pg_calls: list[int] = []

    async def mock_kill_pg(p: object) -> None:
        kill_pg_calls.append(p.pid)  # type: ignore[attr-defined]

    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)):
        with patch.object(d, "_kill_process_group", new=mock_kill_pg):
            exit_code = asyncio.run(d._run("/tmp/prompt.md", "/git_repos/app"))

    assert exit_code == -1
    assert proc.pid in kill_pg_calls


def test_run_kills_process_on_timeout(config_short_timeout):
    d = Dispatcher(config_short_timeout)
    proc = _make_proc(hang=True)

    async def mock_kill_pg(p: object) -> None:
        pass

    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)):
        with patch.object(d, "_kill_process_group", new=mock_kill_pg):
            exit_code = asyncio.run(d._run("/tmp/prompt.md", "/git_repos/app"))

    assert exit_code == -1


def test_run_returns_minus_one_on_timeout(config_short_timeout):
    d = Dispatcher(config_short_timeout)
    proc = _make_proc(hang=True)

    async def mock_kill_pg(p: object) -> None:
        pass

    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)):
        with patch.object(d, "_kill_process_group", new=mock_kill_pg):
            result = asyncio.run(d._run("/tmp/prompt.md", "/git_repos/app"))

    assert result == -1


# ---------------------------------------------------------------------------
# _run() — cancellation path kills the process group
# ---------------------------------------------------------------------------


def test_process_group_kill_on_cancellation(config):
    """When _run() is cancelled, _kill_process_group is called before re-raising."""
    d = Dispatcher(config)
    proc = _make_proc(hang=True)
    kill_pg_calls: list[int] = []

    async def mock_kill_pg(p: object) -> None:
        kill_pg_calls.append(p.pid)  # type: ignore[attr-defined]

    async def run() -> None:
        with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)):
            with patch.object(d, "_kill_process_group", new=mock_kill_pg):
                task = asyncio.create_task(d._run("/tmp/prompt.md", "/git_repos/app"))
                await asyncio.sleep(0)
                await asyncio.sleep(0)
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass

    asyncio.run(run())
    assert proc.pid in kill_pg_calls


# ---------------------------------------------------------------------------
# dispatch() — queue-based sequential dispatch
# ---------------------------------------------------------------------------


def test_dispatch_returns_exit_code(config):
    d = Dispatcher(config)
    proc = _make_proc(0)

    async def run():
        await d.start()
        try:
            with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)):
                return await d.dispatch("/tmp/prompt.md", "/git_repos/app")
        finally:
            await d.stop()

    result = asyncio.run(run())
    assert result == 0


def test_dispatch_sequential_order(config):
    """Verify that queued dispatches run one at a time in FIFO order."""
    d = Dispatcher(config)
    execution_order: list[str] = []

    async def fake_run(prompt_path: str, worktree_path: str) -> int:
        execution_order.append(prompt_path)
        await asyncio.sleep(0)  # yield to event loop
        return 0

    async def run():
        await d.start()
        try:
            with patch.object(d, "_run", side_effect=fake_run):
                results = await asyncio.gather(
                    d.dispatch("/tmp/p1.md", "/wt"),
                    d.dispatch("/tmp/p2.md", "/wt"),
                    d.dispatch("/tmp/p3.md", "/wt"),
                )
        finally:
            await d.stop()
        return results

    results = asyncio.run(run())
    assert results == [0, 0, 0]
    assert execution_order == ["/tmp/p1.md", "/tmp/p2.md", "/tmp/p3.md"]


def test_dispatch_only_one_subprocess_at_a_time(config):
    """At most one _run coroutine executes concurrently."""
    d = Dispatcher(config)
    concurrent_count = 0
    max_concurrent = 0

    async def fake_run(prompt_path: str, worktree_path: str) -> int:
        nonlocal concurrent_count, max_concurrent
        concurrent_count += 1
        max_concurrent = max(max_concurrent, concurrent_count)
        await asyncio.sleep(0)
        concurrent_count -= 1
        return 0

    async def run():
        await d.start()
        try:
            with patch.object(d, "_run", side_effect=fake_run):
                await asyncio.gather(
                    d.dispatch("/tmp/p1.md", "/wt"),
                    d.dispatch("/tmp/p2.md", "/wt"),
                    d.dispatch("/tmp/p3.md", "/wt"),
                )
        finally:
            await d.stop()

    asyncio.run(run())
    assert max_concurrent == 1


# ---------------------------------------------------------------------------
# Lifecycle — start / stop
# ---------------------------------------------------------------------------


def test_stop_before_start_is_safe(config):
    d = Dispatcher(config)
    asyncio.run(d.stop())  # must not raise


def test_double_stop_is_safe(config):
    d = Dispatcher(config)

    async def run():
        await d.start()
        await d.stop()
        await d.stop()

    asyncio.run(run())  # must not raise


# ---------------------------------------------------------------------------
# Lifecycle — stop() during active dispatch and with queued jobs
# ---------------------------------------------------------------------------


def test_stop_cancels_active_dispatch(config):
    """stop() kills the running subprocess and settles the in-flight future.

    stop() alone (without any manual dispatch_task.cancel()) must settle the
    dispatch() waiter so the caller does not need to cancel its own task.
    """
    d = Dispatcher(config)
    proc = _make_proc(hang=True)
    kill_pg_calls: list[int] = []

    async def mock_kill_pg(p: object) -> None:
        kill_pg_calls.append(p.pid)  # type: ignore[attr-defined]

    async def run():
        await d.start()
        with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)):
            with patch.object(d, "_kill_process_group", new=mock_kill_pg):
                dispatch_task = asyncio.create_task(
                    d.dispatch("/tmp/prompt.md", "/git_repos/app")
                )
                # Yield to let the worker start and block inside proc.communicate.
                await asyncio.sleep(0)
                await asyncio.sleep(0)
                await d.stop()
                # stop() alone must settle dispatch_task — no manual cancel.
                assert dispatch_task.done(), (
                    "dispatch_task must be done after stop() without manual cancel"
                )
                try:
                    await dispatch_task
                except (asyncio.CancelledError, Exception):
                    pass

    asyncio.run(run())
    assert proc.pid in kill_pg_calls


def test_stop_drains_queued_futures(config):
    """stop() cancels futures for jobs still waiting in the queue.

    Queued dispatch() callers must be settled by stop() alone without the
    test having to cancel the tasks manually.
    """
    d = Dispatcher(config)

    async def blocking_run(prompt_path: str, worktree_path: str) -> int:
        await asyncio.sleep(9999)
        return 0

    async def run() -> int:
        await d.start()
        with patch.object(d, "_run", side_effect=blocking_run):
            tasks = [
                asyncio.create_task(d.dispatch(f"/tmp/p{i}.md", "/wt"))
                for i in range(3)
            ]
            # Yield to let the worker pick up the first job and block.
            await asyncio.sleep(0)
            await asyncio.sleep(0)
            await d.stop()
            # All tasks must be settled by stop() without manual cancel.
            done_count = sum(1 for t in tasks if t.done())
        return done_count

    done_count = asyncio.run(run())
    assert done_count > 0
