#!/bin/bash
# Step 2 (no downtime): rewrite compose and launch files for 2.10.10.
# Nothing is restarted here; step 3 applies the changes.
set -euo pipefail
cd /root/tg/bundle

docker image inspect trustgraph-flow:2.10.10-oss >/dev/null \
  || { echo "overlay image missing, run 01-prep.sh first"; exit 1; }
grep -q 'docling-decoder' docker-compose.yaml \
  && { echo "already applied"; exit 0; }

TS=$(date +%Y%m%d-%H%M%S)
cp -p docker-compose.yaml docker-compose.yaml.bak-pre-2.10-$TS
cp -p docker-compose.override.yaml docker-compose.override.yaml.bak-pre-2.10-$TS
tar czf launch.bak-pre-2.10-$TS.tgz launch

# Every flow-image service runs the overlay: it carries the OSS librarian,
# tg:chunkCount (ingest) and the gateway error-format fix (api-gateway).
sed -i \
  -e 's#docker.io/trustgraph/trustgraph-flow:2.7.5#trustgraph-flow:2.10.10-oss#' \
  -e 's#docker.io/trustgraph/trustgraph-unstructured:2.7.5#docker.io/trustgraph/trustgraph-docling:2.10.10#' \
  -e 's#^    - universal-decoder$#    - docling-decoder#' \
  -e 's#docker.io/trustgraph/trustgraph-ui:0.3.11#docker.io/trustgraph/trustgraph-ui:2.2.5#' \
  docker-compose.yaml
sed -i 's#image: trustgraph-flow:2.7.5-oss#image: trustgraph-flow:2.10.10-oss#' \
  docker-compose.override.yaml

# Docling loads torch and layout/table models; 0.5 CPU / 1400M is not enough.
# Models are baked into the image; HF_ENDPOINT only matters if one is missing.
echo >> docker-compose.override.yaml   # file may lack a trailing newline
cat >> docker-compose.override.yaml <<'EOF'
# --- 2.10.10 升级：document-decoder 换成 docling（torch + 版面/表格模型）---
  document-decoder:
    environment:
      DOCLING_NUM_THREADS: "2"
      OMP_NUM_THREADS: "2"
      HF_ENDPOINT: "https://hf-mirror.com"
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4G
        reservations:
          memory: 1G
EOF

# 2.10 gives each processor one worker pool shared by all flows/workspaces,
# sized by params.concurrency (default 1). 2.7.5 had one consumer per flow.
# Only fill in values that are not already set.
docker run --rm -i -v /root/tg/bundle/launch:/l --entrypoint python \
  trustgraph-flow:2.10.10-oss - <<'PY'
import glob, yaml
want = {
    "trustgraph.query.triples.cassandra.Processor": 10,
    "trustgraph.storage.triples.cassandra.Processor": 4,
    "trustgraph.query.doc_embeddings.qdrant.Processor": 10,
    "trustgraph.query.graph_embeddings.qdrant.Processor": 10,
    "trustgraph.query.row_embeddings.qdrant.Processor": 10,
    "trustgraph.storage.doc_embeddings.qdrant.Processor": 4,
    "trustgraph.storage.graph_embeddings.qdrant.Processor": 4,
    "trustgraph.query.rows.cassandra.Processor": 10,
    "trustgraph.embeddings.document_embeddings.Processor": 4,
    "trustgraph.embeddings.graph_embeddings.Processor": 4,
    "trustgraph.chunking.recursive.Processor": 4,
    "trustgraph.agent.orchestrator.Processor": 4,
    "trustgraph.retrieval.document_rag.Processor": 4,
    "trustgraph.query.sparql.Processor": 10,
}
for f in sorted(glob.glob("/l/*/launch.yaml")):
    cfg = yaml.safe_load(open(f))
    changed = []
    for p in cfg["processors"]:
        n = want.get(p["class"])
        params = p.setdefault("params", {})
        if n and "concurrency" not in params:
            params["concurrency"] = n
            changed.append(f'{params.get("id")}={n}')
    if changed:
        yaml.safe_dump(cfg, open(f, "w"), sort_keys=False, allow_unicode=True)
    print(f, changed or "unchanged")
PY

echo "== compose diff"
diff docker-compose.yaml.bak-pre-2.10-$TS docker-compose.yaml || true
diff docker-compose.override.yaml.bak-pre-2.10-$TS docker-compose.override.yaml || true
docker compose config -q && echo "compose config OK"
