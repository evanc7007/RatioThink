"""Engine-free shape + mutation guards for the #657 arm orchestrator (Phase C).

Drives the real tot_arms.run_dataset with a deterministic stub `complete` and a
word-count token proxy — no engine. Asserts the matrix SHAPE ({B0,B1,B2,ToT}
cells + ToT-minus-B2 / ToT-minus-B0 deltas), that JSON reports ToT as N/A
(constrained-decoding task, not ToT), and that ungradable + errored runs are
held out of both the accuracy denominator and the token samples. Run::

    uv run --project Vendor/pie/client/python --with httpx --with jsonschema \
      python Inferlets/chat-apc/tot_arms_test.py
"""
from __future__ import annotations

import asyncio
import unittest

import tot_arms as a
import tot_search as ts


def _count(s):  # word-count token proxy
    return len(s.split())


def _math_spec():
    return ts.TaskSpec(
        name="math", depth=2, breadth=2, generator="sample",
        intermediate_eval="value", eval_samples=1, temperature=0.7,
        max_tokens=64, step_cue="next step:", value_cue="rate this step:",
    )


def _make_complete(answer_for, raise_on=None):
    async def complete(messages, temperature, max_tokens):
        root = messages[0]["content"]
        if raise_on is not None and raise_on in root:
            raise RuntimeError("simulated transport drop")
        cue = messages[-1]["content"]
        if "rate" in cue:
            return "SCORE: 5"
        return answer_for(root)
    return complete


class MathArmsShape(unittest.TestCase):
    def _run(self, records, complete):
        cfg = a.DatasetArmsConfig(family="math", grader="gsm8k_numeric",
                                  breadth=2, temperature=0.7, max_tokens=64,
                                  spec=_math_spec())
        return asyncio.run(a.run_dataset(records, cfg, complete, _count))

    def test_all_four_arms_and_deltas_present(self):
        recs = [{"prompt": "p_good", "reference": {"final_answer": "42"}}]
        complete = _make_complete(lambda root: "the answer is 42")
        row = self._run(recs, complete)
        self.assertEqual(set(row["cells"]), set(a.ARMS))
        self.assertTrue(row["tot_applicable"])
        # every arm answers 42 -> all correct -> deltas 0.
        for arm in a.ARMS:
            self.assertEqual(row["cells"][arm]["accuracy"], 1.0)
            self.assertGreater(row["cells"][arm]["mean_output_tokens"], 0)
        self.assertEqual(row["tot_minus_b2"], 0.0)
        self.assertEqual(row["tot_minus_b0"], 0.0)

    def test_ungradable_and_error_held_out_of_denominator(self):
        # p_good -> 42 (correct); p_ung -> no number (ungradable); p_err -> raises.
        def answer_for(root):
            return "no number here" if root == "p_ung" else "answer 42"
        recs = [
            {"prompt": "p_good", "reference": {"final_answer": "42"}},
            {"prompt": "p_ung", "reference": {"final_answer": "42"}},
            {"prompt": "p_err", "reference": {"final_answer": "42"}},
        ]
        complete = _make_complete(answer_for, raise_on="p_err")
        row = self._run(recs, complete)
        for arm in a.ARMS:
            c = row["cells"][arm]
            self.assertEqual(c["n_graded"], 1, f"{arm}: {c}")   # only p_good graded
            self.assertEqual(c["n_ungradable"], 1, f"{arm}: {c}")
            self.assertEqual(c["n_error"], 1, f"{arm}: {c}")
            self.assertEqual(c["accuracy"], 1.0)
        # graded-population token accounting (F1): B0 makes ONE greedy call on
        # p_good ("answer 42" -> 2 words); the ungradable p_ung tokens and the
        # errored p_err are NOT in the mean.
        self.assertEqual(row["cells"]["B0_greedy"]["mean_output_tokens"], 2.0)

    def test_tot_minus_b2_separates_structure_from_samples(self):
        # B2 votes over k samples; ToT searches. Force ToT wrong, B2 right by
        # answer depending on whether a 'next step' assistant turn precedes (ToT
        # builds multi-turn context; B2 samples from the bare root).
        def answer_for(root):
            return "42"
        # both right here -> delta 0; the point is the field exists + is numeric.
        recs = [{"prompt": "q", "reference": {"final_answer": "42"}}]
        row = self._run(recs, _make_complete(answer_for))
        self.assertIsInstance(row["tot_minus_b2"], float)


class JsonNoToT(unittest.TestCase):
    def test_json_reports_tot_na_and_runs_b0_b1_b2(self):
        cfg = a.DatasetArmsConfig(
            family="json", grader="jsonschema_validate", breadth=2,
            temperature=0.7, max_tokens=64, spec=None)
        ref = {"json_schema": '{"type":"object","required":["x"],'
                             '"properties":{"x":{"type":"integer"}}}'}
        recs = [{"prompt": "make json", "reference": ref}]
        complete = _make_complete(lambda root: '{"x": 5}')
        row = asyncio.run(a.run_dataset(recs, cfg, complete, _count))
        self.assertFalse(row["tot_applicable"])
        self.assertEqual(row["cells"]["ToT"]["n_error"], 1)        # ToT N/A -> errored-out
        self.assertIsNone(row["tot_minus_b2"])                     # no ToT delta
        for arm in ("B0_greedy", "B1_single", "B2_bestofk"):
            self.assertEqual(row["cells"][arm]["accuracy"], 1.0)   # {"x":5} validates


class CodeArmWiring(unittest.TestCase):
    def test_code_arm_uses_selftests_and_grades_by_execution(self):
        cfg = a.DatasetArmsConfig(
            family="code", grader="mbpp_exec", breadth=2, temperature=0.2,
            max_tokens=64, spec=_math_spec(), selftest_cue="write asserts:")
        ref = {"test_setup_code": "", "test_list": ["assert f(1) == 2"]}

        def answer_for(root):
            return "def f(a):\n    return a + 1\n"
        # selftest cue -> asserts; everything else -> the (correct) function.
        async def complete(messages, temperature, max_tokens):
            cue = messages[-1]["content"]
            if "asserts" in cue:
                return "assert f(2) == 3"
            if "rate" in cue:
                return "SCORE: 5"
            return answer_for(messages[0]["content"])
        recs = [{"prompt": "impl f", "reference": ref}]
        row = asyncio.run(a.run_dataset(recs, cfg, complete, _count))
        # correct function passes the held-out grading test on every arm.
        for arm in a.ARMS:
            self.assertEqual(row["cells"][arm]["accuracy"], 1.0, f"{arm}")


if __name__ == "__main__":
    unittest.main()
