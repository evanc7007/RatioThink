import asyncio
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.modules.setdefault("pie_client", types.SimpleNamespace(PieClient=object))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import tot_wasm_before as w  # noqa: E402


class _Verdict:
    def __init__(self, passed):
        self.passed = passed


class WasmBeforeAccountingTest(unittest.TestCase):
    def test_run_dataset_counts_ungradable_in_measured_population(self):
        records = [
            {"prompt": "p1", "reference": {"final_answer": "1"}},
            {"prompt": "p2", "reference": {"final_answer": "2"}},
            {"prompt": "p3", "reference": {"final_answer": "3"}},
        ]

        async def fake_tot_once(_http_c, _base_url, prompt, _depth):
            return {"p1": "1", "p2": "no number", "p3": ""}[prompt], {
                "selected": "n1", "ok_nodes": 1
            }

        def fake_grade(_grader, answer, _reference):
            return _Verdict({"1": True, "no number": None, "": False}[answer])

        with mock.patch.object(w.base, "FAMILY", {"gsm8k": "math"}), \
                mock.patch.object(w.base, "_load_prompts", return_value=(records, 10)), \
                mock.patch.object(w, "_tot_once", side_effect=fake_tot_once), \
                mock.patch.object(w.g, "grade", side_effect=fake_grade):
            row = asyncio.run(w._run_dataset(object(), "http://example", "gsm8k", "gsm8k_numeric"))

        self.assertEqual(row["graded"], 2)
        self.assertEqual(row["correct"], 1)
        self.assertEqual(row["n_ungradable"], 1)
        self.assertEqual(row["measured"], 3)
        self.assertEqual(row["coverage"], {"measured": 3, "total": 10})

    def test_reasoning_defaults_and_legend_disclose_numeric_majority_no_synthesis(self):
        self.assertEqual(w._default_datasets("reasoning"), ["gsm8k"])
        legend = w._legend("reasoning")
        self.assertIn("numeric-majority", legend)
        self.assertIn("no final synthesis", legend)
        self.assertNotIn("LLM value-judge select", legend)

    def test_chat_defaults_and_legend_keep_shipped_value_judge_contract(self):
        self.assertEqual(w._default_datasets("chat"), ["gsm8k", "humaneval"])
        legend = w._legend("chat")
        self.assertIn("LLM value-judge select", legend)
        self.assertIn("code NOT executed", legend)


if __name__ == "__main__":
    unittest.main()
