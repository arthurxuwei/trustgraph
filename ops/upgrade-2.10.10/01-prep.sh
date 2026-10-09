#!/bin/bash
# Step 1 (no downtime): pull 2.10.10 images through the mirror and build the
# patched flow overlay. Safe to re-run; skips what is already present.
set -euo pipefail

REF=97079b66d4923d0f5b2d87c500f681e46e10ab21   # fork upgrade/v2.10.10-oss
MIRROR=hub.rat.dev
PIP_MIRROR=https://mirrors.aliyun.com/pypi/simple/
SRC_ROOT=/root/tg/src
SRC=$SRC_ROOT/trustgraph-$REF

echo "== disk before"; df -h / | tail -1

for img in trustgraph/trustgraph-flow:2.10.10 \
           trustgraph/trustgraph-docling:2.10.10 \
           trustgraph/trustgraph-ui:2.2.5; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "have $img"
  else
    echo "pull $MIRROR/$img"
    docker pull -q "$MIRROR/$img"
    docker tag "$MIRROR/$img" "$img"
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
