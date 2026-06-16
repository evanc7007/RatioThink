"""Engine-free unit guards for the ToT accuracy harness + graders (#657).

Deterministic, CI-safe — no engine, no model, no network. Two layers:

  1. The deterministic graders (`grade.py`): for each dataset, a correct answer
     scores True, a wrong one False, and an unparseable/empty one None (held out
     of the accuracy denominator, NOT scored wrong). HumanEval/MBPP exec trusted
     fixture code in a subprocess; jsonschema validates against a fixture schema.
  2. The matrix aggregation (`tot_accuracy_real._bench_dataset`): driven end to
     end against the real aggregator with a stubbed `_tot_run` so the accuracy /
     token / ungradable bookkeeping is exercised without an engine — including a
     mutation check that an ungradable answer and a non-200 error never inflate
     or deflate the reported accuracy.

Run::

    uv run --project Vendor/pie/client/python --with httpx --with jsonschema \
      python -m unittest Inferlets/chat-apc/tot_accuracy_real_test.py
"""
from __future__ import annotations

import asyncio
import unittest
from unittest import mock

import grade as g
import tot_accuracy_real as a


# --- extraction helpers ----------------------------------------------------


class Extraction(unittest.TestCase):
    def test_extract_code_prefers_first_fenced_block(self):
        text = "blah\n```python\nx = 1\n```\nmore\n```\ny = 2\n```"
        self.assertEqual(g.extract_code(text), "x = 1\n")

    def test_extract_code_falls_back_to_raw(self):
        self.assertEqual(g.extract_code("def f(): pass"), "def f(): pass")

    def test_last_number_takes_final_strips_commas(self):
        self.assertEqual(g.last_number("first 7 then 1,024 dollars"), "1024")
        self.assertEqual(g.last_number("the answer is -3.5."), "-3.5")
        self.assertIsNone(g.last_number("no digits here"))

    def test_extract_json_returns_first_balanced_object(self):
        self.assertEqual(g.extract_json('here: {"x": {"y": 1}}. done'), '{"x": {"y": 1}}')

    def test_extract_json_ignores_braces_inside_strings(self):
        self.assertEqual(g.extract_json('{"s": "a}b"}'), '{"s": "a}b"}')

    def test_extract_json_none_when_absent(self):
        self.assertIsNone(g.extract_json("plain prose, no json"))


# --- graders ---------------------------------------------------------------


class GSM8KGrader(unittest.TestCase):
    REF = {"final_answer": "18"}

    def test_correct_final_number(self):
        self.assertTrue(g.gsm8k_numeric("So the total is 18 apples.", self.REF).passed)

    def test_correct_with_decimal_equivalence(self):
        self.assertTrue(g.gsm8k_numeric("answer: 18.0", self.REF).passed)

    def test_wrong_number(self):
        self.assertIs(g.gsm8k_numeric("the answer is 17", self.REF).passed, False)

    def test_no_number_is_ungradable_not_wrong(self):
        self.assertIsNone(g.gsm8k_numeric("I cannot tell", self.REF).passed)

    def test_empty_is_ungradable(self):
        self.assertIsNone(g.gsm8k_numeric("", self.REF).passed)


class HumanEvalGrader(unittest.TestCase):
    REF = {
        "canonical_prompt": 'from typing import List\n\n\ndef add(a, b):\n    """add"""\n',
        "test": "def check(candidate):\n    assert candidate(1, 2) == 3\n",
        "entry_point": "add",
    }

    def test_body_continuation_passes(self):
        self.assertTrue(g.humaneval_exec("    return a + b\n", self.REF).passed)

    def test_full_function_passes_with_prompt_imports(self):
        # The model re-emitted the WHOLE function and uses `math`, which is only
        # available if the prompt's leading `import math` is carried in — proving
        # _import_lines wires the prompt imports for a standalone definition.
        ref = {
            "canonical_prompt": 'import math\n\n\ndef isqrt4(x):\n    """sqrt"""\n',
            "test": "def check(candidate):\n    assert candidate(16) == 4\n",
            "entry_point": "isqrt4",
        }
        out = "```python\ndef isqrt4(x):\n    return int(math.sqrt(x))\n```"
        self.assertTrue(g.humaneval_exec(out, ref).passed)

    def test_wrong_body_fails(self):
        self.assertIs(g.humaneval_exec("    return a - b\n", self.REF).passed, False)

    def test_empty_is_ungradable(self):
        self.assertIsNone(g.humaneval_exec("   ", self.REF).passed)


class MBPPGrader(unittest.TestCase):
    REF = {"test_setup_code": "", "test_list": ["assert add(1, 2) == 3"]}

    def test_correct_function_passes(self):
        self.assertTrue(g.mbpp_exec("def add(a, b):\n    return a + b\n", self.REF).passed)

    def test_wrong_function_fails(self):
        self.assertIs(g.mbpp_exec("def add(a, b):\n    return a - b\n", self.REF).passed, False)

    def test_setup_code_is_run(self):
        ref = {"test_setup_code": "import math", "test_list": ["assert f() == math.pi"]}
        self.assertTrue(g.mbpp_exec("def f():\n    import math\n    return math.pi\n", ref).passed)

    def test_empty_is_ungradable(self):
        self.assertIsNone(g.mbpp_exec("", self.REF).passed)


class JSONSchemaGrader(unittest.TestCase):
    REF = {"json_schema": '{"type":"object","required":["x"],'
                          '"properties":{"x":{"type":"integer"}}}'}

    def test_valid_instance_passes(self):
        self.assertTrue(g.jsonschema_validate('{"x": 5}', self.REF).passed)

    def test_invalid_instance_fails(self):
        self.assertIs(g.jsonschema_validate('{"x": "not-int"}', self.REF).passed, False)

    def test_missing_required_fails(self):
        self.assertIs(g.jsonschema_validate('{"y": 1}', self.REF).passed, False)

    def test_non_json_is_ungradable(self):
        self.assertIsNone(g.jsonschema_validate("I cannot produce JSON", self.REF).passed)

    def test_prose_wrapped_json_is_extracted(self):
        self.assertTrue(g.jsonschema_validate('Here it is: {"x": 1}. Enjoy!', self.REF).passed)


class GraderDispatch(unittest.TestCase):
    def test_unknown_grader_is_hard_error(self):
        with self.assertRaises(KeyError):
            g.grade("nope", "x", {})

    def test_registry_names_match_lock_graders(self):
        self.assertEqual(
            sorted(g.GRADERS),
            ["gsm8k_numeric", "humaneval_exec", "jsonschema_validate", "mbpp_exec"],
        )


# --- aggregation (stubbed engine) ------------------------------------------


def _tree(answer: str, breadth: int, node_text: str = "reasoning words here") -> dict:
    """A minimal /v1/inferlet tree body: `breadth` sibling nodes (so the token
    count scales with width) and a chosen final_answer."""
    children = [
        {"id": f"n{i}", "content": node_text, "reasoning": ""}
        for i in range(breadth)
    ]
    return {"root": {"id": "root", "children": children}, "final_answer": answer}


class Aggregation(unittest.TestCase):
    """Drive the real `_bench_dataset` with a stubbed `_tot_run`. The single
    column (breadth 1) returns a WRONG answer for one prompt; the tot column
    (breadth k) gets it RIGHT — so ToT shows a positive accuracy delta and a
    higher token count. A third prompt is ungradable on both, and a fourth
    errors (non-200) on single, to mutation-check the denominator handling."""

    def _bench(self, records):
        # word-count token proxy (no tokenizer needed in CI).
        def count(s):
            return len(s.split())

        async def fake_tot_run(http_c, base, prompt, think, breadth, temperature):
            # prompt 'p_err' errors on the single (greedy) column only.
            if prompt == "p_err" and breadth == 1:
                return {"status": 500, "error_body": "all branches failed", "wall_s": 0.1}
            # prompt 'p_ung' yields no extractable number on both columns. Its
            # node text is DELIBERATELY huge (100 words/node) so that if an
            # ungradable run leaked into the token/wall samples, the per-token
            # metrics below would shift far off the graded-only value.
            if prompt == "p_ung":
                return {"status": 200,
                        "body": _tree("no number", breadth, "w " * 100),
                        "wall_s": 9.9}
            # 'p_hard': single greedy gets it wrong, ToT width selects right.
            if prompt == "p_hard":
                ans = "42" if breadth > 1 else "41"
                return {"status": 200, "body": _tree(ans, breadth), "wall_s": 0.1}
            # 'p_easy': both right.
            return {"status": 200, "body": _tree("7", breadth), "wall_s": 0.1}

        failures: list[str] = []
        with mock.patch.object(a, "_tot_run", fake_tot_run):
            row = asyncio.run(
                a._bench_dataset(None, "http://stub", "gsm8k", "gsm8k_numeric",
                                 records, len(records), count, failures)
            )
        return row, failures

    RECORDS = [
        {"id": "0", "prompt": "p_easy", "think": False, "reference": {"final_answer": "7"}},
        {"id": "1", "prompt": "p_hard", "think": False, "reference": {"final_answer": "42"}},
        {"id": "2", "prompt": "p_ung", "think": False, "reference": {"final_answer": "5"}},
        {"id": "3", "prompt": "p_err", "think": False, "reference": {"final_answer": "9"}},
    ]

    def test_tot_beats_single_on_accuracy(self):
        row, _ = self._bench(self.RECORDS)
        s, t = row["cells"]["single"], row["cells"]["tot"]
        # single: p_easy ✓, p_hard ✗(41≠42), p_ung ungradable, p_err errored.
        #   graded denominator = {p_easy, p_hard} = 2; correct = 1 → 0.5.
        self.assertEqual((s["n_correct"], s["n_wrong"]), (1, 1))
        self.assertEqual(s["n_ungradable"], 1)
        self.assertEqual(s["n_error"], 1)
        self.assertEqual(s["accuracy"], 0.5)
        # tot: p_easy ✓, p_hard ✓(42), p_ung ungradable, p_err 200 (no breadth-1
        #   error path) but '9'≠ reference → wrong. graded = 3, correct = 2.
        self.assertEqual(t["n_correct"], 2)
        self.assertEqual(t["n_error"], 0)  # no engine error on the tot column
        self.assertAlmostEqual(t["accuracy"], 2 / 3)
        self.assertGreater(row["accuracy_delta_tot_minus_single"], 0)

    def test_ungradable_and_error_excluded_from_denominator(self):
        # MUTATION CHECK: if p_ung (ungradable) or p_err (non-200) leaked into the
        # graded denominator, single accuracy would shift off 1/2.
        row, failures = self._bench(self.RECORDS)
        s = row["cells"]["single"]
        self.assertEqual(s["n_graded"], 2)  # NOT 3 or 4
        self.assertEqual(s["accuracy"], 0.5)
        # the non-200 is surfaced as a disclosed failure, not a silent drop.
        self.assertTrue(any("inferlet -> 500" in f for f in failures),
                        f"expected a 500 failure, got {failures!r}")

    def test_token_cost_ratio_scales_with_width(self):
        # tot generates TOT_WIDTH sibling nodes vs single's 1 → more tokens.
        row, _ = self._bench(self.RECORDS)
        self.assertGreater(row["token_cost_ratio_tot_over_single"], 1.0)
        self.assertEqual(row["cells"]["tot"]["breadth"], a.TOT_WIDTH)
        self.assertEqual(row["cells"]["single"]["breadth"], 1)

    def test_per_token_metrics_use_graded_population_only(self):
        # MUTATION CHECK (F1): the ungradable p_ung run emits 100-word nodes, far
        # larger than the graded p_easy/p_hard runs (3-word nodes). If its tokens
        # leaked into the samples, mean_output_tokens / accuracy_per_ktok would
        # be skewed; they must reflect the GRADED subset alone.
        row, _ = self._bench(self.RECORDS)
        s = row["cells"]["single"]
        # single graded runs = p_easy + p_hard, each 1 node × 3 words → mean 3.0;
        # NOT pulled up toward 100 by the ungradable run, and wall mean is 0.1
        # (the graded runs' wall), NOT 9.9 (the ungradable run's).
        self.assertEqual(s["mean_output_tokens"], 3.0)
        self.assertEqual(s["total_output_tokens"], 6)
        self.assertAlmostEqual(s["mean_wall_s"], 0.1)
        # accuracy_per_ktok divides the graded accuracy by the graded-only mean.
        self.assertAlmostEqual(s["accuracy_per_ktok"], s["accuracy"] / (3.0 / 1000.0))
        # tot column: each graded run forks TOT_WIDTH 3-word nodes → mean 3·k.
        t = row["cells"]["tot"]
        self.assertEqual(t["mean_output_tokens"], 3.0 * a.TOT_WIDTH)


class ColumnConfig(unittest.TestCase):
    def test_single_is_greedy_breadth1_tot_is_sampled_widthk(self):
        self.assertEqual(a.COLUMNS["single"]["breadth"], 1)
        self.assertEqual(a.COLUMNS["single"]["temperature"], 0.0)
        self.assertEqual(a.COLUMNS["tot"]["breadth"], a.TOT_WIDTH)
        self.assertGreater(a.COLUMNS["tot"]["temperature"], 0.0)


if __name__ == "__main__":
    unittest.main()
