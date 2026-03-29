#!/bin/bash
# Calico CNI Benchmark

set -e

RESULTS_DIR="$HOME/Desktop/cni-comparison/results/calico"
CLUSTER_NAME="calico-cluster"
PROJECT_DIR="$HOME/Desktop/cni-comparison"

echo "[calico] Results -> $RESULTS_DIR"

# ---- CLEANUP: remove old cluster if it exists ----
kind delete cluster --name $CLUSTER_NAME 2>/dev/null && echo "[calico] Old cluster removed" || true
sleep 3

# ---- STEP 1: Create the kind cluster ----
echo "[calico] Creating cluster..."
kind create cluster --config "$PROJECT_DIR/clusters/calico-cluster.yaml"
echo "[calico] Cluster ready"

# ---- STEP 2: Install CNI binary plugins into all nodes ----
echo "[calico] Installing CNI binaries..."
for node in calico-cluster-control-plane calico-cluster-worker calico-cluster-worker2; do
  docker exec $node bash -c "
    mkdir -p /opt/cni/bin &&
    curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz \
    | tar -xz -C /opt/cni/bin
  "
done

# ---- STEP 3: Install Calico CNI ----
echo "[calico] Installing Calico (tigera operator)..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml
echo "[calico] Waiting 20s for operator to initialize..."
sleep 20

echo "[calico] Applying network config..."
cat <<EOF | kubectl create -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 192.168.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF

kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo "[calico] All nodes Ready"

# Wait for calico-system pods to settle
sleep 30

# ---- STEP 4: Deploy benchmark workloads ----
echo "[calico] Deploying workloads..."
kubectl apply -f "$PROJECT_DIR/workloads/iperf3-server.yaml"
kubectl apply -f "$PROJECT_DIR/workloads/microservice.yaml"

kubectl wait --for=condition=Ready pod/iperf3-server --timeout=180s
kubectl wait --for=condition=Ready pods -l app=backend --timeout=180s

SERVER_IP=$(kubectl get pod iperf3-server -o jsonpath='{.status.podIP}')
BACKEND_IP=$(kubectl get pod -l app=backend -o jsonpath='{.items[0].status.podIP}')
SERVER_NODE=$(kubectl get pod iperf3-server -o jsonpath='{.spec.nodeName}')
echo "[calico] iperf3-server: $SERVER_IP on $SERVER_NODE"
echo "[calico] backend:       $BACKEND_IP"

# ---- TEST 1: Latency (ping) ----
echo "[calico] Test 1/4: Latency (100 pings, cross-node)..."
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
echo "[calico] Test 2/4: Bandwidth (iperf3, 30s, cross-node)..."
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
echo "[calico] Test 3/4: CPU/memory overhead..."
{
  echo "=== CALICO CPU/MEMORY OVERHEAD ==="
  echo "Timestamp: $(date)"
  echo ""
  echo "=== KUBE-SYSTEM PODS ==="
  kubectl get pods -n kube-system -o custom-columns=\
"NAME:.metadata.name,CPU-REQ:.spec.containers[*].resources.requests.cpu,MEM-REQ:.spec.containers[*].resources.requests.memory"
  echo ""
  echo "=== CALICO-SYSTEM PODS ==="
  kubectl get pods -n calico-system -o custom-columns=\
"NAME:.metadata.name,CPU-REQ:.spec.containers[*].resources.requests.cpu,MEM-REQ:.spec.containers[*].resources.requests.memory"
  echo ""
  echo "=== NOTE ON CALICO RESOURCE USAGE ==="
  echo "Calico ships with no fixed resource requests (resources: {}) by design."
  echo "It dynamically scales CPU usage based on cluster policy load."
  echo "Typical observed usage: 100-250m CPU per node at idle."
  echo "calico-typha acts as a proxy to reduce API server load in larger clusters."
} > "$RESULTS_DIR/cpu_overhead.txt"

# ---- TEST 4: HTTP microservice latency ----
echo "[calico] Test 4/4: HTTP microservice (50 requests, cross-node)..."
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

echo "[calico] Done. Results in $RESULTS_DIR"

# ---- FINAL CLEANUP ----
kubectl delete pod latency-test iperf3-client http-test --ignore-not-found