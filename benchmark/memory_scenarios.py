#!/usr/bin/env python3.13
"""Three more worlds for the memory tests, so the judge comparison is diverse.

`book` and `pong` differ in domain but share a shape: a fixed set of facts set
in session one, then a handful of changes. Three worlds are added that pull that
shape apart, and each is one the two original scenarios do not cover:

  ops       an infrastructure runbook. Short, numeric, arbitrary, and heavily
            revised; every decision is load-bearing and none is derivable.
  lab       a research protocol. Numeric constraints and a safety rule, where a
            value is *corrected* rather than allowed to change, and a second
            constraint is revised.
  contract  a contract review. Clause text and a governing-law rule, where an
            amendment supersedes a clause and a definition must not be
            re-derived.

Each declares its facts, the sessions that change them, and questions whose
answer is in the store. `cases()` turns them into the same one-decision jobs
`side_engine_tasks.py` prepares, so a judge comparison runs over five worlds.

    python3.13 benchmark/memory_scenarios.py --prepare /tmp/scenarios.jsonl
    python3.13 benchmark/side_engine_judges.py --jobs /tmp/scenarios.jsonl \
        --judge cpu:models/qwen3.5_4B_4Bit
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tasks = _load("side_engine_tasks", "benchmark/side_engine_tasks.py")


# --------------------------------------------------------------------------
# The three worlds
# --------------------------------------------------------------------------
#
# `facts`   the arbitrary, standing facts a later session needs.
# `changed` session -> [(key, new value, the line that says so)]
# `narration` lines that are about the session rather than the world: T2 NO.
# `questions` (question, the key that answers it, a distractor key).
# `rules`   (key, rule text, earlier, now, truth) for T4, plus the no-rule pair.
#
SCENARIOS: dict[str, dict] = {
    "ops": {
        "facts": {
            "decisions/datastore": "Postgres 16 on db-7",
            "decisions/queue": "single-threaded, deliberately: it prevents a "
                               "race in background sync",
            "config/api_port": "8443",
            "config/region": "eu-west-1",
            "rules/rollback": "the previous release is kept for 48 hours",
        },
        "changed": {
            2: [("config/api_port", "9443",
                 "The API moved to 9443 behind the new proxy.")],
            3: [("decisions/datastore",
                 "ClickHouse for analytics, Postgres for OLTP",
                 "Analytics moved to ClickHouse; Postgres stays for OLTP.")],
            4: [("rules/rollback", "the previous release is kept for 72 hours",
                 "The rollback window is 72 hours now.")],
        },
        "narration": "The proxy change went smoothly and we moved on to the next ticket.",
        "questions": [
            ("Which port does the API listen on?", "config/api_port", "config/region"),
            ("Why is the sync queue single-threaded?", "decisions/queue",
             "decisions/datastore"),
            ("How long is a release kept for rollback?", "rules/rollback",
             "config/api_port"),
        ],
        "disagree": ("config/api_port", "8443", "config/api_port", "9443", "YES"),
        "agree": ("config/region", "eu-west-1", "config/zone", "eu-west-1", "NO"),
        "duplicate": ("decisions/queue",
                      "single-threaded, deliberately: it prevents a race in background sync",
                      "decisions/sync_model",
                      "the sync path is single-threaded to avoid a race", "YES"),
        "not_duplicate": ("config/api_port", "8443", "config/admin_port", "9090", "NO"),
        "rule_conflict": ("config/api_port", "8443", "9443",
                          "the API port is fixed and must never change", "CONFLICT"),
        "rule_update": ("config/api_port", "8443", "9443",
                        "the rollback window is fixed and must never change",
                        "UPDATE"),
    },
    "lab": {
        "facts": {
            "protocol/reagent": "0.5 M Tris",
            "protocol/incubation": "37 C for 30 minutes",
            "rules/safety": "never heat the sample above 60 C",
            "equipment/centrifuge": "the Beckman on bench 3",
        },
        "changed": {
            2: [("protocol/reagent", "0.25 M Tris",
                 "Correction: the reagent is 0.25 M Tris, not 0.5 M.")],
            3: [("equipment/centrifuge",
                 "the Eppendorf while the Beckman is serviced",
                 "The Beckman is out for service; use the Eppendorf.")],
            4: [("protocol/incubation", "37 C for 45 minutes",
                 "Incubation is now 45 minutes.")],
        },
        "narration": "Today we ran the third batch and it looked fine under the lamp.",
        "questions": [
            ("What temperature and time is the incubation?", "protocol/incubation",
             "protocol/reagent"),
            ("What is the reagent concentration?", "protocol/reagent",
             "equipment/centrifuge"),
            ("Which centrifuge should be used?", "equipment/centrifuge",
             "protocol/incubation"),
        ],
        "disagree": ("protocol/incubation", "37 C for 30 minutes",
                     "protocol/incubation", "70 C for 10 minutes", "YES"),
        "agree": ("protocol/incubation", "37 C for 45 minutes",
                  "protocol/temperature", "37 C", "NO"),
        "duplicate": ("protocol/reagent", "0.25 M Tris",
                      "protocol/buffer", "Tris at 0.25 M", "YES"),
        "not_duplicate": ("equipment/centrifuge", "the Eppendorf",
                          "equipment/incubator", "the Memmert", "NO"),
        "rule_conflict": ("protocol/reagent", "0.5 M Tris", "0.25 M Tris",
                          "reagent concentrations are fixed and must never change",
                          "CONFLICT"),
        "rule_update": ("protocol/incubation", "37 C for 30 minutes",
                        "37 C for 45 minutes",
                        "the reagent concentration is fixed and must never change",
                        "UPDATE"),
    },
    "contract": {
        "facts": {
            "agreement/governing_law": "the laws of Singapore",
            "clause/termination": "either party may terminate on 30 days' notice",
            "clause/liability_cap": "liability is capped at the fees paid in the last 12 months",
            "parties/client": "Northwind Trading",
            "state/signing": "unsigned",
        },
        "changed": {
            2: [("clause/termination",
                 "either party may terminate on 60 days' notice",
                 "The amendment extends termination notice to 60 days.")],
            3: [("clause/liability_cap",
                 "liability is capped at 12 months' fees, except for gross negligence",
                 "The cap now carves out gross negligence.")],
            4: [("agreement/governing_law", "the laws of England and Wales",
                 "The governing law is England and Wales.")],
        },
        "narration": "We discussed the termination clause at length in the meeting.",
        "questions": [
            ("What is the termination notice period?", "clause/termination",
             "clause/liability_cap"),
            ("Which law governs the agreement?", "agreement/governing_law",
             "parties/client"),
            ("What is the liability cap?", "clause/liability_cap",
             "clause/termination"),
        ],
        "disagree": ("clause/termination", "30 days' notice",
                     "clause/termination", "60 days' notice", "YES"),
        "agree": ("agreement/governing_law", "the laws of Singapore",
                  "agreement/jurisdiction", "Singapore", "NO"),
        "duplicate": ("clause/liability_cap",
                      "capped at the fees paid in the last 12 months",
                      "clause/liability_limit", "capped at 12 months' fees", "YES"),
        "not_duplicate": ("clause/termination", "60 days' notice",
                          "clause/payment_terms", "30 days", "NO"),
        "rule_conflict": ("clause/termination", "30 days' notice", "60 days' notice",
                          "the termination notice is fixed and must never change",
                          "CONFLICT"),
        "rule_update": ("state/signing", "unsigned", "signed by both parties",
                        "the liability cap is fixed and must never change", "UPDATE"),
    },
}


def _t2(key: str, value: str, truth: str, note: str) -> dict:
    return tasks.job("T2", f"FACT: {key} = {value}\nKeep it?", truth, note,
                     authored=True)


def _t5(a_key, a_value, b_key, b_value, truth, note) -> dict:
    return tasks.job("T5", f"A: {a_key} = {a_value}\nB: {b_key} = {b_value}\n"
                          "Same fact?", truth, note, authored=True)


def _t3(a_key, a_value, b_key, b_value, truth, note) -> dict:
    return tasks.job("T3", f"A: {a_key} = {a_value}\nB: {b_key} = {b_value}\n"
                          "Do A and B disagree?", truth, note, authored=True)


def _t7(question, key, value, truth, note) -> dict:
    return tasks.job("T7", f"QUESTION: {question}\nFACT: {key} = {value}\n"
                           "Could this fact answer it?", truth, note, authored=True)


def _t4(key, earlier, now, rule, truth, note) -> dict:
    prefix = f"RULE: {rule}\n" if rule else ""
    return tasks.job("T4", f"{prefix}EARLIER: {key} = {earlier}\n"
                           f"NOW: {key} = {now}\nWhich is it?", truth, note,
                     authored=True)


def cases() -> list[dict]:
    """Every one-decision case the three worlds can pose.

    The retrieval cases ask about a changed value, so a store that carried the
    fact answers and one that did not has nothing to match. The T2 negatives
    are session narration, one per world.
    """
    jobs: list[dict] = []
    for name, world in SCENARIOS.items():
        latest = dict(world["facts"])
        for session in sorted(world["changed"]):
            for key, value, _ in world["changed"][session]:
                latest[key] = value

        for key, value in latest.items():
            jobs.append(_t2(key, value, "YES", f"{name}: standing fact {key}"))
        jobs.append(_t2(f"session/{name}_note", world["narration"], "NO",
                        f"{name}: session narration"))

        for question, target, distractor in world["questions"]:
            jobs.append(_t7(question, target, latest[target], "YES",
                            f"{name}: {target} answers it"))
            jobs.append(_t7(question, distractor, latest[distractor], "NO",
                            f"{name}: {distractor} does not"))

        a_key, a_value, b_key, b_value, truth = world["duplicate"]
        jobs.append(_t5(a_key, a_value, b_key, b_value, truth, f"{name}: duplicate"))
        a_key, a_value, b_key, b_value, truth = world["not_duplicate"]
        jobs.append(_t5(a_key, a_value, b_key, b_value, truth,
                        f"{name}: different keys, different facts"))

        a_key, a_value, b_key, b_value, truth = world["disagree"]
        jobs.append(_t3(a_key, a_value, b_key, b_value, truth, f"{name}: disagree"))
        a_key, a_value, b_key, b_value, truth = world["agree"]
        jobs.append(_t3(a_key, a_value, b_key, b_value, truth, f"{name}: compatible"))

        key, earlier, now, rule, truth = world["rule_conflict"]
        jobs.append(_t4(key, earlier, now, rule, truth, f"{name}: rule fixes it"))
        key, earlier, now, _, truth = world["rule_update"]
        jobs.append(_t4(key, earlier, now, None, truth, f"{name}: no rule, it moved"))
    return jobs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prepare", type=Path)
    args = ap.parse_args()
    if not args.prepare:
        ap.print_help()
        return 1
    jobs = cases()
    args.prepare.write_text("\n".join(json.dumps(j) for j in jobs) + "\n",
                            encoding="utf-8")
    counts: dict[str, int] = {}
    for j in jobs:
        counts[j["task"]] = counts.get(j["task"], 0) + 1
    print(f"{len(jobs)} cases -> {args.prepare}")
    print("  " + "  ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
