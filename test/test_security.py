"""Tests for scrub_secrets credential scrubbing utility."""
import pytest

from src.models.security import scrub_secrets

# Build fake token prefixes at runtime so the source file never contains
# literal provider-prefix strings that trip secret scanners (e.g. gitleaks).
_GHP = "ghp" + "_"
_GHS = "ghs" + "_"
_GHO = "gho" + "_"
_PAT = "github_pat" + "_"
_SK = "sk" + "-"


def test_scrub_github_pat_classic():
    text = "token: " + _GHP + "FAKE000000000000000000000000000000000000"
    result = scrub_secrets(text)
    assert _GHP + "FAKE" not in result
    assert "***REDACTED***" in result


def test_scrub_github_app_token():
    text = "token: " + _GHS + "FAKE000000000000000000000000000000000000"
    result = scrub_secrets(text)
    assert _GHS + "FAKE" not in result
    assert "***REDACTED***" in result


def test_scrub_github_oauth_token():
    text = "token: " + _GHO + "FAKE000000000000000000000000000000000000"
    result = scrub_secrets(text)
    assert _GHO + "FAKE" not in result
    assert "***REDACTED***" in result


def test_scrub_github_fine_grained_pat():
    text = "token: " + _PAT + "FAKEFAKEFAKEFAKEFAKEFAKE"
    result = scrub_secrets(text)
    assert _PAT + "FAKE" not in result
    assert "***REDACTED***" in result


def test_scrub_bearer_token():
    text = "Authorization: Bearer FAKETOKEN00000000000000000000"
    result = scrub_secrets(text)
    assert "FAKETOKEN" not in result
    assert "***REDACTED***" in result


def test_scrub_openai_key():
    text = "key: " + _SK + "FAKE00000000000000000000"
    result = scrub_secrets(text)
    assert _SK + "FAKE" not in result
    assert "***REDACTED***" in result


def test_scrub_zhipu_key():
    text = "key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.zhipuFAKE"
    result = scrub_secrets(text)
    assert "zhipuFAKE" not in result
    assert "***REDACTED***" in result


def test_clean_text_unchanged():
    text = "This text contains no secrets. Just regular information."
    result = scrub_secrets(text)
    assert result == text


def test_custom_replacement():
    text = "token: " + _GHP + "FAKE000000000000000000000000000000000000"
    result = scrub_secrets(text, replacement="[HIDDEN]")
    assert "[HIDDEN]" in result
    assert _GHP + "FAKE" not in result
