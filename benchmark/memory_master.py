#!/usr/bin/env python3.13
"""Drive the ten master prompts through the memory arms.

One scenario per process (`TINYTITAN_MASTER_SCENARIO`), one arm per invocation,
mirroring `memory_book.py`'s contract with `memval_run.sh`:

    TINYTITAN_MASTER_SCENARIO=ledger python3 benchmark/memory_master.py auto
    TINYTITAN_MASTER_SCENARIO=ledger python3 benchmark/memory_master.py report

**Scoring is the point of this module.** `master_scenarios.py` derives the
foundation set (keys that never change) and the carryable set (keys that change
at least once) from the timeline. Foundation is a no-regression check; carryable
is the signal; and a **stale** answer — the previous value, given after a
change — is counted separately, because a stale fact is worse than a missing
one. Every number is recomputed from the stored answers, so a scoring change
applies to runs already on disk.

Pong is the exception: its rules are the model's own session-1 choice, so the
run stores that JSON block as `self_truth` and later sessions are scored against
it.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scenarios = _load("master_scenarios", "benchmark/master_scenarios.py")

PORT = int(os.environ.get("TINYTITAN_PORT", "8096"))
BASE = f"http://127.0.0.1:{PORT}/v1"
OUT = Path(os.environ.get("TINYTITAN_MEMVAL_RESULTS",
                          ROOT / ".build/benchmark-logs/memory-master"))
RUN = os.environ.get("TINYTITAN_MEMVAL_RUN", "1")
SERVER_LOG = os.environ.get("TINYTITAN_MEMVAL_SERVER_LOG")
NAME = os.environ.get("TINYTITAN_MASTER_SCENARIO", "photograph")
SPEC = scenarios.SCENARIOS[NAME]
ARMS = ("summary", "auto")
TEMPERATURE = os.environ.get("TINYTITAN_MEMVAL_TEMPERATURE")
# Pong's stages emit a whole file of code; the others emit sections. The ceiling
# is room for the work *and* the closing quiz: at 2,500 a session that deliberates
# about formatting was cut off before the JSON block, which scored as a full set
# of misses and journalled a truncated session into memory. Compliant sessions
# never approached the old cap, so raising it changes nothing for them.
MAX_TOKENS = 5_200 if NAME == "pong" else 6_000

SUMMARY_PROMPT = (
    "Summarize, in at most 200 words, everything a worker of the next session "
    "must not contradict: every fixed fact, every decision and its reason, and "
    "the current value of everything that has changed. State the current value, "
    "not the history."
)


def sampling() -> dict:
    return {} if TEMPERATURE is None else {"temperature": float(TEMPERATURE)}


def post(messages, model, max_tokens=MAX_TOKENS):
    body = json.dumps({"model": model, "messages": messages,
                       "max_completion_tokens": max_tokens,
                       **sampling()}).encode()
    request = urllib.request.Request(f"{BASE}/chat/completions", data=body,
                                     headers={"Content-Type": "application/json"})
    started = time.time()
    with urllib.request.urlopen(request, timeout=3_600) as response:
        payload = json.load(response)
    choice = payload["choices"][0]["message"]
    usage = payload.get("usage", {})
    return {"content": choice.get("content") or "",
            "finish_reason": choice.get("finish_reason") or "",
            "prompt_tokens": usage.get("prompt_tokens", 0),
            "completion_tokens": usage.get("completion_tokens", 0),
            "seconds": time.time() - started}


def model_id() -> str:
    with urllib.request.urlopen(f"{BASE}/models", timeout=30) as response:
        return json.load(response)["data"][0]["id"]


def consolidation_outcomes() -> tuple[int, int]:
    """The engine's decisions so far: (distilled, skipped).

    Every session the engine considers ends in one of two lines, so a caller can
    wait for *a decision* rather than for a distillation. Counting only
    `memory consolidated session=` made a skip — "nothing to distil" — look like
    work still in flight, and the wait then burned its whole limit, which put up
    to 600 s of harness overhead into the memory arm's wall clock and made the
    cost comparison read as if every session paid a consolidation generation.
    The store's own `memory memory session=<id> consolidated N records` line is a
    write summary, not an engine decision, and is deliberately not counted.
    """
    if not SERVER_LOG or not os.path.exists(SERVER_LOG):
        return (-1, -1)
    distilled = skipped = 0
    with open(SERVER_LOG, errors="replace") as handle:
        for line in handle:
            if "memory consolidated session=" in line:
                distilled += 1
            elif "memory consolidation skipped session=" in line:
                skipped += 1
    return (distilled, skipped)


def wait_for_consolidation(before: tuple[int, int], limit: float = 600) -> float:
    if before[0] < 0:
        return 0.0
    started = time.time()
    while time.time() - started < limit:
        if consolidation_outcomes() != before:
            return time.time() - started
        time.sleep(2)
    print("  (no consolidation decision within the wait)")
    return time.time() - started


def assert_arm_is_real(arm: str, prompt_tokens: int) -> None:
    """A memory arm's session-1 prompt carries the fragment; a bare one does not."""
    if arm == "auto" and prompt_tokens < 200:
        raise SystemExit(
            f"ABORT: arm 'auto' saw {prompt_tokens} prompt tokens in session 1; the "
            "memory fragment is missing. Check TINYTITAN_MEMORY on the server.")


def run_arm(arm: str) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    model = model_id()
    memory_on = arm != "summary"
    results = []
    carried = None
    self_truth = None
    for session in range(1, SPEC["sessions"] + 1):
        prompt = scenarios.session_prompt(
            SPEC, session, carried if arm == "summary" else None)
        seen = consolidation_outcomes()
        result = post([{"role": "user", "content": prompt}], model)
        answers = scenarios.extract_quiz(result["content"], SPEC["keys"])
        result.update(session=session, answers=answers)
        if not answers:
            print(f"  WARNING: {NAME}/{arm}/session {session} produced no quiz "
                  f"(finish={result.get('finish_reason') or 'unknown'}); "
                  f"scored as invalid, not as a total miss")
        if SPEC["self_chosen"] and session == 1:
            self_truth = {key: answers.get(key) for key in SPEC["keys"]}
            result["self_truth"] = self_truth
        (OUT / f"{NAME}-{arm}-r{RUN}-{session:02d}.md").write_text(result["content"])
        print(f"{NAME}/{arm}/session {session:2d}: {result['completion_tokens']} tokens, "
              f"{result['seconds']:.0f}s, prompt {result['prompt_tokens']}, "
              f"answers {len(answers)}/{len(SPEC['keys'])}")
        if session == 1:
            assert_arm_is_real(arm, result["prompt_tokens"])
        if arm == "summary":
            summary = post([{"role": "user", "content": prompt},
                            {"role": "assistant", "content": result["content"]},
                            {"role": "user", "content": SUMMARY_PROMPT}], model,
                           max_tokens=600)
            carried = summary["content"]
            result.update(summary_prompt_tokens=summary["prompt_tokens"],
                          summary_completion_tokens=summary["completion_tokens"],
                          summary_seconds=summary["seconds"])
            (OUT / f"{NAME}-{arm}-r{RUN}-{session:02d}-summary.md").write_text(carried)
        result["consolidation_wait"] = (
            wait_for_consolidation(seen) if memory_on else 0.0)
        results.append(result)
        (OUT / f"{NAME}-{arm}-r{RUN}.json").write_text(json.dumps(results, indent=2))


def expected_for(session: int, self_truth):
    if SPEC["self_chosen"]:
        return None if session == 1 else self_truth
    return SPEC["truth"](session)


def history(session: int, self_truth, key: str):
    """(session, value) for this key in every earlier session that had one."""
    out = []
    for earlier in range(1, session):
        expected = expected_for(earlier, self_truth)
        if expected is not None and key in expected:
            out.append((earlier, expected[key]))
    return out


def score_run(results: list) -> dict:
    """Per-session scores, recomputed from the stored answers."""
    self_truth = results[0].get("self_truth")
    scored = []
    for result in results:
        session = result["session"]
        expected = expected_for(session, self_truth)
        row = {"session": session, "foundation": [0, 0], "carryable": [0, 0],
               "stale": 0, "wrong": [], "invalid": False,
               "finish_reason": result.get("finish_reason", ""),
               "prompt_tokens": result["prompt_tokens"],
               "completion_tokens": result["completion_tokens"],
               "seconds": result["seconds"],
               "wait": result.get("consolidation_wait", 0.0)}
        if expected is None:
            scored.append(row)
            continue
        if not result["answers"]:
            # No quiz at all: the instrument failed, usually a completion cut off
            # by the token cap before the JSON block. Scoring it would record a
            # full set of misses that say nothing about memory, so the session is
            # excluded from the denominators and named in the report instead.
            row["invalid"] = True
            scored.append(row)
            continue
        for key in SPEC["keys"]:
            if key not in expected:
                continue
            ok = scenarios.hit(expected[key], result["answers"].get(key))
            bucket = "carryable" if key in SPEC["carryable"] else "foundation"
            if session > 1:
                row[bucket][1] += 1
                if ok:
                    row[bucket][0] += 1
                else:
                    row["wrong"].append(key)
                    # Stale: the answer is a value this key really held before.
                    if any(scenarios.hit(old, result["answers"].get(key))
                           for _, old in history(session, self_truth, key)):
                        row["stale"] += 1
        scored.append(row)
    return {"name": NAME, "sessions": scored}


def load_runs() -> dict:
    runs: dict[str, list] = {}
    for path in sorted(OUT.glob(f"{NAME}-*-r*.json")):
        stem = path.stem.rsplit("-r", 1)[0]
        arm = stem.rsplit("-", 1)[-1]
        if arm in ARMS:
            runs.setdefault(arm, []).append(score_run(json.loads(path.read_text())))
    return runs


def report() -> None:
    runs = load_runs()
    print(f"\n=== {NAME} ({SPEC['domain']}, {SPEC['sessions']} sessions) "
          f"foundation={len(SPEC['foundation'])} carryable={len(SPEC['carryable'])}")
    print(f"{'arm':8s} {'foundation':>14s} {'carryable':>14s} {'stale':>6s} "
          f"{'prompt':>8s} {'completion':>11s} {'seconds':>8s}")
    for arm in ARMS:
        for run in runs.get(arm, []):
            foundation = [0, 0]
            carryable = [0, 0]
            stale = 0
            prompt = completion = seconds = 0
            for row in run["sessions"]:
                foundation[0] += row["foundation"][0]
                foundation[1] += row["foundation"][1]
                carryable[0] += row["carryable"][0]
                carryable[1] += row["carryable"][1]
                stale += row["stale"]
                prompt += row["prompt_tokens"]
                completion += row["completion_tokens"]
                seconds += row["seconds"] + row["wait"]
            pct = (lambda pair: f"{100 * pair[0] / pair[1]:.0f}%"
                   if pair[1] else "n/a")
            print(f"{arm:8s} {foundation[0]}/{foundation[1]} {pct(foundation):>5s} "
                  f"{carryable[0]}/{carryable[1]} {pct(carryable):>5s} {stale:6d} "
                  f"{prompt:8d} {completion:11d} {seconds:8.0f}")
            invalid = [r for r in run["sessions"] if r.get("invalid")]
            if invalid:
                named = ", ".join(
                    f"{r['session']} ({r['finish_reason'] or 'no finish reason'})"
                    for r in invalid)
                print(f"         excluded: {len(invalid)} session(s) with no quiz — "
                      f"{named}")
    # The one line a suite-level reader needs: carryable carried, and stale.
    print("carryable carried (sessions 2+), and stale old values:")
    for arm in ARMS:
        for run in runs.get(arm, []):
            carried = sum(r["carryable"][0] for r in run["sessions"])
            total = sum(r["carryable"][1] for r in run["sessions"])
            stale = sum(r["stale"] for r in run["sessions"])
            print(f"  {arm:8s} {carried}/{total}  stale {stale}")
            misses = [f"{r['session']}:{key}" for r in run["sessions"] for key in r["wrong"]]
            if misses:
                print(f"    misses: {' '.join(misses)}")


def report_all(root: Path) -> None:
    """Every master scenario that has results under `root`, one line each."""
    print(f"\n{'scenario':12s} {'arm':8s} {'carryable':>14s} {'stale':>6s} {'foundation':>14s}")
    for name in scenarios.SCENARIOS:
        for arm in ARMS:
            paths = sorted(root.glob(f"memory-{name}-*/{name}-{arm}-r*.json"))
            if not paths:
                continue
            spec = scenarios.SCENARIOS[name]
            carried = total = stale = foundation = foundation_total = 0
            for path in paths:
                run = score_run(json.loads(path.read_text()))
                for row in run["sessions"]:
                    carried += row["carryable"][0]
                    total += row["carryable"][1]
                    foundation += row["foundation"][0]
                    foundation_total += row["foundation"][1]
                    stale += row["stale"]
            print(f"{name:12s} {arm:8s} {carried:6d}/{total:<5d} {stale:6d} "
                  f"{foundation:6d}/{foundation_total:<5d}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "report"
    if command in ARMS:
        run_arm(command)
    elif command == "report-all":
        report_all(OUT.parent)
    else:
        report()
