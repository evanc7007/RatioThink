"""Engine-free unit guards for the faithful ToT search controller (#657).

Deterministic, CI-safe — no engine, no model, no network. Drives the real
tot_search functions with a synchronous stub `complete` that returns canned
text, so the generator (sample vs propose), the robust value evaluator (×3
median), the BFS keep-b prune (Yao Alg. 1), and the depth>1 loop are all
exercised without decoding a token. Run::

    uv run --project Vendor/pie/client/python --with httpx \
      python Inferlets/chat-apc/tot_search_test.py
"""
from __future__ import annotations

import asyncio
import unittest

import tot_search as t


def _spec(**kw):
    base = dict(
        name="x", depth=2, breadth=2, generator="sample",
        intermediate_eval="value", eval_samples=3, temperature=0.7,
        max_tokens=64, step_cue="next step:", propose_cue="give options:",
        value_cue="rate it:",
    )
    base.update(kw)
    return t.TaskSpec(**base)


class Parsers(unittest.TestCase):
    def test_proposals_numbered_and_bulleted(self):
        self.assertEqual(t.parse_proposals("1. a\n2) b\n- c\n* d", 4), ["a", "b", "c", "d"])

    def test_proposals_fallback_to_lines_when_unmarked(self):
        self.assertEqual(t.parse_proposals("alpha\nbeta\n", 5), ["alpha", "beta"])

    def test_proposals_dedup_and_cap_k(self):
        self.assertEqual(t.parse_proposals("1. a\n2. a\n3. b\n4. c", 2), ["a", "b"])

    def test_value_prefers_score_line(self):
        self.assertEqual(t.parse_value("worked check ... SCORE: 7"), 7.0)

    def test_value_takes_last_score(self):
        self.assertEqual(t.parse_value("SCORE: 3 then revised SCORE: 9"), 9.0)

    def test_value_word_fallback(self):
        self.assertEqual(t.parse_value("this looks sure to work"), 10.0)
        self.assertEqual(t.parse_value("that is impossible"), 1.0)

    def test_value_none_when_absent(self):
        self.assertIsNone(t.parse_value("no verdict here"))


class KeepBestB(unittest.TestCase):
    def _s(self, score):
        st = t.State(messages=[], score=score)
        return st

    def test_keeps_top_b_descending(self):
        states = [self._s(2.0), self._s(9.0), self._s(5.0)]
        kept = t.keep_best_b(states, 2)
        self.assertEqual([s.score for s in kept], [9.0, 5.0])

    def test_none_ranks_last(self):
        a, b, c = self._s(None), self._s(4.0), self._s(None)
        kept = t.keep_best_b([a, b, c], 2)
        self.assertIs(kept[0], b)              # the only scored state wins
        self.assertIn(kept[1], (a, c))         # a None fills the rest

    def test_ties_are_order_stable(self):
        a, b = self._s(5.0), self._s(5.0)
        self.assertEqual(t.keep_best_b([a, b], 2), [a, b])


class StubComplete:
    """Records every (messages, temperature, max_tokens) call and replies from a
    cue->text routing table so tests are fully deterministic."""
    def __init__(self, router):
        self.router = router
        self.calls: list[dict] = []

    async def __call__(self, messages, temperature, max_tokens):
        self.calls.append({"messages": messages, "temperature": temperature,
                           "max_tokens": max_tokens})
        cue = messages[-1]["content"]
        return self.router(cue, messages)


class Generate(unittest.TestCase):
    def test_sample_draws_breadth_iid_children(self):
        n = {"i": 0}

        def router(cue, msgs):
            n["i"] += 1
            return f"step{n['i']}"

        stub = StubComplete(router)
        spec = _spec(generator="sample", breadth=3, depth=2)
        root = t.State(messages=[{"role": "user", "content": "Q"}])
        kids = asyncio.run(t.generate(root, spec, stub))
        self.assertEqual(len(kids), 3)                 # breadth children
        self.assertEqual(len(stub.calls), 3)           # breadth complete() calls
        self.assertEqual([k.thoughts[-1] for k in kids], ["step1", "step2", "step3"])
        self.assertTrue(all(k.depth == 1 for k in kids))
        self.assertFalse(any(k.terminal for k in kids))  # depth 1 < spec.depth 2

    def test_propose_one_call_parsed_into_children(self):
        stub = StubComplete(lambda cue, msgs: "1. plan A\n2. plan B")
        spec = _spec(generator="propose", breadth=2, depth=1)
        root = t.State(messages=[{"role": "user", "content": "Q"}])
        kids = asyncio.run(t.generate(root, spec, stub))
        self.assertEqual(len(stub.calls), 1)           # propose = ONE context
        self.assertEqual([k.thoughts[-1] for k in kids], ["plan A", "plan B"])
        self.assertTrue(all(k.terminal for k in kids))  # depth 1 == spec.depth 1


class Evaluate(unittest.TestCase):
    def test_value_x3_median(self):
        # three value samples 3,9,7 -> median 7.
        seq = iter(["SCORE: 3", "SCORE: 9", "SCORE: 7"])
        stub = StubComplete(lambda cue, msgs: next(seq))
        spec = _spec(intermediate_eval="value", eval_samples=3)
        s = t.State(messages=[{"role": "user", "content": "Q"}])
        asyncio.run(t.evaluate([s], spec, stub))
        self.assertEqual(s.score, 7.0)
        self.assertEqual(len(stub.calls), 3)

    def test_none_evaluator_leaves_scores_unset(self):
        stub = StubComplete(lambda cue, msgs: "SCORE: 10")
        spec = _spec(intermediate_eval="none")
        s = t.State(messages=[], score=None)
        asyncio.run(t.evaluate([s], spec, stub))
        self.assertIsNone(s.score)
        self.assertEqual(len(stub.calls), 0)            # no judge calls at all


class BFS(unittest.TestCase):
    def test_depth2_breadth2_prunes_then_descends(self):
        # Level 1 generates 2 children; value scores them by an embedded digit so
        # the prune is observable; level 2 expands the kept frontier into leaves.
        def router(cue, msgs):
            if cue.startswith("rate"):
                # score = last step's trailing digit (so step with higher id wins)
                last = msgs[-2]["content"]
                return f"SCORE: {last[-1]}"
            # generation: id by call count within the step
            return f"s{len(msgs)}"

        stub = StubComplete(router)
        spec = _spec(generator="sample", breadth=2, depth=2,
                     intermediate_eval="value", eval_samples=1)
        root = t.State(messages=[{"role": "user", "content": "Q"}])
        leaves = asyncio.run(t.bfs(root, spec, stub))
        # frontier after level 1 = best-2 of 2 = 2 states; level 2 expands each
        # into 2 leaves -> 4 leaves, all terminal at depth 2.
        self.assertEqual(len(leaves), 4)
        self.assertTrue(all(lf.terminal and lf.depth == 2 for lf in leaves))

    def test_bfs_keeps_only_breadth_between_levels(self):
        # breadth=2 from a wide level-1 (4 children via breadth=4 at L1)? Keep it
        # simple: breadth=2 means each level keeps 2; with depth 3 the frontier
        # never exceeds breadth*breadth before prune. Assert frontier size law.
        sizes = []

        def router(cue, msgs):
            if cue.startswith("rate"):
                return "SCORE: 5"
            return f"t{len(msgs)}"

        stub = StubComplete(router)
        spec = _spec(generator="sample", breadth=2, depth=3,
                     intermediate_eval="value", eval_samples=1)
        root = t.State(messages=[{"role": "user", "content": "Q"}])
        leaves = asyncio.run(t.bfs(root, spec, stub))
        # depth 3, breadth 2: L1 keep2, L2 keep2, L3 leaves = 2*2 = 4.
        self.assertEqual(len(leaves), 4)


if __name__ == "__main__":
    unittest.main()
