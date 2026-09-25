#!/usr/bin/env python3
"""Assert that the audit ledger has no open tasks.

Phase E is only complete when every task is DONE or BLOCKED-with-owner, so the
verification run needs a machine check rather than a human reading the table.
Prints the milestone report either way.

    python3 AUDIT/assert_ledger_closed.py            # exit 1 while work is open
    python3 AUDIT/assert_ledger_closed.py --report   # report only, exit 0
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

LEDGER = pathlib.Path(__file__).resolve().parent / "ledger.json"
TERMINAL = {"DONE", "BLOCKED"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", action="store_true",
                        help="print the report and exit 0 whatever the state")
    args = parser.parse_args()

    data = json.loads(LEDGER.read_text(encoding="utf-8"))
    tasks = data["tasks"]
    done = [t for t in tasks if t["status"] == "DONE"]
    blocked = [t for t in tasks if t["status"] == "BLOCKED"]
    open_tasks = [t for t in tasks if t["status"] not in TERMINAL]

    print(f"== {len(tasks)} tasks | done:{len(done)} open:{len(open_tasks)} "
          f"blocked:{len(blocked)}")
    for task in tasks:
        if task["status"] not in TERMINAL:
            print(f"   OPEN  {task['id']} [{task['severity']}/{task['tier']}] {task['title']}")
    for task in blocked:
        reason = task.get("blocked_reason") or "(no reason recorded)"
        print(f"   BLOCKED {task['id']} owner={task.get('blocked_owner', '?')}: {reason}")

    if args.report:
        return 0
    if open_tasks:
        print(f"\nFAIL: {len(open_tasks)} task(s) are not DONE or BLOCKED; Phase E cannot pass.",
              file=sys.stderr)
        return 1
    if any(not task.get("blocked_reason") for task in blocked):
        print("\nFAIL: a BLOCKED task has no recorded reason.", file=sys.stderr)
        return 1
    print("\nOK: the ledger is closed (every task DONE or BLOCKED with a reason).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
