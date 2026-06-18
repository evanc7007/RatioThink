"""HONEST 'before' baseline (#657 step 2): the SHIPPED wasm tree-of-thought.

This measures what users get TODAY — the production product path — by driving
the checked-in `chat-apc.wasm` tree-of-thought inferlet through the real daemon
``POST /v1/inferlet`` endpoint (NOT the Python `tot_search` harness), on the
SAME engine/model (Qwen3-8B portable/metal) and the SAME prompts as the faithful
matrix, then grading the selected leaf with the SAME deterministic oracle
(`grade.py`). It is the contrast the redesign exists to justify: the shipped
inferlet selects with a single LLM value-judge — including LLM-judging CODE
instead of executing it — so the code rows are expected to trail the faithful
harness (which execute-ranks code). #679 (KV-drop free + starvation guard) is
what lets the thinking-ON gsm8k row run at all on this path.

Reuses `tot_accuracy_real`'s engine boot + config + prompt loader verbatim; the
only new thing is the per-prompt ``/v1/inferlet`` tree-of-thought call and its
event-stream parse to the selected ``final_answer``. Knobs match the credible
matrix: WIDTH=4 (breadth + beam_width), math/code depth=2.

Run::

    MAX_PROMPTS=5 MATH_DEPTH=2 CODE_DEPTH=2 \
      uv run --project Vendor/pie/client/python --with httpx --with jsonschema \
      python Inferlets/chat-apc/tot_wasm_before.py
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import httpx
from pie_client import PieClient

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import e2e_test as h  # noqa: E402  boot/teardown + PIE_BIN/WASM_PATH/MANIFEST_PATH
import grade as g  # noqa: E402  the deterministic accuracy oracle
import tot_accuracy_real as base  # noqa: E402  boot config + MODEL + prompt loader

WIDTH = int(os.environ.get("TOT_WIDTH", "4"))          # breadth + beam_width (keep-b)
MATH_DEPTH = int(os.environ.get("MATH_DEPTH", "2"))
CODE_DEPTH = int(os.environ.get("CODE_DEPTH", "2"))
MAX_TOKENS_PER_NODE = int(os.environ.get("MAX_TOKENS", "512"))
# gsm8k = the decisive math row; one code row (humaneval, matching the matrix's
# strongest faithful ToT lift) makes the LLM-judge-vs-execute gap concrete.
DATASETS = os.environ.get("DATASETS", "gsm8k,humaneval").split(",")
# Task mode sent to the shipped inferlet. "chat" (default) = the honest BEFORE
# (whole-answer + single greedy judge); "reasoning" = the #657 math arm
# (value×N-median + partial-step decomposition) — the AFTER re-measure.
TASK = os.environ.get("TASK", "chat")
OUT = os.environ.get("WASM_BEFORE_OUT", "tot_wasm_before.json")
# Tree-dump mode (#657 mechanism analysis): when set, every prompt's FULL tree
# (each node's id/depth/score/status/content + selected + synthesized answer) is
# appended to DUMP_OUT as JSONL, so the gap can be decomposed offline: was a
# correct answer in the tree but not selected (selection/synthesis loss) vs
# never generated (decomposition loss), branch variation, score spread, etc.
DUMP_TREE = os.environ.get("DUMP_TREE") == "1"
DUMP_OUT = os.environ.get("DUMP_OUT", "tot_tree_dump.jsonl")
# Restrict the run to specific 1-based prompt indices (into the SAME records the
# full run loads), so the mechanism dump targets only the divergent prompts
# instead of re-running all 30. Empty = all. e.g. PROMPT_INDICES="1,5,6,9".
PROMPT_INDICES = {int(x) for x in os.environ.get("PROMPT_INDICES", "").split(",") if x.strip()}
_FAITHFUL = {"gsm8k": 0.750, "humaneval": 1.000, "mbpp": 0.800}  # ToT col, credible matrix


def _depth_for(family: str) -> int:
    return MATH_DEPTH if family == "math" else CODE_DEPTH


async def _tot_once(http_c: httpx.AsyncClient, base_url: str, prompt: str,
                    depth: int) -> tuple[str, dict]:
    """One shipped-wasm ToT search via /v1/inferlet. Returns (final_answer,
    diag). diag carries the streamed node/terminal shape so a degenerate tree
    (no selected answer, error terminal) is disclosed, not silently scored 0."""
    r = await http_c.post(
        f"{base_url}/v1/inferlet",
        json={
            "inferlet": "tree-of-thought",
            "stream": True,
            "input": {
                "messages": [{"role": "user", "content": prompt}],
                "breadth": WIDTH, "depth": depth, "beam_width": WIDTH,
                "max_tokens_per_node": MAX_TOKENS_PER_NODE,
                "task": TASK,
            },
        },
    )
    if r.status_code != 200:
        return "", {"error": f"status {r.status_code}: {r.text[:200]}"}
    events = []
    for line in r.text.splitlines():
        if not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if payload and payload != "[DONE]":
            events.append(json.loads(payload))
    term = events[-1] if events else {}
    kinds = [e.get("event") for e in events]
    ok_nodes = sum(1 for e in events if e.get("event") == "node_complete"
                   and (e.get("node") or {}).get("status") == "ok"
                   and ((e.get("node") or {}).get("content") or "").strip())
    diag = {"terminal": term.get("event"), "selected": term.get("selected_node_id"),
            "ok_nodes": ok_nodes, "n_frames": len(kinds)}
    if term.get("event") != "tree_complete":
        diag["error"] = f"terminal={term.get('event')!r} (no tree_complete)"
    if DUMP_TREE:
        # Capture the full tree for offline mechanism analysis. node_complete
        # carries node.{id,depth,branch_index,score,status,content}.
        nodes = []
        for e in events:
            if e.get("event") != "node_complete":
                continue
            nd = e.get("node") or {}
            nodes.append({k: nd.get(k) for k in
                          ("id", "depth", "branch_index", "score", "status", "content")})
        diag["nodes"] = nodes
        diag["final_answer"] = term.get("final_answer") or ""
    return term.get("final_answer") or "", diag


async def _run_dataset(http_c, base_url, key, grader):
    family = base.FAMILY[key] if hasattr(base, "FAMILY") else \
        {"gsm8k": "math", "humaneval": "code", "mbpp": "code"}[key]
    depth = _depth_for(family)
    records, total = base._load_prompts(key)
    print(f"[wasm-before] dataset={key!r} family={family} grader={grader!r} "
          f"shipped-wasm ToT breadth={WIDTH} depth={depth} beam={WIDTH} "
          f"measuring {len(records)}/{total}", flush=True)
    correct = graded = errored = 0
    first_error = None
    loop = asyncio.get_event_loop()
    for i, rec in enumerate(records, 1):
        if PROMPT_INDICES and i not in PROMPT_INDICES:
            continue  # mechanism dump: only the requested (e.g. divergent) prompts
        t0 = loop.time()
        ans, diag = await _tot_once(http_c, base_url, rec["prompt"], depth)
        dt = loop.time() - t0
        if diag.get("error"):
            errored += 1
            first_error = first_error or diag["error"]
            verdict = "ERR"
        else:
            res = g.grade(grader, ans, rec["reference"])
            if res.passed is None:
                verdict = "ungradable"
            else:
                graded += 1
                correct += 1 if res.passed else 0
                verdict = "PASS" if res.passed else "fail"
        print(f"[wasm-before]   {key} {i}/{len(records)} {verdict} "
              f"sel={diag.get('selected')!r} ok_nodes={diag.get('ok_nodes')} "
              f"{dt:.0f}s", flush=True)
        if DUMP_TREE and "nodes" in diag:
            rec_out = {"dataset": key, "index": i, "prompt": rec["prompt"],
                       "reference": rec["reference"], "grader": grader,
                       "final_verdict": verdict, "selected": diag.get("selected"),
                       "final_answer": diag.get("final_answer"), "nodes": diag["nodes"]}
            with open(DUMP_OUT, "a") as fh:
                fh.write(json.dumps(rec_out) + "\n")
    acc = (correct / graded) if graded else None
    return {"dataset": key, "family": family, "grader": grader, "depth": depth,
            "graded": graded, "correct": correct, "errored": errored,
            "accuracy": acc, "first_error": first_error}


async def _run(base_url: str) -> dict:
    lock = json.loads(base.LOCK_PATH.read_text())
    rows = []
    async with httpx.AsyncClient(timeout=600) as http_c:
        for key in DATASETS:
            grader = lock["datasets"][key]["grader"]
            rows.append(await _run_dataset(http_c, base_url, key, grader))
    return {"model": base.MODEL, "width": WIDTH, "task": TASK, "rows": rows}


def _print(artifact: dict) -> None:
    print("\n" + "=" * 78)
    label = "AFTER (math arm)" if TASK == "reasoning" else "honest BEFORE"
    print(f"SHIPPED wasm ToT — {label} — task={TASK!r} — "
          f"{artifact['model']} (breadth={WIDTH})")
    print("=" * 78)
    print(f"{'dataset':11} {'cover':>8} {'wasm-ToT':>9} {'faithful':>9} {'gap':>7}")
    print("-" * 78)
    for r in artifact["rows"]:
        w = r["accuracy"]
        f = _FAITHFUL.get(r["dataset"])
        gap = (w - f) if (w is not None and f is not None) else None
        cover = f"{r['graded']}/{r['graded'] + r['errored']}"
        print(f"{r['dataset']:11} {cover:>8} "
              f"{('--' if w is None else f'{w:.3f}'):>9} "
              f"{('--' if f is None else f'{f:.3f}'):>9} "
              f"{('--' if gap is None else f'{gap:+.3f}'):>7}")
        if r["first_error"]:
            print(f"            first_error: {r['first_error']}")
    print("-" * 78)
    print("wasm-ToT = SHIPPED inferlet (LLM value-judge select, code NOT executed). "
          "faithful = Python harness ToT (execute-rank code). gap = wasm - faithful.")


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()
    with tempfile.TemporaryDirectory(prefix="tw-", dir="/tmp") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(base.CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {**os.environ, "PIE_HOME": str(pie_home),
               "PIE_SHMEM_NAME": f"/tot_wasm_before_{os.getpid()}"}
        proc = subprocess.Popen(
            [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
            bufsize=1,
        )
        try:
            ws_addr, token = await h._parse_handshake(proc, timeout=300)
            print(f"[wasm-before] engine ws=ws://{ws_addr}")
            drain = asyncio.create_task(h._drain_stdout(proc))
            try:
                client = PieClient(f"ws://{ws_addr}")
                await client.connect()
                await client.auth_by_token(token)
                await client.install_program(h.WASM_PATH, h.MANIFEST_PATH,
                                             force_overwrite=True)
                port = h._free_port()
                base_url = f"http://127.0.0.1:{port}"
                await client.launch_daemon("chat-apc@0.1.0", port)
                if not h._wait_for_port(port, timeout=30):
                    raise RuntimeError(f"daemon never bound port {port}")
                artifact = await _run(base_url)
            finally:
                drain.cancel()
        finally:
            h._terminate_subprocess(proc, "engine")
    Path(OUT).write_text(json.dumps(artifact, indent=2))
    _print(artifact)
    print(f"\n[wasm-before] artifact -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
