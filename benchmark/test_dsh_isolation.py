"""The isolation contract of TinyTitan's private DeepSeek Harness.

`tools/dsh_local.sh` and `tools/install_tinytitan.sh` are what let a factory-new
Mac run the bundle without touching the user's environment — no PATH edit, no
shell-rc edit, no writes into `~/.dsh`, `~/.npm`, `~/Library/pnpm`, `~/.cache` or
`~/.local/state`. That property is not visible in any single line, so it is easy
to lose in a refactor: `--prefix` reads like isolation but moves only where
packages are unpacked, and pnpm creates `~/Library/pnpm` even with `--store-dir`.
Both were real (measured 2026-09-24), so this file pins the redirections that
close them.

The real end-to-end proof was run by hand in a simulated factory-new HOME (engine,
tools, DSH, pnpm, plugin and route under one root; the user's npm/pnpm/XDG caches
untouched) and is recorded in the wiki. What is pinned here is the mechanism, plus
one dry run that must write nothing at all.

    cd benchmark && python3 -m unittest test_dsh_isolation -v
"""
from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DSH_LOCAL = ROOT / "tools/dsh_local.sh"
INSTALLER = ROOT / "tools/install_tinytitan.sh"


def logical_lines(text: str) -> list[str]:
    """Join backslash continuations, so one command is one string.

    The redirects sit on the `env` lines and the tool being run on the last line
    of the same command; a per-line search would miss every one of them.
    """
    joined: list[str] = []
    current = ""
    for line in text.splitlines():
        stripped = line.rstrip()
        if stripped.endswith("\\"):
            current += stripped[:-1] + " "
            continue
        joined.append(current + stripped)
        current = ""
    if current:
        joined.append(current)
    return joined


class PrivateHarnessIsolationTests(unittest.TestCase):
    """Every npm and pnpm invocation keeps its writes inside the private root."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.script = DSH_LOCAL.read_text()
        cls.commands = logical_lines(cls.script)

    def test_every_npm_install_redirects_its_cache_and_user_config(self) -> None:
        # `--prefix` does not move npm's cache or log directory, and npm reads
        # the user's ~/.npmrc unless told not to. DSH, pnpm and Playwright each
        # install with npm, so all three must carry both variables.
        installs = [command for command in self.commands
                    if re.search(r'"\$\(?npm(?:_bin)?\)?"\s+install', command)]
        self.assertEqual(len(installs), 3, "expected the DSH, pnpm and Playwright installs")
        for command in installs:
            head = command.strip()[:70]
            self.assertIn("npm_config_cache=", command, head)
            self.assertIn("npm_config_userconfig=", command, head)

    def test_the_plugin_install_redirects_pnpm_home_and_xdg(self) -> None:
        # `--store-dir` moves the store; PNPM_HOME is what stops pnpm creating
        # ~/Library/pnpm, and the XDG pair catches its cache and state.
        plugin = [c for c in self.commands if "plugin --profile web add" in c]
        self.assertEqual(len(plugin), 1)
        for variable in ("--store-dir", "PNPM_HOME=", "XDG_CACHE_HOME=", "XDG_STATE_HOME="):
            self.assertIn(variable, plugin[0])

    def test_the_web_launch_redirects_caches_but_keeps_config_readable(self) -> None:
        # Caches private; HOME, XDG_CONFIG_HOME and XDG_DATA_HOME left alone so the
        # agent can read the user's git, gh and registry configuration.
        web = [c for c in self.commands if "web --port" in c and "exec env" in c]
        self.assertEqual(len(web), 1)
        for variable in ("XDG_CACHE_HOME=", "XDG_STATE_HOME=", "PNPM_HOME=",
                         "npm_config_cache="):
            self.assertIn(variable, web[0])
        for absent in ("npm_config_userconfig=", "XDG_CONFIG_HOME=", "XDG_DATA_HOME="):
            self.assertNotIn(absent, web[0])

    def test_the_private_paths_live_under_one_root(self) -> None:
        for name in ("DSH_NPM_CACHE", "DSH_NPMRC", "DSH_XDG_CACHE", "DSH_XDG_STATE",
                     "DSH_PNPM_HOME"):
            with self.subTest(name=name):
                pattern = re.compile(rf'^{name}="\$DSH_ROOT/', re.M)
                self.assertRegex(self.script, pattern, name)

    def test_dsh_is_never_put_on_the_users_path(self) -> None:
        for pattern in (r"^\s*export PATH=", r"\.zshrc", r"\.bash_profile",
                        r"\.profile", r"npm install -g", r"/usr/local/bin"):
            with self.subTest(pattern=pattern):
                self.assertIsNone(re.search(pattern, self.script, re.M), pattern)

    def test_a_dry_run_writes_nothing_at_all(self) -> None:
        home = pathlib.Path(tempfile.mkdtemp(prefix="dsh-isolation-home-"))
        try:
            marker = home / "marker"
            marker.write_text("")
            env = dict(os.environ, HOME=str(home),
                       TINYTITAN_DSH_ROOT=str(home / ".tinytitan/dsh"),
                       TINYTITAN_DSH_DRY_RUN="1")
            result = subprocess.run(["bash", str(DSH_LOCAL), "ensure"], env=env,
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr[-400:])
            self.assertIn("would", result.stdout)
            written = [str(p.relative_to(home)) for p in home.rglob("*")
                       if p.is_file() and p != marker]
            self.assertEqual(written, [], "the dry run wrote into the home")
        finally:
            shutil.rmtree(home, ignore_errors=True)


class InstallerIsolationTests(unittest.TestCase):
    """The installer owns one root and two launcher scripts — nothing else."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.script = INSTALLER.read_text()

    def test_it_never_edits_a_shell_rc_file(self) -> None:
        # It *prints* the line to add when ~/.local/bin is not on PATH; that is
        # advice, not an edit.
        self.assertIsNone(re.search(r'>>?\s*"?\$HOME/\.(?:zshrc|bash_profile|profile)',
                                    self.script))
        self.assertIn("Add it to your PATH", self.script)

    def test_its_only_writes_outside_the_root_are_the_two_launchers(self) -> None:
        writes = set(re.findall(
            r'(?:cat\s*>\s*|mkdir\s+-p\s+|chmod\s+\+x\s+)"?(\$HOME[^"\\ ]*)', self.script))
        allowed = {"$HOME/.local/bin", "$HOME/.local/bin/tinytitan",
                   "$HOME/.local/bin/tinytitan-web"}
        self.assertEqual(writes - allowed, set())

    def test_the_install_root_is_overridable_for_a_simulated_machine(self) -> None:
        self.assertIn('INSTALL_ROOT="${TINYTITAN_ROOT:-$HOME/.tinytitan}"', self.script)
        for directory in ("~/.tinytitan", "~/.local/bin"):
            self.assertIn(directory, self.script)


if __name__ == "__main__":
    unittest.main()
