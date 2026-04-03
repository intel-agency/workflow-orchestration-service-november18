#!/usr/bin/env python3
"""
Subagent Trace Extractor — parses the opencode server log (structured text format)
to produce a per-agent activity timeline for CI artifact and post-mortem analysis.

Server log format (one entry per line):
  LEVEL  TIMESTAMP +Xms service=NAME key=value key=value ...

Key entries used:
  service=llm  ... sessionID=X agent=Y modelID=Z stream        → LLM call start
  service=llm  ... sessionID=X agent=Y ... error=...           → LLM call error
  service=session.prompt step=N sessionID=X loop               → Agent turn N begins
  service=mcp  key=sequential-thinking mcp stderr:             → seq-thinking invoked
  service=mcp  key=memory mcp stderr:                         → memory tool invoked
  ERROR  ...                                                    → any error

Usage:
  python3 trace-extract.py [--log <file>] [--scrub] [--no-scrub]
"""

import os
import re
import sys
import argparse
from pathlib import Path
from collections import defaultdict

_script_dir = Path(__file__).resolve().parent
if str(_script_dir) not in sys.path:
    sys.path.insert(0, str(_script_dir))
try:
    from WorkItemModel import scrub_secrets
except ImportError:
    def scrub_secrets(text, replacement="***REDACTED***"):
        return text

# Regex to split a structured log line into its key=value fields.
# Handles: key=value, key="quoted value", key={json...}
_KV_RE = re.compile(r'(\w[\w.]*?)=(\{[^}]*\}|"[^"]*"|\S+)')

# Server log line prefix: LEVEL  TIMESTAMP +Xms  <rest>
_LINE_RE = re.compile(
    r'^(?P<level>\w+)\s+(?P<ts>\S+)\s+\+\d+ms\s+(?P<rest>.+)$'
)


def parse_kv(text):
    """Parse key=value pairs from a structured log line fragment."""
    return {m.group(1): m.group(2).strip('"') for m in _KV_RE.finditer(text)}


def extract_trace(log_path, scrub=False):
    if not os.path.exists(log_path):
        print(f"Error: log file not found: {log_path}", file=sys.stderr)
        return

    # session_id → { agent, model, first_ts, last_ts, llm_calls, turns,
    #                 seq_thinking_calls, memory_calls, errors }
    sessions = defaultdict(lambda: {
        "agent": None, "model": None,
        "first_ts": None, "last_ts": None,
        "llm_calls": 0, "turns": 0,
        "seq_thinking_calls": 0, "memory_calls": 0,
        "errors": [],
    })
    # ordered list of session IDs as first seen
    session_order = []
    global_errors = []

    with open(log_path, "r", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            m = _LINE_RE.match(line)
            if not m:
                continue
            level = m.group("level")
            ts = m.group("ts")
            rest = m.group("rest")
            kv = parse_kv(rest)
            service = kv.get("service", "")

            # ── LLM call ─────────────────────────────────────────────────
            if service == "llm":
                sid = kv.get("sessionID")
                if not sid:
                    continue
                if sid not in session_order:
                    session_order.append(sid)
                s = sessions[sid]
                if s["first_ts"] is None:
                    s["first_ts"] = ts
                s["last_ts"] = ts
                if s["agent"] is None and kv.get("agent"):
                    s["agent"] = kv["agent"]
                if s["model"] is None and kv.get("modelID"):
                    s["model"] = kv["modelID"]
                if level == "ERROR":
                    err = kv.get("error", rest)
                    if scrub:
                        err = scrub_secrets(err)
                    # Truncate very long error blobs (permission rulesets etc.)
                    if len(err) > 200:
                        err = err[:200] + " ...[truncated]"
                    s["errors"].append(f"[{ts}] {err}")
                else:
                    s["llm_calls"] += 1

            # ── Session loop step (one per agent turn) ────────────────────
            elif service == "session.prompt":
                sid = kv.get("sessionID")
                status = kv.get("status", rest)
                if sid and "loop" in rest:
                    sessions[sid]["turns"] += 1

            # ── MCP tool calls ────────────────────────────────────────────
            elif service == "mcp":
                key = kv.get("key", "")
                if "mcp stderr:" in rest and "running on stdio" not in rest:
                    if "sequential-thinking" in key:
                        # associate with most recently active session
                        target = session_order[-1] if session_order else None
                        if target:
                            sessions[target]["seq_thinking_calls"] += 1
                    elif "memory" in key:
                        target = session_order[-1] if session_order else None
                        if target:
                            sessions[target]["memory_calls"] += 1

            # ── Top-level errors not tied to a session ────────────────────
            if level == "ERROR" and service not in ("llm",):
                err = rest
                if scrub:
                    err = scrub_secrets(err)
                if len(err) > 300:
                    err = err[:300] + " ...[truncated]"
                global_errors.append(f"[{ts}] {err}")

    # ── Output ──────────────────────────────────────────────────────────
    if not session_order:
        print("No agent sessions found in log.")
        return

    print(f"{'='*70}")
    print(f"SUBAGENT TRACE REPORT — {log_path}")
    print(f"{'='*70}")
    print(f"Sessions found: {len(session_order)}")
    print()

    total_llm = 0
    total_seq = 0
    total_mem = 0

    for idx, sid in enumerate(session_order, 1):
        s = sessions[sid]
        agent = s["agent"] or "unknown"
        model = s["model"] or "?"
        first = s["first_ts"] or "?"
        last = s["last_ts"] or "?"
        calls = s["llm_calls"]
        turns = s["turns"]
        seq = s["seq_thinking_calls"]
        mem = s["memory_calls"]
        total_llm += calls
        total_seq += seq
        total_mem += mem

        print(f"── [{idx:02d}] agent={agent}  model={model}")
        print(f"       session: {sid}")
        print(f"       first: {first}  last: {last}")
        print(f"       LLM calls: {calls}  turns: {turns}  "
              f"seq_thinking: {seq}  memory: {mem}")
        if s["errors"]:
            for e in s["errors"]:
                print(f"       ERROR: {e}")
        print()

    print(f"{'─'*70}")
    print(f"TOTALS: sessions={len(session_order)}  llm_calls={total_llm}  "
          f"seq_thinking={total_seq}  memory={total_mem}")
    if total_mem == 0:
        print("  ⚠  No memory tool calls detected — agents did not use knowledge graph.")
    if total_seq == 0:
        print("  ⚠  No sequential_thinking calls detected.")

    if global_errors:
        print(f"\n{'─'*70}")
        print("GLOBAL ERRORS (not session-specific):")
        for e in global_errors[:20]:
            print(f"  {e}")
        if len(global_errors) > 20:
            print(f"  ... and {len(global_errors) - 20} more")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Extract subagent traces from the opencode server log"
    )
    parser.add_argument(
        "--log",
        default="/tmp/opencode-serve.log",
        help="Path to server log file (default: /tmp/opencode-serve.log)",
    )
    parser.add_argument(
        "--scrub",
        action="store_true",
        default=True,
        help="Scrub credentials from output (default: on)",
    )
    parser.add_argument(
        "--no-scrub", action="store_true", help="Disable credential scrubbing"
    )
    args = parser.parse_args()

    do_scrub = not args.no_scrub
    extract_trace(args.log, scrub=do_scrub)
