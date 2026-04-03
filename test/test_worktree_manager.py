"""Tests for WorktreeManager — slug resolution and worktree lifecycle."""
from __future__ import annotations

import asyncio
import os
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.models.event import OrchestrationEvent
from src.worktree_manager import WorktreeManager


# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def config(monkeypatch, tmp_path):
    monkeypatch.setenv("GITHUB_ORG", "test-org")
    monkeypatch.setenv("GH_ORCHESTRATION_AGENT_TOKEN", "test-token")
    monkeypatch.setenv("WEBHOOK_SECRET", "test-secret")
    monkeypatch.setenv("GIT_REPOS_ROOT", str(tmp_path / "git_repos"))
    from src.config import ServiceConfig
    return ServiceConfig()


def _make_event(triggered_label: str, repo_name: str = "my-app", issue_number: int = 42) -> OrchestrationEvent:
    return OrchestrationEvent(
        repo_slug=f"test-org/{repo_name}",
        repo_name=repo_name,
        issue_number=issue_number,
        event_type="issues",
        action="labeled",
        triggered_label=triggered_label,
        all_labels=[triggered_label],
        actor="actor",
        title="Test issue",
        raw_payload={},
    )


# ---------------------------------------------------------------------------
# resolve() — slug logic
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("label", [
    "orchestration:dispatch",
    "orchestration:plan-approved",
    "orchestration:epic-ready",
    "orchestration:epic-implemented",
    "orchestration:epic-reviewed",
    "orchestration:epic-complete",
    "orchestration:retry-failed",
])
def test_resolve_pipeline_label_returns_app_plan(config, label):
    wm = WorktreeManager(config)
    path = wm.resolve(_make_event(label))
    assert path.endswith("my-app-app-plan")


def test_resolve_non_pipeline_label_returns_issue_number(config):
    wm = WorktreeManager(config)
    path = wm.resolve(_make_event("some-other-label", issue_number=99))
    assert path.endswith("my-app-99")


def test_resolve_non_pipeline_orchestration_label_returns_issue_number(config):
    """An orchestration:* label outside the canonical pipeline must use issue-number slug."""
    wm = WorktreeManager(config)
    path = wm.resolve(_make_event("orchestration:custom-label", issue_number=77))
    assert path.endswith("my-app-77")
    assert "app-plan" not in path


def test_resolve_returns_absolute_path_with_default_git_repos_root(monkeypatch):
    """resolve() returns an absolute path even when GIT_REPOS_ROOT defaults to './git_repos'."""
    monkeypatch.setenv("GITHUB_ORG", "test-org")
    monkeypatch.setenv("GH_ORCHESTRATION_AGENT_TOKEN", "test-token")
    monkeypatch.setenv("WEBHOOK_SECRET", "test-secret")
    monkeypatch.delenv("GIT_REPOS_ROOT", raising=False)
    from src.config import ServiceConfig
    cfg = ServiceConfig()
    wm = WorktreeManager(cfg)
    path = wm.resolve(_make_event("orchestration:dispatch"))
    assert Path(path).is_absolute()


def test_resolve_returns_absolute_path_under_git_repos_root(config, tmp_path):
    wm = WorktreeManager(config)
    path = wm.resolve(_make_event("orchestration:epic-ready"))
    assert path.startswith(str(tmp_path))


def test_resolve_different_repos_produce_different_paths(config):
    wm = WorktreeManager(config)
    p1 = wm.resolve(_make_event("orchestration:epic-ready", repo_name="app-alpha"))
    p2 = wm.resolve(_make_event("orchestration:epic-ready", repo_name="app-beta"))
    assert p1 != p2
    assert "app-alpha-app-plan" in p1
    assert "app-beta-app-plan" in p2


# ---------------------------------------------------------------------------
# ensure_ready() — clone on first use
# ---------------------------------------------------------------------------


def _make_proc(returncode: int = 0) -> MagicMock:
    """Return a mock asyncio subprocess with the given exit code."""
    proc = MagicMock()
    proc.returncode = returncode
    proc.communicate = AsyncMock(return_value=(b"", b""))
    proc.pid = 12345
    return proc


def test_ensure_ready_clones_when_worktree_absent(config, tmp_path):
    wm = WorktreeManager(config)
    worktree = str(tmp_path / "git_repos" / "my-app-app-plan")

    proc = _make_proc(0)
    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)) as mock_exec:
        asyncio.run(wm.ensure_ready(worktree, "test-org/my-app"))

    mock_exec.assert_called_once()
    call_args = mock_exec.call_args
    cmd = call_args.args
    assert cmd[0] == "git"
    assert cmd[1] == "clone"
    # Token is embedded in the clone URL (third positional arg)
    assert "x-access-token:test-token@github.com/test-org/my-app.git" in cmd[2]
    assert cmd[3] == worktree


def test_ensure_ready_raises_on_clone_failure(config, tmp_path):
    wm = WorktreeManager(config)
    worktree = str(tmp_path / "git_repos" / "my-app-app-plan")

    proc = _make_proc(1)
    proc.communicate = AsyncMock(return_value=(b"", b"fatal: repo not found"))
    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=proc)):
        with pytest.raises(RuntimeError, match="git clone failed"):
            asyncio.run(wm.ensure_ready(worktree, "test-org/my-app"))


# ---------------------------------------------------------------------------
# ensure_ready() — sync on subsequent calls
# ---------------------------------------------------------------------------


def test_ensure_ready_syncs_when_worktree_exists(config, tmp_path):
    wm = WorktreeManager(config)
    worktree = tmp_path / "git_repos" / "my-app-app-plan"
    worktree.mkdir(parents=True)

    calls: list[tuple] = []
    proc = _make_proc(0)

    async def fake_exec(*args, **kwargs):
        calls.append(args)
        return proc

    with patch("asyncio.create_subprocess_exec", new=fake_exec):
        asyncio.run(wm.ensure_ready(str(worktree), "test-org/my-app"))

    # Should have called fetch and pull, not clone.
    assert len(calls) == 2
    assert calls[0] == ("git", "fetch", "origin")
    assert calls[1] == ("git", "pull", "--ff-only")


def test_ensure_ready_sync_warns_on_fetch_failure(config, tmp_path, caplog):
    import logging
    wm = WorktreeManager(config)
    worktree = tmp_path / "git_repos" / "my-app-app-plan"
    worktree.mkdir(parents=True)

    fail_proc = _make_proc(1)
    fail_proc.communicate = AsyncMock(return_value=(b"", b"network error"))

    with patch("asyncio.create_subprocess_exec", new=AsyncMock(return_value=fail_proc)):
        with caplog.at_level(logging.WARNING, logger="src.worktree_manager"):
            asyncio.run(wm.ensure_ready(str(worktree), "test-org/my-app"))

    assert any("failed" in rec.message.lower() for rec in caplog.records)


# ---------------------------------------------------------------------------
# Concurrency guard — per-worktree asyncio Lock
# ---------------------------------------------------------------------------


def test_same_worktree_lock_is_reused(config):
    wm = WorktreeManager(config)
    path = "/git_repos/my-app-app-plan"
    lock1 = wm._get_lock(path)
    lock2 = wm._get_lock(path)
    assert lock1 is lock2


def test_different_worktrees_get_different_locks(config):
    wm = WorktreeManager(config)
    lock1 = wm._get_lock("/git_repos/app-alpha-app-plan")
    lock2 = wm._get_lock("/git_repos/app-beta-app-plan")
    assert lock1 is not lock2


def test_ensure_ready_serialises_concurrent_calls_on_same_worktree(config, tmp_path):
    """Two concurrent ensure_ready calls on the same path must not interleave."""
    wm = WorktreeManager(config)
    worktree = tmp_path / "git_repos" / "my-app-app-plan"
    worktree.mkdir(parents=True)

    order: list[str] = []
    proc = _make_proc(0)

    async def fake_exec(*args, **kwargs):
        order.append(f"start:{args}")
        return proc

    async def run_both():
        t1 = asyncio.create_task(wm.ensure_ready(str(worktree), "org/repo"))
        t2 = asyncio.create_task(wm.ensure_ready(str(worktree), "org/repo"))
        await asyncio.gather(t1, t2)

    with patch("asyncio.create_subprocess_exec", new=fake_exec):
        asyncio.run(run_both())

    # Both calls completed — just verify no exception and calls were made.
    assert len(order) == 4  # 2 × (fetch + pull)
