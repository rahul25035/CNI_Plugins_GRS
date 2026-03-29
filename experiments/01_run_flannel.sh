#!/bin/bash
# ============================================================
# Flannel CNI Benchmark Script
# Runs all 4 benchmark tests and saves results to results/flannel/
# ============================================================

set -e  # stop on any error

RESULTS_DIR="$HOME/Desktop/cni-comparison/results/flannel"
CLUSTER_NAME="flannel-cluster"
PROJECT_DIR="$HOME/Desktop/cni-comparison"

echo "[flannel] Results -> $RESULTS_DIR"

# ---- CLEANUP: remove old cluster if it exists from a previous run ----
kind delete cluster --name $CLUSTER_NAME 2>/dev/null && echo "[flannel] Old cluster removed" || true
sleep 3

# ---- CLEANUP: remove old test pods if any leftover ----
kubectl delete pod latency-test iperf3-client http-test --ignore-not-found 2>/dev/null || true

# ---- STEP 1: Create the kind cluster ----
echo "[flannel] Creating cluster..."
kind create cluster --config "$PROJECT_DIR/clusters/flannel-cluster.yaml"

# ---- STEP 2: Install CNI binary plugins into all nodes ----
# Kind nodes are missing the 'bridge' CNI binary by default.
# Flannel needs it to create pod network interfaces.
echo "[flannel] Installing CNI binaries..."
for node in flannel-cluster-control-plane flannel-cluster-worker flannel-cluster-worker2; do
  docker exec $node bash -c "
    mkdir -p /opt/cni/bin &&
    curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz \
    | tar -xz -C /opt/cni/bin
  "
done

# ---- STEP 3: Install Flannel CNI ----
echo "[flannel] Installing Flannel CNI..."
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
kubectl wait --for=condition=Ready nodes --all --timeout=180s
echo "[flannel] All nodes Ready"

# ---- STEP 4: Deploy benchmark workloads ----
echo "[flannel] Deploying workloads..."
kubectl apply -f "$PROJECT_DIR/workloads/iperf3-server.yaml"
kubectl apply -f "$PROJECT_DIR/workloads/microservice.yaml"

kubectl wait --for=condition=Ready pod/iperf3-server --timeout=180s
kubectl wait --for=condition=Ready pods -l app=backend --timeout=180s

# Get server IP and node for tests
SERVER_IP=$(kubectl get pod iperf3-server -o jsonpath='{.status.podIP}')
BACKEND_IP=$(kubectl get pod -l app=backend -o jsonpath='{.items[0].status.podIP}')
# Record which node the server is on so test pods are forced to a DIFFERENT node
# This ensures all tests measure real cross-node traffic through the CNI, not same-node loopback
SERVER_NODE=$(kubectl get pod iperf3-server -o jsonpath='{.spec.nodeName}')
echo "[flannel] iperf3-server: $SERVER_IP on $SERVER_NODE"
echo "[flannel] backend:       $BACKEND_IP"

# ---- TEST 1: Latency (ping) ----
# Sends 100 pings at 0.2s intervals (total ~20s), saves min/avg/max stats
echo "[flannel] Test 1/4: Latency (100 pings, cross-node)..."
kubectl delete pod latency-test --ignore-not-found 2>/dev/null
sleep 2
# --overrides forces latency-test onto a different node than iperf3-server (cross-node traffic)
kubectl run latency-test \
  --image=busybox \
  --restart=Never \
  --overrides="{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"NotIn\",\"values\":[\"$SERVER_NODE\"]}]}]}}}}}" \
  -- ping -c 100 -i 0.2 $SERVER_IP

sleep 40

kubectl logs latency-test > "$RESULTS_DIR/latency_ping.txt"
grep "round-trip\|packets transmitted" "$RESULTS_DIR/latency_ping.txt"

# ---- TEST 2: Bandwidth (iperf3) ----
# Runs iperf3 for 30 seconds and saves JSON output with throughput data
echo "[flannel] Test 2/4: Bandwidth (iperf3, 30s, cross-node)..."
kubectl delete pod iperf3-client --ignore-not-found 2>/dev/null
sleep 2
# --overrides forces iperf3-client onto a different node than iperf3-server (cross-node traffic)
kubectl run iperf3-client \
  --image=networkstatic/iperf3 \
  --restart=Never \
  --overrides="{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"NotIn\",\"values\":[\"$SERVER_NODE\"]}]}]}}}}}" \
  -- iperf3 -c $SERVER_IP -t 30 -J

echo "Waiting for iperf3-client pod to complete (up to 2 min)..."
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/iperf3-client --timeout=120s \
  || kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/iperf3-client --timeout=10s \
  || true
sleep 3  # brief settle so logs are fully flushed

kubectl logs iperf3-client > "$RESULTS_DIR/bandwidth_iperf3.json"

# Verify the file is non-empty before parsing
if [ ! -s "$RESULTS_DIR/bandwidth_iperf3.json" ]; then
  echo "ERROR: iperf3 output is empty. Pod status:"
  kubectl describe pod iperf3-client | tail -20
  exit 1
fi

python3 -c "
import json
with open('$RESULTS_DIR/bandwidth_iperf3.json') as f:
    d = json.load(f)
bps = d['end']['sum_received']['bits_per_second']
print('  Bandwidth: ' + str(round(bps/1e9, 2)) + ' Gbps')
"

# ---- TEST 3: CPU and memory overhead ----
# Records the resource requests of Flannel pods (daemonset runs one per node)
echo "[flannel] Test 3/4: CPU/memory overhead..."
{
  echo "=== FLANNEL CPU/MEMORY OVERHEAD ==="
  echo "Timestamp: $(date)"
  echo ""
  echo "=== KUBE-SYSTEM PODS ==="
  kubectl get pods -n kube-system -o custom-columns=\
"NAME:.metadata.name,CPU-REQ:.spec.containers[*].resources.requests.cpu,MEM-REQ:.spec.containers[*].resources.requests.memory"
  echo ""
  echo "=== FLANNEL DAEMONSET PODS (one per node) ==="
  kubectl get pods -n kube-flannel -o custom-columns=\
"NAME:.metadata.name,CPU-REQ:.spec.containers[*].resources.requests.cpu,MEM-REQ:.spec.containers[*].resources.requests.memory"
  echo ""
  echo "=== FLANNEL RESOURCE SPEC ==="
  kubectl get daemonset kube-flannel-ds -n kube-flannel -o yaml | grep -A 5 "resources:"
} > "$RESULTS_DIR/cpu_overhead.txt"

# ---- TEST 4: HTTP microservice latency ----
# Makes 50 HTTP requests from one pod to backend, checks all succeed
echo "[flannel] Test 4/4: HTTP microservice (50 requests, cross-node)..."
kubectl delete pod http-test --ignore-not-found 2>/dev/null
sleep 2
# --overrides forces http-test onto a different node than iperf3-server (cross-node HTTP traffic)
kubectl run http-test \
  --image=busybox \
  --restart=Never \
  --overrides="{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"NotIn\",\"values\":[\"$SERVER_NODE\"]}]}]}}}}}" \
  -- sh -c "
    i=0
    while [ \$i -lt 50 ]; do
      i=\$((i+1))
      wget -q -O /dev/null --server-response http://${BACKEND_IP}/ 2>&1 | grep 'HTTP/' || true
      echo request \$i done
    done
    echo ALL DONE
  "

sleep 40

kubectl logs http-test > "$RESULTS_DIR/http_latency.txt"
grep "ALL DONE\|request 50" "$RESULTS_DIR/http_latency.txt"

echo "[flannel] Done. Results in $RESULTS_DIR"

# ---- FINAL CLEANUP: delete test pods ----
kubectl delete pod latency-test iperf3-client http-test --ignore-not-found 2>/dev/null