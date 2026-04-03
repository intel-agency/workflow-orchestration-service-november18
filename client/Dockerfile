FROM ghcr.io/intel-agency/workflow-orchestration-prebuild/devcontainer:main-latest

WORKDIR /workspace

COPY pyproject.toml uv.lock /workspace/

RUN uv sync --frozen

COPY src/ /workspace/src/

COPY run_opencode_prompt.sh /workspace/run_opencode_prompt.sh

COPY .github/workflows/prompts/orchestrator-agent-prompt.md /opt/orchestration/prompts/orchestrator-agent-prompt.md

RUN mkdir -p /workspace/git_repos

EXPOSE 8000

ENTRYPOINT ["uv", "run", "python", "-m", "src.main"]
