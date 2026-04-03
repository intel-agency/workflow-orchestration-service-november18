"""Tests for PromptAssembler — Python port of assemble-orchestrator-prompt.sh."""
import json
import os
from pathlib import Path

import pytest

from src.models.event import OrchestrationEvent
from src.prompt_assembler import PromptAssembler

FIXTURES_DIR = Path(__file__).parent / "fixtures"
TEMPLATE_PATH = (
    Path(__file__).parent.parent / ".github" / "workflows" / "prompts" / "orchestrator-agent-prompt.md"
)
ISSUES_OPENED = FIXTURES_DIR / "issues-opened.json"
EXPECTED_FIXTURE = FIXTURES_DIR / "assembled-prompt-expected.md"


@pytest.fixture
def event():
    raw = ISSUES_OPENED.read_text(encoding="utf-8")
    payload = json.loads(raw)
    return OrchestrationEvent.from_webhook_payload(payload, raw_payload_str=raw)


@pytest.fixture
def assembler(monkeypatch, tmp_path):
    monkeypatch.setenv("GITHUB_ORG", "test-org")
    monkeypatch.setenv("GITHUB_TOKEN", "test-token")
    monkeypatch.setenv("WEBHOOK_SECRET", "test-secret")
    monkeypatch.setenv("PROMPT_TEMPLATE_PATH", str(TEMPLATE_PATH))

    from src.config import ServiceConfig

    config = ServiceConfig()
    return PromptAssembler(config, output_dir=str(tmp_path))


@pytest.fixture
def assembled_path(assembler, event):
    return assembler.assemble(event)


@pytest.fixture
def assembled_content(assembled_path):
    return Path(assembled_path).read_text(encoding="utf-8")


def test_assembled_prompt_contains_template_content(assembled_content):
    template_text = TEMPLATE_PATH.read_text(encoding="utf-8")
    template_before_marker = template_text.split("{{__EVENT_DATA__}}")[0]
    assert assembled_content.startswith(template_before_marker)


def test_event_context_block_format(assembled_content):
    assert "          Event Name: issues" in assembled_content
    assert "          Action: opened" in assembled_content
    assert "          Actor: nam20485" in assembled_content
    assert "          Repository: intel-agency/workflow-orchestration" in assembled_content
    assert "          Ref: refs/heads/main" in assembled_content
    assert "          SHA: " in assembled_content


def test_raw_event_json_wrapped_in_code_block(assembled_content, event):
    # The raw string must appear verbatim — not re-serialized via json.dumps.
    raw = event.raw_payload_str
    assert "```json\n" in assembled_content
    assert raw.rstrip("\n") in assembled_content
    assert "\n```\n" in assembled_content


def test_raw_payload_str_preserved_verbatim(assembler):
    """Assembler writes raw_payload_str verbatim; re-serialization would corrupt Unicode."""
    # Pretty-formatted JSON with non-ASCII chars — json.dumps would produce \u-escapes.
    raw_json = (
        '{\n'
        '  "action": "opened",\n'
        '  "issue": {"number": 99, "title": "H\u00e9llo W\u00f6rld", "body": null,\n'
        '             "labels": [], "user": {"login": "actor"}, "assignees": [],\n'
        '             "milestone": null},\n'
        '  "repository": {"full_name": "org/repo", "name": "repo",\n'
        '                  "owner": {"login": "org"}},\n'
        '  "sender": {"login": "actor"}\n'
        '}'
    )
    payload = json.loads(raw_json)
    event = OrchestrationEvent.from_webhook_payload(payload, raw_payload_str=raw_json)
    path = assembler.assemble(event)
    content = Path(path).read_text(encoding="utf-8")
    # The literal Unicode characters must appear — not backslash-escaped.
    assert "Héllo Wörld" in content
    # The pretty-formatted raw string must be present verbatim.
    assert raw_json.rstrip("\n") in content


def test_no_event_data_marker_in_output(assembled_content):
    assert "{{__EVENT_DATA__}}" not in assembled_content


def test_output_file_written_to_tmp(assembled_path, tmp_path):
    p = Path(assembled_path)
    assert p.exists()
    assert p.name.startswith("orchestrator-prompt-")
    assert p.suffix == ".md"
    assert p.parent == tmp_path


def test_output_matches_known_good_fixture(assembled_content):
    expected = EXPECTED_FIXTURE.read_text(encoding="utf-8")
    assert assembled_content == expected
