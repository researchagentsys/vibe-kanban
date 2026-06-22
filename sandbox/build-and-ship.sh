#!/usr/bin/env bash
# 本地构建沙箱镜像 → 直推 prod 主机**本地镜像库**(docker daemon,不经 registry)。
#
# 用法:
#   # 先确认 prod 架构:ssh <prod> uname -m  →  x86_64=amd64, aarch64=arm64
#   PLATFORM=linux/amd64 PROD_SSH=root@<prod-ip> ./sandbox/build-and-ship.sh   # 构建并 load 到 prod
#   ./sandbox/build-and-ship.sh                                                # 只构建 + 存本地 tar(再手动 scp/load)
#
# 关键提醒:
#   1) PLATFORM 必须匹配 prod 架构。本机若是 arm、prod 是 x86,构建 amd64 走 QEMU 模拟,
#      Rust 编译很慢(30~90min)、内存吃紧——耐心等,或换 x86 构建机/走 GHA(sandbox-image.yml)。
#   2) 本地 save/load 不产生 registry digest,故 med agent 用 **tag** 引用,
#      SANDBOX_REQUIRE_PINNED_IMAGE 保持 off(要 digest 钉就走 ACR 或 prod 上的本地 registry)。
#   3) 镜像约 1~2GB,save/传输按网速等。
set -euo pipefail

PLATFORM="${PLATFORM:-linux/amd64}"
TAG="${TAG:-$(git rev-parse --short HEAD)}"
IMAGE="${IMAGE:-med_agent_repo:${TAG}}"

cd "$(git rev-parse --show-toplevel)" # 构建上下文 = 仓库根(镜像 COPY crates/ packages/)

echo "[build] ${IMAGE}  platform=${PLATFORM}  context=${PWD}"
# --load:把**单平台**镜像装进本机 docker(多平台不能 --load,故固定单平台)。
docker buildx build --platform "${PLATFORM}" \
  -f sandbox/Dockerfile -t "${IMAGE}" --load .

if [ -n "${PROD_SSH:-}" ]; then
  echo "[ship] docker save | ssh ${PROD_SSH} docker load …"
  docker save "${IMAGE}" | gzip -1 | ssh "${PROD_SSH}" 'gunzip | docker load'
  ssh "${PROD_SSH}" "docker image inspect '${IMAGE}' >/dev/null && echo '[ok] prod 已有 ${IMAGE}'"
  echo "→ med agent 设:SANDBOX_CODING_IMAGE=${IMAGE}"
else
  out="${IMAGE//[\/:]/_}.tar.gz"
  echo "[save] PROD_SSH 未设 → 存本地 ${out}"
  docker save "${IMAGE}" | gzip -1 >"${out}"
  echo "→ 传输并加载:scp ${out} <prod>:  &&  ssh <prod> 'gunzip -c ${out} | docker load'"
  echo "→ med agent 设:SANDBOX_CODING_IMAGE=${IMAGE}"
fi
