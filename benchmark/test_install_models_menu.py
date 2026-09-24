"""The install menu's answer handling — an EOF is not a choice.

`tools/install_models.sh --choose` starts a real download on a single keystroke,
so the difference between "the caller pressed Enter" and "the caller's stdin
ended" matters: one is consent to the recommended model, the other is not. It
was measured the wrong way round on 2026-09-24 — closing stdin started the
recommended 36.9 GB download — so this file pins both directions.

`install_one` is replaced with a stub before the menu is called: a regression
here prints `INSTALLED <model>` instead of downloading one. Nothing here touches
the network or `models/`.

    cd benchmark && python3 -m unittest test_install_models_menu -v
"""
from __future__ import annotations

import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/install_models.sh"

# `source` also runs the script's own dispatcher, which with no arguments prints
# the status table; it is silenced, and `install_one` is stubbed straight after.
HARNESS = f"""
set -uo pipefail
set --
source "{SCRIPT}" >/dev/null 2>&1 || true
install_one() {{ echo "INSTALLED $1"; }}
choose_model
echo "rc=$?"
"""


def run_menu(stdin: str | None) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", HARNESS], input=stdin,
                          capture_output=True, text=True, timeout=60)


class InstallMenuAnswerTests(unittest.TestCase):
    def test_an_empty_line_takes_the_default(self) -> None:
        result = run_menu("\n")
        self.assertIn("INSTALLED ornith15-8bit", result.stdout + result.stderr)

    def test_a_number_installs_that_row(self) -> None:
        result = run_menu("13\n")
        self.assertIn("INSTALLED qwen35-2b", result.stdout + result.stderr)

    def test_end_of_input_installs_nothing(self) -> None:
        # The bug: `read` failing left the reply empty, and the empty reply fell
        # through to the default. stdin closed must refuse, not choose for the
        # caller.
        result = run_menu("")
        output = result.stdout + result.stderr
        self.assertNotIn("INSTALLED", output)
        self.assertIn("rc=2", result.stdout)
        self.assertIn("nothing was installed", output)

    def test_a_choice_outside_the_list_installs_nothing(self) -> None:
        result = run_menu("0\n")
        output = result.stdout + result.stderr
        self.assertNotIn("INSTALLED", output)
        self.assertIn("not a choice", output)


if __name__ == "__main__":
    unittest.main()
