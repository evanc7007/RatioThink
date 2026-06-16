"""ToT task-ACCURACY matrix: single-chain CoT vs ToT(width=k, depth=1) (#657).

Extends the #652 spec-decode benefit matrix from a throughput-only axis to a
graded CORRECTNESS axis. Where `spec_matrix_real.py` asks "does n-gram drafting
make this workload faster", this harness asks "does exploring k sibling chains
and value-selecting the best one make the model more ACCURATE than a single CoT
chain" — on the four deterministically-gradable PUBLIC pinned datasets (GSM8K,
HumanEval, MBPP, JSONSchemaBench). It reuses the #652 prep/lock/gitignore pin
infrastructure (`Scripts/benchmark`) and the engine bootstrap from `e2e_test`.

ISOLATING WIDTH. Both columns go through the SAME `/v1/inferlet`
tree-of-thought endpoint and the SAME final-answer extraction, so the ONLY thing
that changes between them is the search width:

  * single  — breadth=1, depth=1, temperature=0 (greedy). One CoT chain, taken
              as-is. This is the canonical single-chain CoT baseline:
              deterministic and reproducible.
  * tot      — breadth=k, depth=1, temperature>0 (sampled). k sibling chains,
              each value-scored 1–10 by the model, the best selected as the
              final answer (Yao et al. ToT, restricted to one level).

A width>1 search needs temperature>0 or the k greedy branches would be
byte-identical and the search would be a no-op (#555/#523 diversity finding);
the single-chain baseline stays greedy because greedy IS the canonical CoT
baseline. The temperatures are therefore intentionally different and disclosed
in the artifact, not hidden. The tot column is consequently STOCHASTIC: its
accuracy varies run-to-run. The grading is deterministic; the generation is not.

DEPTH=1 ONLY (the ticket's scope). depth>1 is blocked on #647/#649 — a depth>1
search returned empty/zero-reasoning final-depth nodes (e2e-tot red), so
measuring accuracy through it would grade garbage. depth>1 is an explicit
follow-up once that path is fixed.

PER-CELL METRICS (per dataset × column):
  * accuracy            = correct / graded   (graded = correct + wrong; an
                          ungradable run — empty output, no extractable answer —
                          is held OUT of the denominator, never scored wrong)
  * n_correct / n_wrong / n_ungradable / n_error (non-200)
  * output tokens       = Σ tokenizer tokens over every generated node
                          (content + reasoning) — counted ONLY for graded runs,
                          the same population as accuracy, so the per-token
                          efficiency numbers can't be skewed by a column's
                          ungradable rate; the value-scoring decode is internal
                          and not counted — both disclosed, not hidden
  * wall seconds        = end-to-end per prompt (graded runs only, as above)
  * accuracy_per_ktok   = accuracy ÷ (mean output tokens / 1000): the
                          accuracy-per-token axis the ticket asks for, numerator
                          and denominator over the same graded subset
The row summary reports the ToT−single accuracy DELTA and the token-cost ratio,
so "did width help, and at what token cost" is answered directly.

NO-CHERRYPICK / COVERAGE. The prompt set is the FULL pinned split (datasets.lock
content_sha256); a split too large to run end-to-end is bounded ONLY at
measurement time by `MAX_PROMPTS` over the canonical-ordered prefix, and the
per-row `coverage` field records `measured / total`. Emission stays full.

CODE EXECUTION WARNING: HumanEval/MBPP grading executes model-generated Python
in a subprocess (see grade.py). This is why the bench is operator-gated, never
CI; the CI guard is the engine-free `tot_accuracy_real_test.py`.

Requires: built portable-Metal `Vendor/pie/target/release/pie`, the chat-apc
wasm + stamp, a real model WITH WEIGHTS, the prep scripts run so
`Scripts/benchmark/data/<key>.jsonl` exists, and `jsonschema` for the structured
row. Run via `Scripts/run-tot-accuracy.sh` (self-bootstraps all of these).

Usage::

    MODEL=Qwen/Qwen3-8B MAX_TOKENS=512 MAX_PROMPTS=12 TOT_WIDTH=4 \
      uv run --project Vendor/pie/client/python --with httpx --with jsonschema \
        --with tokenizers --with huggingface_hub \
        python Inferlets/chat-apc/tot_accuracy_real.py
"""
from __future__ import annotations

import asyncio
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx
from pie_client import PieClient

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import e2e_test as h  # noqa: E402  boot/teardown + PIE_BIN/WASM_PATH/MANIFEST_PATH
import grade as g  # noqa: E402  deterministic per-dataset graders

MODEL = os.environ.get("MODEL", "Qwen/Qwen3-8B")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "512"))
MAX_PROMPTS = int(os.environ.get("MAX_PROMPTS", "12"))  # 0 → whole split
TOT_WIDTH = int(os.environ.get("TOT_WIDTH", "4"))  # k for the ToT column
TOT_TEMPERATURE = float(os.environ.get("TOT_TEMPERATURE", "0.7"))
# Single-chain decode temperature. Default 0.0 = greedy CoT (the canonical
# baseline; keeps the module docstring's "single is deterministic" framing).
# Set it equal to TOT_TEMPERATURE to ISOLATE search width as the only variable
# (single = best-of-1 sample, tot = best-of-k samples, identical temperature) —
# separating "did width help" from "did sampling vs greedy move the number".
SINGLE_TEMPERATURE = float(os.environ.get("SINGLE_TEMPERATURE", "0.0"))
ACCURACY_OUT = os.environ.get(
    "ACCURACY_OUT", f"tot_accuracy_{MODEL.replace('/', '__')}.json"
)
_REPO_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = _REPO_ROOT / "Scripts" / "benchmark" / "data"
LOCK_PATH = _REPO_ROOT / "Scripts" / "benchmark" / "datasets.lock"

# The two columns. Both run through tree-of-thought; only `breadth`/`temperature`
# differ (see module docstring). depth/beam are fixed at the single-level shape.
COLUMNS = {
    "single": {"breadth": 1, "temperature": SINGLE_TEMPERATURE},
    "tot": {"breadth": TOT_WIDTH, "temperature": TOT_TEMPERATURE},
}

CONFIG_TOML = f"""
[server]
host = "127.0.0.1"
port = 0

[auth]
enabled = false

[telemetry]
enabled = false

[runtime]
allow_fs = false
allow_network = true

[[model]]
name = "{MODEL}"
hf_repo = "{MODEL}"

[model.scheduler]
batch_policy = "adaptive"
request_timeout_secs = 600
default_endowment_pages = 4
admission_oversubscription_factor = 8.0
restore_pause_at_utilization = 0.85

[model.driver]
type = "portable"
device = ["metal"]
"""


def _load_tokenizer():
    """Real token counter for the SERVED model (so the per-token axis uses the
    model's own tokenization). Falls back to a labeled whitespace proxy if the
    tokenizer can't be fetched, so the report never passes a proxy off as real
    tokens."""
    try:
        from huggingface_hub import hf_hub_download
        from tokenizers import Tokenizer

        path = hf_hub_download(MODEL, "tokenizer.json")
        tok = Tokenizer.from_file(path)
        return (lambda s: len(tok.encode(s).ids), "tokens")
    except Exception as e:  # noqa: BLE001
        print(f"[accuracy] tokenizer unavailable ({e}); using word-count proxy",
              flush=True)
        return (lambda s: len(s.split()), "words(proxy)")


def _which_datasets() -> list[str]:
    """Graded datasets only (those carrying a `grader` in the lock), intersected
    with an optional DATASETS allow-list. An ungraded request is a hard error so
    a typo can't silently drop a row."""
    lock = json.loads(LOCK_PATH.read_text()) if LOCK_PATH.exists() else {"datasets": {}}
    graded = {k: v for k, v in lock.get("datasets", {}).items() if v.get("grader")}
    sel = os.environ.get("DATASETS")
    if sel:
        want = [s.strip() for s in sel.split(",") if s.strip()]
        missing = [w for w in want if w not in graded]
        if missing:
            raise SystemExit(
                f"requested datasets not graded/locked: {missing}; "
                f"graded: {sorted(graded)}"
            )
        return want
    return sorted(graded)


def _grader_for(key: str) -> str:
    lock = json.loads(LOCK_PATH.read_text())
    return lock["datasets"][key]["grader"]


def _load_prompts(key: str) -> tuple[list[dict], int]:
    path = DATA_DIR / f"{key}.jsonl"
    if not path.exists():
        raise SystemExit(
            f"missing prompt set {path} — run Scripts/benchmark/prep_{key}.sh first"
        )
    records = [json.loads(line) for line in path.read_text().splitlines() if line]
    total = len(records)
    if MAX_PROMPTS > 0:
        records = records[:MAX_PROMPTS]
    missing_ref = [r["id"] for r in records if "reference" not in r]
    if missing_ref:
        raise SystemExit(
            f"{key}: {len(missing_ref)} records lack a `reference` — re-run "
            f"prep_{key}.sh after the #657 prep change (e.g. {missing_ref[:3]})"
        )
    return records, total


def _walk(node: dict) -> list:
    out = [node]
    for c in node.get("children", []) or []:
        out.extend(_walk(c))
    return out


def _count_tree_tokens(body: dict, count) -> int:
    total = 0
    for n in _walk(body.get("root") or {}):
        if n.get("id") == "root":
            continue
        total += count(n.get("content") or "") + count(n.get("reasoning") or "")
    return total


async def _tot_run(http_c, base, prompt, think, breadth, temperature) -> dict:
    """One greedy/sampled tree-of-thought search at depth 1; returns the final
    answer string, the generated-token count, and the wall time. A non-200 (a
    total branch failure returns 500) — OR a transport-level failure (the wasm
    daemon trapping/closing the socket mid-search, surfacing as an httpx
    RemoteProtocolError/ConnectError) — is surfaced as an errored run, not
    silently scored as a wrong answer and NOT allowed to abort the whole matrix.
    Recording it as `status=0` keeps the failure fully disclosed (it lands in the
    cell's n_error and the run-level failures list, forcing a non-zero verdict)
    while letting the remaining prompts/datasets still produce numbers and
    pin-pointing exactly where the daemon died."""
    payload = {
        "inferlet": "tree-of-thought",
        "stream": False,
        "input": {
            "messages": [{"role": "user", "content": prompt}],
            "breadth": breadth,
            "depth": 1,
            "beam_width": 1,
            "max_tokens_per_node": MAX_TOKENS,
            "temperature": temperature,
            "top_p": 1.0 if temperature == 0.0 else 0.95,
            "thinking": bool(think),
        },
    }
    t0 = time.perf_counter()
    try:
        r = await http_c.post(f"{base}/v1/inferlet", json=payload)
    except httpx.HTTPError as e:
        # Daemon dropped the connection / never replied. Disclosed, not fatal.
        return {"status": 0, "error_body": f"{type(e).__name__}: {e}",
                "wall_s": time.perf_counter() - t0}
    wall_s = time.perf_counter() - t0
    if r.status_code != 200:
        return {"status": r.status_code, "error_body": r.text[:400], "wall_s": wall_s}
    return {"status": 200, "body": r.json(), "wall_s": wall_s}


async def _bench_dataset(http_c, base, key, grader, records, total, count, failures) -> dict:
    print(f"\n[accuracy] dataset={key!r} grader={grader!r} "
          f"measuring {len(records)}/{total} prompts")
    cells: dict[str, dict] = {}
    for col, cfg in COLUMNS.items():
        graded_pass = 0
        graded_fail = 0
        ungradable = 0
        errored = 0
        tokens: list[int] = []
        walls: list[float] = []
        for idx, rec in enumerate(records):
            run = await _tot_run(
                http_c, base, rec["prompt"], bool(rec.get("think")),
                cfg["breadth"], cfg["temperature"],
            )
            if run["status"] != 200:
                errored += 1
                failures.append(
                    f"[{key}[{idx}] {col}] /v1/inferlet -> {run['status']}: "
                    f"{run.get('error_body','')[:160]}"
                )
                continue
            body = run["body"]
            answer = (body.get("final_answer") or "").strip()
            verdict = g.grade(grader, answer, rec["reference"])
            if verdict.passed is None:
                # Ungradable (empty/no-extractable answer). Held out of BOTH the
                # accuracy denominator AND the token/wall samples, so every
                # per-token metric (mean_output_tokens, accuracy_per_ktok, the
                # cross-column token_cost_ratio) divides over the SAME graded
                # population the accuracy is computed on — no hidden mismatch
                # between a stochastic-tot ungradable rate and greedy single.
                ungradable += 1
                continue
            tokens.append(_count_tree_tokens(body, count))
            walls.append(run["wall_s"])
            if verdict.passed is True:
                graded_pass += 1
            else:
                graded_fail += 1
        graded = graded_pass + graded_fail
        mean_tok = statistics.mean(tokens) if tokens else None
        accuracy = (graded_pass / graded) if graded else None
        cells[col] = {
            "column": col,
            "breadth": cfg["breadth"],
            "temperature": cfg["temperature"],
            "n_correct": graded_pass,
            "n_wrong": graded_fail,
            "n_ungradable": ungradable,
            "n_error": errored,
            "n_graded": graded,
            "accuracy": accuracy,
            "mean_output_tokens": mean_tok,
            "total_output_tokens": sum(tokens) if tokens else 0,
            "mean_wall_s": statistics.mean(walls) if walls else None,
            "accuracy_per_ktok": (accuracy / (mean_tok / 1000.0))
            if (accuracy is not None and mean_tok) else None,
        }

    single, tot = cells["single"], cells["tot"]
    acc_delta = (
        tot["accuracy"] - single["accuracy"]
        if (tot["accuracy"] is not None and single["accuracy"] is not None) else None
    )
    token_ratio = (
        tot["mean_output_tokens"] / single["mean_output_tokens"]
        if (tot["mean_output_tokens"] and single["mean_output_tokens"]) else None
    )
    measured = len(records)
    return {
        "dataset": key,
        "grader": grader,
        "category": records[0].get("category") if records else None,
        "think": bool(records[0].get("think")) if records else None,
        "coverage": {
            "measured": measured, "total": total,
            "fraction": (measured / total) if total else None,
            "bounded_by": "MAX_PROMPTS" if (MAX_PROMPTS and measured < total) else "full",
        },
        "accuracy_delta_tot_minus_single": acc_delta,
        "token_cost_ratio_tot_over_single": token_ratio,
        "cells": cells,
    }


async def _run(base: str, count) -> tuple[dict, list[str]]:
    failures: list[str] = []
    rows = []
    async with httpx.AsyncClient(timeout=600) as http_c:
        for key in _which_datasets():
            grader = _grader_for(key)
            records, total = _load_prompts(key)
            if not records:
                failures.append(f"[{key}] no prompts after cap")
                continue
            rows.append(
                await _bench_dataset(http_c, base, key, grader, records, total, count, failures)
            )
    artifact = {
        "model": MODEL,
        "driver": "portable/metal",
        "decode_settings": {
            "max_tokens_per_node": MAX_TOKENS, "max_prompts": MAX_PROMPTS,
            "tot_width": TOT_WIDTH, "tot_temperature": TOT_TEMPERATURE,
            "single_temperature": SINGLE_TEMPERATURE, "depth": 1,
        },
        "columns": {
            "single": f"single-chain CoT: breadth=1, depth=1, temperature="
                      f"{SINGLE_TEMPERATURE}"
                      + (" (greedy, deterministic baseline)"
                         if SINGLE_TEMPERATURE == 0.0
                         else " (best-of-1 SAMPLE — width-isolation arm; STOCHASTIC)"),
            "tot": f"ToT width={TOT_WIDTH}, depth=1, temperature={TOT_TEMPERATURE} "
                   "(sampled k siblings, value-selected; STOCHASTIC)",
        },
        "out_of_scope": {
            "depth_gt_1": "blocked on #647/#649 (depth>1 final-depth nodes returned "
            "empty/zero-reasoning); measuring through it would grade garbage",
            "soft_metric_datasets": "CNN/DM (ROUGE proxy) + MT-Bench (LLM-judge) break "
            "the deterministic/PUBLIC/reproducible spirit — separate follow-up",
        },
        "token_accounting_caveat": "output tokens/wall are counted for GRADED runs "
        "only (the same population as accuracy), so accuracy_per_ktok and "
        "token_cost_ratio share one denominator and a column's ungradable rate "
        "cannot skew them; output tokens = Σ generated node content+reasoning, and "
        "the internal value-scoring decode is not counted (short, capped per #649).",
        "rows": rows,
    }
    return artifact, failures


def _print_matrix(artifact: dict, unit: str) -> None:
    print("\n" + "=" * 104)
    print(f"ToT accuracy matrix — {artifact['model']} ({artifact['driver']})")
    ds = artifact["decode_settings"]
    print(f"single=greedy CoT (b1) vs tot=ToT(width={ds['tot_width']}, depth=1, "
          f"temp={ds['tot_temperature']})  max_tokens/node={ds['max_tokens_per_node']} "
          f"max_prompts={ds['max_prompts']} (0=full)")
    print("=" * 104)
    hdr = (
        f"{'dataset':<11} {'grader':<18} {'cover':>9} "
        f"{'acc single':>10} {'acc tot':>8} {'Δacc':>7} "
        f"{f'{unit}/p single':>15} {f'{unit}/p tot':>13} {'tok×':>6} {'acc/ktok t':>11}"
    )
    print(hdr)
    print("-" * len(hdr))

    def f(x, fmt="{:.3f}"):
        return fmt.format(x) if isinstance(x, (int, float)) else "--"

    for r in artifact["rows"]:
        s, t = r["cells"]["single"], r["cells"]["tot"]
        cov = r["coverage"]
        print(
            f"{r['dataset']:<11} {r['grader']:<18} "
            f"{cov['measured']}/{cov['total']:<7} "
            f"{f(s['accuracy']):>10} {f(t['accuracy']):>8} "
            f"{f(r['accuracy_delta_tot_minus_single'],'{:+.3f}'):>7} "
            f"{f(s['mean_output_tokens'],'{:.0f}'):>15} "
            f"{f(t['mean_output_tokens'],'{:.0f}'):>13} "
            f"{f(r['token_cost_ratio_tot_over_single'],'{:.1f}'):>6} "
            f"{f(t['accuracy_per_ktok']):>11}"
        )
    print("-" * len(hdr))
    print("acc = correct/graded (ungradable held out of denominator); Δacc = tot−single; "
          "tok× = tot tokens ÷ single tokens; acc/ktok = accuracy per 1k output tokens.")
    print(f"\nToken accounting: {artifact['token_accounting_caveat']}")
    print("Out of scope:")
    for k, v in artifact["out_of_scope"].items():
        print(f"  • {k}: {v}")


async def main() -> int:
    assert h.PIE_BIN.exists(), f"missing pie binary at {h.PIE_BIN}"
    assert h.WASM_PATH.exists(), f"missing wasm at {h.WASM_PATH}"
    h.verify_stamp()
    if not LOCK_PATH.exists():
        raise SystemExit("no datasets.lock — run Scripts/benchmark/prep_all.sh first")

    count, unit = _load_tokenizer()

    # PIE_HOME under a SHORT /tmp dir, not the per-user $TMPDIR
    # (/var/folders/…, ~50 chars): the portable driver opens an aux_server unix
    # socket at $PIE_HOME/standalone/<pid>/g0/aux.sock, and the macOS sun_path
    # limit is 104 bytes — a $TMPDIR-nested home overflows it before the engine
    # can serve a single request.
    with tempfile.TemporaryDirectory(prefix="ta-", dir="/tmp") as tmp:
        tmp = Path(tmp)
        cfg = tmp / "config.toml"
        cfg.write_text(CONFIG_TOML)
        pie_home = tmp / "home"
        pie_home.mkdir()
        env = {
            **os.environ,
            "PIE_HOME": str(pie_home),
            "PIE_SHMEM_NAME": f"/tot_accuracy_{os.getpid()}",
        }
        proc = subprocess.Popen(
            [str(h.PIE_BIN), "serve", "--config", str(cfg), "--no-auth", "--debug"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
            bufsize=1,
        )
        try:
            ws_addr, token = await h._parse_handshake(proc, timeout=300)
            print(f"[accuracy] engine ws=ws://{ws_addr}")
            drain = asyncio.create_task(h._drain_stdout(proc))
            try:
                client = PieClient(f"ws://{ws_addr}")
                await client.connect()
                await client.auth_by_token(token)
                await client.install_program(
                    h.WASM_PATH, h.MANIFEST_PATH, force_overwrite=True
                )
                port = h._free_port()
                base = f"http://127.0.0.1:{port}"
                await client.launch_daemon("chat-apc@0.1.0", port)
                if not h._wait_for_port(port, timeout=30):
                    raise RuntimeError(f"daemon never bound port {port}")
                artifact, failures = await _run(base, count)
            finally:
                drain.cancel()
        finally:
            h._terminate_subprocess(proc, "engine")

    Path(ACCURACY_OUT).write_text(json.dumps(artifact, indent=2))
    _print_matrix(artifact, unit)
    print(f"\n[accuracy] machine-readable artifact -> {ACCURACY_OUT}")

    if failures:
        print("\n[accuracy] CONTRACT/MEASUREMENT FAILURES:")
        for fl in failures:
            print(f"  ✗ {fl}")
        return 1
    helped = [r["dataset"] for r in artifact["rows"]
              if isinstance(r["accuracy_delta_tot_minus_single"], (int, float))
              and r["accuracy_delta_tot_minus_single"] > 0]
    print(
        f"\n[accuracy] PASS (measurement contract): {len(artifact['rows'])} rows. "
        f"ToT width={TOT_WIDTH} improved accuracy on: {helped or 'none'}. "
        "Δacc is advisory; the tot column is stochastic (temperature>0)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
