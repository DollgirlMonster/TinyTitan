"""The install tool's contract with the person running it.

Two things `tools/install_models.sh` must not get wrong:

- `--choose` starts a real download on a single keystroke, so "the caller pressed
  Enter" and "the caller's stdin ended" have to mean different things. It was
  measured the wrong way round on 2026-09-24 — closing stdin started the
  recommended 36.9 GB download — so this file pins both directions.
- Every download and conversion is staged under one absolute work root. The
  staging paths were bare `.build/...` until 2026-09-24, which put a factory-new
  install's tens-to-hundreds of GB in `~/.build` — outside the install root —
  because a relative path follows the caller's working directory and the
  installer never changes it.

`install_one` is replaced with a stub before the menu is called: a regression
there prints `INSTALLED <model>` instead of downloading one. The path tests read
the script. Nothing here touches the network or `models/`.

    cd benchmark && python3 -m unittest test_install_models_menu -v
"""
from __future__ import annotations

import pathlib
import re
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


class StagingPathTests(unittest.TestCase):
    """Downloads stage under one absolute root, whatever the caller's cwd is."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.script = SCRIPT.read_text()

    def test_the_root_is_derived_absolutely_from_the_script_path(self) -> None:
        self.assertIn('ROOT="$(cd "$(dirname "$0")/.." && pwd)"', self.script)

    def test_the_work_root_defaults_under_the_install_root(self) -> None:
        self.assertIn('WORK="${TINYTITAN_WORK_DIR:-$ROOT/.build}"', self.script)

    def test_no_staging_path_is_relative_to_the_working_directory(self) -> None:
        # Comments may name `.build/release` (the repack binary default) or the
        # old shape; what matters is that no *code* argument or variable is a
        # bare relative `.build/...` path any more.
        for number, line in enumerate(self.script.splitlines(), start=1):
            if line.lstrip().startswith("#") or ".build/release" in line:
                continue
            with self.subTest(line=number):
                self.assertNotIn(".build/", line)

    def test_download_and_conversion_arguments_use_the_work_root(self) -> None:
        for argument in ('--work "$WORK/${preset}-shards"',
                         '--output "$WORK/qwen38-affine-${width}bit"',
                         '--work "$WORK/qwen38-shards"',
                         '--output "$WORK/${preset}-affine"'):
            with self.subTest(argument=argument):
                self.assertIn(argument, self.script)

    def test_relative_staging_paths_are_not_quoted_in_a_command(self) -> None:
        # Belt and braces for a future edit that reintroduces the old spelling.
        self.assertIsNone(re.search(r'"\.build/(?!release)', self.script))


if __name__ == "__main__":
    unittest.main()
