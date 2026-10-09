#!/bin/bash
# usage: rc.sh <instance-id> <script> [timeout]
ID=$1; S=$2; T=${3:-300}
B64=$(base64 -i "$S" | tr -d '\n')
INV=$(aliyun ecs RunCommand --RegionId cn-shenzhen --InstanceId.1 $ID --Type RunShellScript --Timeout $T --ContentEncoding Base64 --CommandContent "$B64" | jq -r .InvokeId)
N=$(( T/3 + 20 ))
for i in $(seq 1 $N); do
  R=$(aliyun ecs DescribeInvocationResults --RegionId cn-shenzhen --InvokeId $INV)
  ST=$(echo "$R" | jq -r '.Invocation.InvocationResults.InvocationResult[0].InvocationStatus')
  case $ST in Success|Failed|Aborted|Cancelled|Terminated|Error|Timeout)
    echo "status=$ST exit=$(echo "$R" | jq -r '.Invocation.InvocationResults.InvocationResult[0].ExitCode')"
    echo "$R" | jq -r '.Invocation.InvocationResults.InvocationResult[0].Output' | base64 -d; exit 0;; esac
  sleep 3
done; echo "TIMEOUT waiting $INV"
