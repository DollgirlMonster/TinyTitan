/**
 * Keep the harness's route to TinyTitan current, by asking the checkout.
 *
 * The plugin deliberately owns no adapter: the harness's own `llm-pi-ai` route
 * serves these models, and `tools/dsh_route.sh` in this checkout is the one
 * place that turns the installed models into that route's block (ids, effort
 * ladders and the three switches that are easy to get wrong by hand). Running it
 * at boot is what makes the route follow `models/` instead of a copy someone
 * typed once.
 *
 * @module dsh-tinytitan/route
 */
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

/** The tool this delegates to. */
export function routeScript(repoRoot) {
  return join(repoRoot, "tools", "dsh_route.sh");
}

/**
 * Write the route block into the DSH settings file.
 * @param options - resolved config fields, plus injectable `run`/`log` for tests.
 * @returns `{status}` — `written`, `missing`, `failed` or `skipped`.
 */
export function registerRoute({
  repoRoot,
  repoFound = true,
  port,
  provider,
  dshHome,
  run = execFileSync,
  log = () => {},
}) {
  const script = routeScript(repoRoot);
  if (!existsSync(script)) {
    const why = repoFound === false
      ? "no TinyTitan checkout found (set TINYTITAN_REPO or the repoRoot config)"
      : `${script} does not exist`;
    log(`dsh-tinytitan: ${why}; leaving the llm-pi-ai route as it is`);
    return { status: "missing", script };
  }
  const args = [
    script,
    "--write",
    "--port",
    String(port),
    "--provider",
    provider,
    "--settings",
    join(dshHome, "settings.yaml"),
  ];
  try {
    const stdout = run("bash", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    const first = String(stdout).trim().split("\n")[0] || "written";
    log(`dsh-tinytitan: route refreshed from ${script} (${first})`);
    return { status: "written", script, detail: first };
  } catch (error) {
    const detail = String(error?.stderr ?? error?.message ?? error).trim().split("\n")[0];
    log(`dsh-tinytitan: route refresh failed: ${detail}`);
    return { status: "failed", script, detail };
  }
}
