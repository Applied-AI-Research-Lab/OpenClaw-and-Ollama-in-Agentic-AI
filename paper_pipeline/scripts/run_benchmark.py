#!/usr/bin/env python3
"""Run Project.md benchmark protocol and save JSON traces."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sqlite3
import subprocess
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib import request
from urllib import error as url_error

ROOT = Path(__file__).resolve().parents[1]
TASKS_DIR = ROOT / "tasks"
RUNS_DIR = ROOT / "runs"


@dataclass
class Task:
    task_id: str
    category: str
    prompt: str
    expected_contains: list[str]
    expected_exact: str | None
    expected_regex: str | None
    expected_not_contains: list[str] = field(default_factory=list)
    verify_file_exists: str | None = None
    requires_tools: bool = False
    requires_memory: bool = False


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_tasks(limit: int | None = None) -> list[Task]:
    files = sorted(TASKS_DIR.glob("task_*.json"))
    if limit is not None:
        files = files[:limit]

    items: list[Task] = []
    for p in files:
        obj = load_json(p)
        items.append(
            Task(
                task_id=obj["id"],
                category=obj["category"],
                prompt=obj["prompt"],
                expected_contains=obj.get("expected_contains", []),
                expected_exact=obj.get("expected_exact"),
                expected_regex=obj.get("expected_regex"),
                expected_not_contains=obj.get("expected_not_contains", []),
                verify_file_exists=obj.get("verify_file_exists"),
                requires_tools=bool(obj.get("requires_tools", False)),
                requires_memory=bool(obj.get("requires_memory", False)),
            )
        )
    return items


def build_prompt(prefix: str, task: Task, disable_thinking: bool = False) -> str:
    contract = (
        "Return your final answer as strict JSON with exactly one key: "
        "{\"answer\": <string>} and no extra keys."
    )
    # /no_think disables CoT token generation (Qwen3.5 feature).
    # Only use it for C1 (ollama_native) where thinking inflates latency hugely.
    # C2/C3 need reasoning to invoke OpenClaw tools - disabling thinking breaks tool use.
    parts = []
    if disable_thinking:
        parts.append("/no_think")
    if prefix:
        parts.append(prefix)
    parts.append(contract)
    parts.append(f"Task:\n{task.prompt}")
    return "\n\n".join(parts)


def apply_runtime_guards(prompt: str, cfg: dict[str, Any]) -> str:
    guards: list[str] = []
    if cfg.get("forbid_tools"):
        guards.append("Hard constraint: Do not use any tools, commands, web calls, or file access.")
    if cfg.get("forbid_memory"):
        guards.append("Hard constraint: Do not rely on memory from previous turns; answer only from this prompt.")
    if not guards:
        return prompt
    return "\n".join(guards) + "\n\n" + prompt


def enrich_prompt_with_local_data(task: Task, prompt: str, allow_tool_tasks: bool = False) -> str:
    # Inline local file data when tools are not required, unless explicitly allowed.
    if task.requires_tools and not allow_tool_tasks:
        return prompt

    paths = sorted(set(re.findall(r"paper_pipeline/data/[\w.\-_/]+", prompt)))
    if not paths:
        return prompt

    chunks: list[str] = []
    for rel in paths:
        fp = ROOT / rel.replace("paper_pipeline/", "")
        if fp.exists() and fp.is_file():
            chunks.append(f"[BEGIN CONTENT]\n{fp.read_text(encoding='utf-8')}\n[END CONTENT]")

    if not chunks:
        return prompt

    # Replace file path mentions in the prompt text with a note pointing to the injected
    # data below. This prevents models with file-read tools from attempting to open paths
    # that do not exist in their working directory.
    enriched_prompt = prompt
    for rel in paths:
        enriched_prompt = enriched_prompt.replace(rel, "the reference data provided below")
    return f"{enriched_prompt}\n\nReference data:\n" + "\n\n".join(chunks)


def score_task(task: Task, output_text: str) -> tuple[bool, dict[str, bool]]:
    txt = output_text.lower()
    contains_ok = all(tok.lower() in txt for tok in task.expected_contains)
    not_contains_ok = not any(tok.lower() in txt for tok in task.expected_not_contains)
    exact_ok = True if task.expected_exact is None else (output_text.strip() == task.expected_exact.strip())
    regex_ok = True if task.expected_regex is None else (
        re.search(task.expected_regex, output_text, re.MULTILINE | re.IGNORECASE) is not None
    )
    file_ok = True
    if task.verify_file_exists:
        vfe = task.verify_file_exists
        if vfe.startswith("/"):
            # Absolute path — use directly.
            candidates = [Path(vfe)]
        else:
            # Relative — check from paper_pipeline root and OpenClaw workspace.
            candidates = [ROOT / vfe]
            oc_home = os.environ.get("OPENCLAW_HOME", "")
            if oc_home:
                candidates.append(
                    Path(oc_home) / ".openclaw" / "workspace" / vfe
                )
        file_ok = any(c.exists() for c in candidates)
    # A verified file write is sufficient evidence of success even when the agent
    # produces an empty or non-standard acknowledgment string.
    text_ok = regex_ok or (task.verify_file_exists is not None and file_ok)
    passed = contains_ok and not_contains_ok and exact_ok and text_ok and file_ok
    return passed, {
        "contains_ok": contains_ok,
        "not_contains_ok": not_contains_ok,
        "exact_ok": exact_ok,
        "regex_ok": regex_ok,
        "file_ok": file_ok,
    }


def extract_last_json_blob(text: str) -> dict[str, Any] | None:
    # Strip markdown code fences (e.g. ```json\n{...}\n```) before parsing.
    cleaned = re.sub(r"```(?:json)?\s*", "", text).strip()
    for candidate in (cleaned, text):
        start = candidate.rfind("{")
        while start != -1:
            try:
                return json.loads(candidate[start:])
            except json.JSONDecodeError:
                start = candidate.rfind("{", 0, start)
    return None


def extract_answer_field(text: str) -> str:
    # Prefer explicit JSON answer contract; fallback to raw text.
    obj = extract_last_json_blob(text)
    if isinstance(obj, dict):
        ans = obj.get("answer")
        if isinstance(ans, str) and ans.strip():
            return ans.strip()
    return text.strip()


def extract_openclaw_payload_text(obj: dict[str, Any]) -> str:
    if isinstance(obj.get("payloads"), list):
        vals = [str(x.get("text", "")) for x in obj["payloads"] if isinstance(x, dict)]
        txt = "\n".join([v for v in vals if v]).strip()
        if txt:
            return txt

    if isinstance(obj.get("result"), dict) and isinstance(obj["result"].get("payloads"), list):
        vals = [str(x.get("text", "")) for x in obj["result"]["payloads"] if isinstance(x, dict)]
        txt = "\n".join([v for v in vals if v]).strip()
        if txt:
            return txt

    # fallback to summary-like fields if present
    for key in ("summary", "message", "text"):
        val = obj.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()

    return ""


def detect_tool_usage(raw: dict[str, Any], output_text: str) -> bool:
    # Use raw telemetry only to avoid false positives from plain-language words.
    haystack = json.dumps(raw, ensure_ascii=False).lower()
    markers = [
        "tool_call",
        "function_call",
        "tools/invoke",
        "run_in_terminal",
        "apply_patch",
    ]
    return any(tok in haystack for tok in markers)


def estimate_reasoning_steps(adapter: str, raw: dict[str, Any], output_text: str) -> int:
    if adapter == "ollama_native":
        return 1

    haystack = (json.dumps(raw, ensure_ascii=False) + "\n" + output_text).lower()
    markers = [
        "tool_call",
        "function_call",
        "iteration",
        "step",
        "thinking",
        "reasoning",
    ]
    count = sum(haystack.count(tok) for tok in markers)
    # Keep this as a stable, bounded proxy metric.
    return max(1, min(20, 1 + count))


def call_ollama_native(config: dict[str, Any], prompt: str) -> tuple[str, dict[str, Any]]:
    payload = {
        "model": config["model"],
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "think": False,
        "options": {
            "temperature": config.get("temperature", 0.2),
            "think": False,
        },
    }
    req = request.Request(
        config["base_url"],
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with request.urlopen(req, timeout=int(config.get("request_timeout_sec", 420))) as resp:
            body = resp.read().decode("utf-8")
    except url_error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        raise RuntimeError(f"Ollama HTTP {exc.code}: {details}") from exc

    obj = json.loads(body)
    txt = obj.get("message", {}).get("content", "")
    return extract_answer_field(str(txt)), obj


def call_openclaw_docker(prompt: str, session_id: str, agent_id: str = "main", no_deps: bool = False) -> tuple[str, dict[str, Any], str, str, int]:
    docker_cmd = os.environ.get("OPENCLAW_DOCKER_CMD", "docker")
    run_mode = os.environ.get("OPENCLAW_DOCKER_RUN_MODE", "compose")
    base = shlex.split(docker_cmd)

    if run_mode == "host":
        root = Path(__file__).resolve().parents[2]
        openclaw_token = os.environ.get("OPENCLAW_GATEWAY_TOKEN", "")
        cmd = [
            *base,
            "run",
            "--rm",
            "--network",
            "host",
            "-e",
            "OPENCLAW_HOME=/home/node/.openclaw",
            "-e",
            "OPENCLAW_STATE_DIR=/home/node/.openclaw",
            "-e",
            "OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json",
            "-e",
            f"OPENCLAW_GATEWAY_TOKEN={openclaw_token}",
            "-v",
            f"{root / 'state' / 'openclaw'}:/home/node/.openclaw",
            "-v",
            f"{root / 'workspace'}:/home/node/.openclaw/workspace",
            "ghcr.io/openclaw/openclaw:latest",
            "openclaw",
            "agent",
            "--agent",
            agent_id,
            "--session-id",
            session_id,
            "--message",
            prompt,
            "--json",
        ]
    else:
        cmd = [
            *base,
            "compose",
            "run",
            "--rm",
        ]
        if no_deps:
            cmd.append("--no-deps")
        cmd += [
            "openclaw-cli",
            "agent",
            "--agent",
            agent_id,
            "--session-id",
            session_id,
            "--message",
            prompt,
            "--json",
        ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    stdout = proc.stdout or ""
    stderr = proc.stderr or ""

    obj = extract_last_json_blob(stdout)
    if obj is None:
        obj = {"status": "error", "error": "JSON parse failed", "stdout": stdout[-4000:]}
        # Fallback for non-JSON cli output (some environments print plain text)
        return extract_answer_field(stdout), obj, stdout, stderr, proc.returncode

    txt = extract_openclaw_payload_text(obj)
    txt = extract_answer_field(txt)
    return txt, obj, stdout, stderr, proc.returncode


def call_openclaw_host(prompt: str, session_id: str, agent_id: str = "main") -> tuple[str, dict[str, Any], str, str, int]:
    cmd = [
        "openclaw",
        "agent",
        "--agent",
        agent_id,
        "--session-id",
        session_id,
        "--message",
        prompt,
        "--json",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    stdout = proc.stdout or ""
    stderr = proc.stderr or ""

    obj = extract_last_json_blob(stdout)
    if obj is None:
        obj = {"status": "error", "error": "JSON parse failed", "stdout": stdout[-4000:]}
        # Fallback for non-JSON cli output (some environments print plain text)
        return extract_answer_field(stdout), obj, stdout, stderr, proc.returncode

    txt = extract_openclaw_payload_text(obj)
    txt = extract_answer_field(txt)
    return txt, obj, stdout, stderr, proc.returncode


def run_task(task: Task, cfg: dict[str, Any], run_nonce: str) -> dict[str, Any]:
    adapter = cfg["adapter"]
    # Disable thinking tokens only for C1 (ollama_native). C2/C3 need reasoning to invoke tools.
    prompt = build_prompt(cfg.get("system_prefix", ""), task, disable_thinking=(adapter == "ollama_native"))
    prompt = apply_runtime_guards(prompt, cfg)
    start = time.time()
    error = None
    output_text = ""
    raw: dict[str, Any] = {}

    try:
        # C1 (ollama_native) is a raw-model baseline with no file access, no tools, no memory.
        # Only enrich prompts for OpenClaw adapters that have real file-access capability.
        if adapter != "ollama_native":
            prompt = enrich_prompt_with_local_data(task, prompt, allow_tool_tasks=False)
        if adapter == "ollama_native":
            output_text, obj = call_ollama_native(cfg, prompt)
            raw = {"response": obj}
        elif adapter == "openclaw_docker_cli":
            agent_id = "main"

            if cfg.get("forbid_memory") and os.environ.get("OPENCLAW_AGENT_MODE", "docker") == "host":
                # Stateless reset: wipe session files AND all memory stores so C2
                # cannot carry state across tasks.
                oc_home = Path(os.environ.get("OPENCLAW_HOME", ""))
                sess_dir = oc_home / "agents" / agent_id / "sessions"
                if sess_dir.exists() and sess_dir.is_dir():
                    for p in sess_dir.glob("*"):
                        if p.is_file():
                            p.unlink(missing_ok=True)
                # Clear SQLite memory store so stored values don't leak between tasks.
                mem_db = oc_home / "memory" / "main.sqlite"
                if mem_db.exists():
                    try:
                        con = sqlite3.connect(str(mem_db))
                        cur = con.cursor()
                        cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
                        for (tbl,) in cur.fetchall():
                            try:
                                cur.execute(f'DELETE FROM "{tbl}"')
                            except Exception:  # noqa: BLE001
                                pass  # Skip virtual/special tables (e.g. FTS shadow tables)
                        con.commit()
                        con.close()
                    except Exception:  # noqa: BLE001
                        pass  # Non-fatal; memory may already be empty
                # Clear OpenClaw workspace memory files (Markdown memory store).
                # OpenClaw writes long-term memories to MEMORY.md and memory/*.md files
                # in the workspace; these must also be wiped for true stateless isolation.
                # Use rmtree to catch nested subdirectories (e.g. deep absolute-path echoes).
                import shutil
                ws = oc_home / ".openclaw" / "workspace"
                memory_md = ws / "MEMORY.md"
                if memory_md.exists():
                    memory_md.write_text("# Long-Term Memory\n", encoding="utf-8")
                # Wipe the whole memory/ tree, then recreate the directory.
                ws_mem_dir = ws / "memory"
                if ws_mem_dir.exists():
                    shutil.rmtree(ws_mem_dir, ignore_errors=True)
                ws_mem_dir.mkdir(parents=True, exist_ok=True)
                # Also wipe date-named or project note files at workspace root.
                for p in ws.glob("*.md"):
                    if p.name not in {
                        "MEMORY.md", "AGENTS.md", "BOOTSTRAP.md", "HEARTBEAT.md",
                        "IDENTITY.md", "SOUL.md", "TOOLS.md", "USER.md",
                    }:
                        try:
                            p.unlink(missing_ok=True)
                        except Exception:  # noqa: BLE001
                            pass

            if cfg.get("session_mode") == "persistent":
                # Per-task session ID: each task gets a fresh chat context so
                # prior tool-call traces don't contaminate later tasks.
                # On-disk memory (MEMORY.md, SQLite) still accumulates across
                # tasks within the rep, so T7→T8 and T9→T10 memory recall works.
                sid = f"paper-{task.task_id}-{run_nonce}"
            else:
                sid = f"paper-{task.task_id}-{uuid.uuid4().hex[:8]}"
            if os.environ.get("OPENCLAW_AGENT_MODE", "docker") == "host":
                output_text, obj, stdout, stderr, rc = call_openclaw_host(prompt, sid, agent_id)
            else:
                output_text, obj, stdout, stderr, rc = call_openclaw_docker(
                    prompt,
                    sid,
                    agent_id,
                    bool(cfg.get("docker_no_deps", False)),
                )
            raw = {
                "session_id": sid,
                "agent_id": agent_id,
                "response": obj,
                "returncode": rc,
                "stdout_tail": stdout[-4000:],
                "stderr_tail": stderr[-2000:],
            }
            if rc != 0 and not output_text.strip():
                error = f"OpenClaw agent command failed (rc={rc}): {stderr[-400:].strip()}"
            elif isinstance(obj, dict) and obj.get("status") == "error":
                error = f"OpenClaw response parse failed: {obj.get('error', 'unknown error')}"
        else:
            raise ValueError(f"Unsupported adapter: {adapter}")
    except Exception as exc:  # noqa: BLE001
        error = str(exc)

    latency_ms = int((time.time() - start) * 1000)
    observed_tool_use = detect_tool_usage(raw, output_text)
    reasoning_steps = estimate_reasoning_steps(adapter, raw, output_text)

    if cfg.get("forbid_tools") and cfg.get("enforce_no_tool_violation", False) and observed_tool_use and error is None:
        error = "Strict mode violation: tool usage detected while forbid_tools=true"

    if cfg.get("forbid_memory") and cfg.get("session_mode") == "persistent" and error is None:
        error = "Invalid config: forbid_memory=true with persistent session_mode"

    success, score = (False, {"contains_ok": False, "exact_ok": False, "regex_ok": False})
    if error is None:
        success, score = score_task(task, output_text)

    return {
        "task_id": task.task_id,
        "category": task.category,
        "adapter": adapter,
        "prompt": prompt,
        "expected_contains": task.expected_contains,
        "expected_exact": task.expected_exact,
        "expected_regex": task.expected_regex,
        "output_text": output_text,
        "score": score,
        "success": success,
        "error": error,
        "latency_ms": latency_ms,
        "reasoning_steps": reasoning_steps,
        "observed_tool_use": observed_tool_use,
        "tool_call_accuracy": None if not task.requires_tools else (1.0 if success else 0.0),
        "memory_recall_accuracy": None if not task.requires_memory else (1.0 if success else 0.0),
        "raw": raw,
    }


def summarize(results: list[dict[str, Any]]) -> dict[str, Any]:
    n = len(results)
    passed = sum(1 for x in results if x["success"])
    avg_latency = int(sum(x["latency_ms"] for x in results) / n) if n else 0
    avg_reasoning = round(sum(x.get("reasoning_steps", 1) for x in results) / n, 2) if n else 0.0

    tools = [x for x in results if x["tool_call_accuracy"] is not None]
    mems = [x for x in results if x["memory_recall_accuracy"] is not None]

    tool_acc = round(sum(x["tool_call_accuracy"] for x in tools) / len(tools), 3) if tools else None
    mem_acc = round(sum(x["memory_recall_accuracy"] for x in mems) / len(mems), 3) if mems else None

    per_category: dict[str, dict[str, Any]] = {}
    for r in results:
        c = r["category"]
        per_category.setdefault(c, {"total": 0, "passed": 0})
        per_category[c]["total"] += 1
        per_category[c]["passed"] += 1 if r["success"] else 0

    for c in per_category:
        total = per_category[c]["total"]
        per_category[c]["success_rate"] = round(per_category[c]["passed"] / total, 3) if total else 0.0

    return {
        "total_tasks": n,
        "passed_tasks": passed,
        "task_success_rate": round(passed / n, 3) if n else 0.0,
        "avg_latency_ms": avg_latency,
        "avg_reasoning_steps": avg_reasoning,
        "tool_call_accuracy": tool_acc,
        "memory_recall_accuracy": mem_acc,
        "per_category": per_category,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Run benchmark for one config")
    parser.add_argument("--config", required=True)
    parser.add_argument("--runs-dir", default=None, help="Directory to write run JSON (default: paper_pipeline/runs)")
    parser.add_argument("--label", default=None)
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--run-group", default=None)
    parser.add_argument("--rep", type=int, default=None)
    args = parser.parse_args()

    cfg_path = Path(args.config).resolve()
    cfg = load_json(cfg_path)

    # Env model override for flexible model sweeps (e.g., Gemma).
    if os.getenv("PAPER_MODEL_OVERRIDE"):
        cfg["model"] = os.environ["PAPER_MODEL_OVERRIDE"]

    tasks = load_tasks(args.limit)
    run_nonce = uuid.uuid4().hex[:6]

    runs_dir = Path(args.runs_dir).resolve() if args.runs_dir else RUNS_DIR
    runs_dir.mkdir(parents=True, exist_ok=True)

    results = [run_task(t, cfg, run_nonce) for t in tasks]
    summary = summarize(results)

    ts = int(time.time())
    label = args.label or cfg.get("id", "run")
    out_path = runs_dir / f"run_{ts}_{label}.json"

    payload = {
        "timestamp": ts,
        "config_id": cfg.get("id", "unknown"),
        "config_path": str(cfg_path),
        "run_group": args.run_group,
        "rep": args.rep,
        "summary": summary,
        "results": results,
    }

    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(json.dumps({"output": str(out_path), "summary": summary}, indent=2))


if __name__ == "__main__":
    main()
