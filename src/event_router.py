"""EventRouter — FastAPI webhook handler for GitHub org-wide webhooks."""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from src.config import ServiceConfig
from src.dispatcher import Dispatcher
from src.models.event import OrchestrationEvent
from src.prompt_assembler import PromptAssembler
from src.worktree_manager import WorktreeManager

logger = logging.getLogger(__name__)


def create_app(
    config: ServiceConfig,
    prompt_assembler: PromptAssembler,
    worktree_manager: WorktreeManager,
    dispatcher: Dispatcher,
    lifespan=None,
    sentinel=None,
) -> FastAPI:
    """Build and return a FastAPI application instance.

    Accepts shared components via constructor injection so the app is
    testable (components can be swapped for mocks).
    """
    app = FastAPI(title="workflow-orchestration-service Client", lifespan=lifespan)

    _background_tasks: set[asyncio.Task] = set()

    async def _verify_hmac(request: Request) -> bytes:
        """Read body and verify X-Hub-Signature-256; raise HTTP 401 on failure."""
        body = await request.body()
        sig_header = request.headers.get("X-Hub-Signature-256")
        if not sig_header:
            raise HTTPException(status_code=401, detail="X-Hub-Signature-256 missing")
        expected = "sha256=" + hmac.new(
            config.webhook_secret.encode(), body, hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(expected, sig_header):
            raise HTTPException(status_code=401, detail="Invalid signature")
        return body

    @app.post("/webhooks/github")
    async def handle_github_webhook(request: Request):
        body = await _verify_hmac(request)
        raw_payload_str = body.decode(errors="replace")
        payload: dict = json.loads(body)
        event_type = request.headers.get("X-GitHub-Event", "")

        actor: str = payload.get("sender", {}).get("login", "")
        if actor == "traycerai[bot]":
            return {"status": "ignored", "reason": "bot actor"}

        if event_type == "issues" and payload.get("action") == "labeled":
            label_name: str = (payload.get("label") or {}).get("name", "")
            if not label_name.startswith("orchestration:"):
                return {"status": "ignored", "reason": "non-orchestration label"}

        try:
            event = OrchestrationEvent.from_webhook_payload(
                payload,
                event_type=event_type,
                raw_payload_str=raw_payload_str,
            )
        except ValidationError as exc:
            logger.exception(
                "Validation error building event from webhook payload (repo=%s, event=%s)",
                payload.get("repository", {}).get("full_name"),
                event_type,
            )
            return JSONResponse(status_code=422, content={"status": "error", "reason": str(exc)})
        except Exception as exc:
            logger.exception(
                "Unexpected error building event from webhook payload (repo=%s, event=%s)",
                payload.get("repository", {}).get("full_name"),
                event_type,
            )
            return JSONResponse(status_code=500, content={"status": "error", "reason": str(exc)})

        async def _process_event() -> None:
            worktree_path = worktree_manager.resolve(event)
            await worktree_manager.ensure_ready(worktree_path, event.repo_slug)
            prompt_path = prompt_assembler.assemble(event)
            await dispatcher.dispatch(prompt_path, worktree_path)

        task = asyncio.create_task(_process_event())
        _background_tasks.add(task)

        def _on_done(t: asyncio.Task) -> None:
            _background_tasks.discard(t)
            if not t.cancelled() and t.exception() is not None:
                logger.error(
                    "Background dispatch failed for issue %s in %s: %s",
                    event.issue_number,
                    event.repo_slug,
                    t.exception(),
                )

        task.add_done_callback(_on_done)

        return {"status": "accepted", "issue": event.issue_number}

    @app.get("/health")
    async def health_check():
        server_reachable = False
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                resp = await client.get(config.opencode_server_url)
                server_reachable = resp.status_code < 500
        except Exception:
            server_reachable = False
        return {
            "status": "online",
            "service": "orchestration-client",
            "server_reachable": server_reachable,
            "sentinel_running": sentinel.is_running if sentinel else False,
        }

    return app
