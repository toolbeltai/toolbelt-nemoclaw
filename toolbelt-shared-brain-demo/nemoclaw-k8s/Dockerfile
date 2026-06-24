# Run the demo WITH the OpenShell sandbox, anywhere — the NemoClaw stack baked into an image.
# The sandbox itself is built at RUNTIME by the gateway (NemoClaw ships no pullable sandbox image),
# so the pod needs a Docker daemon — provided by Sysbox (privilege-free) or a DinD sidecar (see k8s/).
#
# Build: bake NemoClaw CLI + OpenShell substrate + Docker engine + Node + @toolbeltai/cli +
#        the demo's openclaw.json / policy.yaml / personas + the provision flow.
# Run (entrypoint): wait for daemon -> provision (onboard => gateway BUILDS the sandbox, apply egress
#        policy, install Toolbelt in-sandbox bound to TOOLBELT_NAMESPACE, recover) -> hold the pod up.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates gnupg jq python3 iptables uidmap \
    && rm -rf /var/lib/apt/lists/*

# Node 24 (OpenClaw/NemoClaw requirement)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs && rm -rf /var/lib/apt/lists/*

# Docker engine (dockerd + CLI + containerd): dockerd for the Sysbox path (in-container daemon);
# CLI-only used in the DinD-sidecar path. One image serves both.
RUN install -m0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
       docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# NemoClaw CLI + OpenShell substrate (bake binaries; the sandbox is built at runtime).
# VERIFY the installer's install-without-onboard flag for your NemoClaw version.
ENV NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1
RUN (curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash -s -- --install-only) \
    || (curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash -s -- --non-interactive --skip-onboard) \
    || echo "WARN: confirm the bake-install flag — see k8s/README VERIFY"

RUN npm i -g @toolbeltai/cli@latest

# The demo's own config + personas + provision flow (NOT the teammate's repo).
WORKDIR /opt/demo
COPY openclaw.json ./openclaw.template.json
COPY policy.yaml   ./policy.yaml
COPY workspaces/   ./workspaces/
COPY nemoclaw-k8s/provision.sh ./provision.sh
COPY nemoclaw-k8s/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh ./provision.sh

EXPOSE 18789
ENTRYPOINT ["/entrypoint.sh"]
