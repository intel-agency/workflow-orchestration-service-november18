"""Sentinel — polls GitHub for eligible issues and dispatches them through the pipeline."""
from __future__ import annotations

import asyncio
import logging
import random
from typing import TYPE_CHECKING

import httpx

from src.config import ServiceConfig
from src.models.event import OrchestrationEvent

if TYPE_CHECKING:
    from src.dispatcher import Dispatcher
    from src.eligibility_checker import EligibilityChecker
    from src.prompt_assembler import PromptAssembler
    from src.worktree_manager import WorktreeManager

logger = logging.getLogger(__name__)

MAX_BACKOFF = 960  # 16 minutes

_LABEL_PRIORITY: tuple[str, ...] = (
    "orchestration:retry-failed",
    "orchestration:epic-complete",
    "orchestration:epic-reviewed",
    "orchestration:epic-implemented",
    "orchestration:epic-ready",
    "orchestration:plan-approved",
    "orchestration:dispatch",
)


class Sentinel:
    """Polls the GitHub Search API for eligible orchestration issues and dispatches them."""

    def __init__(
        self,
        config: ServiceConfig,
        eligibility_checker: "EligibilityChecker",
        prompt_assembler: "PromptAssembler",
        worktree_manager: "WorktreeManager",
        dispatcher: "Dispatcher",
    ) -> None:
        self._config = config
        self._eligibility_checker = eligibility_checker
        self._prompt_assembler = prompt_assembler
        self._worktree_manager = worktree_manager
        self._dispatcher = dispatcher

        self._shutdown_requested: bool = False
        self._worker_task: asyncio.Task | None = None
        self._poll_cycle: int = 0
        self._current_backoff: float = float(config.poll_interval_secs)
        self._client: httpx.AsyncClient | None = None

    @property
    def is_running(self) -> bool:
        """Return True if the polling task is active."""
        return self._worker_task is not None and not self._worker_task.done()

    async def start(self) -> None:
        """Spawn the polling task."""
        self._shutdown_requested = False
        self._worker_task = asyncio.create_task(self._poll_loop(), name="sentinel-poll-loop")
        logger.info("Sentinel polling task started (interval: %ds)", self._config.poll_interval_secs)

    async def stop(self) -> None:
        """Request shutdown and wait for the polling task to finish."""
        self._shutdown_requested = True
        if self._worker_task and not self._worker_task.done():
            self._worker_task.cancel()
            try:
                await self._worker_task
            except (asyncio.CancelledError, Exception):
                pass
        logger.info("Sentinel stopped")

    async def close(self) -> None:
        """Close the internal httpx client."""
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    # ------------------------------------------------------------------
    # Polling loop
    # ------------------------------------------------------------------

    async def _poll_loop(self) -> None:
        """Main polling loop — runs until shutdown is requested."""
        self._client = httpx.AsyncClient(
            headers={
                "Authorization": f"token {self._config.github_token}",
                "Accept": "application/vnd.github+json",
            },
            timeout=15.0,
        )
        logger.info("Sentinel poll loop entered")
        try:
            while not self._shutdown_requested:
                try:
                    await self._poll_once()
                    self._current_backoff = float(self._config.poll_interval_secs)
                except httpx.HTTPStatusError as exc:
                    status = exc.response.status_code
                    if status in (403, 429):
                        jitter = random.uniform(0, self._current_backoff * 0.1)
                        wait = min(self._current_backoff + jitter, MAX_BACKOFF)
                        logger.warning(
                            "Rate limited (%d) — backing off %.0fs", status, wait
                        )
                        self._current_backoff = min(self._current_backoff * 2, MAX_BACKOFF)
                        await asyncio.sleep(wait)
                        continue
                    else:
                        logger.error("GitHub API error during poll: %s", exc)
                except asyncio.CancelledError:
                    logger.info("Sentinel poll loop cancelled — shutting down")
                    break
                except Exception:
                    logger.exception("Unexpected error in poll cycle")

                self._poll_cycle += 1
                if self._poll_cycle % 10 == 0:
                    try:
                        await self._eligibility_checker.refresh_cache()
                    except Exception:
                        logger.exception("Eligibility cache refresh failed")

                if self._shutdown_requested:
                    break

                await asyncio.sleep(self._current_backoff)
        finally:
            if self._client is not None:
                await self._client.aclose()
                self._client = None
        logger.info("Sentinel poll loop exited")

    async def _poll_once(self) -> None:
        """Execute one poll cycle — search for eligible issues and dispatch one."""
        if self._client is None:
            return

        query = (
            f"org:{self._config.github_org} "
            "label:orchestration:dispatch,orchestration:plan-approved,"
            "orchestration:epic-ready,orchestration:epic-implemented,"
            "orchestration:epic-reviewed,orchestration:epic-complete,"
            "orchestration:retry-failed "
            "is:open is:issue"
        )
        url = "https://api.github.com/search/issues"
        resp = await self._client.get(url, params={"q": query})
        resp.raise_for_status()

        items = resp.json().get("items", [])
        if not items:
            return

        # Process one issue per poll cycle (Decision 8)
        for item in items:
            repo_url: str = item.get("repository_url", "")
            parts = repo_url.rstrip("/").rsplit("/", 2)
            if len(parts) < 3:
                continue
            repo_slug = f"{parts[-2]}/{parts[-1]}"

            if not await self._eligibility_checker.is_eligible(repo_slug):
                continue

            labels_raw: list = item.get("labels", [])
            all_labels: list[str] = [
                lbl["name"] if isinstance(lbl, dict) else str(lbl)
                for lbl in labels_raw
            ]
            triggered_label = ""
            for priority_label in _LABEL_PRIORITY:
                if priority_label in all_labels:
                    triggered_label = priority_label
                    break

            payload = {
                "action": "labeled",
                "label": {"name": triggered_label},
                "issue": {
                    "number": item.get("number", 0),
                    "title": item.get("title", ""),
                    "body": item.get("body", ""),
                    "labels": labels_raw,
                },
                "repository": {"full_name": repo_slug},
                "sender": {"login": "sentinel-bot"},
            }

            try:
                event = OrchestrationEvent.from_webhook_payload(
                    payload, event_type="issues"
                )
            except Exception:
                logger.exception(
                    "Failed to construct OrchestrationEvent for issue #%d in %s",
                    item.get("number"),
                    repo_slug,
                )
                continue

            logger.info(
                "Sentinel dispatching issue #%d in %s (label: %s)",
                event.issue_number,
                event.repo_slug,
                triggered_label,
            )
            try:
                worktree_path = self._worktree_manager.resolve(event)
                await self._worktree_manager.ensure_ready(worktree_path, event.repo_slug)
                prompt_path = self._prompt_assembler.assemble(event)
                await self._dispatcher.dispatch(prompt_path, worktree_path)
            except Exception:
                logger.exception(
                    "Dispatch failed for issue #%d in %s",
                    event.issue_number,
                    event.repo_slug,
                )

            # One issue per poll cycle
            return
