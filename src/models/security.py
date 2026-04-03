"""Credential scrubbing utilities for safe public posting (R-7)."""
import re

# Regex patterns that match common secret formats. Used to sanitize
# worker output before posting to GitHub issue comments.
_SECRET_PATTERNS = [
    re.compile(r"ghp_[A-Za-z0-9_]{36,}"),  # GitHub PAT (classic)
    re.compile(r"ghs_[A-Za-z0-9_]{36,}"),  # GitHub App installation token
    re.compile(r"gho_[A-Za-z0-9_]{36,}"),  # GitHub OAuth token
    re.compile(r"github_pat_[A-Za-z0-9_]{22,}"),  # GitHub fine-grained PAT
    re.compile(r"Bearer\s+[A-Za-z0-9\-._~+/]+=*", re.IGNORECASE),
    re.compile(r"token\s+[A-Za-z0-9\-._~+/]{20,}", re.IGNORECASE),
    re.compile(r"sk-[A-Za-z0-9]{20,}"),  # OpenAI-style API keys
    re.compile(r"[A-Za-z0-9]{32,}\.zhipu[A-Za-z0-9]*"),  # ZhipuAI keys
]


def scrub_secrets(text: str, replacement: str = "***REDACTED***") -> str:
    """Strip known secret patterns from text for safe public posting."""
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text
