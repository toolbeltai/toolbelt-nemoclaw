# Run the demo WITH the sandbox, on k8s (keep OpenShell)

This is the path that **keeps NemoClaw's OpenShell egress sandbox** (the security story) — unlike
`../run-anywhere/` which drops it for an unprivileged plain container. Here the NemoClaw stack is baked
into an image; the **gateway builds the sandbox at runtime**, so the pod needs a Docker daemon. Two
ways to give it one:

- **Sysbox (primary)** — Docker-in-Docker **without `--privileged`**. Requires the Sysbox runtimeclass
  on your nodes. `k8s/deployment-sysbox.yaml`.
- **DinD sidecar (fallback)** — a privileged `docker:dind` sidecar; the app container stays
  unprivileged. `k8s/deployment-dind.yaml`.

There is no unprivileged-stock-pod option for the sandbox: sandboxing means building/running a
locked-down child container, which needs a runtime that can do that.

## Build the image (context = the demo root, so it can COPY openclaw.json/policy.yaml/workspaces)

```bash
cd ..                      # toolbelt-demo/
docker build -f nemoclaw-k8s/Dockerfile -t ghcr.io/toolbeltai/toolbelt-shared-brain:latest .
docker push ghcr.io/toolbeltai/toolbelt-shared-brain:latest
```

## Prepare the shared brain (once, out of band)

The pod binds an existing namespace; create it + adopt the datasets first:
```bash
npx -y @toolbeltai/cli@latest namespace create "toolbelt-shared-brain"     # note the id
npx -y @toolbeltai/cli@latest public-assets adopt "NWS Active Weather Alerts" --namespace <id>
npx -y @toolbeltai/cli@latest public-assets adopt "US Census Blocks 2024"    --namespace <id>
npx -y @toolbeltai/cli@latest public-assets adopt "US Building Footprints"   --namespace <id>
```
Put `<id>` into `TOOLBELT_NAMESPACE` in the ConfigMap.

## Deploy

```bash
cp k8s/secret.example.yaml k8s/secret.yaml     # fill NEMOCLAW_PROVIDER_KEY, TOOLBELT_TOKEN, TOOLBELT_NAMESPACE
kubectl create ns toolbelt-claw-demo
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/deployment-sysbox.yaml    # or deployment-dind.yaml
kubectl apply -f k8s/service.yaml
```

The entrypoint then: waits for the daemon → onboards NemoClaw (gateway builds the OpenShell sandbox) →
installs the Toolbelt skill bound to the namespace → applies the egress policy → recovers. The
40Gi PVC caches the built sandbox so restarts don't rebuild from scratch.

## Runs anywhere that allows a Docker daemon

Local Docker, any k8s with Sysbox or a DinD sidecar, any cloud. The only place it can't run is a
cluster that forbids both Sysbox and privileged sidecars — there, fall back to `../run-anywhere/`
(no sandbox).

## VERIFY before relying on it (NemoClaw specifics I couldn't confirm without running it)
- The NemoClaw installer's **install-without-onboard** flag (so binaries bake, sandbox builds at runtime).
- `nemoclaw sandbox cp` / `config set` subcommands for applying `openclaw.json` + personas into the sandbox.
- The **OpenClaw gateway port** (18789 is a placeholder from the healthcare demo) for the Service + probes.
- The **foreground gateway / keep-alive** command (entrypoint uses `tail -f` as a holder).
- That the chosen **Nemotron supports tool-calling**.
- `@toolbeltai/cli` subcommands `namespace create` / `public-assets adopt` exact names.
