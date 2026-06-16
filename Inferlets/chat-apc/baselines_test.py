"""Engine-free unit guards for the #657 fair baselines (B0/B1/B2 selectors).

Deterministic, CI-safe. The selection rules are pinned with fixtures (code
execution runs trusted fixtures in a subprocess, same as grade.py); the async
samplers are driven by a counting stub. Run::

    uv run --project Vendor/pie/client/python --with httpx --with jsonschema \
      python Inferlets/chat-apc/baselines_test.py
"""
from __future__ import annotations

import asyncio
import unittest

import baselines as b


class MajorityVoteNumeric(unittest.TestCase):
    def test_picks_the_modal_number(self):
        # 42 appears twice, 41 once -> a "42" answer wins (self-consistency).
        ans = ["the answer is 41", "I get 42", "so 42 apples"]
        self.assertEqual(b.majority_vote_numeric(ans), "I get 42")

    def test_tie_is_order_stable_first_bucket(self):
        ans = ["x = 7", "y = 9"]            # 7 and 9 each once -> first wins
        self.assertEqual(b.majority_vote_numeric(ans), "x = 7")

    def test_ignores_numberless_candidates(self):
        ans = ["no idea", "result 5", "also 5"]
        self.assertEqual(b.majority_vote_numeric(ans), "result 5")

    def test_all_numberless_falls_back_to_first(self):
        self.assertEqual(b.majority_vote_numeric(["a", "b"]), "a")


class FirstValidJson(unittest.TestCase):
    REF = {"json_schema": '{"type":"object","required":["x"],'
                          '"properties":{"x":{"type":"integer"}}}'}

    def test_returns_first_validating_sample(self):
        ans = ['{"x": "no"}', '{"x": 5}', '{"x": 6}']
        self.assertEqual(b.select_first_valid_json(ans, self.REF), '{"x": 5}')

    def test_falls_back_to_first_when_none_valid(self):
        ans = ['{"x": "no"}', '{"y": 1}']
        self.assertEqual(b.select_first_valid_json(ans, self.REF), '{"x": "no"}')


class SelfTestsAndAgreement(unittest.TestCase):
    def test_parse_self_tests_keeps_only_asserts(self):
        text = "```python\nassert f(1)==2\nx = 3\nassert f(2)==4\n```"
        self.assertEqual(b.parse_self_tests(text), ["assert f(1)==2", "assert f(2)==4"])

    def test_agreement_selects_candidate_passing_most_selftests(self):
        good = "def f(a):\n    return a + 1\n"
        bad = "def f(a):\n    return a - 1\n"
        tests = ["assert f(1) == 2", "assert f(3) == 4"]
        self.assertEqual(b.select_by_test_agreement([bad, good], tests), good)

    def test_no_selftests_falls_back_to_first(self):
        cands = ["def f(): return 1", "def f(): return 2"]
        self.assertEqual(b.select_by_test_agreement(cands, []), cands[0])


class StubComplete:
    def __init__(self, seq):
        self.seq = iter(seq)
        self.calls = []

    async def __call__(self, messages, temperature, max_tokens):
        self.calls.append(temperature)
        return next(self.seq)


class Samplers(unittest.TestCase):
    def test_greedy_uses_temperature_zero(self):
        stub = StubComplete(["g"])
        out = asyncio.run(b.greedy(stub, [{"role": "user", "content": "Q"}], 64))
        self.assertEqual(out, "g")
        self.assertEqual(stub.calls, [0.0])

    def test_single_sample_uses_matched_temperature(self):
        stub = StubComplete(["s"])
        asyncio.run(b.single_sample(stub, [{"role": "user", "content": "Q"}], 0.7, 64))
        self.assertEqual(stub.calls, [0.7])

    def test_sample_k_draws_k_at_matched_temperature(self):
        stub = StubComplete(["a", "b", "c"])
        out = asyncio.run(b.sample_k(stub, [{"role": "user", "content": "Q"}], 3, 0.7, 64))
        self.assertEqual(out, ["a", "b", "c"])
        self.assertEqual(stub.calls, [0.7, 0.7, 0.7])


if __name__ == "__main__":
    unittest.main()
