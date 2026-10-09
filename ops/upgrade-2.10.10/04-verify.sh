#!/bin/bash
# Step 4 (read-only): health checks after the cutover. Re-run until clean.
cd /root/tg/bundle

echo "== containers (image / state / restarts)"
for c in $(docker ps -a --filter name=bundle- --format '{{.Names}}' | sort); do
  docker inspect -f '{{.Name}}	{{.Config.Image}}	{{.State.Status}}	restarts={{.RestartCount}}' "$c"
done

echo "== errors in the last 10 min (count, then last 3 lines)"
for c in $(docker ps --filter name=bundle- --format '{{.Names}}' | grep -vE 'cassandra|pulsar|bookie|zookeeper|qdrant' | sort); do
  n=$(docker logs --since 10m "$c" 2>&1 | grep -cE 'Traceback|ERROR|Exception' || true)
  echo "-- $c errors=$n"
  [ "$n" != "0" ] && docker logs --since 10m "$c" 2>&1 | grep -E 'Traceback|ERROR|Exception' | tail -3
done

echo "== worker pools (concurrency actually applied)"
for c in bundle-triples-1 bundle-vector-store-1 bundle-rag-1 bundle-ingest-1; do
  echo "-- $c"; docker logs --since 30m "$c" 2>&1 | grep -oE 'ReceiverPool started with [0-9]+ workers' | sort | uniq -c
done

echo "== prompt/template problems (2.10 loads every template.* key; a missing or broken one shows here)"
for c in bundle-rag-1 bundle-ingest-1; do
  echo "-- $c"; docker logs --since 30m "$c" 2>&1 | grep -iE 'template|prompt.*(not found|unknown|invalid|error)' | grep -iE 'error|not found|unknown|invalid|fail' | tail -5
done

echo "== gateway on 8088: bad login must be 401 auth failure (overlay fix; unpatched 2.10 answers 200)"
curl -s -m 10 -w ' http=%{http_code}\n' -X POST http://localhost:8088/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"upgrade-probe","password":"wrong"}'

echo "== UI on 8888"
curl -s -m 10 -o /dev/null -w 'ui http=%{http_code}\n' http://localhost:8888/

echo "== docling decoder"
docker logs --since 30m bundle-document-decoder-1 2>&1 | grep -vE '^\s*$' | tail -5

echo "== disk"; df -h / | tail -1
