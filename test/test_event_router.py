"""Tests for EventRouter — HMAC verification, event filtering, and dispatch."""
from __future__ import annotations

import hashlib
import hmac
import json
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from starlette.testclient import TestClient

FIXTURES_DIR = Path(__file__).parent / "fixtures"
ISSUES_LABELED = FIXTURES_DIR / "issues-labeled.json"

_SECRET = "test-webhook-secret"


@pytest.fixture
def config(monkeypatch):
    monkeypatch.setenv("GITHUB_ORG", "test-org")
    monkeypatch.setenv("GH_ORCHESTRATION_AGENT_TOKEN", "tok-abc")
    monkeypatch.setenv("WEBHOOK_SECRET", _SECRET)
    monkeypatch.setenv("OPENCODE_SERVER_URL", "http://server:4096")
    from src.config import ServiceConfig
    return ServiceConfig()


def _make_components(config):
    prompt_assembler = MagicMock()
    prompt_assembler.assemble.return_value = "/tmp/prompt.md"

    worktree_manager = MagicMock()
    worktree_manager.resolve.return_value = "/git_repos/test-worktree"
    worktree_manager.ensure_ready = AsyncMock()

    dispatcher = MagicMock()
    dispatcher.dispatch = AsyncMock(return_value=0)

    return prompt_assembler, worktree_manager, dispatcher


def _make_client(config):
    from src.event_router import create_app
    prompt_assembler, worktree_manager, dispatcher = _make_components(config)
    app = create_app(config, prompt_assembler, worktree_manager, dispatcher)
    return TestClient(app), prompt_assembler, worktree_manager, dispatcher


def _sign(body: bytes, secret: str = _SECRET) -> str:
    digest = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return f"sha256={digest}"


def _labeled_payload(label: str = "orchestration:dispatch", actor: str = "nam20485") -> bytes:
    raw = json.loads(ISSUES_LABELED.read_text(encoding="utf-8"))
    raw["label"]["name"] = label
    raw["issue"]["labels"] = [{"name": label}]
    raw["sender"]["login"] = actor
    return json.dumps(raw).encode()


# ---------------------------------------------------------------------------
# HMAC verification
# ---------------------------------------------------------------------------


def test_valid_hmac_orchestration_label_returns_200(config):
    client, _, _, _ = _make_client(config)
    body = _labeled_payload()
    with patch("asyncio.create_task"):
        resp = client.post(
            "/webhooks/github",
            content=body,
            headers={
                "Content-Type": "application/json",
                "X-GitHub-Event": "issues",
                "X-Hub-Signature-256": _sign(body),
            },
        )
    assert resp.status_code == 200
    assert resp.json()["status"] == "accepted"


def test_invalid_hmac_returns_401(config):
    client, _, _, _ = _make_client(config)
    body = _labeled_payload()
    resp = client.post(
        "/webhooks/github",
        content=body,
        headers={
            "Content-Type": "application/json",
            "X-GitHub-Event": "issues",
            "X-Hub-Signature-256": "sha256=badhash",
        },
    )
    assert resp.status_code == 401


def test_missing_hmac_header_returns_401(config):
    client, _, _, _ = _make_client(config)
    body = _labeled_payload()
    resp = client.post(
        "/webhooks/github",
        content=body,
        headers={
            "Content-Type": "application/json",
            "X-GitHub-Event": "issues",
        },
    )
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Event filtering
# ---------------------------------------------------------------------------


def test_non_orchestration_label_returns_ignored(config):
    client, _, _, _ = _make_client(config)
    body = _labeled_payload(label="bug")
    resp = client.post(
        "/webhooks/github",
        content=body,
        headers={
            "Content-Type": "application/json",
            "X-GitHub-Event": "issues",
            "X-Hub-Signature-256": _sign(body),
        },
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ignored"
    assert data["reason"] == "non-orchestration label"


def test_bot_actor_returns_ignored(config):
    client, _, _, _ = _make_client(config)
    body = _labeled_payload(actor="traycerai[bot]")
    resp = client.post(
        "/webhooks/github",
        content=body,
        headers={
            "Content-Type": "application/json",
            "X-GitHub-Event": "issues",
            "X-Hub-Signature-256": _sign(body),
        },
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ignored"
    assert data["reason"] == "bot actor"


# ---------------------------------------------------------------------------
# Health endpoint
# ---------------------------------------------------------------------------


def test_health_endpoint_returns_json(config):
    client, _, _, _ = _make_client(config)
    with patch("httpx.AsyncClient") as mock_client_cls:
        mock_resp = MagicMock()
        mock_resp.status_code = 200
        mock_aclient = AsyncMock()
        mock_aclient.__aenter__ = AsyncMock(return_value=mock_aclient)
        mock_aclient.__aexit__ = AsyncMock(return_value=False)
        mock_aclient.get = AsyncMock(return_value=mock_resp)
        mock_client_cls.return_value = mock_aclient
        resp = client.get("/health")
    assert resp.status_code == 200
    data = resp.json()
    assert "status" in data
    assert data["status"] == "online"
    assert "server_reachable" in data


# ---------------------------------------------------------------------------
# OrchestrationEvent construction
# ---------------------------------------------------------------------------


def test_event_construction_uses_from_webhook_payload(config):
    from src.event_router import create_app
    from src.models.event import OrchestrationEvent

    prompt_assembler, worktree_manager, dispatcher = _make_components(config)
    app = create_app(config, prompt_assembler, worktree_manager, dispatcher)
    client = TestClient(app)

    body = _labeled_payload()

    with patch.object(
        OrchestrationEvent,
        "from_webhook_payload",
        wraps=OrchestrationEvent.from_webhook_payload,
    ) as mock_factory:
        with patch("asyncio.create_task"):
            resp = client.post(
                "/webhooks/github",
                content=body,
                headers={
                    "Content-Type": "application/json",
                    "X-GitHub-Event": "issues",
                    "X-Hub-Signature-256": _sign(body),
                },
            )

    assert resp.status_code == 200
    mock_factory.assert_called_once()
    call_kwargs = mock_factory.call_args
    assert call_kwargs.kwargs.get("event_type") == "issues"
    assert "raw_payload_str" in call_kwargs.kwargs
