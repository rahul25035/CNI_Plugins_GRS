#!/bin/bash
# Cilium CNI Benchmark

set -e

RESULTS_DIR="$HOME/Desktop/cni-comparison/results/cilium"
CLUSTER_NAME="cilium-cluster"
PROJECT_DIR="$HOME/Desktop/cni-comparison"

echo "[cilium] Results -> $RESULTS_DIR"

# ---- CLEANUP: remove old cluster if it exists ----
kind delete cluster --name $CLUSTER_NAME 2>/dev/null && echo "[cilium] Old cluster removed" || true
sleep 3

# ---- STEP 1: Create the kind cluster ----
echo "[cilium] Creating cluster..."
kind create cluster --config "$PROJECT_DIR/clusters/cilium-cluster.yaml"
echo "[cilium] Cluster ready"

# ---- STEP 2: Install CNI binary plugins into all nodes ----
echo "[cilium] Installing CNI binaries..."
for node in cilium-cluster-control-plane cilium-cluster-worker cilium-cluster-worker2; do
  docker exec $node bash -c "
    mkdir -p /opt/cni/bin &&
    curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz \
    | tar -xz -C /opt/cni/bin
  "
done

# ---- STEP 3: Install Cilium via Helm ----
echo "[cilium] Installing Cilium via Helm..."
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update

helm install cilium cilium/cilium \
  --version 1.14.5 \
  --namespace kube-system \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes \
  --set tunnel=vxlan \
  --set kubeProxyReplacement=false

kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo "[cilium] All nodes Ready"

# Wait for eBPF programs to fully load
echo "[cilium] Waiting 20s for eBPF programs to initialize..."
sleep 20

# ---- STEP 4: Deploy benchmark workloads ----
echo "[cilium] Deploying workloads..."
kubectl apply -f "$PROJECT_DIR/workloads/iperf3-server.yaml"
kubectl apply -f "$PROJECT_DIR/workloads/microservice.yaml"

kubectl wait --for=condition=Ready pod/iperf3-server --timeout=180s
kubectl wait --for=condition=Ready pods -l app=backend --timeout=180s

SERVER_IP=$(kubectl get pod iperf3-server -o jsonpath='{.status.podIP}')
BACKEND_IP=$(kubectl get pod -l app=backend -o jsonpath='{.items[0].status.podIP}')
SERVER_NODE=$(kubectl get pod iperf3-server -o jsonpath='{.spec.nodeName}')
echo "[cilium] iperf3-server: $SERVER_IP on $SERVER_NODE"
echo "[cilium] backend:       $BACKEND_IP"

# ---- TEST 1: Latency (ping) ----
echo "[cilium] Test 1/4: Latency (100 pings, cross-node)..."
kubectl delete pod latency-test --ignore-not-found 2>/dev/null
sleep 2
kubectl run latency-test \
  --image=busybox \
  --restart=Never \
  --overrides="{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"NotIn\",\"values\":[\"$SERVER_NODE\"]}]}]}}}}}" \
  -- ping -c 100 -i 0.2 $SERVER_IP

sleep 40

kubectl logs latency-test > "$RESULTS_DIR/latency_ping.txt"
grep "round-trip\|packets transmitted" "$RESULTS_DIR/latency_ping.txt"

# ---- TEST 2: Bandwidth (iperf3) ----
echo "[cilium] Test 2/4: Bandwidth (iperf3, 30s, cross-node)..."
kubectl delete pod iperf3-client --ignore-not-found 2>/dev/null
sleep 2
kubectl run iperf3-client \
  --image=networkstatic/iperf3 \
  --restart=Never \
  --overrides="{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"NotIn\",\"values\":[\"$SERVER_NODE\"]}]}]}}}}}" \
  -- iperf3 -c $SERVER_IP -t 30 -J

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/iperf3-client --timeout=120s \
  || kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/iperf3-client --timeout=10s \
  || true
sleep 3

kubectl logs iperf3-client > "$RESULTS_DIR/bandwidth_iperf3.json"

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
echo "[cilium] Test 3/4: CPU/memory overhead..."
{
  echo "=== CILIUM CPU/MEMORY OVERHEAD ==="
  echo "Timestamp: $(date)"
  echo ""
  echo "=== KUBE-SYSTEM PODS (cilium components) ==="
  kubectl get pods -n kube-system -o custom-columns=\
"NAME:.metadata.name,CPU-REQ:.spec.containers[*].resources.requests.cpu,MEM-REQ:.spec.containers[*].resources.requests.memory"
  echo ""
  echo "=== CILIUM DAEMONSET RESOURCE SPEC ==="
  kubectl get daemonset cilium -n kube-system -o yaml | grep -A 8 "resources:" | head -30
  echo ""
  echo "=== NOTE ON CILIUM RESOURCE USAGE ==="
  echo "Cilium runs an agent (daemonset) on every node to manage eBPF programs."
  echo "The cilium-operator runs once cluster-wide for coordination."
  echo "eBPF programs run in kernel space - their CPU cost appears under the kernel,"
  echo "not directly under the cilium pod. This makes overhead harder to measure"
  echo "purely from pod resource requests."
} > "$RESULTS_DIR/cpu_overhead.txt"

# ---- TEST 4: HTTP microservice latency ----
echo "[cilium] Test 4/4: HTTP microservice (50 requests, cross-node)..."
kubectl delete pod http-test --ignore-not-found 2>/dev/null
sleep 2
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

echo "[cilium] Done. Results in $RESULTS_DIR"

# ---- FINAL CLEANUP ----
kubectl delete pod latency-test iperf3-client http-test --ignore-not-found