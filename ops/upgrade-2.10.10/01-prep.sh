#!/bin/bash
# Step 1 (no downtime): pull 2.10.10 images through the mirror and build the
# patched flow overlay. Safe to re-run; skips what is already present.
set -euo pipefail

REF=97079b66d4923d0f5b2d87c500f681e46e10ab21   # fork upgrade/v2.10.10-oss
# Tried in order; a mirror that has not cached a new tag can hang for a long
# time, so each pull gets a deadline before falling through to the next.
MIRRORS="docker.m.daocloud.io hub.rat.dev"
PULL_TIMEOUT=900
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
    ok=
    for m in $MIRRORS; do
      echo "pull $m/$img (deadline ${PULL_TIMEOUT}s)"
      if timeout $PULL_TIMEOUT docker pull -q "$m/$img"; then
        docker tag "$m/$img" "$img"; ok=1; break
      fi
      echo "  failed or timed out on $m"
    done
    [ -n "$ok" ] || { echo "could not pull $img from any mirror"; exit 1; }
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
