# NemoClaw runtime substrate: what the OpenClaw gateway needs to reach `/health`

Investigation date: 2026-06-22.
Goal: understand what NVIDIA NemoClaw's host CLI ("OpenShell") sets up around the sandbox
container so the OpenClaw gateway becomes healthy on `http://127.0.0.1:18789/health`, and what a
plain `docker run` (and later a Kubernetes Deployment) needs to reproduce that.

Sources:
- Local images `nemoclaw-sandbox:local` and `toolbelt-claw:dev`.
- NemoClaw repo pinned at `4d33291df934819e3e913b64e14348f14e80cbf4` (cloned to `/tmp/nclaw-sub`).
- A **live running** OpenShell substrate observed on this host (`openshell-toolbelt-…` container +
  host-side `openclaw gateway` process), which let me confirm the architecture against running state
  rather than inferring it.

> **Bottom line (answer to Q6 up front):** YES — the gateway can be made healthy under plain Docker.
> It does **not** need GPU, the egress proxy, device-auth, or inference connectivity to reach a healthy
> `/health`. The single thing blocking the current `toolbelt-claw:dev` run is that OpenClaw **refuses to
> bind to `0.0.0.0` without an auth token** in a "container environment", and the entrypoint's
> token-provisioning path does not deliver a usable token to `openclaw gateway run` under bare Docker.
> Supplying `OPENCLAW_GATEWAY_TOKEN` makes `/health` return `200`. Verified below.

> **CORRECTION (controller re-verification, 2026-06-22):** the "200" above was achieved by invoking
> `openclaw gateway run` **directly**, not through our image's real entrypoint. Re-tested against
> `toolbelt-claw:dev` via its normal `docker run` path (ENTRYPOINT → shim → `nemoclaw-start`):
> - Setting `OPENCLAW_GATEWAY_TOKEN` as a `docker run -e` var is **NOT sufficient** — the container
>   still exits `0` and never reaches healthy.
> - `docker logs` shows only `Setting up NemoClaw...` + the config-integrity line; the
>   `[gateway] openclaw gateway launched as 'gateway' user (pid …)` line (`nemoclaw-start.sh:4027`)
>   **never appears**, so the entrypoint exits cleanly *before* launching the gateway, or the gateway
>   exits `0` immediately. `nemoclaw-start` ends in a `wait "$GATEWAY_PID"; if rc==0 exit 0` loop, so a
>   clean gateway exit takes PID 1 (and the container) down.
> - The stepped-down `gateway` user (`STEP_DOWN_PREFIX_GATEWAY`) does **not** inherit the container's
>   `OPENCLAW_GATEWAY_TOKEN`, which is why the run-level env var doesn't help.
>
> **Net:** making *our wrapper* reach healthy headless is a real, bounded integration task, not just
> "pass a token." Two candidate fixes (a design decision, deliberately left open): (1) propagate the
> gateway auth token into the stepped-down `gateway` user's environment, or (2) bake a loopback
> (`127.0.0.1`) gateway bind into `openclaw.json` so OpenClaw does not demand a token. The rest of
> this document (substrate architecture, proxy, device-auth, caps, k8s shape) stands.

---

## How the substrate actually looks when the host CLI runs it (live evidence)

Two cooperating pieces were observed on this host:

1. A host-side process (NOT in any container):
   `node …/openclaw/dist/index.js gateway --port 18789`, listening on `127.0.0.1:18789` and `[::1]:18789`.
   This is the process that answers `/health` with `{"ok":true,"status":"live"}`.
2. A running sandbox container `openshell-toolbelt-…`, image `openshell/sandbox-from:1781193681`,
   entrypoint `/opt/openshell/bin/openshell-sandbox` (NOT `nemoclaw-start` directly).

`docker inspect` of the sandbox container (HostConfig):

```
Privileged       = false
CapAdd           = ["SYS_ADMIN","NET_ADMIN","SYS_PTRACE","SYSLOG"]
CapDrop          = null
Devices          = null            (no /dev/nvidia*)
Runtime          = runc            (NOT nvidia)
NetworkMode      = openshell-docker (custom bridge)
SecurityOpt      = ["apparmor=unconfined"]
DeviceRequests   = null            (no GPU request)
ExtraHosts       = ["host.docker.internal:host-gateway","host.openshell.internal:host-gateway"]
Ports            = {}              (the sandbox does NOT publish 18789)
```

Inside that container the proxy and the nested sandbox were visible:

```
veth-h-ef9247f4 has inet 10.200.0.1/24, link-netns sandbox-ef9247f4
ss -tlnp: 10.200.0.1:3128 LISTEN  users:(("openshell-sandb",pid=1,fd=13))
ip netns: sandbox-ef9247f4 (id: 1)   # the agent's real network namespace
```

So the model is: `openshell-sandbox` (pid 1 in the container) creates an internal `veth` pair, gives
the host side `10.200.0.1/24`, runs an **L7 MITM proxy on `10.200.0.1:3128`**, and runs the actual
NemoClaw workload inside a **nested network namespace** (`sandbox-ef9247f4`) whose only egress is that
proxy. `10.200.0.1` is therefore *not* a docker network gateway (the `openshell-docker` bridge gateway
is `172.20.0.1`); it is an interface `openshell-sandbox` creates with `NET_ADMIN` inside its own
container.

---

## Q1. What does the startup sequence require before `/health` serves?

**Entrypoints**
- `nemoclaw-sandbox:local`: ENTRYPOINT `/usr/local/bin/nemoclaw-start`, CMD `/bin/bash`.
- `toolbelt-claw:dev`: ENTRYPOINT `/usr/local/bin/onboard-and-start.sh` (Toolbelt shim that provisions
  a token, patches the MCP URL into `openclaw.json`, then `exec`s `/usr/local/bin/nemoclaw-start`).

**Sequence inside `nemoclaw-start`** (in-image script == repo `scripts/nemoclaw-start.sh`, same line numbers):
1. `drop_capabilities …` (`scripts/nemoclaw-start.sh:188`) — re-execs through
   `capsh --drop=…cap_dac_override,cap_sys_admin,…` (def at `sandbox-init.sh:312`), dropping
   "dangerous" caps including `CAP_DAC_OVERRIDE`.
2. `migrate_legacy_layout …` (`nemoclaw-start.sh:3702`).
3. logs `Setting up NemoClaw...` (`nemoclaw-start.sh:3704`).
4. Branch on uid: non-root path at `:3717`, root path at `:3818`+. `toolbelt-claw:dev` runs as **root**
   (onboarding wrote to `/root/.openclaw`), so the root path is taken.
5. Root path provisions the gateway token (`prepare_gateway_token_for_current_command` `:3887`,
   `export_gateway_token` `:3892`), writes auth profile, configures messaging, then:
6. Launches the gateway: `nohup "${STEP_DOWN_PREFIX_GATEWAY[@]}" "$OPENCLAW" gateway run --port 18789 >/tmp/gateway.log 2>&1 &`
   (`nemoclaw-start.sh:4027`), as the `gateway` user.
7. `start_plugin_registry_refresh` polls `openclaw gateway status` up to **10×1s** (`:3667-3684`) then
   gives up; this is best-effort and does **not** gate `/health`.
8. `wait "$GATEWAY_PID"` keeps PID 1 alive; an auto-respawn loop restarts the gateway on death, but
   after exhausting a 60s crash budget it does `exit 0` (`:4098`).

**What `/health` truly depends on:** only that `openclaw gateway run` binds 18789 and reaches its own
`[gateway] ready` state. `/health` returns `{"ok":true,"status":"live"}` (HTTP 200) at that point. The
plugin-refresh poll, auto-pair, messaging, proxy and inference are all background/after-the-fact and do
not block `/health`.

**Why it never becomes healthy today:** the gateway process dies immediately on launch (see Q3), so the
nohup'd child never serves 18789; the respawn loop burns its budget and PID 1 exits `0` → container stops
→ Docker marks it `unhealthy`. The last lines you see (`Setting up NemoClaw...`,
`Config integrity check skipped for mutable default`) are exactly the point just before/at the failed
launch.

**Docker `HEALTHCHECK`** (from `docker inspect toolbelt-claw:dev`): computes the port from
`NEMOCLAW_DASHBOARD_PORT`/`OPENCLAW_GATEWAY_PORT`/`CHAT_UI_URL` (default 18789), then
`curl -sf --max-time 3 http://127.0.0.1:$port/health`. `rc=0` → healthy; `rc=7` (refused) falls through
to a process/marker check; the marker `/tmp/nemoclaw-gateway-local` is written by
`mark_in_container_gateway` at the launch site so the probe targets the in-container gateway.

---

## Q2. The managed proxy `NEMOCLAW_PROXY_HOST=10.200.0.1:3128`

- **What provides it:** the OpenShell sandbox runtime (`openshell-sandbox`), not the NemoClaw host CLI
  and not a separate squid container. Confirmed live: `10.200.0.1:3128` is bound by `openshell-sandb`
  (pid 1) on a `veth` it created. It is an **L7 MITM TLS-terminating forward proxy** — the script
  documents it re-signs TLS with its own CA (`nemoclaw-start.sh:2443-2449`).
- **How the sandbox consumes it:** `nemoclaw-start.sh:2429-2435` sets
  `PROXY_HOST="${NEMOCLAW_PROXY_HOST:-10.200.0.1}"`, `PROXY_PORT="${NEMOCLAW_PROXY_PORT:-3128}"`, and
  exports `HTTP(S)_PROXY=http://10.200.0.1:3128`, `NO_PROXY=localhost,127.0.0.1,::1,10.200.0.1`. The
  baked `openclaw.json` also has `proxy.enabled:true, proxyUrl:"http://10.200.0.1:3128",
  loopbackMode:"gateway-only"`.
- **Is it expected to pre-exist on that IP?** Yes — under the substrate the proxy already exists on
  `10.200.0.1` inside the namespace. Under bare Docker nothing listens there, so all egress
  (`HTTP(S)_PROXY`) points at a dead address.
- **Mandatory for the gateway to come up?** **No.** Verified: with the proxy unreachable the gateway
  still binds and `/health` returns 200 (it reached `[gateway] ready`). The proxy is needed for
  **agent tool calls and inference egress** (`https://inference.local/v1` is routed *through* the proxy
  on purpose — `nemoclaw-start.sh:2421-2424`), not for liveness. NOTE: a dead `HTTP(S)_PROXY` will make
  outbound calls hang/fail later, but it does not block `/health`.
- TS plumbing: `src/lib/onboard/sandbox-create-launch.ts:52-69` and
  `src/lib/onboard/dockerfile-patch.ts:236-251` propagate `NEMOCLAW_PROXY_HOST/PORT`; default fallback
  `10.200.0.1:3128` documented at `dockerfile-patch.ts:239`.

---

## Q3. Device auth (`NEMOCLAW_DISABLE_DEVICE_AUTH`) — and the *actual* startup blocker

- **What it is:** OpenClaw's device-pairing gate for the control UI. `NEMOCLAW_DISABLE_DEVICE_AUTH` is a
  **build-time-only** flag (`nemoclaw-start.sh:15`); it bakes
  `gateway.controlUi.dangerouslyDisableDeviceAuth` into `openclaw.json` at build and is auto-disabled
  when `CHAT_UI_URL` is non-loopback (`scripts/generate-openclaw-config.mts:1090`:
  `disableDeviceAuth = env.NEMOCLAW_DISABLE_DEVICE_AUTH === "1" || isRemote`).
- In the current `toolbelt-claw:dev` build the config shows `dangerouslyDisableDeviceAuth:false`.
- **Does device-auth block `/health`?** **No.** A 401 from device-auth still counts as "gateway alive"
  in the readiness whitelist — `src/lib/onboard/gateway-http-readiness.ts:28` allows `{200,401}`. Auto-pair
  runs in the background and does not gate liveness.
- **The real blocker is a *different* auth gate — the gateway listen-bind token.** Running
  `openclaw gateway run` directly in the container produced:
  > `Refusing to bind gateway to auto without auth. Container environment detected — the gateway
  > defaults to bind=auto (0.0.0.0) for port-forwarding compatibility. Set OPENCLAW_GATEWAY_TOKEN or
  > OPENCLAW_GATEWAY_PASSWORD, or pass --token/--password to start with auth.`
  The gateway exits immediately, so 18789 never opens. The entrypoint logs
  `[token] Gateway auth token refreshed for startup` (`export_gateway_token`/`prepare_gateway_token…`,
  `nemoclaw-start.sh:2043,2068,3887,3892`) but under bare Docker the token does not reach the
  `STEP_DOWN_PREFIX_GATEWAY`-launched `openclaw gateway run` (the launch passes no `--token`, and the
  stepped-down `gateway` user does not get `OPENCLAW_GATEWAY_TOKEN` in env on this path).
- **Verified fix:** running `openclaw gateway run --port 18789 --token <tok>` (HOME=/sandbox) reaches
  `[gateway] ready` and `curl /health` → **HTTP 200**. So this gate *can* be satisfied headlessly; it is
  not a hard substrate dependency. UNRESOLVED: whether the cleanest knob is exporting
  `OPENCLAW_GATEWAY_TOKEN`/`OPENCLAW_GATEWAY_PASSWORD` before `nemoclaw-start`, or setting
  `gateway.bind` to loopback in `openclaw.json` to avoid the 0.0.0.0-without-auth refusal; both are
  plausible and should be picked deliberately (see Minimal viable run).

A second, independent defect on the same path: `/tmp/gateway.log: Permission denied` at
`nemoclaw-start.sh:4027`. After `drop_capabilities` strips `CAP_DAC_OVERRIDE` (documented at
`sandbox-init.sh:174`: "After drop_capabilities() strips CAP_DAC_OVERRIDE, root can no longer write
files it does not own"), the redirect into the `gateway:gateway`-owned `/tmp/gateway.log` fails. This
co-occurs with the launch failure; even if the token were fixed, the log redirect can still abort the
nohup. The OpenShell substrate avoids this because its uid/gid setup and retained caps line up; under
bare Docker the cap-drop + step-down combination breaks it. Setting `NEMOCLAW_CAPS_DROPPED=1` got one
step further (baseline snapshot created) but the gateway still did not start, because the token gate
remained.

---

## Q4. OpenShell sandbox runtime — caps, runtime, GPU

- **"OpenShell" is NVIDIA's sandbox driver** (binaries `openshell`, `openshell-gateway`,
  `openshell-sandbox`, downloaded from `github.com/NVIDIA/OpenShell` by `scripts/install-openshell.sh`).
  On Linux it has a **Docker driver** (`openshell-gateway` + `openshell-sandbox` bins). It runs the
  workload container and provides the network namespace, the L7 proxy, seccomp, and (optionally)
  Landlock.
- **Capabilities (observed live):** the sandbox runs with `CAP_ADD: SYS_ADMIN, NET_ADMIN, SYS_PTRACE,
  SYSLOG`, `apparmor=unconfined`, `--security-opt no-new-privileges` (the script notes the latter at
  `nemoclaw-start.sh:3713`). `NET_ADMIN`/`SYS_ADMIN` are what let `openshell-sandbox` build the veth +
  nested netns + proxy. These are **substrate** caps for OpenShell's own use, **not** required by the
  OpenClaw gateway to serve `/health`.
- **Landlock / seccomp:** OpenShell ≥0.0.36 applies a seccomp policy that blocks e.g. `getifaddrs`
  (`nemoclaw-start.sh:2556-2565`) and may Landlock-restrict `/usr/local/lib` (`:2547-2552`); the script
  ships preloads to tolerate this. None of this is needed for liveness under bare Docker — in fact bare
  Docker's *default* seccomp/AppArmor is fine for `openclaw gateway run`.
- **Runtime:** `runc` (NOT sysbox/gVisor/nvidia). No `--privileged`.
- **GPU:** **Not required for the gateway.** Live container had `Runtime=runc`, `DeviceRequests=null`,
  no `/dev/nvidia*`. GPU is added *after* creation only when enabled, via
  `src/lib/onboard/docker-gpu-sandbox-create.ts` (and the gateway itself issues
  `docker create --device nvidia.com/gpu=all` for the agent runtime when GPU is on — see
  `build-context.ts` `gpu_cdi_injection_failed` hint). Liveness verified with no GPU.

---

## Q5. DNS proxy / networking the host CLI performs

- `scripts/setup-dns-proxy.sh` and `scripts/fix-coredns.sh` are thin wrappers that `exec node
  dist/nemoclaw.js internal dns setup-proxy|fix-coredns`. They are part of the **Kubernetes / cluster**
  path (CoreDNS patching), not the single-container Docker path.
- For the Docker path, networking the substrate provides that bare `docker run` lacks:
  1. The custom `openshell-docker` bridge (`172.20.0.0/16`) — minor.
  2. **The in-namespace L7 proxy on `10.200.0.1:3128`** and the **nested sandbox netns** whose only
     egress is that proxy (Q2). This is the big one.
  3. `ExtraHosts: host.docker.internal / host.openshell.internal → host-gateway` so the sandbox can
     reach host-side services (incl. the host-side gateway and OTEL).
  4. `inference.local` resolution: the L7 proxy is what resolves/route `https://inference.local/v1`
     (the baked inference baseUrl). The script explicitly warns *not* to add `inference.local` to
     `NO_PROXY` (`nemoclaw-start.sh:2421-2424`) because resolution happens proxy-side.
- A bare `docker run` has standard Docker DNS and no `10.200.0.1`, no proxy, no `inference.local`. That
  only matters for egress/inference, not for `/health`.

---

## Q6. Minimal path to a healthy gateway under plain Docker

Confirmed empirically. The gateway becomes healthy when:
1. `openclaw gateway run --port 18789` is given an auth token (because it auto-binds `0.0.0.0` in a
   container and refuses to do so unauthenticated), and
2. its log redirect target is writable (avoid the post-cap-drop `CAP_DAC_OVERRIDE` write failure).

Neither GPU, the `10.200.0.1:3128` proxy, device-auth pairing, nor `inference.local` connectivity is
required for `/health` to return 200 (all only matter for actual agent/inference traffic).

**Proven minimal recipe** (gateway reached `[gateway] ready`, `/health` → 200):
- `HOME=/sandbox`
- `OPENCLAW_GATEWAY_TOKEN=<token>` (or `--token`) — satisfies the bind-auth gate.
- Point the proxy at something harmless so later egress fails fast instead of hanging at a dead
  `10.200.0.1` (e.g. `NEMOCLAW_PROXY_HOST=127.0.0.1`), or run a tiny forward-proxy sidecar on
  `10.200.0.1:3128` if you want real egress.

Recommended for the wrapper image / `docker run`:
- Ensure `OPENCLAW_GATEWAY_TOKEN` (or `OPENCLAW_GATEWAY_PASSWORD`) is exported **before**
  `nemoclaw-start` launches the gateway, OR set the gateway to bind loopback in the baked
  `openclaw.json` so the no-auth-on-0.0.0.0 refusal does not trigger. (Pick one deliberately; do not
  modify project code as part of *this* investigation.)
- Build with `NEMOCLAW_DISABLE_DEVICE_AUTH=1` for headless/server runs so the control UI does not gate
  on device pairing (cosmetic for `/health`, real for the UI).
- Make `/tmp/gateway.log` writable by the launching identity (e.g. don't drop `CAP_DAC_OVERRIDE`
  before the gateway-user redirect, or create the log owned by the gateway user *after* the step-down).
  `NEMOCLAW_CAPS_DROPPED=1` skips the capsh re-exec but is not sufficient on its own.
- Publish `-p 18789:18789` and `curl http://127.0.0.1:18789/health`.

It is **NOT** fundamentally unrunnable without the host CLI or GPU. The host CLI's substrate
(proxy/netns/caps/DNS) is about **secure egress and sandbox isolation**, not gateway liveness.

---

## Q7. Kubernetes shape

A Deployment can run the gateway healthy without reproducing the full OpenShell substrate, as long as the
two liveness blockers (Q3) are handled. Translate the requirements as:

- **Container env:** `HOME=/sandbox`; `OPENCLAW_GATEWAY_TOKEN` (from a Secret) or a baked loopback bind;
  build with `NEMOCLAW_DISABLE_DEVICE_AUTH=1`; `NEMOCLAW_DASHBOARD_PORT=18789`.
- **Probes:** `readinessProbe`/`livenessProbe` httpGet `/health` on `18789` (allow 200; the gateway
  returns 200 once ready, 401 only behind device-auth which is disabled here).
- **securityContext:** *no* privileged, *no* GPU needed for liveness. If you keep `nemoclaw-start`'s
  internal cap-drop, ensure the gateway-log write path works (writable `emptyDir` at `/tmp`,
  consistent runAsUser/fsGroup so the `gateway` user can write `/tmp/gateway.log`). You do **not** need
  `SYS_ADMIN`/`NET_ADMIN` unless you also want OpenShell's in-pod L7 proxy + nested netns isolation.
- **Egress / proxy:** if you want the substrate's locked-down egress, run a forward-proxy **sidecar**
  and set `NEMOCLAW_PROXY_HOST`/`PORT` + `HTTP(S)_PROXY` to it; otherwise leave proxy disabled and let
  the gateway egress directly. For inference, replace `https://inference.local/v1` with a real
  endpoint (env overrides exist: `NEMOCLAW_*` model/api overrides) or front it with a Service named to
  resolve `inference.local`.
- **DNS:** the `setup-dns-proxy.sh`/`fix-coredns.sh` CoreDNS patching is OpenShell-cluster-specific; a
  standard k8s Deployment uses cluster DNS. Only relevant if you adopt OpenShell's own cluster image
  (which also carries the k3s/`fuse-overlayfs` snapshotter caveat documented in
  `src/lib/cluster-image-patch.ts`).
- **GPU:** add `nvidia.com/gpu` resources + nvidia runtime **only** for inference/agent GPU work, not
  for the gateway pod's health.
- **NetworkPolicy:** allow egress to the Toolbelt MCP host (`mcp.toolbelt.ai`) and the inference
  endpoint; allow ingress to `18789` from whatever fronts the control UI.

---

## UNRESOLVED / caveats
- The exact reason the entrypoint's `export_gateway_token` token does not reach the stepped-down
  `openclaw gateway run` under bare Docker was not traced to a single line; empirically the launched
  gateway refuses to bind for lack of a token while a manually-passed `--token` works. The cleanest
  remediation (export token pre-start vs. loopback bind in `openclaw.json`) is a design choice, left
  open here per "do not modify project code".
- Whether `OPENCLAW_GATEWAY_PASSWORD` behaves identically to `OPENCLAW_GATEWAY_TOKEN` for the bind gate
  was not separately tested (token path verified, password path inferred from the error message).
- The OpenShell driver binaries themselves (`openshell-sandbox` internals: how it programs iptables /
  the nested netns / the proxy) are closed in these sources; behavior was inferred from the *running*
  container's namespaces, interfaces, and listening sockets rather than source.
