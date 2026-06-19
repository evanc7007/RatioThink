import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import analyze_tree_dump as a  # noqa: E402


class _Verdict:
    passed = False


class AnalyzeTreeDumpTest(unittest.TestCase):
    def test_branch_variation_groups_siblings_by_parent_id(self):
        record = {
            "index": 1,
            "grader": "gsm8k_numeric",
            "reference": {"final_answer": "999"},
            "final_verdict": "fail",
            "selected": "a1",
            "nodes": [
                {"id": "p1", "depth": 1, "parent_id": "root", "content": "parent one", "score": 1},
                {"id": "p2", "depth": 1, "parent_id": "root", "content": "parent two", "score": 1},
                {"id": "a1", "depth": 2, "parent_id": "p1", "content": "dup", "score": 1},
                {"id": "a2", "depth": 2, "parent_id": "p1", "content": "dup", "score": 1},
                {"id": "b1", "depth": 2, "parent_id": "p2", "content": "left", "score": 1},
                {"id": "b2", "depth": 2, "parent_id": "p2", "content": "right", "score": 1},
            ],
        }
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "dump.jsonl"
            path.write_text(json.dumps(record) + "\n")
            out = io.StringIO()
            with mock.patch.object(a.g, "grade", return_value=_Verdict()), \
                    contextlib.redirect_stdout(out):
                a.analyze(str(path))
        self.assertIn("0.83 over 3 sibling-groups", out.getvalue())


if __name__ == "__main__":
    unittest.main()
