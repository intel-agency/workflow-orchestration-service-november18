"""WorktreeManager — clone/sync per-repo worktrees and resolve worktree slugs."""
from __future__ import annotations

import asyncio
import logging
from pathlib import Path

from src.config import ServiceConfig
from src.models.event import OrchestrationEvent

logger = logging.getLogger(__name__)

# Canonical pipeline labels that map to the shared app-plan worktree
# (Decision 9 — Worktree Slug Convention).  Any other orchestration:* label
# is treated as an ad-hoc/standalone issue and gets an issue-number slug.
_APP_PLAN_LABELS: frozenset[str] = frozenset({
    "orchestration:dispatch",
    "orchestration:plan-approved",
    "orchestration:epic-ready",
    "orchestration:epic-implemented",
    "orchestration:epic-reviewed",
    "orchestration:epic-complete",
    "orchestration:retry-failed",
})


class WorktreeManager:
    """Manage ``git_repos/`` worktrees for multi-repo orchestration dispatch.

    Responsibilities:
    - Resolve the worktree slug (and absolute path) from an
      :class:`OrchestrationEvent`.
    - Clone a repo on first use; sync (fetch + pull) on subsequent calls.
    - Serialise concurrent access to the same app-plan worktree via per-path
      asyncio Locks so that only one git operation runs at a time.
    """

    def __init__(self, config: ServiceConfig) -> None:
        self._config = config
        # Per-worktree asyncio Locks; keyed by absolute worktree path.
        # Dict operations are safe without an extra lock because asyncio is
        # single-threaded — no two coroutines run between await points.
        self._locks: dict[str, asyncio.Lock] = {}

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def resolve(self, event: OrchestrationEvent) -> str:
        """Return the absolute worktree path for *event*.

        Slug convention (Decision 9):

        - Canonical pipeline label → ``<repo-name>-app-plan``
        - All other events         → ``<repo-name>-<issue-number>``
        """
        if event.triggered_label in _APP_PLAN_LABELS:
            slug = f"{event.repo_name}-app-plan"
        else:
            slug = f"{event.repo_name}-{event.issue_number}"
        return str(Path(self._config.git_repos_root).resolve() / slug)

    async def ensure_ready(self, worktree_path: str, repo_slug: str) -> None:
        """Clone the repo if the worktree is absent; sync it if present.

        Acquires the per-worktree asyncio Lock so that concurrent callers
        serialise around the same path (concurrency guard for app-plan
        worktrees, per Decision 8).

        Args:
            worktree_path: Absolute path returned by :meth:`resolve`.
            repo_slug:     Full ``owner/repo`` identifier used for cloning.
        """
        lock = self._get_lock(worktree_path)
        async with lock:
            # Ensure the root git_repos directory exists before cloning.
            Path(self._config.git_repos_root).mkdir(parents=True, exist_ok=True)
            if Path(worktree_path).exists():
                await self._sync(worktree_path)
            else:
                await self._clone(worktree_path, repo_slug)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _get_lock(self, worktree_path: str) -> asyncio.Lock:
        """Return (and lazily create) the asyncio Lock for *worktree_path*."""
        if worktree_path not in self._locks:
            self._locks[worktree_path] = asyncio.Lock()
        return self._locks[worktree_path]

    async def _clone(self, worktree_path: str, repo_slug: str) -> None:
        """Run ``git clone`` into *worktree_path*."""
        token = self._config.github_token
        clone_url = f"https://x-access-token:{token}@github.com/{repo_slug}.git"
        proc = await asyncio.create_subprocess_exec(
            "git", "clone", clone_url, worktree_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(
                f"git clone failed for {repo_slug} → {worktree_path}: "
                f"{stderr.decode(errors='replace').strip()}"
            )
        logger.info("Cloned %s to %s", repo_slug, worktree_path)

    async def _sync(self, worktree_path: str) -> None:
        """Fetch and fast-forward pull; log a warning on failure, do not raise."""
        for cmd in (
            ("git", "fetch", "origin"),
            ("git", "pull", "--ff-only"),
        ):
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=worktree_path,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            _, stderr = await proc.communicate()
            if proc.returncode != 0:
                logger.warning(
                    "git sync step %r failed in %s (exit %d): %s",
                    cmd,
                    worktree_path,
                    proc.returncode,
                    stderr.decode(errors="replace").strip(),
                )
                return
        logger.info("Synced worktree %s", worktree_path)
