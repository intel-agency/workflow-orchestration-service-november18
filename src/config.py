from __future__ import annotations

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class ServiceConfig(BaseSettings):
    """Client service configuration loaded from environment variables."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    github_org: str
    """GitHub org to monitor. Env var: GITHUB_ORG (required)."""

    github_token: str = Field(
        validation_alias=AliasChoices("gh_orchestration_agent_token", "github_token")
    )
    """PAT with repo, workflow, project, read:org scopes.
    Env var: GH_ORCHESTRATION_AGENT_TOKEN (required; GITHUB_TOKEN accepted for backward compatibility)."""

    webhook_secret: str
    """HMAC secret for verifying org-wide webhook payloads. Env var: WEBHOOK_SECRET (required)."""

    opencode_server_url: str = "http://server:4096"
    """URL used for --attach when dispatching prompts. Env var: OPENCODE_SERVER_URL."""

    poll_interval_secs: int = 60
    """Sentinel polling interval in seconds. Env var: POLL_INTERVAL_SECS."""

    git_repos_root: str = "./git_repos"
    """Root directory where per-issue worktrees are created. Env var: GIT_REPOS_ROOT."""

    prompt_template_path: str = "/opt/orchestration/prompts/orchestrator-agent-prompt.md"
    """Path to the orchestrator prompt template (baked into prebuild image). Env var: PROMPT_TEMPLATE_PATH."""

    subprocess_timeout_secs: int = 5700
    """Hard timeout for opencode subprocess (95 min). Env var: SUBPROCESS_TIMEOUT_SECS."""

    eligible_repo_patterns: str = ""
    """Comma-separated glob patterns for repo name matching (optional). Env var: ELIGIBLE_REPO_PATTERNS."""

    eligibility_marker_path: str = "plan_docs"
    """Directory/file whose presence in a repo indicates it is eligible. Env var: ELIGIBILITY_MARKER_PATH."""

    orchestration_template_repo: str = "workflow-orchestration-service-november18"
    """Template repo name used for template-origin eligibility check. Env var: ORCHESTRATION_TEMPLATE_REPO."""
