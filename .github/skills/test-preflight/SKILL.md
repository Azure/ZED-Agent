---
name: test-preflight
description: |
  Verifies the ZED Agent's environment is ready to run — auth, tooling, ADO/
  Kusto connectivity, required modules, MCP wiring, Teams CDP, file presence.
  Records the outcome to `.zed-agent/readiness.json → preflight` so that
  `setup-service`, `setup`, and `run` can gate on it without re-executing
  the underlying checks.

  Use this skill whenever the release owner types:
    - `test-preflight`        (run all checks; auto-remediate per Behavior Rule 13)
    - `test-preflight fix`    (same as above — kept as explicit alias)
    - `test-preflight check`  (read-only — show last result from readiness.json)

  Also invoked as Phase 0 of `setup-service`. The release owner does NOT need
  to have any config files filled in before running this — preflight is the
  first thing to run on a fresh clone.
allowed-tools: shell
---

You are the ZED Agent test-preflight runner. The release owner has typed
`test-preflight`, `test-preflight fix`, or `test-preflight check`.

## Ordering in the readiness chain

```
test-preflight   →   setup-service   →   setup   →   run
   (env)             (service config)    (release env)   (execute)
```

Every stage records its outcome to `.zed-agent/readiness.json`. `run` reads
that file and refuses to start cleanly if any stage is missing, failed, or —
for `preflight` only — older than **24 hours**.

## Variant: `test-preflight check` (read-only)

1. Read `.zed-agent/readiness.json`. If the file is missing or `preflight`
   key is absent, tell the owner: *"No prior pre-flight run on record. Run
   `test-preflight` to create one."* and stop.
2. If present, display:
   ```
   Pre-flight last ran: {ranAt} ({age} ago)
   Verdict: {status}    {pass}✓  {warn}⚠️  {fail}❌
   Failures:
     - {failures[i]}
   Warnings:
     - {warnings[i]}
   ```
3. If `(now - ranAt) > 24h`, append: *"⚠️ This result is more than 24 hours
   old. `run` will treat it as stale — re-run `test-preflight` before
   starting a release."*
4. Exit — do not execute any checks.

## Variant: `test-preflight` / `test-preflight fix` (default)

### Step 1 — Invoke Test-PreFlight

```powershell
. .\.github\skills\zed-agent\scripts\Test-PreFlight.ps1
$pre = Test-PreFlight `
    -ServiceConfigPath ".github/skills/zed-agent/service-config.json" `
    -Tenant "microsoft.com"
```

Pass `-ReleaseId` ONLY if the owner explicitly asked to check a specific
release (rare — normally release-scoped checks belong in `run`, not here).

The script auto-writes `readiness.preflight` before returning.

### Step 2 — Render the results table

```
Pre-flight readiness check — {n} items

✅ {name}   {detail}
⚠️ {name}   {detail}
❌ {name}   {detail}
...

Summary: {pass}✓  {warn}⚠️  {fail}❌  → verdict: {verdict}
```

### Step 3 — Auto-remediate failures (Behavior Rule 13)

For every `fail` row, apply the matching automated remediation **without
asking permission first** — this is the whole point of `test-preflight fix`.
Examples (non-exhaustive — reason about and try a fix for anything not
listed):

| Failure | Remediation |
|---|---|
| `az` token expired / `az account get-access-token` errors | `Repair-AzAuth.ps1 -Tenant 'microsoft.com'` (handles `az account clear` → interactive `az login` → WAM-disable → device-code cascade) |
| Missing PowerShell module (e.g., `ImportExcel`) | `Install-Module <name> -Scope CurrentUser -Force` |
| Mail MCP not in `~/.copilot/mcp-config.json` | Patch the file to include the canonical Mail MCP entry |
| Teams CDP port 9222 unreachable | Run `.github/skills/zed-agent/scripts/Ensure-EdgeCDP.ps1` |
| Region cache / query file missing | Re-copy the canonical version from the skill directory |
| Corrupt watcher lock / orphaned scheduled tasks | `Register-WatcherTask -Action cleanup` |
| Empty `service-config.json` / `pipeline-catalog.json` fields | Defer — point owner at `setup-service group <N>` rather than fixing in preflight |
| `Release health skill` fails (only when `releaseHealth.enabled`) | Defer — the service skill has TODOs or schema errors; point the owner at `setup-service group 11` (which also runs the live query dry run) |

After **one** remediation pass, re-invoke `Test-PreFlight` ONCE.

### Step 4 — Verdict

- **All pass after remediation** → tell the owner: *"✅ Pre-flight green. You
  can run `setup-service` next."* and exit.
- **Still has failures** → display the residual failures with the explicit
  manual-fix command for each, then tell the owner: *"❌ Pre-flight has
  unresolved failures. Fix them and re-run `test-preflight`."* and exit
  WITHOUT writing `overridden: true` — the failure stays on record.
- **Warnings only** → tell the owner: *"⚠️ Pre-flight passed with {n}
  warning(s). Some steps may have degraded functionality. You can proceed
  to `setup-service`."* and exit.

### Step 5 — Audit

Append a single line to `audit.jsonl` (in the workspace root if no release
exists yet, else in the release directory):

```json
{"action":"preflight-run","verdict":"<verdict>","fail":N,"warn":M,"remediated":[...],"timestamp":"<UTC ISO>"}
```

If the owner overrode a non-pass verdict by typing `proceed-anyway` (only
relevant when invoked from inside `setup-service` Phase 0 — see that skill),
write `"action":"preflight-override"` instead.
