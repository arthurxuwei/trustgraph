#!/bin/bash
# Step 5: remove the 2.7.5 images once 04-verify.sh and the AML checks pass.
# Removes named images only; never runs a blanket prune of volumes.
cd /root/tg/bundle
echo "== disk before"; df -h / | tail -1
for img in trustgraph/trustgraph-unstructured:2.7.5 \
           trustgraph/trustgraph-flow:2.7.5 \
           trustgraph-flow:2.7.5-oss \
           hub.rat.dev/trustgraph/trustgraph-ui:0.3.11 \
           hub.rat.dev/trustgraph/trustgraph-flow:2.10.10 \
           hub.rat.dev/trustgraph/trustgraph-docling:2.10.10 \
           hub.rat.dev/trustgraph/trustgraph-ui:2.2.5 \
           docker.m.daocloud.io/trustgraph/trustgraph-flow:2.10.10 \
           docker.m.daocloud.io/trustgraph/trustgraph-docling:2.10.10 \
           docker.m.daocloud.io/trustgraph/trustgraph-ui:2.2.5; do
  docker image rm "$img" 2>&1 | tail -1
done
docker builder prune -f | tail -1
echo "== disk after"; df -h / | tail -1
