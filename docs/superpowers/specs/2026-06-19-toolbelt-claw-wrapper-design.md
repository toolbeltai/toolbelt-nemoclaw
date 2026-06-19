# toolbelt-claw — Wrapper Container Design

**Date:** 2026-06-19
**Status:** Approved (design)
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

The wrapper is a **packaging and integration** layer, not an API gateway and not a process
supervisor. NemoClaw remains CLI/agent-driven; we do not add a new network surface.

### Non-goals
- No HTTP/gRPC API in front of NemoClaw's CLI.
- No runtime mutation of NemoClaw's configuration.
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
- **C2 — Locked-down egress.** The agent reaching `mcp.toolbelt.ai` requires that host to be
  permitted through the L7 proxy / network policy, and the MCP client must honor the proxy.
  This is a deployment prerequisite, documented here and owned by the future K8s spec.
- **C3 — Secrets must not be baked.** The integrity hash covers `openclaw.json`, so any
  secret placed there literally would be frozen into the image. Secrets must be referenced,
  not embedded.

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

### Baked at build time (covered by the integrity hash)
| Item | Mechanism | Default |
| --- | --- | --- |
| Toolbelt MCP server entry in `openclaw.json` | config fragment merged into blueprint | n/a |
| Toolbelt MCP URL | `TOOLBELT_MCP_URL` build ARG | `https://mcp.toolbelt.ai/mcp` |
| `@toolbeltai/skills` | ClawHub install into skills dir | `TOOLBELT_SKILLS_VERSION` ARG, default latest |
| NemoClaw base/version | `BASE_IMAGE` ARG | pinned NemoClaw sandbox tag |

Because the MCP URL is baked, **edge and prod are separate image builds** (different
`TOOLBELT_MCP_URL`), not a runtime toggle. This respects C1.

`@toolbeltai/skills` is **floating**: each build pulls the current published version (ARG can
pin a specific version when reproducibility is needed). A given image is still immutable; only
the choice of version at build time floats.

### Injected at runtime (env only — secrets and provider config)
| Env var | Purpose |
| --- | --- |
| `TOOLBELT_SERVICE_SECRET` | value for the `X-Service-Secret` header (service-to-service auth) |
| `TOOLBELT_USER` | value for the `X-Toolbelt-User` header |
| `NEMOCLAW_INFERENCE_BASE_URL` | OpenAI-compatible inference endpoint (provider-agnostic passthrough) |
| `NEMOCLAW_MODEL` | model ref (passthrough) |
| inference API key | provider key, passed via the env var NemoClaw expects |

Secret-bearing fields in `openclaw.json` are baked as **env-var references**
(e.g. `"X-Service-Secret": "${TOOLBELT_SERVICE_SECRET}"`) so the hash covers the placeholder
string, not the resolved secret (satisfies C3).

> **Implementation task (must-verify):** confirm OpenClaw's `openclaw.json` MCP config supports
> env-var interpolation in header/auth fields. If it does not, the auth value cannot be baked as
> a reference; fall back to a minimal pre-launch entrypoint shim that writes the resolved header
> into a runtime-only location the MCP client reads, without touching the hashed file.

### Inference: provider-agnostic
The wrapper does **not** assume Toolbelt's Bifrost router or any specific provider. Inference
endpoint, model, and key are pure runtime env passthrough. Pointing at Bifrost (or any
OpenAI-compatible endpoint) is purely an operational choice made via env at deploy time.

---

## 5. Startup flow

Unchanged from stock NemoClaw in the A2 path:

1. `/usr/local/bin/nemoclaw-start` runs.
2. OpenClaw gateway starts on `:18789`; integrity check passes (hash covers our baked config).
3. Env-referenced secrets resolve into the MCP auth headers.
4. Agent loads the baked Toolbelt skills.
5. Toolbelt MCP server registers as a tool source (outbound via the L7 proxy — see C2).
6. Healthcheck on `:18789/health`.

No new entrypoint logic in the A2 path. A1 (or the C3 fallback) would add a small pre-launch
shim only if hash handling or secret interpolation cannot be done cleanly at build time.

---

## 6. Repo deliverables

```
toolbelt-claw/
├── Dockerfile                      # A2 build: extends NemoClaw, injects MCP config + skills pre-pinning
├── config/
│   └── toolbelt-mcp.json           # MCP server fragment merged into openclaw.json (URL via ARG, secrets via ${ENV})
├── build.sh  (or Makefile)         # exposes ARGs: BASE_IMAGE, TOOLBELT_MCP_URL, TOOLBELT_SKILLS_VERSION
├── test/
│   └── smoke.sh                    # build + assert (see §7)
└── README.md                       # build args + required runtime env, egress prerequisite
```

---

## 7. Testing

A smoke test that builds the image and asserts:

1. **Skills present** — `@toolbeltai/skills` exists in the agent skills directory.
2. **MCP registered** — `openclaw.json` contains the Toolbelt MCP entry with the expected URL.
3. **Integrity intact** — NemoClaw's runtime integrity check passes on container start.
4. **Health** — container starts and `:18789/health` returns OK, using a mocked/dummy inference
   endpoint and dummy secret env so no real Toolbelt/provider calls are required.

The test must not require live network egress to `mcp.toolbelt.ai` or a real inference provider;
registration is structural (config + files present), not a live MCP handshake.

---

## 8. Open implementation risks (carried into the plan)

- **R1 — Hash injection point (A2).** See §3 must-verify. Gates build strategy.
- **R2 — Env interpolation for secrets.** See §4 must-verify. Gates the C3 approach.
- **R3 — ClawHub install mechanism.** Confirm how OpenClaw/NemoClaw installs skills from
  ClawHub (CLI command vs. dropping files into the skills dir) and that it works offline-ish
  within the hardened build (NemoClaw uses an offline npm lock for its own plugin install).
- **R4 — Egress (C2).** Documented prerequisite; owned by the future K8s spec, not this one.

---

## 9. Future specs (not this one)
- Kubernetes deployment: Deployment/ConfigMap/Secret, GPU scheduling, the egress/network-policy
  allowance for `mcp.toolbelt.ai`, likely as a Helm values contribution to `toolbelt-devops/`.
- CI auto-release wiring consistent with the workspace release pattern.
