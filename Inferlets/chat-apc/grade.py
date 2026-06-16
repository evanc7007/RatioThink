"""Deterministic per-dataset graders for the ToT accuracy matrix (#657).

The #652 spec-decode matrix measured throughput only. #657 adds a graded
CORRECTNESS axis: for each prompt, does the model's final answer actually solve
the task? The four datasets here are chosen precisely because they are gradable
WITHOUT a judge model — every verdict is a deterministic function of the model
output and the dataset's own ground truth (the `reference` field emitted by
`Scripts/benchmark/prep_datasets.py`), so the accuracy numbers are reproducible
and free of LLM-as-judge noise:

  * gsm8k_numeric      — numeric exact-match of the final number vs the gold
                         `#### N` answer.
  * humaneval_exec     — pass@1 by executing the shipped `check(entry_point)`.
  * mbpp_exec          — pass@1 by running the shipped assert(s) after setup.
  * jsonschema_validate — the emitted JSON validates against the gold schema.

CODE EXECUTION WARNING: `humaneval_exec`/`mbpp_exec` execute model-generated
Python in a subprocess with a wall-clock timeout. This is intrinsic to code
benchmarks (the reference HumanEval/MBPP harnesses do the same) and is why the
accuracy bench is operator-gated, never CI. The CI self-test only ever execs the
trusted fixtures in `tot_accuracy_real_test.py`.

Each grader returns a `GradeResult(passed, detail)`; `passed is None` marks an
ungradable/measurement error (e.g. empty model output), which the harness keeps
separate from a genuine wrong answer so accuracy isn't silently deflated.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

# Per-task wall-clock cap for executed candidate code (s). Generous enough for
# the trivial HumanEval/MBPP solutions, short enough that a hung/inf-loop
# candidate is graded as a fail rather than wedging the run.
EXEC_TIMEOUT_S = 10


@dataclass
class GradeResult:
    passed: bool | None  # True=correct, False=wrong, None=ungradable (not a wrong answer)
    detail: str


# --- text extraction -------------------------------------------------------

_FENCE_RE = re.compile(r"```(?:[a-zA-Z0-9_+-]*)\n(.*?)```", re.DOTALL)
# A signed integer or decimal, optionally with thousands separators ("1,024").
_NUMBER_RE = re.compile(r"-?\d[\d,]*(?:\.\d+)?")


def extract_code(text: str) -> str:
    """Return the code to run: the first fenced block if the model fenced its
    answer, else the raw text (many models emit bare code on a code prompt)."""
    blocks = _FENCE_RE.findall(text)
    if blocks:
        # Prefer the first block; greedy concatenation would glue prose between
        # multiple blocks into the program.
        return blocks[0]
    return text


def last_number(text: str) -> str | None:
    """The final numeric token in the text, comma-separators stripped. GSM8K
    answers put the result last ("… so the answer is 18"), so the last number is
    the convention used by the reference eval."""
    matches = _NUMBER_RE.findall(text)
    if not matches:
        return None
    return matches[-1].replace(",", "")


def extract_json(text: str) -> str | None:
    """Best-effort: the first balanced JSON object/array in the text. Strips a
    code fence first, then scans for the first `{`/`[` and returns through its
    matching close, so trailing prose ("Here is the JSON: {…}. Hope it helps!")
    does not break parsing."""
    candidate = extract_code(text).strip()
    start = min(
        (i for i in (candidate.find("{"), candidate.find("[")) if i != -1),
        default=-1,
    )
    if start == -1:
        return None
    open_ch = candidate[start]
    close_ch = "}" if open_ch == "{" else "]"
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(candidate)):
        ch = candidate[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return candidate[start:i + 1]
    return None


def _import_lines(prompt: str) -> str:
    """Leading `import`/`from … import` lines of a HumanEval prompt, so a model
    that re-emitted a standalone function still gets the prompt's imports."""
    out = []
    for line in prompt.splitlines():
        s = line.strip()
        if s.startswith("import ") or s.startswith("from "):
            out.append(line)
    return "\n".join(out)


# --- code execution --------------------------------------------------------


def run_program(program: str, timeout: float = EXEC_TIMEOUT_S) -> tuple[bool, str]:
    """Execute `program` in an isolated subprocess. Returns (passed, detail);
    passed is True only on a clean exit 0. An assertion failure, exception, or
    timeout is a graded FAIL (not an error), exactly as the reference code
    benchmarks score it."""
    with tempfile.NamedTemporaryFile(
        "w", suffix=".py", delete=False, encoding="utf-8"
    ) as f:
        f.write(program)
        path = f.name
    try:
        # -I: isolated mode (ignore env/site/user) so the candidate can't reach
        # the harness's installed packages or PYTHON* env. -S as well is too
        # aggressive (blocks `json`-via-site on some builds), so -I only.
        proc = subprocess.run(
            [sys.executable, "-I", path],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if proc.returncode == 0:
            return True, "exit 0"
        tail = (proc.stderr or proc.stdout or "").strip().splitlines()
        return False, (tail[-1] if tail else f"exit {proc.returncode}")
    except subprocess.TimeoutExpired:
        return False, f"timeout >{timeout}s"
    except Exception as e:  # noqa: BLE001
        return None, f"exec error: {e}"
    finally:
        Path(path).unlink(missing_ok=True)


# --- graders ---------------------------------------------------------------


def gsm8k_numeric(output: str, reference: dict) -> GradeResult:
    gold = reference["final_answer"]
    got = last_number(output or "")
    if got is None:
        return GradeResult(None, "no number in model output")
    try:
        ok = abs(float(got) - float(gold)) < 1e-6
    except ValueError:
        ok = got.strip() == str(gold).strip()
    return GradeResult(ok, f"got={got!r} gold={gold!r}")


def humaneval_exec(output: str, reference: dict) -> GradeResult:
    if not (output or "").strip():
        return GradeResult(None, "empty model output")
    code = extract_code(output)
    entry = reference["entry_point"]
    canonical = reference["canonical_prompt"]
    if f"def {entry}" in code:
        # Model re-emitted the whole function; keep the prompt's imports.
        body = f"{_import_lines(canonical)}\n{code}"
    else:
        # Model emitted just the body; continue the prompt's signature.
        body = f"{canonical}{code}"
    program = f"{body}\n\n{reference['test']}\n\ncheck({entry})\n"
    passed, detail = run_program(program)
    return GradeResult(passed, detail)


def mbpp_exec(output: str, reference: dict) -> GradeResult:
    if not (output or "").strip():
        return GradeResult(None, "empty model output")
    code = extract_code(output)
    setup = reference.get("test_setup_code") or ""
    asserts = "\n".join(reference["test_list"])
    program = f"{code}\n\n{setup}\n\n{asserts}\n"
    passed, detail = run_program(program)
    return GradeResult(passed, detail)


def jsonschema_validate(output: str, reference: dict) -> GradeResult:
    raw = extract_json(output or "")
    if raw is None:
        return GradeResult(None, "no JSON object/array in model output")
    try:
        instance = json.loads(raw)
    except json.JSONDecodeError as e:
        return GradeResult(False, f"invalid JSON: {e}")
    try:
        schema = json.loads(reference["json_schema"])
    except json.JSONDecodeError as e:
        # A malformed gold schema is a measurement error, not a wrong answer.
        return GradeResult(None, f"gold schema unparseable: {e}")
    try:
        import jsonschema
        from jsonschema.validators import validator_for
    except ImportError as e:  # noqa: BLE001
        return GradeResult(None, f"jsonschema unavailable: {e}")
    try:
        cls = validator_for(schema)
        cls.check_schema(schema)
        cls(schema).validate(instance)
    except jsonschema.exceptions.SchemaError as e:
        return GradeResult(None, f"gold schema invalid: {e.message}")
    except jsonschema.exceptions.ValidationError as e:
        return GradeResult(False, f"does not validate: {e.message}")
    return GradeResult(True, "validates")


GRADERS: dict[str, Callable[[str, dict], GradeResult]] = {
    "gsm8k_numeric": gsm8k_numeric,
    "humaneval_exec": humaneval_exec,
    "mbpp_exec": mbpp_exec,
    "jsonschema_validate": jsonschema_validate,
}


def grade(grader: str, output: str, reference: dict) -> GradeResult:
    """Dispatch to the named grader. Unknown grader is a hard error (a typo in
    the lock must not silently score everything as wrong)."""
    if grader not in GRADERS:
        raise KeyError(f"unknown grader {grader!r}; known: {sorted(GRADERS)}")
    return GRADERS[grader](output, reference)
