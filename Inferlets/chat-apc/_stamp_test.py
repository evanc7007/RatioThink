#!/usr/bin/env python3
"""Unit tests for `_stamp` — review v1 follow-ups.

Run directly (`python3 Inferlets/chat-apc/_stamp_test.py`) or via
the Makefile (`make test-stamp`). Stays standalone-runnable so the
macro-repo does not have to grow a Python test framework just for one
helper.

Coverage:
  * F1 — schema strictness: missing or empty canonical fields fail.
  * F2 — mode normalization: chmod does not change `hash_src_tree`.
  * F6 — submodule_sha refuses an unpopulated Vendor/pie sentinel.
  * F9 — verify raises the friendly diagnostic when WASM_PATH is gone.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from io import BytesIO
from pathlib import Path
from unittest import mock

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
import _stamp  # noqa: E402


STAMP_TEMPLATE = """\
vendor_pie_sha = "{vendor_pie_sha}"
src_sha256     = "{src_sha256}"
wasm_sha256    = "{wasm_sha256}"
wasm_size      = {wasm_size}
"""

GOOD = {
    "vendor_pie_sha": "a" * 40,
    "src_sha256": "b" * 64,
    "wasm_sha256": "c" * 64,
    "wasm_size": "123",
}


def _write_stamp(stamp_path: Path, fields: dict[str, str]) -> None:
    stamp_path.write_text(STAMP_TEMPLATE.format(**fields))


def _stub_compute(values: dict[str, str]):
    """Return a `_stamp.compute` replacement that returns `values`.

    Accepts the `include_wasm` keyword the real `compute` uses; drops
    the wasm fields when False.
    """
    def _fake(*, include_wasm: bool = True) -> dict[str, str]:
        out = {"vendor_pie_sha": values["vendor_pie_sha"], "src_sha256": values["src_sha256"]}
        if include_wasm:
            out["wasm_sha256"] = values["wasm_sha256"]
            out["wasm_size"] = values["wasm_size"]
        return out
    return _fake


class SchemaStrictness(unittest.TestCase):
    """Review v1 F1 — missing or empty canonical fields must fail."""

    def test_blank_wasm_sha256_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            stamp = Path(tmp) / "stamp"
            _write_stamp(stamp, {**GOOD, "wasm_sha256": ""})
            with mock.patch.object(_stamp, "compute", _stub_compute(GOOD)):
                with self.assertRaises(SystemExit) as ctx:
                    _stamp.verify(stamp_path=stamp)
            self.assertIn("wasm_sha256", str(ctx.exception))
            self.assertIn("missing or has empty", str(ctx.exception))

    def test_missing_key_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            stamp = Path(tmp) / "stamp"
            # Omit wasm_sha256 entirely.
            stamp.write_text(
                f'vendor_pie_sha = "{GOOD["vendor_pie_sha"]}"\n'
                f'src_sha256     = "{GOOD["src_sha256"]}"\n'
                f'wasm_size      = {GOOD["wasm_size"]}\n'
            )
            with mock.patch.object(_stamp, "compute", _stub_compute(GOOD)):
                with self.assertRaises(SystemExit) as ctx:
                    _stamp.verify(stamp_path=stamp)
            self.assertIn("wasm_sha256", str(ctx.exception))

    def test_complete_stamp_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            stamp = Path(tmp) / "stamp"
            _write_stamp(stamp, GOOD)
            with mock.patch.object(_stamp, "compute", _stub_compute(GOOD)):
                _stamp.verify(stamp_path=stamp)  # must not raise

    def test_inputs_only_does_not_require_wasm_keys_to_be_compared(self):
        with tempfile.TemporaryDirectory() as tmp:
            stamp = Path(tmp) / "stamp"
            _write_stamp(stamp, GOOD)
            # Schema still requires all four keys to be present even in
            # inputs-only mode (CANONICAL_KEYS is uniform), but only
            # vendor_pie_sha + src_sha256 are *compared*.
            actual = {**GOOD, "wasm_sha256": "0" * 64, "wasm_size": "999"}
            with mock.patch.object(_stamp, "compute", _stub_compute(actual)):
                _stamp.verify(stamp_path=stamp, inputs_only=True)


class ModeNormalization(unittest.TestCase):
    """Review v1 F2 — `chmod +x` must not change `src_sha256`."""

    def _hash_under(self, paths: list[Path]) -> str:
        with mock.patch.object(_stamp, "INFERLET_DIR", paths[0].parent):
            return _stamp.hash_src_tree(paths)

    def test_chmod_does_not_change_src_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            f = tmpdir / "lib.rs"
            f.write_bytes(b"fn main() {}\n")
            os.chmod(f, 0o644)
            before = self._hash_under([f])
            os.chmod(f, 0o755)
            after = self._hash_under([f])
            self.assertEqual(before, after)

    def test_directory_recursion_normalizes_mode(self):
        # Review v2 F7: include a nested file (sub/c.rs) so this test
        # exercises rglob recursion end-to-end. The top-level chmod
        # alone could pass even if dir-walk skipped normalization
        # (because every file path eventually funnels through the
        # same _normalize_tarinfo); a nested file proves the recursive
        # branch reaches the normalizer.
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            src = tmpdir / "src"
            (src / "sub").mkdir(parents=True)
            (src / "a.rs").write_bytes(b"a\n")
            (src / "b.rs").write_bytes(b"b\n")
            (src / "sub" / "c.rs").write_bytes(b"c\n")
            for p in (src / "a.rs", src / "sub" / "c.rs"):
                os.chmod(p, 0o644)
            with mock.patch.object(_stamp, "INFERLET_DIR", tmpdir):
                before = _stamp.hash_src_tree([src])
            for p in (src / "a.rs", src / "sub" / "c.rs"):
                os.chmod(p, 0o755)
            with mock.patch.object(_stamp, "INFERLET_DIR", tmpdir):
                after = _stamp.hash_src_tree([src])
            self.assertEqual(before, after)

    def test_cargo_lock_drift_changes_src_hash(self):
        # Review v2 F2: a Cargo.lock edit must invalidate src_sha256.
        # Build a synthetic SRC_HASH_PATHS rooted at a tmpdir and prove
        # the hash actually moves when the lockfile content changes.
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = Path(tmp)
            src = tmpdir / "src"
            src.mkdir()
            (src / "lib.rs").write_bytes(b"fn main() {}\n")
            cargo_toml = tmpdir / "Cargo.toml"
            cargo_toml.write_bytes(b'[package]\nname = "x"\n')
            cargo_lock = tmpdir / "Cargo.lock"
            cargo_lock.write_bytes(b'# generated\n[[package]]\nname = "a"\nversion = "1.0.0"\n')
            paths = [src, cargo_toml, cargo_lock]
            with mock.patch.object(_stamp, "INFERLET_DIR", tmpdir):
                before = _stamp.hash_src_tree(paths)
            cargo_lock.write_bytes(b'# generated\n[[package]]\nname = "a"\nversion = "1.0.1"\n')
            with mock.patch.object(_stamp, "INFERLET_DIR", tmpdir):
                after = _stamp.hash_src_tree(paths)
            self.assertNotEqual(before, after)


class WriteCleanup(unittest.TestCase):
    """Review v2 F3 — cleanup unlink failures must not mask the upstream error."""

    def test_write_preserves_original_exception_when_unlink_fails(self):
        sentinel_msg = "synthetic-replace-failure-v2"

        def boom_replace(*_a, **_kw):
            raise RuntimeError(sentinel_msg)

        def boom_unlink(*_a, **_kw):
            raise PermissionError("synthetic-cleanup-failure")

        with tempfile.TemporaryDirectory() as tmp:
            stamp = Path(tmp) / "stamp"
            with mock.patch.object(_stamp, "compute", _stub_compute(GOOD)), \
                 mock.patch.object(_stamp.os, "replace", boom_replace), \
                 mock.patch.object(_stamp.os, "unlink", boom_unlink):
                with self.assertRaises(RuntimeError) as ctx:
                    _stamp.write(stamp_path=stamp)
            self.assertEqual(str(ctx.exception), sentinel_msg)


class SubmoduleGuard(unittest.TestCase):
    """Review v1 F6 — empty Vendor/pie must fail loud."""

    def test_unpopulated_sentinel_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            empty = Path(tmp) / "does-not-exist" / "Cargo.toml"
            with mock.patch.object(_stamp, "VENDOR_PIE_SENTINEL", empty):
                with self.assertRaises(SystemExit) as ctx:
                    _stamp.submodule_sha()
            self.assertIn("Vendor/pie submodule is not populated", str(ctx.exception))


class SubmoduleShaErrors(unittest.TestCase):
    """Review v3 — submodule_sha must humanize every subprocess failure mode."""

    def _bypass_sentinel(self):
        # Sentinel check fires before any subprocess call; patch it
        # out so the test exercises ONLY the subprocess error path.
        return mock.patch.object(_stamp, "_assert_vendor_pie_populated", lambda: None)

    def test_git_missing_from_path_raises_friendly_hint(self):
        # Review v3 F1: exec-side failure (git binary absent) must
        # raise SystemExit with the 'git binary not found' hint, NOT
        # a raw FileNotFoundError stack.
        def boom(*_a, **_kw):
            raise FileNotFoundError(2, "No such file or directory", "git")

        with self._bypass_sentinel(), \
             mock.patch.object(_stamp.subprocess, "run", boom):
            with self.assertRaises(SystemExit) as ctx:
                _stamp.submodule_sha()
        msg = str(ctx.exception)
        self.assertIn("git binary not found", msg)
        # Original exception preserved as __cause__ so debuggers can
        # still walk back to the FileNotFoundError.
        self.assertIsInstance(ctx.exception.__cause__, FileNotFoundError)

    def test_calledprocesserror_surfaces_stderr_with_recovery_hint(self):
        # Review v3 F2: F4's translator was previously untested. Lock
        # the user-facing contract (recovery-hint text + stderr
        # passthrough) so a regression that drops `from e`, edits the
        # wording, or reverts to a bare raise gets caught here.
        def boom(*_a, **_kw):
            raise subprocess.CalledProcessError(
                returncode=128,
                cmd=["git", "rev-parse", "HEAD"],
                output="",
                stderr="fatal: not a git repository\n",
            )

        with self._bypass_sentinel(), \
             mock.patch.object(_stamp.subprocess, "run", boom):
            with self.assertRaises(SystemExit) as ctx:
                _stamp.submodule_sha()
        msg = str(ctx.exception)
        self.assertIn("partially detached", msg)
        self.assertIn("fatal: not a git repository", msg)
        self.assertIn("git submodule update --init --recursive", msg)
        self.assertIsInstance(ctx.exception.__cause__, subprocess.CalledProcessError)


class MissingWasmGuard(unittest.TestCase):
    """Review v1 F9 — missing WASM_PATH must raise the friendly hint."""

    def test_compute_raises_friendly_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            ghost = Path(tmp) / "chat-apc.wasm"
            with mock.patch.object(_stamp, "WASM_PATH", ghost), \
                 mock.patch.object(_stamp, "submodule_sha", return_value="a" * 40), \
                 mock.patch.object(_stamp, "hash_src_tree", return_value="b" * 64):
                with self.assertRaises(SystemExit) as ctx:
                    _stamp.compute()
            self.assertIn("missing prebuilt wasm", str(ctx.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
