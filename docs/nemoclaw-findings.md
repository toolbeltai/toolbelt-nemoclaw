# NemoClaw build facts for `toolbelt-claw` (R1, R2, R3, R5, R6)

Discovery spike (Task 1). All facts below are sourced from a real clone of
NemoClaw and the real published `@toolbeltai/*` npm packages. Anything not
verifiable from a source is explicitly marked **UNRESOLVED**.

## Provenance

- **NemoClaw repo:** https://github.com/NVIDIA/NemoClaw
- **Pinned commit SHA:** `4d33291df934819e3e913b64e14348f14e80cbf4`
  (`git clone --depth 1` then `git rev-parse HEAD`)
- **Toolbelt CLI:** `@toolbeltai/cli@0.1.6` (the package is named
  `@toolbeltai/cli`, **not** `toolbelt-cli` — `npm view toolbelt-cli` returns
  404). Its bin is `toolbelt`; reported internal version string `toolbelt/0.1.5`.
- **MCP-config descriptors:** `@toolbeltai/mcp-config@0.1.3` (depended on by the
  CLI; this is the canonical source of the OpenClaw MCP-entry JSON shape).
- **Skills:** `@toolbeltai/skills@1.0.12`.

---

## R1 — Where/how `openclaw.json` is integrity-pinned, and the A2 injection point

**Resolved.**

### The pinned file is NOT under the blueprint

The integrity-pinned config is `/sandbox/.openclaw/openclaw.json` — the
OpenClaw gateway config in the sandbox user's home — **not** anything under the
immutable blueprint at `/sandbox/.nemoclaw/blueprints/0.1.0/`. The blueprint is
copied in at `Dockerfile:527-528` and made root-owned/immutable
(`Dockerfile:983-986`) but it is **not** sha256-pinned. Only `openclaw.json` is
hashed.

### How the hash is computed and stored (build time)

`Dockerfile:966-968`:

```dockerfile
# Pin config hash at build time so the entrypoint can verify integrity.
RUN sha256sum /sandbox/.openclaw/openclaw.json > /sandbox/.openclaw/.config-hash \
    && chmod 660 /sandbox/.openclaw/.config-hash \
    && chown sandbox:sandbox /sandbox/.openclaw/.config-hash
```

- Hash command: `sha256sum`.
- Expected hash is stored in a **file**, `/sandbox/.openclaw/.config-hash`
  (not an ENV var).
- The file is `660 sandbox:sandbox` — i.e. **mutable default**, owned by the
  agent user.

### How the hash is verified (runtime) — and why it is a no-op by default

Entrypoint `/usr/local/bin/nemoclaw-start` (`scripts/nemoclaw-start.sh:377-384`)
calls `verify_config_integrity_if_locked /sandbox/.openclaw`, defined in
`scripts/lib/sandbox-init.sh:570-606`.

That function **only enforces the hash when `.config-hash` is root-owned with no
write bits** (the state applied by `shields up`). In the default image the hash
file is `660 sandbox:sandbox`, so the verifier logs
`"Config integrity check skipped for mutable default"` and returns 0. From the
header comment (`sandbox-init.sh:564-569`):

> OpenClaw is mutable by default in PR #2227: openclaw.json and .config-hash are
> sandbox-owned until `shields up` locks them. … Enforce the strict verifier
> only once the hash is root-owned and has no write bits.

The entrypoint also **recomputes** `.config-hash` from the live `openclaw.json`
on startup in the mutable-default case (`nemoclaw-start.sh:728-768`,
`refresh` path runs `sha256sum openclaw.json > .config-hash`).

### How openclaw.json is generated at build time

`openclaw.json` is generated from environment variables by
`scripts/generate-openclaw-config.mts` (run at `Dockerfile:~705` via
`node --experimental-strip-types /scripts/generate-openclaw-config.mts`), then
post-processed by an inline `python3` step (`Dockerfile:766-783`) that clears
the gateway auth token and writes the runtime proxy block. The hash is pinned
**after** all of that, at `Dockerfile:967`.

### A2 injection point vs A1 — DECISION

**A2 (inject during a derived build, before the hash is pinned) is FEASIBLE,
and additionally the hash is not even enforced at runtime by default.**

- The pinning step (`Dockerfile:967`) is in **this** Dockerfile, not the base
  image. Any wrapper that does `FROM ghcr.io/nvidia/nemoclaw/...` and re-runs
  config edits can simply `RUN sha256sum … > .config-hash` again to re-pin.
- The last point in the upstream build where blueprint/config files can still
  be edited before pinning is **anywhere before `Dockerfile:967`** (the
  `sha256sum … > .config-hash` line). Practically: after the openclaw.json
  generation/python post-process (`Dockerfile:766-783`) and before line 967.
- Even **without** re-pinning, a modified `openclaw.json` will boot cleanly in
  the default (non-`shields-up`) image because `verify_config_integrity_if_locked`
  no-ops on a `sandbox`-owned hash and the entrypoint recomputes the hash on
  start.

**Recommendation:** Layer on the published image (an A1-style derived build)
and either (a) regenerate `.config-hash` via `sha256sum`, or (b) rely on the
mutable-default no-op. Re-pinning (a) is cheap and keeps `shields up` working,
so prefer it. There is **no** ENV-var-based hash to match — only the file.

> Caveat: if a deployment runs `shields up`, the hash becomes a root-owned trust
> anchor and is enforced. Re-pinning at build time (option a) keeps that path
> valid; runtime edits to openclaw.json under shields-up would be rejected.

---

## R2 — Does the MCP server entry support `${ENV}` interpolation at gateway load?

**Resolved: NO native `${ENV}` interpolation.** The token is written as a
literal string into `openclaw.json`.

Source: `@toolbeltai/mcp-config@0.1.3` `dist/index.js`, OpenClaw descriptor —
`buildEntry5()` produces:

```json
{ "type": "http", "url": "<url>", "headers": { "Authorization": "Bearer <token>" } }
```

The `<token>` is interpolated into the JSON string at write time by the CLI;
there is no `${ENV}` placeholder mechanism in the rendered config, and OpenClaw
is not shown to expand env vars inside `mcp.servers.*.headers`.

### Runtime-config-file fallback (since interpolation is unsupported)

Because the value must be a literal, the token has to be written into
`openclaw.json` itself at runtime (or build time). The relevant runtime file the
OpenClaw gateway reads is:

- **`/sandbox/.openclaw/openclaw.json`** — exported by the entrypoint as
  `OPENCLAW_CONFIG_PATH` (`nemoclaw-start.sh:374`). This is the same file under
  `mcp.servers` (see R3). The wrapper's runtime onboarding step must write the
  resolved token into `mcp.servers.toolbelt.headers.Authorization` here, then
  (optionally) recompute `.config-hash`.

> Implication for the wrapper: the token cannot be supplied purely via an env
> var that openclaw.json references; an entrypoint hook must materialize it into
> the JSON. **UNRESOLVED — needs verification:** whether OpenClaw itself supports
> any `${VAR}` expansion in config (not observed in the descriptor package; would
> need to inspect the OpenClaw runtime, which was not cloned in this spike).

---

## R3 — How OpenClaw loads skills and MCP servers

**Resolved.**

### On-disk skills directory inside the image

`/sandbox/.openclaw/skills` — created in the base image
(`Dockerfile.base:116`) and again in the derived image's dir list
(`Dockerfile:884`), owned `sandbox:sandbox`, mode `2770`. This is the directory
the Toolbelt skills (`@toolbeltai/skills`) should be installed into.

Cross-check: the Toolbelt CLI's own skills installer copies skill folders into
the target client's `skillsDir` (`@toolbeltai/cli` `dist/index.js`
`installSkills()`), so the wrapper can either run the CLI with
`--client openclaw` or copy the skills package contents into
`/sandbox/.openclaw/skills` directly.

### JSON shape of an MCP server entry in `openclaw.json`

OpenClaw uses a **nested `mcp.servers` map** (distinct from the flat
`mcpServers` other clients use). From `@toolbeltai/mcp-config@0.1.3`
(`openclaw.upsertInto` / `buildEntry5`):

```json
{
  "mcp": {
    "servers": {
      "toolbelt": {
        "type": "http",
        "url": "https://mcp.toolbelt.ai/mcp",
        "headers": {
          "Authorization": "Bearer <token>"
        }
      }
    }
  }
}
```

Exact key names:
- URL field: **`url`** (string).
- Auth: **`headers.Authorization`** with value **`Bearer <token>`** (the token
  is embedded in the header value, not a separate `token` field).
- Transport discriminator: **`type": "http"`**.

The README of `@toolbeltai/mcp-config` confirms: *"OpenClaw — `~/.openclaw/openclaw.json` — JSON (nested `mcp.servers`)"*.

NemoClaw's own backup/migration code treats `mcp` and `mcpServers` as durable
sections (`src/lib/state/openclaw-config-merge.ts:32`:
`backupDurableSections: ["mcp", "mcpServers", "customAgents", "agents"]`), and
the credential filter strips secrets from `mcpServers.*.env`/`headers`
(`src/lib/security/credential-filter.test.ts`). This confirms both shapes can
appear; for OpenClaw the wrapper should write under `mcp.servers`.

---

## R5 — Headless onboarding command (token acquisition)

**Resolved with a caveat.** `@toolbeltai/cli` (the bin `toolbelt`) has a fully
non-interactive `install` flow, but **no subcommand that prints a bare token to
stdout**.

### Subcommands (from `toolbelt --help`)

```
install [client]  Install Toolbelt into a specific MCP client
claim             Claim the current anonymous token with an email (OTP flow — interactive)
upgrade           Open billing page (browser)
whoami            Show current token / tier / limits
uninstall         Remove MCP entry and local token store
```

Global flags: `--token <token>`, `--host <url>`,
`--client claude-code|claude-desktop|openclaw|cursor|windsurf|gemini-cli|codex|print`,
`--skills` / `--no-skills`, `--dry-run`.

### The headless path

`toolbelt install --client openclaw [--token <T>] [--host <URL>] [--no-skills] [--dry-run]`
is non-interactive (CLI `runInstall()` in `dist/index.js`):

1. Resolves token from `--token` → `TOOLBELT_TOKEN` env → stored
   `~/.toolbelt/config.json`.
2. **If no token**, it auto-provisions an **anonymous** token via
   `POST {host}/api/onboard` (default host `https://app.toolbelt.ai`) — fully
   headless, no prompt.
3. Writes the MCP entry into the client config (for `openclaw`, into
   `~/.openclaw/openclaw.json` under `mcp.servers`).
4. Persists `{ token, host, siteUrl, tier, namespace }` to
   **`~/.toolbelt/config.json`** (created with file mode `0600`).

### How the token is emitted

- **Not** printed as a bare token to stdout. `--dry-run` prints a **masked**
  token (`mask()` → `tb_x…last4`). On real install it stores the token to
  `~/.toolbelt/config.json` and prints only the MCP URL + tier + (for anonymous)
  a claim URL containing the token.
- The token IS recoverable headlessly from `~/.toolbelt/config.json` (JSON key
  `token`) after a non-interactive `install`, or directly from the raw API:
  `POST {host}/api/onboard` returns `{ token, mcpUrl, siteUrl, namespace }`.

### Credential env it consumes

- `TOOLBELT_TOKEN` — an existing token (skips provisioning).
- `TOOLBELT_HOST` — Toolbelt host override (self-hosted / edge).
- No username/password/API-key env is consumed; provisioning is **anonymous**
  (no credential required). "Claiming" an anonymous token to a real account is
  the `claim` subcommand, which is an **interactive email + OTP** flow (uses
  `@inquirer/prompts input`) — **not headless**.

### Verdict for the wrapper

A fully-headless "obtain a token" path exists for the **anonymous** tier:
either `POST {host}/api/onboard` directly, or `toolbelt install --client openclaw`
then read `~/.toolbelt/config.json`. There is **no** fully-headless command to
obtain a token tied to a specific *authenticated* account/credential — that
requires the interactive `claim` OTP flow. So:

- **Anonymous/dev onboarding: headless OK.**
- **Account-bound token: must be supplied via `TOOLBELT_TOKEN` (pre-obtained);
  the in-container `claim` flow is interactive/local-only.**

> **UNRESOLVED — needs verification:** the exact JSON response shape of
> `POST /api/onboard` beyond `{ token, mcpUrl, siteUrl, namespace }` (inferred
> from CLI usage `res.token` / `res.mcpUrl` / `res.siteUrl` / `res.namespace.id`).

---

## R6 — Writable state path under hardening (`TOOLBELT_STATE_DIR` default)

**Resolved.**

The sandbox user's home is `/sandbox` (`Dockerfile.base:103-104`,
`useradd -d /sandbox … sandbox`; `nemoclaw-start.sh:363` `_SANDBOX_HOME=/sandbox`).
Candidate writable locations the `sandbox` user owns at runtime, outside the
immutable blueprint:

| Path | Ownership / mode | Notes |
|---|---|---|
| `/sandbox/.openclaw/` and children | `sandbox:sandbox`, `2770` | Mutable default; OpenClaw config + skills + workspace live here. |
| `/sandbox/.nemoclaw/state` | `sandbox:sandbox` | Carved out as sandbox-writable inside the otherwise-root-owned, sticky-bit `1755` `/sandbox/.nemoclaw` (`Dockerfile:982-986`). Siblings `migration`, `snapshots`, `staging` likewise. |
| `/sandbox` (`$HOME`) | `sandbox:sandbox` | Home dir; `.bashrc`/`.profile` are root-owned `444` but the dir itself is writable. |
| `/tmp/.local/state` (`XDG_STATE_HOME`) | tmp | Ephemeral; entrypoint sets `XDG_STATE_HOME=/tmp/.local/state` (`nemoclaw-start.sh:146`). Lost on restart. |

The blueprint (`/sandbox/.nemoclaw/blueprints/`) is root-owned and immutable —
must be avoided.

### Chosen default for `TOOLBELT_STATE_DIR`

**`/sandbox/.nemoclaw/state/toolbelt`** (a subdir of the explicitly
sandbox-owned, durable `state/` directory).

Rationale: it is durable (unlike `/tmp/...`), guaranteed `sandbox`-writable even
under blueprint hardening (the entire `/sandbox/.nemoclaw` parent is root-owned
`1755` but `state/` is chowned to `sandbox:sandbox` at `Dockerfile:982`), and
semantically separated from OpenClaw's own `/sandbox/.openclaw` tree so wrapper
state does not collide with config-integrity (`shields up`) hardening of
`openclaw.json`.

> Alternative if avoiding the `.nemoclaw` namespace is preferred:
> `/sandbox/.openclaw/credentials` is also `sandbox:sandbox` and durable, but it
> sits inside the tree that `shields up` can lock — `.nemoclaw/state` is the
> safer default.

---

## Summary table

| Item | Status | Concrete answer | Source |
|---|---|---|---|
| **R1** | Resolved | `openclaw.json` hashed via `sha256sum` into file `/sandbox/.openclaw/.config-hash`; mutable-default (`660 sandbox:sandbox`) so runtime check no-ops unless `shields up`. | `Dockerfile:966-968`, `sandbox-init.sh:570-606` |
| **A2 vs A1** | Decided | A2 feasible (pinning is in this Dockerfile, not base). Recommend derived build + re-run `sha256sum … > .config-hash`. No ENV-var hash exists. | `Dockerfile:967` |
| **R2** | Resolved | No `${ENV}` interpolation; token is a literal in `headers.Authorization`. Must write into `/sandbox/.openclaw/openclaw.json` at runtime. | `@toolbeltai/mcp-config@0.1.3` |
| **R3** | Resolved | Skills dir `/sandbox/.openclaw/skills`; MCP entry under `mcp.servers.<name> = { type:"http", url, headers:{Authorization:"Bearer <token>"} }`. | `Dockerfile.base:116`, mcp-config descriptor |
| **R5** | Resolved (caveat) | `@toolbeltai/cli` (`toolbelt install --client openclaw`) headless-provisions an anonymous token via `POST /api/onboard`; stored at `~/.toolbelt/config.json` (0600), not stdout. `claim` (account-bind) is interactive. | `@toolbeltai/cli@0.1.6` `dist/index.js` |
| **R6** | Resolved | `TOOLBELT_STATE_DIR` default = `/sandbox/.nemoclaw/state/toolbelt` (durable, sandbox-owned, outside immutable blueprint). | `Dockerfile:982-986`, `nemoclaw-start.sh:363` |

### Open / unresolved items needing later verification

1. Whether OpenClaw's runtime itself supports any `${VAR}` expansion inside
   `openclaw.json` (OpenClaw repo not cloned this spike).
2. Exact `POST /api/onboard` response schema (inferred from CLI field access).
