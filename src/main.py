"""Entry point — wire all components together and start uvicorn."""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI

from src.config import ServiceConfig
from src.dispatcher import Dispatcher
from src.eligibility_checker import EligibilityChecker
from src.event_router import create_app
from src.prompt_assembler import PromptAssembler
from src.sentinel import Sentinel
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
    eligibility_checker = EligibilityChecker(config)
    sentinel = Sentinel(config, eligibility_checker, prompt_assembler, worktree_manager, dispatcher)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await dispatcher.start()
        logger.info("Dispatcher started")
        await sentinel.start()
        logger.info("Sentinel started")
        yield
        await sentinel.stop()
        await dispatcher.stop()
        logger.info("Dispatcher stopped")
        await eligibility_checker.close()
        await sentinel.close()

    return create_app(config, prompt_assembler, worktree_manager, dispatcher, lifespan=lifespan, sentinel=sentinel, eligibility_checker=eligibility_checker)


app = build_app()

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
