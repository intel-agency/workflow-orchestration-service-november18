"""Dispatcher — subprocess lifecycle for ``run_opencode_prompt.sh``."""
from __future__ import annotations

import asyncio
import logging
import os
import signal
import sys
from pathlib import Path

from src.config import ServiceConfig

logger = logging.getLogger(__name__)

# Absolute path to run_opencode_prompt.sh (repo root, one level above src/).
_SCRIPT_PATH = Path(__file__).parent.parent / "run_opencode_prompt.sh"

# Seconds to wait for SIGTERM before escalating to SIGKILL during cleanup.
_KILL_GRACE_SECS = 5.0


class Dispatcher:
    """Execute assembled prompts against the opencode server via subprocess.

    Wraps ``run_opencode_prompt.sh`` in an asyncio subprocess, enforces a hard
    timeout, and serialises all dispatch calls through an internal asyncio Queue
    (Decision 8 — Sequential Dispatch).

    Shutdown contract: ``stop()`` stops accepting new work, kills the entire
    process group spawned for the active job (so no opencode or log-tailer
    children survive as orphaned processes), and ensures every pending
    ``dispatch()`` caller is settled (resolved or cancelled) before returning.
    Callers do **not** need to cancel their own tasks.

    Lifecycle::

        dispatcher = Dispatcher(config)
        await dispatcher.start()                                # start worker
        exit_code = await dispatcher.dispatch(prompt, worktree) # queue & wait
        await dispatcher.stop()                                 # graceful stop
    """

    def __init__(self, config: ServiceConfig) -> None:
        self._config = config
        # Each item: (prompt_path, worktree_path, Future[int])
        self._queue: asyncio.Queue[tuple[str, str, asyncio.Future[int]]] = (
            asyncio.Queue()
        )
        self._worker_task: asyncio.Task[None] | None = None
        self._stopping: bool = False
        # All futures handed to dispatch() callers; used by stop() to settle them.
        self._pending_futures: set[asyncio.Future[int]] = set()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def start(self) -> None:
        """Spawn the background queue-worker task."""
        self._stopping = False
        self._worker_task = asyncio.create_task(
            self._worker(), name="dispatcher-worker"
        )

    async def stop(self) -> None:
        """Stop accepting new jobs, kill the process tree, and settle all futures.

        After this coroutine returns every caller of ``dispatch()`` that was
        waiting will have received either a result or a ``CancelledError``.
        Callers do **not** need to cancel their own tasks.

        The in-flight subprocess is killed via ``_kill_process_group`` inside
        ``_run()``'s cancellation handler, so the entire process group
        (bash wrapper + opencode + log-tailer children) is torn down before
        this method returns.
        """
        self._stopping = True
        if self._worker_task is not None:
            self._worker_task.cancel()
            try:
                await self._worker_task
            except asyncio.CancelledError:
                pass
            self._worker_task = None
        # Cancel futures for jobs queued but not yet started by the worker.
        while not self._queue.empty():
            try:
                _, _, future = self._queue.get_nowait()
                if not future.done():
                    future.cancel()
                self._queue.task_done()
            except asyncio.QueueEmpty:
                break
        # Cancel any futures still tracked (e.g. the in-flight job's future
        # if _worker's CancelledError handler hasn't settled it yet).
        for future in list(self._pending_futures):
            if not future.done():
                future.cancel()
        # Yield to the event loop so dispatch() callers can process their
        # CancelledError and complete before stop() returns.
        await asyncio.sleep(0)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def dispatch(self, prompt_path: str, worktree_path: str) -> int:
        """Queue a dispatch job and block until it completes.

        Returns:
            Subprocess exit code (``0`` = success, ``-1`` = timeout-killed).

        Raises:
            RuntimeError: If the dispatcher is shutting down.
        """
        if self._stopping:
            raise RuntimeError("Dispatcher is shutting down; not accepting new jobs")
        future: asyncio.Future[int] = asyncio.get_running_loop().create_future()
        self._pending_futures.add(future)
        future.add_done_callback(self._pending_futures.discard)
        await self._queue.put((prompt_path, worktree_path, future))
        return await future

    # ------------------------------------------------------------------
    # Internal worker
    # ------------------------------------------------------------------

    async def _worker(self) -> None:
        """Drain the queue one item at a time (sequential dispatch)."""
        while True:
            prompt_path, worktree_path, future = await self._queue.get()
            try:
                result = await self._run(prompt_path, worktree_path)
                if not future.done():
                    future.set_result(result)
            except asyncio.CancelledError:
                if not future.done():
                    future.cancel()
                raise
            except Exception as exc:  # noqa: BLE001
                logger.exception("Dispatcher._run raised unexpectedly")
                if not future.done():
                    future.set_exception(exc)
            finally:
                self._queue.task_done()

    async def _run(self, prompt_path: str, worktree_path: str) -> int:
        """Invoke ``run_opencode_prompt.sh`` and return the exit code.

        Launches the shell bridge in its own session (``start_new_session=True``)
        so every child process it spawns — opencode, log-tailer FIFOs, watchdog
        helpers — shares the same process group.  On timeout the entire group is
        terminated via ``_kill_process_group``.  On cancellation the group is
        also killed here, using Python 3.12's ``Task.uncancel()`` / re-cancel
        pattern so the cleanup awaitable completes before CancelledError
        propagates further.
        """
        env = self._build_env()
        logger.info(
            "Dispatching prompt=%s worktree=%s server=%s",
            prompt_path,
            worktree_path,
            self._config.opencode_server_url,
        )
        proc = await asyncio.create_subprocess_exec(
            "bash",
            str(_SCRIPT_PATH),
            "-a", self._config.opencode_server_url,
            "-d", worktree_path,
            "-f", prompt_path,
            env=env,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
        )
        try:
            await asyncio.wait_for(
                proc.communicate(),
                timeout=float(self._config.subprocess_timeout_secs),
            )
        except asyncio.TimeoutError:
            logger.warning(
                "Subprocess timed out after %d s; killing process group pid=%d",
                self._config.subprocess_timeout_secs,
                proc.pid,
            )
            await self._kill_process_group(proc)
            return -1
        except asyncio.CancelledError:
            logger.warning(
                "Dispatch cancelled; killing process group pid=%d", proc.pid
            )
            # Temporarily suspend the task's cancellation counter (Python 3.12+)
            # so the cleanup await can run to completion before we re-raise.
            task = asyncio.current_task()
            n = task.cancelling() if task is not None else 0
            for _ in range(n):
                task.uncancel()  # type: ignore[union-attr]
            try:
                await self._kill_process_group(proc)
            finally:
                # Restore the cancellation count so the task actually terminates.
                for _ in range(n):
                    task.cancel()  # type: ignore[union-attr]
            raise

        exit_code = proc.returncode if proc.returncode is not None else 0
        if exit_code != 0:
            logger.warning(
                "run_opencode_prompt.sh exited %d (prompt=%s worktree=%s)",
                exit_code,
                prompt_path,
                worktree_path,
            )
        else:
            logger.info("Dispatch completed successfully (exit=0)")
        return exit_code

    async def _kill_process_group(self, proc: asyncio.subprocess.Process) -> None:
        """Terminate the entire process group spawned for *proc*.

        On POSIX, sends SIGTERM to the process group and waits up to
        ``_KILL_GRACE_SECS`` for a clean exit, then escalates to SIGKILL.
        On Windows, kills the process directly (no Unix process-group semantics).
        Blocks until the top-level process has exited so the caller is not left
        waiting on zombie state.
        """
        if sys.platform == "win32":
            proc.kill()
            try:
                await asyncio.wait_for(proc.wait(), timeout=_KILL_GRACE_SECS)
            except asyncio.TimeoutError:
                pass
            return

        # POSIX: kill the whole process group (bash + opencode + log tailers).
        try:
            pgid = os.getpgid(proc.pid)
        except (ProcessLookupError, PermissionError):
            return  # process already gone

        try:
            os.killpg(pgid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            return  # process group already gone

        try:
            await asyncio.wait_for(proc.wait(), timeout=_KILL_GRACE_SECS)
            return
        except asyncio.TimeoutError:
            pass

        # SIGTERM was not sufficient — escalate to SIGKILL.
        logger.warning(
            "Process group pgid=%d did not exit after SIGTERM; sending SIGKILL", pgid
        )
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass  # already gone between the timeout check and this call

        await proc.wait()

    def _build_env(self) -> dict[str, str]:
        """Return the subprocess environment with required tokens explicitly set."""
        env = os.environ.copy()
        # Ensure the token the script validates is present even when the config
        # loaded it under the GITHUB_TOKEN alias.
        env["GH_ORCHESTRATION_AGENT_TOKEN"] = self._config.github_token
        return env
