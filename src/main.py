"""Entry point — wire all components together and start uvicorn."""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI

from src.config import ServiceConfig
from src.dispatcher import Dispatcher
from src.event_router import create_app
from src.prompt_assembler import PromptAssembler
from src.worktree_manager import WorktreeManager

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
    level=logging.INFO,
)

logger = logging.getLogger(__name__)


def build_app() -> FastAPI:
    config = ServiceConfig()

    prompt_assembler = PromptAssembler(config)
    worktree_manager = WorktreeManager(config)
    dispatcher = Dispatcher(config)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await dispatcher.start()
        logger.info("Dispatcher started")
        yield
        await dispatcher.stop()
        logger.info("Dispatcher stopped")

    return create_app(config, prompt_assembler, worktree_manager, dispatcher, lifespan=lifespan)


app = build_app()

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
