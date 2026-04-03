FROM ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest

WORKDIR /workspace

COPY opencode.json /workspace/opencode.json
COPY .opencode/agents/ /workspace/.opencode/agents/
COPY .opencode/commands/ /workspace/.opencode/commands/
COPY AGENTS.md /workspace/AGENTS.md
COPY local_ai_instruction_modules/ /workspace/local_ai_instruction_modules/
COPY .agents/skills/ /workspace/.agents/skills/
COPY scripts/start-opencode-server.sh /workspace/scripts/start-opencode-server.sh
COPY server/entrypoint.sh /workspace/server/entrypoint.sh
COPY run_opencode_prompt.sh /workspace/run_opencode_prompt.sh
COPY .github/workflows/prompts/orchestrator-agent-prompt.md /opt/orchestration/prompts/orchestrator-agent-prompt.md

RUN mkdir -p /workspace/git_repos

EXPOSE 4096

ENTRYPOINT ["bash", "server/entrypoint.sh"]
