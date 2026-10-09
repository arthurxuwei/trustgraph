#!/bin/bash
# Step 1 (no downtime): pull 2.10.10 images from our ACR and build the
# patched flow overlay. Safe to re-run; skips what is already present.
set -euo pipefail

REF=fc59d6c562ef71ccd10c42d97950da03d3abe0f8   # fork upgrade/v2.10.10-oss
# The host cannot reach Docker Hub, and the public mirrors either refuse
# trustgraph/* (daocloud allowlist) or hang (hub.rat.dev). The images are
# copied into our ACR first (see README) and pulled over the VPC endpoint.
# ACR_USER / ACR_TOKEN: a temporary token from `aliyun cr GetAuthorizationToken`,
# exported at the top of this script by the operator; logged out afterwards.
ACR=aml-registry-vpc.cn-shenzhen.cr.aliyuncs.com
ACR_NS=$ACR/aml
PULL_TIMEOUT=900
PIP_MIRROR=https://mirrors.aliyun.com/pypi/simple/
SRC_ROOT=/root/tg/src
SRC=$SRC_ROOT/trustgraph-$REF

echo "== disk before"; df -h / | tail -1

echo "${ACR_TOKEN:?export ACR_USER/ACR_TOKEN first}" \
  | docker login -u "$ACR_USER" --password-stdin $ACR >/dev/null
trap 'docker logout $ACR >/dev/null 2>&1 || true' EXIT

# IMAGES may be exported to pull a subset (e.g. while one is still being
# copied into ACR); re-running later fetches whatever is missing.
for img in ${IMAGES:-trustgraph/trustgraph-flow:2.10.10 \
                     trustgraph/trustgraph-docling:2.10.10 \
                     trustgraph/trustgraph-ui:2.2.5}; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "have $img"
  else
    src=$ACR_NS/${img#trustgraph/}
    echo "pull $src"
    timeout $PULL_TIMEOUT docker pull -q "$src"
    docker tag "$src" "$img"
  fi
done

if [ ! -d "$SRC" ]; then
  echo "== fetch source $REF"
  mkdir -p "$SRC_ROOT"
  curl -fsSL --retry 3 --max-time 300 \
    "https://codeload.github.com/arthurxuwei/trustgraph/tar.gz/$REF" \
    | tar xz -C "$SRC_ROOT"
fi

echo "== build trustgraph-flow:2.10.10-oss"
docker build -q \
  --build-arg PIP_INDEX_URL=$PIP_MIRROR \
  -f "$SRC/containers/Containerfile.flow-oss" \
  -t trustgraph-flow:2.10.10-oss "$SRC"

echo "== images"
docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' \
  | grep -E 'trustgraph-(flow|docling|ui)' | sort
echo "== disk after"; df -h / | tail -1
