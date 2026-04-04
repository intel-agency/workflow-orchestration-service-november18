"""Tests for EligibilityChecker — naming patterns, marker file, template origin, and cache."""
from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, MagicMock

import pytest


@pytest.fixture
def config(monkeypatch):
    monkeypatch.setenv("GITHUB_ORG", "test-org")
    monkeypatch.setenv("GH_ORCHESTRATION_AGENT_TOKEN", "tok-abc")
    monkeypatch.setenv("WEBHOOK_SECRET", "test-secret")
    from src.config import ServiceConfig
    return ServiceConfig()


@pytest.fixture
def config_with_pattern(monkeypatch):
    monkeypatch.setenv("GITHUB_ORG", "test-org")
    monkeypatch.setenv("GH_ORCHESTRATION_AGENT_TOKEN", "tok-abc")
    monkeypatch.setenv("WEBHOOK_SECRET", "test-secret")
    monkeypatch.setenv("ELIGIBLE_REPO_PATTERNS", "workflow-*,orchestration-*")
    from src.config import ServiceConfig
    return ServiceConfig()


def _make_checker(config):
    from src.eligibility_checker import EligibilityChecker
    checker = EligibilityChecker(config)
    checker._client = AsyncMock()
    return checker


def _mock_response(status_code: int, json_data=None) -> MagicMock:
    resp = MagicMock()
    resp.status_code = status_code
    resp.json.return_value = json_data or {}
    if status_code >= 400:
        resp.raise_for_status.side_effect = Exception(f"HTTP {status_code}")
    else:
        resp.raise_for_status = MagicMock()
    return resp


# ---------------------------------------------------------------------------
# Naming pattern matching
# ---------------------------------------------------------------------------


def test_matches_name_pattern_returns_eligible(config_with_pattern):
    checker = _make_checker(config_with_pattern)
    assert checker._matches_name_pattern("workflow-my-project") is True
    assert checker._matches_name_pattern("orchestration-core") is True


def test_no_pattern_match_returns_false(config_with_pattern):
    checker = _make_checker(config_with_pattern)
    assert checker._matches_name_pattern("random-repo") is False


def test_empty_patterns_returns_false(config):
    checker = _make_checker(config)
    assert checker._matches_name_pattern("workflow-anything") is False


# ---------------------------------------------------------------------------
# Marker file presence
# ---------------------------------------------------------------------------


def test_has_marker_file_returns_true_on_200(config):
    checker = _make_checker(config)
    checker._client.get = AsyncMock(return_value=_mock_response(200))
    result = asyncio.run(checker._has_marker_file("test-org/some-repo"))
    assert result is True


def test_has_marker_file_returns_false_on_404(config):
    checker = _make_checker(config)
    checker._client.get = AsyncMock(return_value=_mock_response(404))
    result = asyncio.run(checker._has_marker_file("test-org/some-repo"))
    assert result is False


def test_has_marker_file_returns_false_on_exception(config):
    checker = _make_checker(config)
    checker._client.get = AsyncMock(side_effect=Exception("network error"))
    result = asyncio.run(checker._has_marker_file("test-org/some-repo"))
    assert result is False


# ---------------------------------------------------------------------------
# Template origin check
# ---------------------------------------------------------------------------


def test_from_template_repo_returns_true_on_match(config):
    checker = _make_checker(config)
    resp_data = {
        "template_repository": {"full_name": "test-org/workflow-orchestration-service-november18"}
    }
    checker._client.get = AsyncMock(return_value=_mock_response(200, resp_data))
    result = asyncio.run(checker._from_template_repo("test-org/my-project"))
    assert result is True


def test_from_template_repo_returns_false_on_wrong_name(config):
    checker = _make_checker(config)
    resp_data = {
        "template_repository": {"full_name": "test-org/some-other-template"}
    }
    checker._client.get = AsyncMock(return_value=_mock_response(200, resp_data))
    result = asyncio.run(checker._from_template_repo("test-org/my-project"))
    assert result is False


def test_from_template_repo_returns_false_when_no_template(config):
    checker = _make_checker(config)
    checker._client.get = AsyncMock(return_value=_mock_response(200, {}))
    result = asyncio.run(checker._from_template_repo("test-org/my-project"))
    assert result is False


def test_from_template_repo_uses_config_field(monkeypatch):
    monkeypatch.setenv("GITHUB_ORG", "test-org")
    monkeypatch.setenv("GH_ORCHESTRATION_AGENT_TOKEN", "tok-abc")
    monkeypatch.setenv("WEBHOOK_SECRET", "test-secret")
    monkeypatch.setenv("ORCHESTRATION_TEMPLATE_REPO", "custom-template-repo")
    from src.config import ServiceConfig
    cfg = ServiceConfig()
    checker = _make_checker(cfg)
    resp_data = {"template_repository": {"full_name": "test-org/custom-template-repo"}}
    checker._client.get = AsyncMock(return_value=_mock_response(200, resp_data))
    result = asyncio.run(checker._from_template_repo("test-org/my-project"))
    assert result is True


# ---------------------------------------------------------------------------
# Cache hit behavior
# ---------------------------------------------------------------------------


def test_is_eligible_returns_cached_result(config):
    checker = _make_checker(config)
    checker._cache["test-org/cached-repo"] = True
    checker._client.get = AsyncMock(side_effect=AssertionError("should not call API on cache hit"))
    result = asyncio.run(checker.is_eligible("test-org/cached-repo"))
    assert result is True


def test_is_eligible_caches_on_miss(config):
    checker = _make_checker(config)
    checker._client.get = AsyncMock(return_value=_mock_response(404))
    result = asyncio.run(checker.is_eligible("test-org/uncached-repo"))
    assert result is False
    assert "test-org/uncached-repo" in checker._cache
    assert checker._cache["test-org/uncached-repo"] is False


# ---------------------------------------------------------------------------
# Cache refresh — only replaces on success
# ---------------------------------------------------------------------------


def test_refresh_cache_replaces_on_success(config):
    checker = _make_checker(config)
    checker._cache = {"test-org/old-repo": True}

    repos_page = [{"full_name": "test-org/new-repo"}]
    call_count = [0]

    async def _side_effect(url, **kwargs):
        call_count[0] += 1
        if "repos" in url:
            # First call: return one page, second call: empty (end of pagination)
            return _mock_response(200, repos_page if call_count[0] == 1 else [])
        return _mock_response(404)

    checker._client.get = _side_effect
    asyncio.run(checker.refresh_cache())
    assert "test-org/new-repo" in checker._cache
    assert "test-org/old-repo" not in checker._cache


def test_refresh_cache_preserves_old_cache_on_error(config):
    checker = _make_checker(config)
    checker._cache = {"test-org/existing-repo": True}
    checker._client.get = AsyncMock(side_effect=Exception("network error"))
    asyncio.run(checker.refresh_cache())
    assert checker._cache == {"test-org/existing-repo": True}
