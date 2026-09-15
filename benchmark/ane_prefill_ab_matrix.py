#!/usr/bin/env python3
"""ANE-vs-GPU prefill A/B across the installed models.

One variable: `TINYTITAN_PREFILL_ANE`. Arms alternate `off, on, on, off` after a
discarded warm-up per arm, so thermal drift and page-cache state land on both
arms rather than on whichever ran second.

The metric is prefill seconds from the CLI's own footer, on a prompt long enough
to fill more than one 4,096-token chunk — the only workload the sidecar serves
(a short prompt is one partial chunk and deliberately stays on the GPU, and a
non-4,096 prefill chunk never matches the sidecar at all).

The script refuses to report a speedup for an arm that did not use the ANE: the
runtime prints `ane-prefill fallback ... using the GPU path` when a chunk is
ineligible, and such an arm is recorded as fallen back rather than as an ANE
number. A model with no sidecar is reported `no sidecar` — with the switch
explicitly `on`, the runtime fails the load rather than pretending.

  python3 benchmark/ane_prefill_ab_matrix.py \
      --models qwen3.5_2B_4Bit qwen3.5_4B_4Bit --label v5.6 --record
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import statistics
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODELS_DIR = ROOT / "models"
CLI = ROOT / ".build/release/TinyTitanCLI"
RESULTS = ROOT / "benchmark/ane-prefill"

PREFILL_CHUNK = 4096
FALLBACK_MARKER = "ane-prefill fallback"
NO_SIDECAR_MARKER = "is missing; run "

FOOTER = re.compile(
    r"\[stop=(\S+) prefill=(\d+)tok/([\d.]+)s new=(\d+)tok decode=([\d.]+)s "
    r"tok/s=([\d.]+)\]")

# A fixed, self-contained body. Deriving it from repo files would make the
# prompt length move whenever those files are edited, and prompt length is the
# quadratic term this benchmark is about.
PARAGRAPH = (
    "Swift and C++ differ in memory management, dispatch, compilation and type "
    "safety, and a fair comparison names each axis before it judges either "
    "language. ")
PROMPT_CHARACTERS = 32_000


def prompt() -> str:
    repeats = PROMPT_CHARACTERS // len(PARAGRAPH) + 1
    return (PARAGRAPH * repeats)[:PROMPT_CHARACTERS]


def parse_footer(stderr: str) -> dict | None:
    match = FOOTER.search(stderr)
    if not match:
        return None
    return {
        "finish": match.group(1),
        "prefill_tokens": int(match.group(2)),
        "prefill_seconds": float(match.group(3)),
        "decode_tokens": int(match.group(4)),
        "decode_seconds": float(match.group(5)),
        "decode_tokens_per_second": float(match.group(6)),
    }


def run_arm(model: str, ane: bool, timeout: int = 3600) -> dict:
    env = os.environ.copy()
    env["TINYTITAN_PREFILL_ANE"] = "on" if ane else "off"
    command = [str(CLI), "--model", str(MODELS_DIR / model), "--prompt", prompt(),
               "--max-new", "1", "--temperature", "0",
               "--prefill-chunk", str(PREFILL_CHUNK)]
    proc = subprocess.run(command, capture_output=True, text=True, env=env,
                          cwd=ROOT, timeout=timeout)
    arm: dict = {"ane": ane, "exit": proc.returncode}
    if proc.returncode != 0:
        err = proc.stderr
        if NO_SIDECAR_MARKER in err:
            arm["error"] = "no sidecar"
        else:
            # The last few lines, not just one: a load failure prints its
            # reason above whatever the process says on the way out.
            tail = [line.strip() for line in err.strip().splitlines() if line.strip()]
            arm["error"] = " / ".join(tail[-3:])[:400] or f"exit {proc.returncode}"
        return arm
    footer = parse_footer(proc.stderr)
    if footer is None:
        arm["error"] = "no [stop=...] footer"
        return arm
    arm.update(footer)
    arm["used_ane"] = FALLBACK_MARKER not in proc.stderr
    if not arm["used_ane"]:
        arm["fallback_reason"] = next(
            (line.strip() for line in proc.stderr.splitlines()
             if FALLBACK_MARKER in line), FALLBACK_MARKER)
    arm["response_sha256"] = hashlib.sha256(
        proc.stdout.strip().encode()).hexdigest()
    arm["response_head"] = proc.stdout.strip()[:120]
    return arm


def measure(model: str, pairs: int) -> dict:
    """Warm both arms, then interleave off/on/on/off `pairs` times.

    The OFF arm is measured once *before* the ANE arm is attempted, so a model
    the ANE cannot serve — no sidecar, or one whose geometry the runtime
    refuses — still reports its GPU prefill time instead of only the refusal.
    That is the Qwen 3.8 case: it runs, and the ANE is structurally unavailable
    because its sparse indexer is not what a dense sidecar computes.
    """
    arms: dict[str, list[dict]] = {"off": [], "on": []}
    warm_off = run_arm(model, False)
    if "error" in warm_off:
        return {"model": model, "arms": arms,
                "error": f"off warm-up: {warm_off['error']}"}
    arms["off"].append(run_arm(model, False))
    if "error" in arms["off"][-1]:
        return {"model": model, "arms": arms,
                "error": f"off arm: {arms['off'][-1]['error']}"}
    warm_on = run_arm(model, True)
    if "error" in warm_on:
        return {"model": model, "arms": arms, "ane_unavailable": warm_on["error"]}
    arms["on"].append(run_arm(model, True))
    for _ in range(pairs):
        for ane in (False, True, True, False):
            run = run_arm(model, ane)
            if "error" in run:
                return {"model": model, "arms": arms,
                        "error": f"{'on' if ane else 'off'} arm: {run['error']}"}
            arms["on" if ane else "off"].append(run)
    return {"model": model, "arms": arms}


def summarize(record: dict) -> dict:
    out: dict = {"model": record["model"]}
    if "error" in record:
        out["error"] = record["error"]
        return out
    if "ane_unavailable" in record:
        out["ane_unavailable"] = record["ane_unavailable"]
    for name, runs in record["arms"].items():
        good = [r for r in runs if "error" not in r]
        if not good:
            out[name] = {"error": runs[0].get("error", "no runs") if runs
                         else "no runs"}
            continue
        out[name] = {
            "prefill_seconds_median": statistics.median(
                r["prefill_seconds"] for r in good),
            "prefill_tokens": good[0]["prefill_tokens"],
            "used_ane": all(r.get("used_ane", False) for r in good),
            "runs": len(good),
            "digests": sorted({r["response_sha256"] for r in good}),
            "head": good[0].get("response_head", ""),
        }
    off = out.get("off", {}).get("prefill_seconds_median")
    on = out.get("on", {}).get("prefill_seconds_median")
    if off and on and out.get("on", {}).get("used_ane"):
        out["speedup"] = off / on
        out["saved_seconds"] = off - on
    return out


def format_row(r: dict) -> str:
    if "error" in r:
        return (f"{r['model']:<44} {'-':>9} {'-':>9} {'-':>8} {'-':>9}  "
                f"{r['error']}")
    off = r["off"].get("prefill_seconds_median")
    on = r["on"].get("prefill_seconds_median")
    note = ""
    if "ane_unavailable" in r:
        note = f"ANE unavailable: {r['ane_unavailable'][:70]}"
    elif r["on"].get("used_ane") is False:
        note = "ANE arm fell back to the GPU"
    elif not r["off"].get("used_ane", True):
        note = "OFF arm reported an ANE fallback (unexpected)"
    return (f"{r['model']:<44} "
            f"{f'{off:.2f}' if off is not None else '-':>9} "
            f"{f'{on:.2f}' if on is not None else '-':>9} "
            f"{r.get('speedup', 0):>8.3f} "
            f"{str(r.get('on', {}).get('used_ane')):>9}  {note}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", nargs="+", required=True,
                        help="install directory names under models/")
    parser.add_argument("--pairs", type=int, default=1,
                        help="off/on/on/off blocks per model (default 1)")
    parser.add_argument("--label", default=None)
    parser.add_argument("--record", action="store_true",
                        help="write benchmark/ane-prefill/<label>.json")
    args = parser.parse_args()

    header = (f"{'model':<44} {'off s':>9} {'on s':>9} {'speedup':>8} "
              f"{'ANE used':>9}  note")
    print(header, flush=True)

    # Each model is printed as it finishes: a full matrix is hours of prefill,
    # and a table that only appears at the end reports nothing for most of it.
    results = []
    for name in args.models:
        result = summarize(measure(name, args.pairs))
        results.append(result)
        print(format_row(result), flush=True)

    if args.record:
        RESULTS.mkdir(parents=True, exist_ok=True)
        label = args.label or datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
        path = RESULTS / f"{label}.json"
        path.write_text(json.dumps({
            "recorded_at": datetime.datetime.now(
                datetime.timezone.utc).isoformat(timespec="seconds"),
            "prompt_characters": PROMPT_CHARACTERS,
            "prefill_chunk": PREFILL_CHUNK,
            "pairs": args.pairs,
            "results": results,
        }, indent=2) + "\n")
        print(f"\nwrote {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
