#!/usr/bin/env bash
#
# P0 single-tenant smoke test: build the sandbox image (context = repo root) and
# run ONE hardened tenant container. This is the validation/dev path; it is NOT
# multi-tenant-safe for the public until you enable a VM-grade runtime (gVisor /
# Kata) and host-level egress filtering (see sandbox/egress.nft + README).
#
# Usage:
#   ./sandbox/run-local.sh [tenant-id]
#   RUNSC=1 ./sandbox/run-local.sh demo     # run under gVisor (must be installed)
set -euo pipefail

TID="${1:-demo}"
ORIGIN="${VK_ALLOWED_ORIGINS:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Building vibe-kanban-sandbox:latest (context: $REPO_ROOT)"
docker build -f "$REPO_ROOT/sandbox/Dockerfile" -t vibe-kanban-sandbox:latest "$REPO_ROOT"

docker network inspect "vk-net-$TID" >/dev/null 2>&1 || docker network create "vk-net-$TID"

if [ -z "${RUNSC:-}" ]; then
  echo "⚠️  WARNING: RUNSC unset — shared-kernel (runc) isolation only." >&2
  echo "    DEV/TEST ONLY; NOT safe for untrusted/public tenants." >&2
  echo "    Install gVisor, then re-run with: RUNSC=1 $0 $TID" >&2
fi

echo "==> Running tenant '$TID' (origin: $ORIGIN)"
exec docker run --rm -it --name "vk-tenant-$TID" \
  ${RUNSC:+--runtime=runsc} \
  --user 10001:10001 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=512m \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 512 \
  --cpus 2 --memory 4g --memory-swap 4g \
  --network "vk-net-$TID" \
  -p 8080:8080 \
  -e VK_ALLOWED_ORIGINS="$ORIGIN" \
  -v "vk-data-$TID:/data" \
  -v "vk-work-$TID:/var/tmp/vibe-kanban" \
  vibe-kanban-sandbox:latest
#
# Reminder: -p publishes the port only for local testing. In production do NOT
# publish; route through your gateway over the per-tenant docker network, and
# apply egress filtering on the host (block 100.100.100.200) — see egress.nft.
