#!/bin/bash
# Step 3 (DOWNTIME, ~5 min): stop TrustGraph services, recreate the empty rows
# tables under the 2.10 schema, start control first, then everything else.
# Stateful services (cassandra, pulsar, bookie, zookeeper, qdrant) keep running.
set -euo pipefail
cd /root/tg/bundle

grep -q 'docling-decoder' docker-compose.yaml \
  || { echo "compose not updated, run 02-config.sh first"; exit 1; }

STATEFUL='^(cassandra|pulsar|pulsar-init|bookie|zookeeper|qdrant)$'
APP=$(docker compose config --services | grep -vE "$STATEFUL" | tr '\n' ' ')
REST=$(echo $APP | tr ' ' '\n' | grep -vx control | tr '\n' ' ')

echo "== stop: $APP"
docker compose stop $APP

# 2.10 adds row_id to the rows primary key (#1055); existing tables cannot be
# altered and every write to them would fail. All were empty on 2026-10-09;
# re-check and refuse to drop anything that holds data.
CQL="docker exec bundle-cassandra-1 cqlsh -e"
for ks in $($CQL "SELECT keyspace_name FROM system_schema.tables WHERE table_name='rows' ALLOW FILTERING" | awk 'NR>3 && NF==1 {print $1}'); do
  n=$($CQL "SELECT COUNT(*) FROM $ks.rows" | awk 'NR==4{print $1}')
  if [ "$n" != "0" ]; then
    echo "ABORT: $ks.rows has $n rows; services are stopped, investigate before continuing"
    exit 1
  fi
  $CQL "DROP TABLE IF EXISTS $ks.rows; DROP TABLE IF EXISTS $ks.row_partitions;"
  echo "dropped $ks.rows / row_partitions"
done

# Every 2.10 processor asks config-svc for getkeys-all-ws at startup, so the
# control group (config-svc, flow-svc, iam, librarian) must be up first.
echo "== start control"
docker compose up -d --no-deps control
for i in $(seq 1 40); do
  if docker logs --since 5m bundle-control-1 2>&1 | grep -qiE 'config.*(start|ready|listening)|Starting group'; then break; fi
  sleep 3
done
sleep 15
docker inspect -f '{{.Name}} {{.State.Status}} restarts={{.RestartCount}}' bundle-control-1

echo "== start: $REST"
docker compose up -d --no-deps $REST
sleep 30
docker compose ps --format '{{.Service}}\t{{.Image}}\t{{.Status}}'
