"""EligibilityChecker — determines whether a GitHub repo should be polled by Sentinel."""
from __future__ import annotations

import fnmatch
import logging

import httpx

from src.config import ServiceConfig

logger = logging.getLogger(__name__)

_AUTH_HEADERS = {
    "Accept": "application/vnd.github+json",
}


class EligibilityChecker:
    """Checks and caches whether repos are eligible for orchestration polling."""

    def __init__(self, config: ServiceConfig) -> None:
        self._config = config
        self._cache: dict[str, bool] = {}
        self._client = httpx.AsyncClient(
            headers={
                **_AUTH_HEADERS,
                "Authorization": f"token {config.github_token}",
            },
            timeout=10.0,
        )

    async def is_eligible(self, repo_slug: str) -> bool:
        """Return True if the repo is eligible for orchestration dispatch.

        Checks the in-memory cache first; performs on-demand GitHub API checks
        on a cache miss and caches the result.
        """
        if repo_slug in self._cache:
            return self._cache[repo_slug]

        eligible = await self._check_eligibility(repo_slug)
        self._cache[repo_slug] = eligible
        return eligible

    async def refresh_cache(self) -> None:
        """Scan all org repos and rebuild the eligibility cache.

        Called every 10 poll cycles by Sentinel.
        """
        logger.info("Refreshing eligibility cache for org: %s", self._config.github_org)
        new_cache: dict[str, bool] = {}
        page = 1
        success = False
        while True:
            url = f"https://api.github.com/orgs/{self._config.github_org}/repos"
            try:
                resp = await self._client.get(url, params={"per_page": 100, "page": page})
                resp.raise_for_status()
            except Exception:
                logger.exception("Failed to list org repos during cache refresh (page %d)", page)
                break

            repos = resp.json()
            if not repos:
                success = True
                break

            for repo in repos:
                slug = repo.get("full_name", "")
                if slug:
                    new_cache[slug] = await self._check_eligibility(slug)

            if len(repos) < 100:
                success = True
                break
            page += 1

        if success:
            self._cache = new_cache
            logger.info("Eligibility cache refreshed: %d repos evaluated", len(new_cache))
        else:
            logger.warning(
                "Eligibility cache refresh failed — retaining %d cached entries", len(self._cache)
            )

    async def close(self) -> None:
        """Close the underlying httpx client."""
        await self._client.aclose()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    async def _check_eligibility(self, repo_slug: str) -> bool:
        """Run all three eligibility checks; any match returns True."""
        repo_name = repo_slug.rsplit("/", 1)[-1]

        if self._matches_name_pattern(repo_name):
            logger.debug("Repo %s eligible via naming pattern", repo_slug)
            return True

        if await self._has_marker_file(repo_slug):
            logger.debug("Repo %s eligible via marker file", repo_slug)
            return True

        if await self._from_template_repo(repo_slug):
            logger.debug("Repo %s eligible via template origin", repo_slug)
            return True

        return False

    def _matches_name_pattern(self, repo_name: str) -> bool:
        """Return True if repo_name matches any configured glob pattern."""
        patterns_raw = self._config.eligible_repo_patterns
        if not patterns_raw:
            return False
        for pattern in patterns_raw.split(","):
            pattern = pattern.strip()
            if pattern and fnmatch.fnmatch(repo_name, pattern):
                return True
        return False

    async def _has_marker_file(self, repo_slug: str) -> bool:
        """Return True if the eligibility marker path exists in the repo."""
        marker = self._config.eligibility_marker_path
        url = f"https://api.github.com/repos/{repo_slug}/contents/{marker}"
        try:
            resp = await self._client.get(url)
            return resp.status_code == 200
        except Exception:
            logger.debug("Marker file check failed for %s", repo_slug)
            return False

    async def _from_template_repo(self, repo_slug: str) -> bool:
        """Return True if the repo was created from the orchestration template repo."""
        url = f"https://api.github.com/repos/{repo_slug}"
        try:
            resp = await self._client.get(url)
            resp.raise_for_status()
            template = resp.json().get("template_repository") or {}
            template_name: str = template.get("full_name", "")
            return bool(
                template_name
                and template_name == f"{self._config.github_org}/{self._config.orchestration_template_repo}"
            )
        except Exception:
            logger.debug("Template-origin check failed for %s", repo_slug)
            return False
