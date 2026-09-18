#!/usr/bin/env python3.13
"""Would a caller get anything for a T7 judgement? Recall, measured.

T7 is 100% on the main benchmark's pairs and has no caller: `memory_search` is
a tool call the client's turn waits on, and a judgement costs 15.2 s on the 4B
(`docs/side-engine-tasks.md`). So the question a caller has to answer first is
what the ranking is worth. This compares the deterministic token ranking
`MemoryRanking` uses — a term in the key scores 3, in the value 1, and a fact
sharing no term is not returned at all — against asking the engine, for each
fact, whether it could answer the question.

The questions are authored to give the token ranking a hard time: they avoid
the target's own words where they can, name the attribute rather than the
holder, or ask about the value through the key.

    python3.13 benchmark/side_engine_recall.py --prepare jobs.jsonl
    .build/release/TinyTitanBench cpu35batch <install> jobs.jsonl done.jsonl
    python3.13 benchmark/side_engine_recall.py --score done.jsonl

Only an authored set can do this — the book's records have no questions
attached — so every case is marked as such.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tasks = _load("side_engine_tasks", "benchmark/side_engine_tasks.py")
BIBLE = tasks.BIBLE

# (question, the fact that answers it, what makes it hard for the token rank,
#  whether the label really is the fact that answers the question)
#
# The last two were labelled too loosely and the engine's NO is defensible:
# "the lighthouse keeper's son" says whose son Marcus is, not what he does for a
# living or who his family is. They stay in the run because removing a case
# after seeing the answer is how a benchmark stops meaning anything, and they
# are excluded from the totals for the same reason the model was right to
# refuse them.
QUESTIONS = [
    ("Does it ever rain in this town?", "rules/weather",
     "the answer is in the value, and 'town' points at another fact", True),
    ("How often does the boat cross the water?", "rules/ferry",
     "no word in common with the fact", True),
    ("Who keeps the town's records?", "characters/ines/role",
     "'town' gives a different fact the higher score", True),
    ("What colour are Marcus's eyes?", "characters/marcus/eyes",
     "the control: the token rank should win this one", True),
    ("What does Marcus do for a living?", "characters/marcus/role",
     "the label does not hold: the fact is not about his work", False),
    ("What is Marcus's family?", "characters/marcus/role",
     "the label does not hold: the fact says whose son he is", False),
]


def terms_of(text: str) -> list[str]:
    return [t for t in re.split(r"[^0-9a-z]+", text.lower()) if len(t) > 2]


def deterministic_score(question: str, key: str, value: str) -> float:
    """The term scoring in `MemoryRanking.textScore`, tags aside."""
    score = 0.0
    for term in terms_of(question):
        if term in key.lower():
            score += 3
        if term in value.lower():
            score += 1
    return score


def deterministic_rank(question: str) -> list[str]:
    """What `memory_search` would return, best first.

    A fact sharing no term scores 0 and is not returned at all, which is the
    behaviour being measured.
    """
    scored = [(deterministic_score(question, key, value), key)
              for key, value in BIBLE.items()]
    scored = [pair for pair in scored if pair[0] > 0]
    scored.sort(key=lambda pair: -pair[0])
    return [key for _, key in scored]


def cases() -> list[dict]:
    jobs: list[dict] = []
    for question, target, why, _ in QUESTIONS:
        for key, value in BIBLE.items():
            job = tasks.job(
                "T7",
                f"QUESTION: {question}\nFACT: {key} = {value}\nCould this fact answer it?",
                "YES" if key == target else "NO",
                f"{target} <- {why}", authored=True)
            job["question"] = question
            job["target"] = target
            job["fact"] = key
            jobs.append(job)
    return jobs


def prepare(path: Path) -> int:
    jobs = cases()
    path.write_text("\n".join(json.dumps(j) for j in jobs) + "\n")
    print(f"{len(jobs)} cases -> {path}")
    print(f"  {len(QUESTIONS)} questions x {len(BIBLE)} facts")
    return 0


def recall(rank: list[str], target: str, k: int) -> bool:
    return target in rank[:k]


def score(path: Path) -> int:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    by_question: dict[str, list[dict]] = {}
    for row in rows:
        by_question.setdefault(row["question"], []).append(row)

    det_hits = {1: 0, 3: 0}
    t7_hits = {1: 0, 3: 0}
    fair_total = 0
    print(f"{'question':46s} {'det@1':6s} {'det@3':6s} {'t7@1':6s} {'t7@3':6s}")
    for question, target, _, fair in QUESTIONS:
        group = by_question.get(question)
        if not group:
            continue
        yes = {row["fact"]: (row.get("completion") or "").strip().upper().startswith("YES")
               for row in group}
        # T7 first: the facts it says could answer, then the rest, each block in
        # the store's own order.
        t7_rank = [key for key in BIBLE if yes.get(key)] + \
                  [key for key in BIBLE if not yes.get(key)]
        det_rank = deterministic_rank(question)
        if fair:
            fair_total += 1
            for k in (1, 3):
                det_hits[k] += recall(det_rank, target, k)
                t7_hits[k] += recall(t7_rank, target, k)
        mark = "" if fair else "  (label does not hold, not counted)"
        print(f"{question[:44]:46s} "
              f"{'hit' if recall(det_rank, target, 1) else '-':6s} "
              f"{'hit' if recall(det_rank, target, 3) else '-':6s} "
              f"{'hit' if recall(t7_rank, target, 1) else '-':6s} "
              f"{'hit' if recall(t7_rank, target, 3) else '-':6s}{mark}")
    print()
    print(f"token ranking: recall@1 {det_hits[1]}/{fair_total}  recall@3 {det_hits[3]}/{fair_total}")
    print(f"side-engine:   recall@1 {t7_hits[1]}/{fair_total}  recall@3 {t7_hits[3]}/{fair_total}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prepare", type=Path)
    ap.add_argument("--score", type=Path)
    args = ap.parse_args()
    if args.prepare:
        return prepare(args.prepare)
    if args.score:
        return score(args.score)
    ap.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
