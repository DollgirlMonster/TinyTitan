#!/usr/bin/env python3
"""Render AUDIT/ledger.md and the milestone report from AUDIT/ledger.json.

The ledger JSON is the single source of truth; this script is the only writer of
the Markdown table and of the milestone report lines, so the two can never drift
and the report is never hand-maintained.

    python3 AUDIT/render_ledger.py            # rewrite AUDIT/ledger.md
    python3 AUDIT/render_ledger.py --report   # print the milestone report
"""

from __future__ import annotations

import argparse
import json
import pathlib

AUDIT = pathlib.Path(__file__).resolve().parent
LEDGER = AUDIT / "ledger.json"
MARKDOWN = AUDIT / "ledger.md"

DONE = {"DONE"}
BLOCKED = {"BLOCKED"}
NON_TERMINAL = {"OPEN", "START", "PROGRESS", "TEST", "AUDIT", "SWEPT"}
SEVERITY_ORDER = {"S0": 0, "S1": 1, "S2": 2, "S3": 3}


def load() -> dict:
    return json.loads(LEDGER.read_text(encoding="utf-8"))


def counts(tasks: list[dict]) -> dict[str, int]:
    return {
        "total": len(tasks),
        "done": sum(1 for t in tasks if t["status"] in DONE),
        "blocked": sum(1 for t in tasks if t["status"] in BLOCKED),
        "open": sum(1 for t in tasks if t["status"] in NON_TERMINAL),
    }


def ordered(tasks: list[dict]) -> list[dict]:
    return sorted(tasks, key=lambda t: (SEVERITY_ORDER.get(t["severity"], 9), t["id"]))


def render_markdown(data: dict) -> str:
    tasks = ordered(data["tasks"])
    c = counts(data["tasks"])
    lines = [
        "# Audit ledger",
        "",
        f"Repository `{data['repo']}`, branch `{data['branch']}`, base commit "
        f"`{data['base_commit']}`. Generated from `AUDIT/ledger.json` by "
        "`AUDIT/render_ledger.py` — do not edit by hand.",
        "",
        f"**{c['total']} tasks — done {c['done']}, open {c['open']}, blocked {c['blocked']}.**",
        "",
        "| id | sev | tier | project | location | title | status | host |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for t in tasks:
        lines.append(
            f"| {t['id']} | {t['severity']} | {t['tier']} | {t['project']} | "
            f"`{t['location']}` | {t['title']} | {t['status']} | {t['host']} |"
        )
    lines += ["", "## Detail", ""]
    for t in tasks:
        lines += [
            f"### {t['id']} — {t['title']}",
            "",
            f"- severity **{t['severity']}**, tier {t['tier']}, project {t['project']}, "
            f"status **{t['status']}**",
            f"- location: `{t['location']}`",
            f"- discovered by: {t['discovered_by']}",
            f"- evidence (before): {t['evidence_before']}",
            f"- fix: {t['fix_summary'] or '—'}",
            f"- evidence (after): {t['evidence_after'] or '—'}",
            f"- commit: {t['commit'] or '—'}",
            f"- blocked: {t['blocked_reason'] or '—'}",
            "",
        ]
    return "\n".join(lines) + "\n"


def report(data: dict) -> str:
    tasks = ordered(data["tasks"])
    c = counts(data["tasks"])
    lines = []
    for index, t in enumerate(tasks, start=1):
        lines.append(
            f"[#{t['id']} {index}/{c['total']} | done:{c['done']} open:{c['open']} "
            f"blocked:{c['blocked']} new:0] {t['status']} — {t['title']}"
        )
    lines.append(
        f"== {c['total']} tasks | done:{c['done']} open:{c['open']} blocked:{c['blocked']}"
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", action="store_true")
    args = parser.parse_args()
    data = load()
    if args.report:
        print(report(data))
    else:
        MARKDOWN.write_text(render_markdown(data), encoding="utf-8")
        c = counts(data["tasks"])
        print(f"wrote {MARKDOWN} ({c['total']} tasks, open {c['open']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
