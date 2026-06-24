# Run anywhere (without NemoClaw)

The parent demo runs *inside NemoClaw's sandbox* (the secure NVIDIA venue) — that path needs the
NemoClaw CLI + a Docker daemon at runtime (DinD/privileged on k8s), because NemoClaw builds its sandbox
at start.

**This folder is the portable path.** It runs the *same agent definitions* (`openclaw.json` +
`workspaces/`) in **plain OpenClaw + Toolbelt**, in one ordinary container — no NemoClaw, no sandbox, no
DinD, no privilege.

- **Keep:** the multi-agent collaboration (`sessions_spawn`), the Toolbelt **shared brain**, Nemotron.
- **Drop:** OpenShell's egress sandbox (the policy/`403` security layer). Re-add NemoClaw only when the
  security story is the point of the demo.
- **Why it's portable:** the brain (state) lives in Toolbelt, a service the container connects to. The
  container is stateless → laptop, any k8s, any cloud.

## Run it

```bash
cp ../.env.example ../.env     # set NEMOCLAW_PROVIDER_KEY (NVIDIA key) + TOOLBELT_TOKEN + TOOLBELT_NAMESPACE
docker compose --env-file ../.env up --build
docker compose exec team openclaw tui     # ask main: "Give me the current severe-weather situation brief."
```
`TOOLBELT_NAMESPACE` is the shared brain — create + adopt the datasets first (see `../scripts/setup.sh`
steps 2, which work without NemoClaw too: `@toolbeltai/cli namespace create` + `public-assets adopt`).

## k8s
One Deployment of `toolbelt-shared-brain`, env from a Secret/ConfigMap. No special privileges.
(For independently-scaling specialists, split into one container per agent, all sharing
`TOOLBELT_NAMESPACE` — a more decoupled topology than `sessions_spawn`.)

## Verify before relying on it
- The exact OpenClaw serve/daemon command (`onboard --install-daemon` then the gateway) for your version.
- The `mcp__toolbelt__*` tool-permission names + what `toolbelt install --client openclaw` writes.
- That the chosen Nemotron model supports tool-calling.
