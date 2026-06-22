# toolbelt-claw — Wrapper Container Design

> ⚠️ **SUPERSEDED (2026-06-22)** by `2026-06-22-toolbelt-claw-via-quickstart-design.md`. This
> baked-custom-image approach fights NemoClaw's design (no pullable sandbox image; the gateway
> won't run healthy outside the OpenShell substrate). The current direction uses NemoClaw's
> official quickstart and plugs Toolbelt in via a blueprint preset + `toolbelt install`. The
> implementation here (two-stage build, shim, inference wiring) is kept as verified reference only.

**Date:** 2026-06-19
**Status:** Superseded
**Repo:** `toolbelt-claw/` (greenfield)
**Scope:** Container image only. Kubernetes manifests, GPU scheduling, and network
policy are explicitly out of scope and will be separate specs.

---

## 1. Purpose

Produce a single OCI image that extends NVIDIA's [NemoClaw](https://github.com/NVIDIA/NemoClaw)
sandbox so the OpenClaw agent inside it is **Toolbelt-aware out of the box**. "Toolbelt-aware"
means two things, both baked into the image at build time:

1. The **Toolbelt MCP server** is registered as a tool source for the agent.
2. The **`@toolbeltai/skills`** package (from ClawHub) is installed into the agent's skills
   directory.

In addition, the wrapper owns a small **onboarding bootstrap** at startup: it binds the agent
to a specific **Toolbelt instance** (URL + token) supplied at runtime. If a token is provided
(the normal path: a user who already has an account and token) it is used as-is. If no token is
provided, the bootstrap **delegates** to existing Toolbelt tooling, `toolbelt-cli` or the
onboarding capability in `@toolbeltai/skills`, to obtain a token, then persists it so restarts
reuse it. The shim does not implement its own onboarding protocol.

The wrapper is a **packaging, integration, and instance-binding** layer, not an API gateway and
not a process supervisor. NemoClaw remains CLI/agent-driven; we do not add a new network
surface. The only runtime logic we add is the thin pre-launch onboarding shim described in §5.

### Non-goals
- No HTTP/gRPC API in front of NemoClaw's CLI.
- No mutation of the **hash-pinned blueprint** at runtime. The onboarding shim resolves
  instance URL/token into env or a separate writable runtime location only; it never edits the
  pinned `openclaw.json`.
- No Kubernetes manifests, Helm values, GPU scheduling, or network-policy configuration.
- No CI auto-release wiring.
- No Stripe/billing knowledge (workspace OSS-purity rule).

---

## 2. Background: how NemoClaw is actually built

Established from NemoClaw's `Dockerfile` (`main`):

- Multi-stage build `FROM ghcr.io/nvidia/nemoclaw/sandbox-base:latest` (overridable via
  `BASE_IMAGE` ARG). Builds OpenClaw (pinned `2026.5.27`) plus the NemoClaw TypeScript plugin.
- Agent config lives in an **immutable blueprint** at
  `/sandbox/.nemoclaw/blueprints/0.1.0/`: root-owned, sticky bit, hardened DAC.
- `openclaw.json` is **SHA256-pinned at build time** and the hash is **verified at runtime**.
- Entrypoint `/usr/local/bin/nemoclaw-start` launches the OpenClaw gateway, then drops
  privileges from `gateway` to the `sandbox` user.
- Healthcheck probes `http://127.0.0.1:${port}/health` (default port `18789`).
- Outbound traffic is forced through a **managed L7 proxy** (`NEMOCLAW_PROXY_HOST`, default
  `10.200.0.1:3128`) with SSRF-hardening patches.
- Many build ARGs (`NEMOCLAW_MODEL`, `NEMOCLAW_INFERENCE_BASE_URL`, proxy host/port, etc.) are
  promoted to runtime ENV.

### Constraints this imposes
- **C1 — Config is hash-pinned and immutable.** MCP/skill config cannot be edited at runtime
  without breaking the integrity check. Therefore registration and skill install happen at
  **build time**.
- **C2 — Locked-down egress.** The agent reaching the Toolbelt instance (both the MCP endpoint
  and, during onboarding, the instance API) requires that host to be permitted through the L7
  proxy / network policy, and the client must honor the proxy. Deployment prerequisite,
  documented here and owned by the future K8s spec.
- **C3 — Secrets must not be baked.** The integrity hash covers `openclaw.json`, so any
  secret placed there literally would be frozen into the image. The instance URL and token are
  referenced, not embedded.
- **C4 — Token persistence needs a writable mount.** A token obtained during onboarding must
  be saved outside the immutable, root-owned blueprint, in a writable state path the `sandbox`
  user can read/write. For durability across restarts this path must be a persistent mount
  (a volume locally; a PVC/Secret in the future K8s spec).

---

## 3. Build strategy

**Chosen: A2 — build from NemoClaw source.** Fallback: A1 — layer on the published image.

### A2 (primary)
Our `Dockerfile` drives NemoClaw's own build (parameterized via `BASE_IMAGE` and ARGs) and
injects our additions into the blueprint **before** NemoClaw's SHA256-pinning step runs.
NemoClaw's existing machinery then pins the hash over our modified `openclaw.json`. We never
reimplement or reverse-engineer their integrity scheme.

### A1 (fallback)
If NemoClaw's build is not extensible enough to inject pre-pinning, fall back to
`FROM ghcr.io/nvidia/nemoclaw/sandbox:<pinned>`, modify `openclaw.json`, then recompute and
rewrite the integrity hash ourselves. Lighter build, but couples us to their hashing details.

> **Implementation task (must-verify):** before committing to A2, confirm exactly where and
> how NemoClaw stores and computes the `openclaw.json` integrity hash (build script, ENV such
> as a `NEMOCLAW_CONFIG_SHA256`, or a sidecar file), and confirm the injection point in their
> build runs **before** pinning. If injection-before-pinning is not reachable, switch to A1
> and own the recompute step. This decision gates the rest of the build work.

---

## 4. Baked vs. injected

The instance binding (URL + token) is **runtime**, so a single image can target any Toolbelt
instance. Only image-shaping concerns are baked.

### Baked at build time (covered by the integrity hash)
| Item | Mechanism | Default |
| --- | --- | --- |
| Toolbelt MCP server entry skeleton in `openclaw.json` | config fragment merged into blueprint; URL + token are env references | n/a |
| `@toolbeltai/skills` | ClawHub install into skills dir | `TOOLBELT_SKILLS_VERSION` ARG, default latest |
| `toolbelt-cli` (onboarding delegate) | npm install into image | `TOOLBELT_CLI_VERSION` ARG, default latest |
| NemoClaw base/version | `BASE_IMAGE` ARG | pinned NemoClaw sandbox tag |

The MCP entry is baked as a **skeleton referencing env** (e.g. URL `${TOOLBELT_URL}`, auth
`${TOOLBELT_TOKEN}`), so the hash covers the placeholder strings, not the per-instance values
(satisfies C1 + C3). One image, many instances.

`@toolbeltai/skills` is **floating**: each build pulls the current published version (ARG can
pin a specific version when reproducibility is needed). A given image is still immutable; only
the choice of version at build time floats.

### Instance binding + config (runtime, via env file)
Supplied through an **env file** (`docker run --env-file`; later a K8s Secret/ConfigMap). The
wrapper reads these; the onboarding shim (§5) resolves the token before launch.

| Env var | Purpose | Required |
| --- | --- | --- |
| `TOOLBELT_URL` | Toolbelt instance base URL (MCP endpoint + onboarding API) | yes |
| `TOOLBELT_TOKEN` | instance auth token. If set, used as-is | no |
| `TOOLBELT_STATE_DIR` | writable path where an onboarding-obtained token is persisted | defaulted |
| `NEMOCLAW_INFERENCE_BASE_URL` | OpenAI-compatible inference endpoint (provider-agnostic passthrough) | yes |
| `NEMOCLAW_MODEL` | model ref (passthrough) | yes |
| inference API key | provider key, via the env var NemoClaw expects | yes |

**Token model:** the Toolbelt token is the auth used to reach the instance's MCP endpoint. If
`TOOLBELT_TOKEN` is provided it is used directly; if absent, the onboarding shim obtains one
from `TOOLBELT_URL` and **persists it to `TOOLBELT_STATE_DIR`** so subsequent starts reuse it
without re-onboarding (C4). This supersedes the earlier `X-Service-Secret` framing for the MCP
connection.

> **Implementation task (must-verify):** confirm OpenClaw's `openclaw.json` MCP config supports
> env-var interpolation in the URL and header/auth fields. If it does not, the onboarding shim
> writes the resolved URL + token into a runtime-only config location the MCP client reads,
> without touching the hash-pinned file.

### Inference: provider-agnostic
The wrapper does **not** assume Toolbelt's Bifrost router or any specific provider. Inference
endpoint, model, and key are pure runtime env passthrough. Pointing at Bifrost (or any
OpenAI-compatible endpoint) is purely an operational choice made via env at deploy time.

---

## 5. Startup flow

The wrapper adds a thin **onboarding shim** that runs before NemoClaw's own entrypoint, then
`exec`s it:

1. **Shim — instance binding.** Read `TOOLBELT_URL` (fail fast if unset). Resolve the token:
   - If `TOOLBELT_TOKEN` is set, use it.
   - Else if a persisted token exists in `TOOLBELT_STATE_DIR`, reuse it.
   - Else delegate to `toolbelt-cli` (or the `@toolbeltai/skills` onboarding capability) to
     obtain a token from `TOOLBELT_URL`, then write it to `TOOLBELT_STATE_DIR` (C4). The shim
     invokes existing tooling; it does not implement onboarding itself.
2. **Shim — expose binding.** Export the resolved URL + token as the env the baked MCP skeleton
   references (R2 interpolation path), or write them to the runtime-only config location the MCP
   client reads (R2 fallback). The hash-pinned blueprint is never modified.
3. **Hand off.** `exec /usr/local/bin/nemoclaw-start`.
4. OpenClaw gateway starts on `:18789`; integrity check passes (hash covers the baked skeleton).
5. Agent loads the baked Toolbelt skills.
6. Toolbelt MCP server registers as a tool source against the bound instance (outbound via the
   L7 proxy — see C2).
7. Healthcheck on `:18789/health`.

The shim is deliberately minimal: instance binding + token persistence only. It does no process
supervision and adds no network surface.

---

## 6. Repo deliverables

```
toolbelt-claw/
├── Dockerfile                      # A2 build: extends NemoClaw, injects MCP skeleton + skills pre-pinning
├── config/
│   └── toolbelt-mcp.json           # MCP server skeleton merged into openclaw.json (URL/token as ${ENV} refs)
├── bin/
│   └── onboard-and-start.sh        # onboarding shim: bind instance, resolve/persist token, exec nemoclaw-start
├── build.sh  (or Makefile)         # exposes ARGs: BASE_IMAGE, TOOLBELT_SKILLS_VERSION, TOOLBELT_CLI_VERSION
├── .env.example                    # documents the runtime env file (TOOLBELT_URL/TOKEN/STATE_DIR, inference vars)
├── test/
│   └── smoke.sh                    # build + assert (see §7)
└── README.md                       # build args, runtime env file, state-dir mount, egress prerequisite
```

---

## 7. Testing

A smoke test that builds the image and asserts:

1. **Skills present** — `@toolbeltai/skills` exists in the agent skills directory.
2. **MCP skeleton baked** — `openclaw.json` contains the Toolbelt MCP entry with `${TOOLBELT_URL}` /
   `${TOOLBELT_TOKEN}` references.
3. **Integrity intact** — NemoClaw's runtime integrity check passes on container start.
4. **Token-provided path** — with `TOOLBELT_TOKEN` set, the shim binds the instance without
   calling onboarding (assert no onboarding request).
5. **Onboarding path** — with `TOOLBELT_TOKEN` unset and a **mocked** onboarding endpoint, the
   shim obtains a token, persists it to `TOOLBELT_STATE_DIR`, and a second start reuses the
   persisted token (no second onboarding call).
6. **Health** — container starts and `:18789/health` returns OK, using a mocked/dummy inference
   endpoint and dummy instance env.

The test must not require live egress to a real Toolbelt instance or inference provider;
onboarding and inference are mocked, and MCP registration is asserted structurally, not via a
live handshake.

---

## 8. Open implementation risks (carried into the plan)

- **R1 — Hash injection point (A2).** See §3 must-verify. Gates build strategy.
- **R2 — Env interpolation for URL/token.** See §4 must-verify. Determines whether the shim sets
  env or writes a runtime config file.
- **R3 — ClawHub install mechanism.** Confirm how OpenClaw/NemoClaw installs skills from
  ClawHub (CLI command vs. dropping files into the skills dir) and that it works offline-ish
  within the hardened build (NemoClaw uses an offline npm lock for its own plugin install).
- **R4 — Egress (C2).** Documented prerequisite; owned by the future K8s spec, not this one.
- **R5 — Onboarding delegate.** The no-token path delegates to `toolbelt-cli` or the
  `@toolbeltai/skills` onboarding capability. Confirm the exact non-interactive command, what
  credential it consumes, and how it emits the token (stdout/file) so the shim can capture and
  persist it. If neither can run fully headless, the token-provided path remains the supported
  K8s path and onboarding is a local/dev convenience.
- **R6 — State dir writability under hardening.** Confirm the `sandbox` user can write
  `TOOLBELT_STATE_DIR` given Landlock/DAC hardening, and choose a default path outside the
  immutable blueprint.

---

## 9. Future specs (not this one)
- Kubernetes deployment: Deployment/ConfigMap/Secret, GPU scheduling, a persistent volume for
  `TOOLBELT_STATE_DIR`, and the egress/network-policy allowance for the Toolbelt instance host,
  likely as a Helm values contribution to `toolbelt-devops/`.
- CI auto-release wiring consistent with the workspace release pattern.
