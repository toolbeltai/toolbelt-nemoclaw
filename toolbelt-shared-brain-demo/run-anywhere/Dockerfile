# Run the shared-brain demo ANYWHERE — plain OpenClaw + Toolbelt, NO NemoClaw.
# No sandbox, no DinD, no privilege. You keep: multi-agent collaboration (sessions_spawn) +
# the Toolbelt shared brain + Nemotron. You drop: OpenShell's egress sandbox (re-add NemoClaw
# only for the secure venue). One container runs main + the spawned subagents.
FROM node:24-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl python3 \
    && rm -rf /var/lib/apt/lists/*
RUN npm i -g openclaw@latest @toolbeltai/cli@latest

# Bake the agent definitions (the SAME ones the NemoClaw demo uses, minus policy/sandbox).
WORKDIR /root/.openclaw
COPY openclaw.json            /root/.openclaw/openclaw.template.json
COPY workspaces/main.md       /root/.openclaw/workspace-main/AGENTS.md
COPY workspaces/watch.md      /root/.openclaw/workspace-watch/AGENTS.md
COPY workspaces/exposure.md   /root/.openclaw/workspace-exposure/AGENTS.md
COPY workspaces/comms.md      /root/.openclaw/workspace-comms/AGENTS.md
COPY run-anywhere/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# These paths in openclaw.json are /sandbox/... for NemoClaw; here they're /root/.openclaw/...
# entrypoint.sh rewrites them along with the env placeholders.
ENTRYPOINT ["/entrypoint.sh"]
