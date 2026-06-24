#!/usr/bin/env bash
# Ensure a Docker daemon, run the provision flow (gateway builds the sandbox + wires Toolbelt),
# then hold the pod up.
set -euo pipefail

# Sysbox path: this container runs its own dockerd  -> START_DOCKERD=1
# DinD-sidecar path: a sidecar runs dockerd          -> START_DOCKERD=0 + DOCKER_HOST=tcp://localhost:2375
if [ "${START_DOCKERD:-0}" = "1" ]; then
  echo "==> starting in-container dockerd (Sysbox)"
  dockerd >/var/log/dockerd.log 2>&1 &
fi

echo "==> waiting for docker daemon (${DOCKER_HOST:-local socket})"
for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null 2>&1 || {
  echo "ERROR: no Docker daemon — need the Sysbox runtimeclass (START_DOCKERD=1) or a DinD sidecar." >&2
  exit 1; }
echo "==> docker daemon ready"

/opt/demo/provision.sh

# Hold the pod open while the gateway + sandbox serve. VERIFY the foreground gateway command / use a
# readiness probe against the gateway port for real health.
echo "==> gateway + sandbox up; holding"
exec tail -f /dev/null
