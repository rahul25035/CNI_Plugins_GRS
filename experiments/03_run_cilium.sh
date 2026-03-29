#!/bin/bash
# ============================================================
# Cilium CNI Benchmark Script
# Runs all 4 benchmark tests and saves results to results/cilium/
# Cilium uses eBPF - a kernel-level fast path for packet processing
# ============================================================

set -e

RESULTS_DIR="$HOME/cni-comparison/results/cilium"
CLUSTER_NAME="cilium-cluster"
PROJECT_DIR="$HOME/cni-comparison"

echo "============================================================"
echo "  Cilium CNI Benchmark"
echo "  Results will be saved to: $RESULTS_DIR"
echo "============================================================"

# ---- CLEANUP: remove old cluster if it exists ----
echo ""
echo "[Cleanup] Removing any existing cilium cluster..."
kind delete cluster --name $CLUSTER_NAME 2>/dev/null && echo "Old cluster deleted" || echo "No old cluster found"
sleep 3

# ---- STEP 1: Create the kind cluster ----
echo ""
echo "[Step 1] Creating kind cluster: $CLUSTER_NAME"
kind create cluster --config "$PROJECT_DIR/clusters/cilium-cluster.yaml"
echo "Cluster created"

# ---- STEP 2: Install CNI binary plugins into all nodes ----
echo ""
echo "[Step 2] Installing CNI binary plugins into all nodes..."
for node in cilium-cluster-control-plane cilium-cluster-worker cilium-cluster-worker2; do
  echo "  Installing on $node..."
  docker exec $node bash -c "
    mkdir -p /opt/cni/bin &&
    curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz \
    | tar -xz -C /opt/cni/bin
  "
  echo "  Done: $node"
done

# ---- STEP 3: Install Cilium via Helm ----
# Cilium is installed using Helm (package manager for Kubernetes)
# kubeProxyReplacement=false keeps it compatible with kind
echo ""
echo "[Step 3] Adding Cilium Helm repo..."
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update

echo "Installing Cilium via Helm..."
helm install cilium cilium/cilium \
  --version 1.14.5 \
  --namespace kube-system \
  --set image.pullPolicy=IfNotPresent \
  --set ipam.mode=kubernetes \
  --set tunnel=vxlan \
  --set kubeProxyReplacement=false

echo "Cilium installed. Waiting for nodes to become Ready (up to 5 min)..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo "All nodes are Ready"
kubectl get nodes

# Wait a bit extra for Cilium eBPF programs to fully load
echo "Waiting 20 extra seconds for Cilium eBPF programs to initialize..."
sleep 20
echo "Cilium pods status:"
kubectl get pods -n kube-system | grep cilium

# ---- STEP 4: Deploy benchmark workloads ----
echo ""
echo "[Step 4] Deploying benchmark workloads..."
kubectl apply -f "$PROJECT_DIR/workloads/iperf3-server.yaml"
kubectl apply -f "$PROJECT_DIR/workloads/microservice.yaml"

echo "Waiting for iperf3-server to be ready (up to 3 min)..."
kubectl wait --for=condition=Ready pod/iperf3-server --timeout=180s

echo "Waiting for backend pods to be ready (up to 3 min)..."
kubectl wait --for=condition=Ready pods -l app=backend --timeout=180s

echo "All workloads are running:"
kubectl get pods -o wide

SERVER_IP=$(kubectl get pod iperf3-server -o jsonpath='{.status.podIP}')
BACKEND_IP=$(kubectl get pod -l app=backend -o jsonpath='{.items[0].status.podIP}')
echo ""
echo "iperf3 server IP: $SERVER_IP"
echo "backend IP:       $BACKEND_IP"

# ---- TEST 1: Latency (ping) ----
echo ""
echo "[Test 1] Running latency test (100 pings to iperf3-server)..."
kubectl delete pod latency-test --ignore-not-found 2>/dev/null
sleep 2
kubectl run latency-test \
  --image=busybox \
  --restart=Never \
  -- ping -c 100 -i 0.2 $SERVER_IP

echo "Waiting 40 seconds for ping to complete..."
sleep 40

kubectl logs latency-test > "$RESULTS_DIR/latency_ping.txt"
echo "Latency result:"
grep "round-trip\|packets transmitted" "$RESULTS_DIR/latency_ping.txt"

# ---- TEST 2: Bandwidth (iperf3) ----
echo ""
echo "[Test 2] Running bandwidth test (iperf3, 30 seconds)..."
kubectl delete pod iperf3-client --ignore-not-found 2>/dev/null
sleep 2
kubectl run iperf3-client \
  --image=networkstatic/iperf3 \
  --restart=Never \
  -- iperf3 -c $SERVER_IP -t 30 -J

echo "Waiting 50 seconds for iperf3 to complete..."
sleep 50

kubectl logs iperf3-client > "$RESULTS_DIR/bandwidth_iperf3.json"
echo "Bandwidth result:"
python3 -c "
import json
with open('$RESULTS_DIR/bandwidth_iperf3.json') as f:
    d = json.load(f)
bps = d['end']['sum_received']['bits_per_second']
print('  Received: ' + str(round(bps/1e9, 2)) + ' Gbps')
"

# ---- TEST 3: CPU and memory overhead ----
# Cilium has more components than Flannel: agent + operator + Hubble (if enabled)
echo ""
echo "[Test 3] Recording CPU and memory overhead..."
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
echo "CPU overhead saved"
cat "$RESULTS_DIR/cpu_overhead.txt"

# ---- TEST 4: HTTP microservice latency ----
echo ""
echo "[Test 4] Running HTTP microservice latency test (50 requests)..."
kubectl delete pod http-test --ignore-not-found 2>/dev/null
sleep 2
kubectl run http-test \
  --image=busybox \
  --restart=Never \
  -- sh -c "
    i=0
    while [ \$i -lt 50 ]; do
      i=\$((i+1))
      wget -q -O /dev/null --server-response http://${BACKEND_IP}/ 2>&1 | grep 'HTTP/' || true
      echo request \$i done
    done
    echo ALL DONE
  "

echo "Waiting 40 seconds for HTTP test to complete..."
sleep 40

kubectl logs http-test > "$RESULTS_DIR/http_latency.txt"
echo "HTTP test result:"
grep "ALL DONE\|request 50" "$RESULTS_DIR/http_latency.txt"

# ---- SUMMARY ----
echo ""
echo "============================================================"
echo "  CILIUM BENCHMARK SUMMARY"
echo "============================================================"
echo ""
echo "Latency (ping):"
grep "round-trip\|packets transmitted" "$RESULTS_DIR/latency_ping.txt"
echo ""
echo "Bandwidth (iperf3):"
python3 -c "
import json
with open('$RESULTS_DIR/bandwidth_iperf3.json') as f:
    d = json.load(f)
bps  = d['end']['sum_received']['bits_per_second']
sent = d['end']['sum_sent']['bits_per_second']
print('  Received: ' + str(round(bps/1e9, 2)) + ' Gbps')
print('  Sent:     ' + str(round(sent/1e9, 2)) + ' Gbps')
"
echo ""
echo "CPU overhead: see $RESULTS_DIR/cpu_overhead.txt"
echo ""
echo "HTTP test:"
grep "ALL DONE" "$RESULTS_DIR/http_latency.txt"
echo ""
echo "All results saved to: $RESULTS_DIR"
echo "============================================================"

# ---- FINAL CLEANUP ----
echo ""
echo "[Cleanup] Removing benchmark pods..."
kubectl delete pod latency-test iperf3-client http-test --ignore-not-found
echo "Done. Cluster '$CLUSTER_NAME' is still running."
echo "To delete it, run: kind delete cluster --name $CLUSTER_NAME"
