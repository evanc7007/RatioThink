"""Offline mechanism analysis of a ToT tree dump (#657 gap autopsy).

Reads the JSONL produced by tot_wasm_before.py with DUMP_TREE=1 (one record per
prompt: prompt, reference, grader, selected, final_answer, nodes[]) and answers
WHY the wasm math arm trails the python faithful harness — without any engine.

Per prompt it grades EVERY node's content with grade.py (the same oracle) and
classifies, for failures:

  SELECTION/SYNTHESIS LOSS — a correct answer EXISTED in the tree but the final
    (selected/synthesized) answer was wrong. The search found it; the scorer or
    the post-search synthesis dropped it. Fixable in the selection/synthesis.
  GENERATION LOSS — no node in the tree was correct. The decomposition / step
    generation never produced the right reasoning. A harder, model-side gap.

Plus the sub-diagnostics: branch variation (distinct vs near-dup siblings under
the same parent), score spread (does value×N discriminate or saturate?), and
synthesis corruption (selected node correct but synthesized final answer wrong).

Run::

    uv run --with jsonschema python Inferlets/chat-apc/analyze_tree_dump.py tot_tree_dump.jsonl
"""
from __future__ import annotations

import json
import sys
from collections import Counter

import grade as g


def _passed(grader: str, text: str, ref: dict) -> bool | None:
    try:
        return g.grade(grader, text or "", ref).passed
    except Exception:  # noqa: BLE001  a node may carry junk; treat as ungradable
        return None


def _norm(s: str) -> str:
    return " ".join((s or "").split()).lower()


def analyze(path: str) -> None:
    with open(path) as fh:
        records = [json.loads(line) for line in fh if line.strip()]
    if not records:
        print("empty dump")
        return

    n = len(records)
    fails = sel_loss = gen_loss = synth_corrupt = 0
    correct_in_tree_count = 0
    score_hist: Counter = Counter()
    dup_ratios: list[float] = []
    per_prompt = []

    for r in records:
        grader, ref = r["grader"], r["reference"]
        nodes = r.get("nodes") or []
        final_ok = r.get("final_verdict") == "PASS"
        # grade every node
        graded = [(_passed(grader, nd.get("content"), ref), nd) for nd in nodes]
        correct_nodes = [nd for ok, nd in graded if ok is True]
        any_correct = bool(correct_nodes)
        if any_correct:
            correct_in_tree_count += 1

        # score distribution (saturation check)
        for nd in nodes:
            sc = nd.get("score")
            score_hist[sc if sc is not None else "none"] += 1

        # branch variation: siblings are nodes at the same depth with the same
        # parent. Grouping by depth alone mixes cousins and can make separate
        # branches look like duplicate siblings. Older dumps lack parent_id;
        # they fall back to one depth-level group for backward compatibility.
        by_sibling_group: dict = {}
        for nd in nodes:
            key = (nd.get("depth"), nd.get("parent_id"))
            by_sibling_group.setdefault(key, []).append(_norm(nd.get("content") or ""))
        for sibs in by_sibling_group.values():
            if len(sibs) > 1:
                dup_ratios.append(len(set(sibs)) / len(sibs))  # 1.0 = all distinct

        # selected node correctness (synthesis corruption check)
        sel_id = r.get("selected")
        sel_node = next((nd for nd in nodes if nd.get("id") == sel_id), None)
        sel_node_ok = _passed(grader, (sel_node or {}).get("content"), ref) if sel_node else None

        if not final_ok:
            fails += 1
            if any_correct:
                sel_loss += 1
            else:
                gen_loss += 1
        # synthesis corruption: the SELECTED node was correct but the final
        # (synthesized) answer scored wrong → synthesis turned right into wrong.
        if sel_node_ok is True and not final_ok:
            synth_corrupt += 1

        per_prompt.append({
            "index": r.get("index"), "final_ok": final_ok,
            "correct_in_tree": any_correct, "selected_node_ok": sel_node_ok,
            "n_correct_nodes": len(correct_nodes), "n_nodes": len(nodes),
        })

    print(f"=== ToT tree-dump mechanism analysis ({path}) ===")
    print(f"prompts: {n} | final PASS: {n - fails} | final FAIL: {fails}")
    print(f"correct answer present somewhere in the tree: {correct_in_tree_count}/{n}")
    print()
    print("FAILURE DECOMPOSITION:")
    print(f"  SELECTION/SYNTHESIS loss (right answer in tree, not chosen): {sel_loss}/{fails}")
    print(f"  GENERATION loss (no correct node anywhere):                  {gen_loss}/{fails}")
    print(f"  synthesis corruption (selected node correct → final wrong):  {synth_corrupt}")
    print()
    avg_dup = sum(dup_ratios) / len(dup_ratios) if dup_ratios else float("nan")
    print(f"branch variation (distinct-sibling ratio, 1.0=all distinct): {avg_dup:.2f} "
          f"over {len(dup_ratios)} sibling-groups")
    print(f"score distribution: {dict(sorted(score_hist.items(), key=lambda x: str(x[0])))}")
    print()
    print("per-prompt (index: final / correct_in_tree / selected_node_ok / #correct_nodes):")
    for p in per_prompt:
        flag = "" if p["final_ok"] else ("  <- SEL-LOSS" if p["correct_in_tree"]
                                         else "  <- GEN-LOSS")
        print(f"  {p['index']:>3}: {'PASS' if p['final_ok'] else 'FAIL'} / "
              f"in_tree={p['correct_in_tree']} / sel_ok={p['selected_node_ok']} / "
              f"{p['n_correct_nodes']}/{p['n_nodes']}{flag}")


if __name__ == "__main__":
    analyze(sys.argv[1] if len(sys.argv) > 1 else "tot_tree_dump.jsonl")
