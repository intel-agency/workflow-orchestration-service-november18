"""Prompt assembler — Python port of scripts/assemble-orchestrator-prompt.sh."""
import json
import uuid
from pathlib import Path

from src.config import ServiceConfig
from src.models.event import OrchestrationEvent


class PromptAssembler:
    """Assembles the orchestrator agent prompt by injecting event data into the template.

    Replicates the assembly logic of scripts/assemble-orchestrator-prompt.sh.
    """

    def __init__(self, config: ServiceConfig, output_dir: str = "/tmp") -> None:
        self._config = config
        self._output_dir = output_dir

    def assemble(self, event: OrchestrationEvent) -> str:
        """Inject event data into the prompt template and write to a temp file.

        Reads the template, splits at ``{{__EVENT_DATA__}}``, appends the
        structured event context block (10-space indented) and raw JSON payload,
        then writes to a uniquely named temp file — matching the shell script's
        exact output format (lines 53–76 of assemble-orchestrator-prompt.sh).

        Returns:
            Absolute path to the assembled prompt file.
        """
        content = Path(self._config.prompt_template_path).read_text(encoding="utf-8")

        # Replicate: sed '/{{__EVENT_DATA__}}/,$ d'
        lines = content.split("\n")
        template_lines = []
        for line in lines:
            if "{{__EVENT_DATA__}}" in line:
                break
            template_lines.append(line)
        template_part = "\n".join(template_lines) + "\n"

        # 10-space indentation matches the shell script heredoc format exactly
        event_block = (
            f"          Event Name: {event.event_type}\n"
            f"          Action: {event.action}\n"
            f"          Actor: {event.actor}\n"
            f"          Repository: {event.repo_slug}\n"
            f"          Ref: {event.ref}\n"
            f"          SHA: {event.sha}\n"
        )

        # Use the original raw JSON string verbatim (matching `echo "$EVENT_JSON"` in the
        # shell script).  Fall back to json.dumps only when no raw string was captured.
        json_raw = (event.raw_payload_str or json.dumps(event.raw_payload)).rstrip("\n")
        json_block = f"```json\n{json_raw}\n```\n"

        output = template_part + event_block + "\n" + json_block

        out_path = f"{self._output_dir}/orchestrator-prompt-{uuid.uuid4()}.md"
        Path(out_path).write_text(output, encoding="utf-8")
        return out_path
