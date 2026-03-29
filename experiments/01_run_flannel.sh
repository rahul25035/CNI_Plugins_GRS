#!/bin/bash
# Flannel CNI Benchmark

set -e

RESULTS_DIR="$HOME/Desktop/cni-comparison/results/flannel"
CLUSTER_NAME="flannel-cluster"
PROJECT_DIR="$HOME/Desktop/cni-comparison"

echo "[flannel] Results -> $RESULTS_DIR"

# Cleanup
kind delete cluster --name $CLUSTER_NAME 2>/dev/null && echo "[flannel] Old cluster removed" || true
sleep 3
kubectl delete pod latency-test iperf3-client http-test --ignore-not-found 2>/dev/null || true

# Step 1: Create cluster
echo "[flannel] Creating cluster..."
kind create cluster --config "$PROJECT_DIR/clusters/flannel-cluster.yaml" --quiet
echo "[flannel] Cluster ready"

# Step 2: Install CNI binaries
echo "[flannel] Installing CNI binaries on nodes..."
for node in flannel-cluster-control-plane flannel-cluster-worker flannel-cluster-worker2; do
  docker exec $node bash -c "
    mkdir -p /opt/cni/bin &&
    curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz \
    | tar -xz -C /opt/cni/bin
  " 2>/dev/null
done
echo "[flannel] CNI binaries installed"

# Step 3: Install Flannel
echo "[flannel] Installing Flannel CNI..."
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml -q
kubectl wait --for=condition=Ready nodes --all --timeout=180s --quiet
echo "[flannel] All nodes Ready"

# Step 4: Deploy workloads
echo "[flannel] Deploying workloads..."
kubectl apply -f "$PROJECT_DIR/workloads/iperf3-server.yaml" -q
kubectl apply -f "$PROJECT_DIR/workloads/microservice.yaml" -q
kubectl wait --for=condition=Ready pod/iperf3-server --timeout=180s --quiet
kubectl wait --for=condition=Ready pods -l app=backend --timeout=180s --quiet

SERVER_IP=$(kubectl get pod iperf3-server -o jsonpath='{.status.podIP}')
BACKEND_IP=$(kubectl get pod -l app=backend -o jsonpath='{.items[0].status.podIP}')
SERVER_NODE=$(kubectl get pod iperf3-server -o jsonpath='{.spec.nodeName}')
echo "[flannel] iperf3-server: $SERVER_IP on $SERVER_NODE"
echo "[flannel] backend:       $BACKEND_IP"

# Test 1: Latency
echo "[flannel] Test 1/4: Latency (100 pings, cross-node)..."
kubectl delete pod latency-test --ignore-not-found 2>/dev/null; sleep 2
kubectl run latency-test \
  --image=busybox --restart=Never \
  --overrides="{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"NotIn\",\"values\":[\"$SERVER_NODE\"]}]}]}}}}}" \
  -- ping -c 100 -i 0.2 $SERVER_IP 2>/dev/null
sleep 40
kubectl logs latency-test > "$RESULTS_DIR/latency_ping.txt"
grep "round-trip\|packets transmitted" "$RESULTS_DIR/latency_ping.txt"

# Test 2: Bandwidth
echo "[flannel] Test 2/4: Bandwidth (iperf3, 30s, cross-node)..."
kubectl delete pod iperf3-client --ignore-not-found 2>/dev/null; sleep 2
kubectl run iperf3-client \
  --image=networkstatic/iperf3 --restart=Never \
  --overrides="{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"NotIn\",\"values\":[\"$SERVER_NODE\"]}]}]}}}}}" \
  -- iperf3 -c $SERVER_IP -t 30 -J 2>/dev/null
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/iperf3-client --timeout=120s \
  || kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/iperf3-client --timeout=10s || true
sleep 3
kubectl logs iperf3-client > "$RESULTS_DIR/bandwidth_iperf3.json"
if [ ! -s "$RESULTS_DIR/bandwidth_iperf3.json" ]; then
  echo "ERROR: iperf3 output empty"; kubectl describe pod iperf3-client | tail -10; exit 1
fi
python3 -c "
import json
with open('$RESULTS_DIR/bandwidth_iperf3.json') as f: d = json.load(f)
bps = d['end']['sum_received']['bits_per_second']
print('  Bandwidth: ' + str(round(bps/1e9, 2)) + ' Gbps')
"

# Test 3: CPU overhead
echo "[flannel] Test 3/4: CPU/memory overhead..."
{
  echo "Timestamp: $(date)"
  echo ""
  echo "--- kube-system pods ---"
  kubectl get pods -n kube-system -o custom-columns=\
"NAME:.metadata.name,CPU-REQ:.spec.containers[*].resources.requests.cpu,MEM-REQ:.spec.containers[*].resources.requests.memory"
  echo ""
  echo "--- flannel daemonset pods (one per node) ---"
  kubectl get pods -n kube-flannel -o custom-columns=\
"NAME:.metadata.name,CPU-REQ:.spec.containers[*].resources.requests.cpu,MEM-REQ:.spec.containers[*].resources.requests.memory"
  echo ""
  echo "--- flannel resource requests ---"
  kubectl get daemonset kube-flannel-ds -n kube-flannel -o yaml | grep -A 5 "resources:"
} > "$RESULTS_DIR/cpu_overhead.txt"
echo "  Saved to cpu_overhead.txt"

# Test 4: HTTP microservice latency
echo "[flannel] Test 4/4: HTTP microservice (50 requests, cross-node)..."
kubectl delete pod http-test --ignore-not-found 2>/dev/null; sleep 2
kubectl run http-test \
  --image=busybox --restart=Never \
  --overrides="{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"NotIn\",\"values\":[\"$SERVER_NODE\"]}]}]}}}}}" \
  -- sh -c "
    i=0
    while [ \$i -lt 50 ]; do
      i=\$((i+1))
      wget -q -O /dev/null --server-response http://\${BACKEND_IP}/ 2>&1 | grep 'HTTP/' || true
      echo request \$i done
    done
    echo ALL DONE
  " 2>/dev/null
sleep 40
kubectl logs http-test > "$RESULTS_DIR/http_latency.txt"
grep "ALL DONE\|request 50" "$RESULTS_DIR/http_latency.txt"

echo "[flannel] All tests done. Results in $RESULTS_DIR"
kubectl delete pod latency-test iperf3-client http-test --ignore-not-found 2>/dev/null