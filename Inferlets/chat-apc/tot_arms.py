"""Per-dataset arm orchestration for the faithful ToT comparison (#657 Phase C).

Runs four arms per prompt — B0 greedy, B1 single@T, B2 self-consistency
best-of-k, ToT (harness-side BFS, tot_search.bfs) — selects each arm's final
answer with a TASK-APPROPRIATE rule that never touches the gold answer, grades
every answer with grade.py (the deterministic oracle), and aggregates a per-cell
record per arm plus the headline ToT−B2 and ToT−B0 accuracy deltas.

The engine is injected as `complete(messages, temperature, max_tokens) -> str`;
this module is pure given that callable, so the engine-free self-test drives the
whole orchestration (arm bookkeeping, ungradable-held-out denominator, graded-
population token accounting, the ToT−B2 "structure vs samples" delta) with a
stub. Token cost per arm = Σ tokenizer tokens over EVERY engine call the arm
made (B2 pays for k samples, ToT for the whole tree) so accuracy-per-token is a
fair compute comparison, not just the winning leaf.

JSON is a constrained-decoding task, not ToT: its config carries no search spec,
so the ToT arm is reported as N/A and only B0/B1/B2(first-valid) are run.
"""
from __future__ import annotations

import statistics
from dataclasses import dataclass
from typing import Awaitable, Callable

import baselines as bl
import grade as g
import tot_search as ts

Complete = Callable[[list[dict], float, int], Awaitable[str]]
ARMS = ("B0_greedy", "B1_single", "B2_bestofk", "ToT")


@dataclass
class DatasetArmsConfig:
    family: str                 # "math" | "code" | "json"
    grader: str                 # grade.py terminal grader (the oracle)
    breadth: int                # k for B2 + ToT
    temperature: float          # matched temp for B2 + ToT
    max_tokens: int
    spec: ts.TaskSpec | None    # ToT search spec; None for json (ToT N/A)
    selftest_cue: str | None = None  # code: asks the model for a few asserts
    # B1's temperature (the SINGLE_TEMPERATURE knob): default 0.0 = greedy; set
    # equal to `temperature` to isolate search width at matched temperature.
    single_temperature: float = 0.0


class _Tally:
    """Wraps `complete` to sum tokenizer tokens over an arm's calls (its compute
    cost), so accuracy-per-token compares B2's k samples / ToT's whole tree
    against B0's single chain fairly. Transport failures are surfaced as a
    RuntimeError so the arm is recorded errored, not silently zero."""
    def __init__(self, complete: Complete, count):
        self._complete = complete
        self._count = count
        self.tokens = 0

    async def __call__(self, messages, temperature, max_tokens):
        text = await self._complete(messages, temperature, max_tokens)
        self.tokens += self._count(text or "")
        return text


async def _select(family: str, answers: list[str], reference: dict,
                 self_tests: list[str]) -> str | None:
    if not answers:
        return None
    if family == "math":
        return bl.majority_vote_numeric(answers)
    if family == "json":
        return bl.select_first_valid_json(answers, reference)
    if family == "code":
        return bl.select_by_test_agreement(answers, self_tests)
    return answers[0]


async def run_prompt(prompt: str, reference: dict, cfg: DatasetArmsConfig,
                     complete: Complete, count) -> dict:
    """Run all four arms for one prompt. Returns {arm: {answer, tokens, error}}.
    Each arm's compute is metered independently via a fresh _Tally."""
    msgs = [{"role": "user", "content": prompt}]
    out: dict[str, dict] = {}

    async def _arm(fn):
        tally = _Tally(complete, count)
        try:
            answer = await fn(tally)
        except Exception as e:  # noqa: BLE001  transport drop etc. -> errored arm
            return {"answer": None, "tokens": tally.tokens, "error": f"{type(e).__name__}: {e}"}
        return {"answer": answer, "tokens": tally.tokens, "error": None}

    # B0 greedy
    out["B0_greedy"] = await _arm(lambda c: bl.greedy(c, msgs, cfg.max_tokens))
    # B1 single sample @ the SINGLE_TEMPERATURE arm temperature
    out["B1_single"] = await _arm(
        lambda c: bl.single_sample(c, msgs, cfg.single_temperature, cfg.max_tokens))

    # self-generated tests for code selection (shared by B2 + ToT; NOT the
    # grading tests, so the oracle never leaks into selection).
    self_tests: list[str] = []
    if cfg.family == "code" and cfg.selftest_cue:
        try:
            raw = await complete(msgs + [{"role": "user", "content": cfg.selftest_cue}],
                                 cfg.temperature, cfg.max_tokens)
            self_tests = bl.parse_self_tests(raw)
        except Exception:  # noqa: BLE001  no self-tests -> selector falls back to first
            self_tests = []

    async def _b2(c):
        pool = await bl.sample_k(c, msgs, cfg.breadth, cfg.temperature, cfg.max_tokens)
        return await _select(cfg.family, pool, reference, self_tests)

    out["B2_bestofk"] = await _arm(_b2)

    # ToT arm (None for json)
    if cfg.spec is None:
        out["ToT"] = {"answer": None, "tokens": 0, "error": "N/A (constrained-decoding task)"}
    else:
        async def _tot(c):
            root = ts.State(messages=msgs)
            leaves = await ts.bfs(root, cfg.spec, c)
            return await _select(cfg.family, [lf.answer or "" for lf in leaves],
                                 reference, self_tests)
        out["ToT"] = await _arm(_tot)
    return out


def _cell(arm: str, results: list[dict], grader: str, references: list[dict]) -> dict:
    """Aggregate one arm over the dataset. Ungradable (no extractable answer) and
    errored (engine failure / N/A) runs are held OUT of both the accuracy
    denominator AND the token samples — one graded population, as in the prior
    F1 fix."""
    n_correct = n_wrong = n_ungradable = n_error = 0
    tokens: list[int] = []
    first_error: str | None = None
    for r, ref in zip(results, references):
        if r["error"] is not None:
            n_error += 1
            if first_error is None:
                first_error = r["error"]
            continue
        if r["answer"] is None:
            n_ungradable += 1
            continue
        verdict = g.grade(grader, r["answer"], ref)
        if verdict.passed is None:
            n_ungradable += 1
            continue
        tokens.append(r["tokens"])
        if verdict.passed is True:
            n_correct += 1
        else:
            n_wrong += 1
    graded = n_correct + n_wrong
    accuracy = (n_correct / graded) if graded else None
    mean_tok = statistics.mean(tokens) if tokens else None
    return {
        "arm": arm, "n_correct": n_correct, "n_wrong": n_wrong,
        "n_ungradable": n_ungradable, "n_error": n_error, "n_graded": graded,
        "first_error": first_error,
        "accuracy": accuracy, "mean_output_tokens": mean_tok,
        "accuracy_per_ktok": (accuracy / (mean_tok / 1000.0))
        if (accuracy is not None and mean_tok) else None,
    }


async def run_dataset(records: list[dict], cfg: DatasetArmsConfig,
                      complete: Complete, count) -> dict:
    """Run every prompt through all arms, aggregate per-arm cells, and compute
    the headline deltas. Returns the row dict for the matrix."""
    per_arm: dict[str, list[dict]] = {a: [] for a in ARMS}
    references = [r["reference"] for r in records]
    for rec in records:
        res = await run_prompt(rec["prompt"], rec["reference"], cfg, complete, count)
        for a in ARMS:
            per_arm[a].append(res[a])
    cells = {a: _cell(a, per_arm[a], cfg.grader, references) for a in ARMS}

    def _delta(x, y):
        ax, ay = cells[x]["accuracy"], cells[y]["accuracy"]
        return (ax - ay) if (ax is not None and ay is not None) else None

    return {
        "family": cfg.family,
        "grader": cfg.grader,
        "tot_applicable": cfg.spec is not None,
        "cells": cells,
        "tot_minus_b2": _delta("ToT", "B2_bestofk"),   # structure vs more samples
        "tot_minus_b0": _delta("ToT", "B0_greedy"),    # vs greedy CoT
        "b2_minus_b0": _delta("B2_bestofk", "B0_greedy"),  # samples vs greedy
    }
