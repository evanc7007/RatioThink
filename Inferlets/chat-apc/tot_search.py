"""Faithful Tree-of-Thoughts search controller (#657, Yao et al. 2023 §3, Alg. 1).

This is the harness-side ToT the #657 redesign is built on: the engine is a
DECODE PRIMITIVE (an injected async ``complete(messages, temperature,
max_tokens) -> str``) and THIS module is the deliberate search — it decomposes a
task into intermediate PARTIAL states, generates child thoughts (sample or
propose, Yao §3 "thought generator"), evaluates partial states with a robust
LLM heuristic (value ×3 or vote ×5, Yao §3 "state evaluator"), and keeps the
best ``breadth`` states per level (BFS keep-b, Alg. 1). It deliberately does NOT
embed the deterministic terminal graders (execute tests / validate schema /
numeric match) or the gold answer — those live in the harness layer and
``grade.py`` so the search never selects on the accuracy oracle.

Everything here is pure given the injected ``complete``; the engine-free
self-test drives it with a deterministic stub. The shipped wasm tree-of-thought
inferlet is untouched — this measures ToT-the-method, not that inferlet.
"""
from __future__ import annotations

import asyncio
import re
from dataclasses import dataclass, field
from typing import Awaitable, Callable

# An injected decode primitive. Returns the assistant completion text for the
# given message list. Async so the harness can drive a real engine; the
# self-test passes a synchronous-result stub.
Complete = Callable[[list[dict], float, int], Awaitable[str]]


@dataclass
class State:
    """A node in the search tree = a PARTIAL solution (Yao's state s=[x, z_1..i])."""
    messages: list[dict]            # conversation to continue from (input + thoughts so far)
    thoughts: list[str] = field(default_factory=list)  # the intermediate steps taken
    depth: int = 0
    score: float | None = None      # intermediate value (None ranks last)
    terminal: bool = False
    answer: str | None = None       # final answer text once terminal


@dataclass
class TaskSpec:
    name: str
    depth: int                      # max tree depth (number of levels expanded)
    breadth: int                    # b: children per state AND keep-b width
    generator: str                  # "sample" | "propose"
    intermediate_eval: str          # "value" | "vote" | "none"
    eval_samples: int               # 3 for value (median), 5 for vote (majority)
    temperature: float
    max_tokens: int
    step_cue: str                   # appended to ask for the next thought (sample)
    propose_cue: str | None = None  # asks for `breadth` distinct next thoughts (propose)
    value_cue: str | None = None    # asks the evaluator to rate a partial state
    final_cue: str | None = None    # terminal level: ask for the FINAL answer (else step_cue)


# --- parsers (pure) --------------------------------------------------------

_PROPOSAL_RE = re.compile(r"^\s*(?:\d+[.)]|[-*])\s+(.*\S)", re.MULTILINE)
# Yao's value labels (Game-of-24 §4.1) mapped to a numeric heuristic.
_VALUE_WORDS = {"impossible": 1.0, "unlikely": 3.0, "maybe": 5.0,
                "likely": 7.0, "sure": 10.0}
_SCORE_RE = re.compile(r"\bSCORE\s*[:=]\s*(\d+(?:\.\d+)?)", re.IGNORECASE)


def parse_proposals(text: str, k: int) -> list[str]:
    """Pull up to k distinct proposals from a 'propose' generation. Accepts a
    numbered/bulleted list; falls back to non-empty lines so a model that
    forgot the markers still yields candidates."""
    items = [m.group(1).strip() for m in _PROPOSAL_RE.finditer(text)]
    if not items:
        items = [ln.strip() for ln in text.splitlines() if ln.strip()]
    # de-dup preserving order (propose must avoid duplicate thoughts, Yao §3).
    seen: set[str] = set()
    out: list[str] = []
    for it in items:
        if it not in seen:
            seen.add(it)
            out.append(it)
        if len(out) >= k:
            break
    return out


def parse_value(text: str) -> float | None:
    """Score a partial state from an evaluator generation. Prefers an explicit
    ``SCORE: N`` line; else the last Yao value word (sure/likely/maybe/…).
    Returns None when neither is present (ranks the state last, never crashes)."""
    m = list(_SCORE_RE.finditer(text))
    if m:
        return float(m[-1].group(1))
    last = None
    low = text.lower()
    for word, val in _VALUE_WORDS.items():
        idx = low.rfind(word)
        if idx != -1 and (last is None or idx > last[0]):
            last = (idx, val)
    return last[1] if last else None


def _median(xs: list[float]) -> float:
    s = sorted(xs)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 else (s[mid - 1] + s[mid]) / 2.0


def keep_best_b(states: list[State], b: int) -> list[State]:
    """BFS prune (Yao Alg. 1): the b states with the highest value, score-
    descending, None last, ORDER-STABLE so ties keep generation order."""
    return sorted(states, key=lambda s: (s.score is not None, s.score or 0.0),
                  reverse=True)[:b]


# --- generation + evaluation (async, via injected complete) ----------------


async def generate(state: State, spec: TaskSpec, complete: Complete) -> list[State]:
    """Expand one state into child states. 'sample' draws `breadth` i.i.d.
    continuations (rich space); 'propose' asks for `breadth` distinct next
    thoughts in ONE context (constrained space) — Yao §3 thought generator."""
    next_depth = state.depth + 1
    terminal = next_depth >= spec.depth
    # At the terminal level solicit the FINAL answer (final_cue); intermediate
    # levels solicit the next partial thought. propose stays for intermediate
    # constrained expansion; the terminal level always samples a full answer.
    # The `breadth` siblings are issued CONCURRENTLY (asyncio.gather) so the
    # engine co-batches them — sequential per-node calls make a thinking-ON deep
    # tree intractable (~15s/call × thousands). gather preserves result order.
    if (terminal and spec.final_cue) or spec.generator != "propose" or not spec.propose_cue:
        cue = spec.final_cue if (terminal and spec.final_cue) else spec.step_cue
        thoughts = await asyncio.gather(*[
            complete(state.messages + [{"role": "user", "content": cue}],
                     spec.temperature, spec.max_tokens)
            for _ in range(spec.breadth)
        ])
        return [_child(state, t, next_depth, terminal) for t in thoughts]
    # propose: ONE constrained call yields `breadth` distinct next thoughts.
    text = await complete(state.messages + [{"role": "user", "content": spec.propose_cue}],
                          spec.temperature, spec.max_tokens)
    return [_child(state, t, next_depth, terminal)
            for t in parse_proposals(text, spec.breadth)]


def _child(parent: State, thought: str, depth: int, terminal: bool) -> State:
    return State(
        messages=parent.messages + [{"role": "assistant", "content": thought}],
        thoughts=parent.thoughts + [thought],
        depth=depth,
        terminal=terminal,
        answer=thought if terminal else None,
    )


async def evaluate(states: list[State], spec: TaskSpec, complete: Complete) -> None:
    """Set each state's .score via a robust LLM heuristic (Yao §3). 'value'
    scores each state independently, sampled `eval_samples` times and median'd
    (§4.1, ×3); 'vote' would compare across states (§4.2). 'none' leaves scores
    None (deterministic-terminal tasks like code that rank leaves by execution,
    not by an LLM judge). Mutates states in place."""
    if spec.intermediate_eval == "none" or not spec.value_cue:
        return
    n = max(1, spec.eval_samples) if spec.intermediate_eval == "value" else 1
    # Flat-gather every (state × sample) value call so the engine co-batches the
    # whole level's scoring (×3 per child × frontier) instead of serializing it.
    texts = await asyncio.gather(*[
        complete(s.messages + [{"role": "user", "content": spec.value_cue}],
                 spec.temperature, spec.max_tokens)
        for s in states for _ in range(n)
    ])
    for i, s in enumerate(states):
        vals = [v for v in (parse_value(t) for t in texts[i * n:(i + 1) * n]) if v is not None]
        s.score = _median(vals) if vals else None


async def bfs(root: State, spec: TaskSpec, complete: Complete) -> list[State]:
    """BFS keep-b deliberate search (Yao Alg. 1). Expands every frontier state
    into children, scores them (intermediate evaluator), keeps the best b, and
    descends until `depth` levels are taken. Returns the final frontier (the
    leaf states); terminal selection + accuracy grading happen in the harness
    against grade.py, NOT here (the search never sees the gold answer)."""
    frontier = [root]
    for level in range(spec.depth):
        # Expand every frontier state CONCURRENTLY so the whole level's
        # generations co-batch on the engine (one batched wave per level rather
        # than frontier×breadth serial 15s calls).
        expansions = await asyncio.gather(*[generate(s, spec, complete) for s in frontier])
        children: list[State] = [c for kids in expansions for c in kids]
        if not children:
            break
        last_level = level == spec.depth - 1
        if not last_level:
            await evaluate(children, spec, complete)
            frontier = keep_best_b(children, spec.breadth)
        else:
            frontier = children  # leaves: ranked by the deterministic terminal step
    return frontier
