# syntax=docker/dockerfile:1
# NemoClaw publishes no pullable runtime "sandbox" image, so build.sh produces one
# from NemoClaw source (FROM the public sandbox-base) and passes its tag as BASE_IMAGE.
# The default matches build.sh's Stage 1 output. Override to use a prebuilt sandbox.
ARG BASE_IMAGE=nemoclaw-sandbox:local
FROM ${BASE_IMAGE}

ARG TOOLBELT_SKILLS_VERSION=latest
ARG TOOLBELT_CLI_VERSION=latest
ARG TOOLBELT_MCP_URL=https://mcp.toolbelt.ai/mcp
ENV TOOLBELT_MCP_URL=${TOOLBELT_MCP_URL}

USER root

# 1. Toolbelt tooling: CLI (onboarding delegate) globally; skills into OpenClaw's skills dir.
RUN npm install -g "@toolbeltai/cli@${TOOLBELT_CLI_VERSION}"
# Install skills into /sandbox/.openclaw/skills. The @toolbeltai/skills package ships
# skill directories at the package root (e.g. package/toolbelt/SKILL.md). The install
# script copies any top-level directory containing SKILL.md flat into the target skills
# dir. We replicate that logic: copy package/toolbelt -> skills/toolbelt (flat, per spec).
RUN npm pack "@toolbeltai/skills@${TOOLBELT_SKILLS_VERSION}" --pack-destination /tmp \
    && tar -xzf /tmp/toolbeltai-skills-*.tgz -C /tmp \
    && mkdir -p /sandbox/.openclaw/skills \
    && for d in /tmp/package/*/; do \
         name="$(basename "$d")"; \
         if [ -f "${d}SKILL.md" ] && [ "$name" != "bin" ] && [ "$name" != "node_modules" ] && [ "$name" != "assets" ]; then \
           cp -r "$d" "/sandbox/.openclaw/skills/${name}"; \
         fi; \
       done \
    && chown -R sandbox:sandbox /sandbox/.openclaw/skills \
    && rm -rf /tmp/package /tmp/toolbeltai-skills-*.tgz

# 2. Merge the MCP entry into the loaded config, substituting the url ARG.
COPY config/toolbelt-mcp.json /tmp/toolbelt-mcp.json
RUN node -e 'const fs=require("fs");const cfgPath="/sandbox/.openclaw/openclaw.json";const cfg=JSON.parse(fs.readFileSync(cfgPath,"utf8"));const frag=JSON.parse(fs.readFileSync("/tmp/toolbelt-mcp.json","utf8").replace("__TOOLBELT_MCP_URL__",process.env.TOOLBELT_MCP_URL));cfg.mcp=cfg.mcp||{};cfg.mcp.servers=Object.assign(cfg.mcp.servers||{},frag.mcp.servers);fs.writeFileSync(cfgPath,JSON.stringify(cfg,null,2))' \
    && rm -f /tmp/toolbelt-mcp.json

# 3. Re-pin the integrity hash so `shields up` stays valid.
RUN sha256sum /sandbox/.openclaw/openclaw.json > /sandbox/.openclaw/.config-hash \
    && chmod 660 /sandbox/.openclaw/.config-hash \
    && chown sandbox:sandbox /sandbox/.openclaw/.config-hash

# 4. State dir for persisted onboarded tokens (sandbox-owned, durable).
RUN mkdir -p /sandbox/.nemoclaw/state/toolbelt && chown -R sandbox:sandbox /sandbox/.nemoclaw/state/toolbelt
ENV TOOLBELT_STATE_DIR=/sandbox/.nemoclaw/state/toolbelt

# 5. Pre-launch shim becomes the entrypoint; it execs the original nemoclaw-start.
COPY bin/onboard-and-start.sh /usr/local/bin/onboard-and-start.sh
RUN chmod +x /usr/local/bin/onboard-and-start.sh

# No default CMD: nemoclaw-start launches the gateway + supervises it ONLY when
# invoked with no command (an arg sends it down an `exec "$@"` path that never
# starts the gateway). The shim forwards "$@", so an empty CMD = headless gateway.
# Override at runtime for a debug shell, e.g. `docker run -it … toolbelt-claw:dev bash`.
ENTRYPOINT ["/usr/local/bin/onboard-and-start.sh"]
CMD []
