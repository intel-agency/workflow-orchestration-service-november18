from __future__ import annotations

from pydantic import BaseModel, Field, field_validator, model_validator


class OrchestrationEvent(BaseModel):
    """Represents a GitHub event that has been parsed and enriched for orchestration dispatch."""

    repo_slug: str
    """Full repo identifier, e.g. 'intel-agency/my-app-foxtrot99'."""

    repo_name: str = Field(default="")
    """Repo name derived from repo_slug (the part after the slash); auto-derived when not supplied."""

    issue_number: int
    """GitHub issue number."""

    event_type: str
    """Webhook event type header, e.g. 'issues'."""

    action: str
    """Event action, e.g. 'labeled'."""

    triggered_label: str
    """The specific label that triggered this event."""

    all_labels: list[str]
    """All current labels on the issue at the time of the event."""

    actor: str
    """GitHub login of the user who triggered the event."""

    title: str
    """Issue title."""

    body: str = Field(default="")
    """Issue body text; null values from the GitHub API are normalized to an empty string."""

    ref: str = Field(default="refs/heads/main")
    """Git ref; defaults to main branch."""

    sha: str = Field(default="")
    """Git SHA; populated when available."""

    raw_payload: dict
    """Complete webhook JSON payload used for __EVENT_DATA__ injection."""

    worktree_slug: str = Field(default="")
    """Resolved worktree slug; computed by WorktreeManager before dispatch."""

    @field_validator("body", mode="before")
    @classmethod
    def _normalize_body(cls, v: object) -> str:
        """Coerce None (GitHub API null) to an empty string."""
        return "" if v is None else v

    @model_validator(mode="after")
    def _derive_repo_name(self) -> "OrchestrationEvent":
        """Auto-derive repo_name from repo_slug when the caller did not supply it."""
        if not self.repo_name and self.repo_slug:
            self.repo_name = self.repo_slug.rsplit("/", 1)[-1]
        return self

    @classmethod
    def from_webhook_payload(
        cls,
        payload: dict,
        *,
        event_type: str = "issues",
        triggered_label: str = "",
    ) -> "OrchestrationEvent":
        """Construct an OrchestrationEvent from a raw GitHub webhook payload dict.

        Extracts nested fields from the standard GitHub issues-event shape
        (``repository.full_name``, ``issue.number``, ``label.name``, etc.),
        populates ``raw_payload`` automatically, derives ``repo_name`` from
        ``repo_slug``, and normalises a null issue body to an empty string.

        Args:
            payload: The parsed webhook JSON body.
            event_type: Value of the ``X-GitHub-Event`` request header (e.g. ``'issues'``).
            triggered_label: The label that caused this event; falls back to
                ``payload['label']['name']`` for ``labeled`` actions when not given.
        """
        issue = payload.get("issue", {})
        repository = payload.get("repository", {})
        sender = payload.get("sender", {})

        repo_slug: str = repository.get("full_name", "")

        if not triggered_label:
            triggered_label = (payload.get("label") or {}).get("name", "")

        raw_labels: list = issue.get("labels", [])
        all_labels: list[str] = [
            lbl["name"] if isinstance(lbl, dict) else str(lbl) for lbl in raw_labels
        ]

        return cls(
            repo_slug=repo_slug,
            issue_number=issue.get("number", 0),
            event_type=event_type,
            action=payload.get("action", ""),
            triggered_label=triggered_label,
            all_labels=all_labels,
            actor=sender.get("login", ""),
            title=issue.get("title", ""),
            body=issue.get("body"),
            raw_payload=payload,
        )
