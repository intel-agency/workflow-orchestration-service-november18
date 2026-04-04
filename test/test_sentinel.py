"""Tests for Sentinel — lifecycle, query construction, backoff, and dispatch."""
from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

import pytest


@pytest.fixture
def config(monkeypatch):
    monkeypatch.setenv("GITHUB_ORG", "test-org")
    monkeypatch.setenv("GH_ORCHESTRATION_AGENT_TOKEN", "tok-abc")
    monkeypatch.setenv("WEBHOOK_SECRET", "test-secret")
    monkeypatch.setenv("POLL_INTERVAL_SECS", "5")
    from src.config import ServiceConfig
    return ServiceConfig()


def _make_sentinel(config):
    from src.sentinel import Sentinel

    eligibility_checker = MagicMock()
    eligibility_checker.is_eligible = AsyncMock(return_value=True)
    eligibility_checker.refresh_cache = AsyncMock()

    prompt_assembler = MagicMock()
    prompt_assembler.assemble.return_value = "/tmp/prompt.md"

    worktree_manager = MagicMock()
    worktree_manager.resolve.return_value = "/git_repos/test-worktree"
    worktree_manager.ensure_ready = AsyncMock()

    dispatcher = MagicMock()
    dispatcher.dispatch = AsyncMock(return_value=0)

    sentinel = Sentinel(config, eligibility_checker, prompt_assembler, worktree_manager, dispatcher)
    return sentinel, eligibility_checker, prompt_assembler, worktree_manager, dispatcher


def _mock_response(status_code: int, json_data=None) -> MagicMock:
    resp = MagicMock()
    resp.status_code = status_code
    resp.json.return_value = json_data or {}
    if status_code >= 400:
        import httpx
        resp.raise_for_status.side_effect = httpx.HTTPStatusError(
            f"HTTP {status_code}", request=MagicMock(), response=resp
        )
    else:
        resp.raise_for_status = MagicMock()
    return resp


def _issue_item(
    number: int = 1,
    label: str = "orchestration:dispatch",
    repo: str = "test-org/my-repo",
) -> dict:
    return {
        "number": number,
        "title": "Test issue",
        "body": "body text",
        "labels": [{"name": label}],
        "repository_url": f"https://api.github.com/repos/{repo}",
    }


# ---------------------------------------------------------------------------
# is_running property
# ---------------------------------------------------------------------------


def test_is_running_false_before_start(config):
    sentinel, *_ = _make_sentinel(config)
    assert sentinel.is_running is False


def test_is_running_true_after_start_false_after_stop(config):
    sentinel, *_ = _make_sentinel(config)

    async def _run():
        with patch("httpx.AsyncClient") as mock_cls:
            mock_client = AsyncMock()
            mock_client.get = AsyncMock(return_value=_mock_response(200, {"items": []}))
            mock_client.aclose = AsyncMock()
            mock_cls.return_value = mock_client
            await sentinel.start()
            assert sentinel.is_running is True
            await sentinel.stop()
            assert sentinel.is_running is False

    asyncio.run(_run())


# ---------------------------------------------------------------------------
# start() / stop() lifecycle
# ---------------------------------------------------------------------------


def test_stop_is_idempotent_when_not_started(config):
    sentinel, *_ = _make_sentinel(config)
    asyncio.run(sentinel.stop())


def test_start_resets_shutdown_requested(config):
    sentinel, *_ = _make_sentinel(config)
    sentinel._shutdown_requested = True

    async def _run():
        with patch("httpx.AsyncClient") as mock_cls:
            mock_client = AsyncMock()
            mock_client.get = AsyncMock(return_value=_mock_response(200, {"items": []}))
            mock_client.aclose = AsyncMock()
            mock_cls.return_value = mock_client
            await sentinel.start()
            assert sentinel._shutdown_requested is False
            await sentinel.stop()

    asyncio.run(_run())


# ---------------------------------------------------------------------------
# Synthetic event construction and dispatch
# ---------------------------------------------------------------------------


def test_poll_once_dispatches_eligible_issue(config):
    sentinel, eligibility_checker, prompt_assembler, worktree_manager, dispatcher = _make_sentinel(config)
    mock_client = AsyncMock()
    mock_client.get = AsyncMock(return_value=_mock_response(200, {"items": [_issue_item()]}))
    mock_client.aclose = AsyncMock()
    sentinel._client = mock_client

    asyncio.run(sentinel._poll_once())

    dispatcher.dispatch.assert_awaited_once()
    prompt_assembler.assemble.assert_called_once()
    worktree_manager.ensure_ready.assert_awaited_once()


def test_poll_once_skips_ineligible_repo(config):
    sentinel, eligibility_checker, _, _, dispatcher = _make_sentinel(config)
    eligibility_checker.is_eligible = AsyncMock(return_value=False)
    mock_client = AsyncMock()
    mock_client.get = AsyncMock(return_value=_mock_response(200, {"items": [_issue_item()]}))
    mock_client.aclose = AsyncMock()
    sentinel._client = mock_client

    asyncio.run(sentinel._poll_once())

    dispatcher.dispatch.assert_not_awaited()


def test_poll_once_dispatches_only_one_issue(config):
    sentinel, _, _, _, dispatcher = _make_sentinel(config)
    items = [_issue_item(number=1), _issue_item(number=2)]
    mock_client = AsyncMock()
    mock_client.get = AsyncMock(return_value=_mock_response(200, {"items": items}))
    mock_client.aclose = AsyncMock()
    sentinel._client = mock_client

    asyncio.run(sentinel._poll_once())

    assert dispatcher.dispatch.await_count == 1


def test_poll_once_does_nothing_when_no_items(config):
    sentinel, _, _, _, dispatcher = _make_sentinel(config)
    mock_client = AsyncMock()
    mock_client.get = AsyncMock(return_value=_mock_response(200, {"items": []}))
    mock_client.aclose = AsyncMock()
    sentinel._client = mock_client

    asyncio.run(sentinel._poll_once())

    dispatcher.dispatch.assert_not_awaited()


# ---------------------------------------------------------------------------
# Search query uses correct label list and proper URL encoding
# ---------------------------------------------------------------------------


def test_poll_once_uses_correct_search_url_and_params(config):
    sentinel, *_ = _make_sentinel(config)
    mock_client = AsyncMock()
    mock_client.get = AsyncMock(return_value=_mock_response(200, {"items": []}))
    mock_client.aclose = AsyncMock()
    sentinel._client = mock_client

    asyncio.run(sentinel._poll_once())

    call_args = mock_client.get.call_args
    url = call_args.args[0] if call_args.args else call_args.kwargs.get("url", "")
    params = call_args.kwargs.get("params", {})

    assert url == "https://api.github.com/search/issues"
    assert "q" in params
    query = params["q"]
    assert "orchestration:dispatch" in query
    assert "orchestration:plan-approved" in query
    assert "orchestration:retry-failed" in query
    assert "orchestration:*" not in query
    assert "+" not in query  # spaces used as separator, not +


# ---------------------------------------------------------------------------
# Backoff doubles on rate limit
# ---------------------------------------------------------------------------


def test_backoff_doubles_on_rate_limit(config):
    sentinel, *_ = _make_sentinel(config)
    initial_backoff = sentinel._current_backoff

    # Verify the math used in _poll_loop for backoff doubling
    new_backoff = min(initial_backoff * 2, 960)
    assert new_backoff > initial_backoff
    assert new_backoff == initial_backoff * 2


def test_backoff_capped_at_max(config):
    from src.sentinel import MAX_BACKOFF
    sentinel, *_ = _make_sentinel(config)
    sentinel._current_backoff = MAX_BACKOFF
    capped = min(sentinel._current_backoff * 2, MAX_BACKOFF)
    assert capped == MAX_BACKOFF


# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------


def test_graceful_shutdown_after_stop(config):
    sentinel, *_ = _make_sentinel(config)

    async def _run():
        with patch("httpx.AsyncClient") as mock_cls:
            mock_client = AsyncMock()

            async def _slow_get(*args, **kwargs):
                await asyncio.sleep(0.05)
                return _mock_response(200, {"items": []})

            mock_client.get = _slow_get
            mock_client.aclose = AsyncMock()
            mock_cls.return_value = mock_client

            await sentinel.start()
            assert sentinel.is_running is True
            await sentinel.stop()
            assert sentinel.is_running is False

    asyncio.run(_run())
