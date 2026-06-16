"""Fair baselines for the #657 ToT comparison — matched temperature + budget.

The literature's decisive control: ToT must beat SELF-CONSISTENCY best-of-k
(Wang et al. 2023) to show that the search STRUCTURE helps beyond merely drawing
more samples. So every dataset is run against:

  * B0 greedy   — single chain, temperature 0 (canonical CoT baseline).
  * B1 single@T — single sample at the matched temperature (the SINGLE_TEMPERATURE
                  arm; isolates sampling from search at k=1).
  * B2 best-of-k — k whole samples at the matched temperature, selected by a
                  TASK-APPROPRIATE rule that NEVER touches the gold answer:
                    math  → majority vote over the extracted numeric answer
                            (self-consistency, Wang 2023 §2).
                    code  → execution agreement against SELF-GENERATED tests
                            (CodeT-style, Chen 2022) — NOT the held-out grading
                            tests, so the accuracy oracle never leaks into
                            selection. Falls back to the first candidate when no
                            self-test is usable (disclosed by the caller).
                    json  → first sample that validates against the schema
                            (the schema is given in the prompt, not a hidden
                            oracle; this is the only baseline reported for JSON,
                            which is a constrained-decoding task, not ToT).

Selection rules are PURE (or deterministic-offline for code execution) so the
engine-free self-test pins them; the async samplers take the injected
`complete`. grade.py stays the final-accuracy oracle — these only SELECT.
"""
from __future__ import annotations

from collections import Counter
from typing import Awaitable, Callable

import grade as g

Complete = Callable[[list[dict], float, int], Awaitable[str]]


# --- selection rules (pure / deterministic-offline) ------------------------


def majority_vote_numeric(answers: list[str]) -> str | None:
    """Self-consistency for math: bucket candidates by their extracted final
    number and return a representative of the largest bucket (the first such
    candidate, so ties are order-stable). Candidates with no number are ignored
    for the vote but never crash it."""
    keyed = [(g.last_number(a), a) for a in answers]
    numbers = [k for k, _ in keyed if k is not None]
    if not numbers:
        return answers[0] if answers else None
    winner = Counter(numbers).most_common(1)[0][0]
    for k, a in keyed:
        if k == winner:
            return a
    return None


def select_first_valid_json(answers: list[str], schema_ref: dict) -> str | None:
    """JSON best-of-k: the first sample that validates against the schema. Falls
    back to the first sample so the leaf is always defined (graded wrong if
    invalid)."""
    for a in answers:
        if g.jsonschema_validate(a, schema_ref).passed is True:
            return a
    return answers[0] if answers else None


def select_by_test_agreement(candidates: list[str], self_tests: list[str]) -> str | None:
    """Code best-of-k (CodeT-lite): run each candidate against the SELF-GENERATED
    tests and return the candidate passing the most. No usable self-test → return
    the first candidate (caller discloses the fallback). Never uses the held-out
    grading tests, so the accuracy oracle does not leak into selection."""
    if not candidates:
        return None
    tests = [s for s in self_tests if s.strip()]
    if not tests:
        return candidates[0]
    best, best_pass = candidates[0], -1
    for cand in candidates:
        code = g.extract_code(cand)
        passed = 0
        for assertion in tests:
            ok, _ = g.run_program(f"{code}\n\n{assertion}\n")
            if ok is True:
                passed += 1
        if passed > best_pass:
            best, best_pass = cand, passed
    return best


def parse_self_tests(text: str, limit: int = 5) -> list[str]:
    """Pull `assert ...` lines out of a test-generation completion (CodeT). Only
    bare asserts are kept — they run standalone against a candidate's code."""
    out = []
    for line in g.extract_code(text).splitlines():
        s = line.strip()
        if s.startswith("assert "):
            out.append(s)
        if len(out) >= limit:
            break
    return out


# --- samplers (async, via injected complete) -------------------------------


async def greedy(complete: Complete, messages: list[dict], max_tokens: int) -> str:
    """B0: one greedy chain (temperature 0)."""
    return await complete(messages, 0.0, max_tokens)


async def single_sample(complete: Complete, messages: list[dict],
                        temperature: float, max_tokens: int) -> str:
    """B1: one sample at the matched temperature."""
    return await complete(messages, temperature, max_tokens)


async def sample_k(complete: Complete, messages: list[dict], k: int,
                  temperature: float, max_tokens: int) -> list[str]:
    """Draw k i.i.d. samples at the matched temperature (the B2 candidate pool)."""
    return [await complete(messages, temperature, max_tokens) for _ in range(k)]
