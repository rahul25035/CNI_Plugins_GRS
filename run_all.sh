#!/bin/bash
# Run all CNI benchmarks: Flannel -> Calico -> Cilium
# Each cluster is deleted between runs to free RAM.
# Estimated time: 30-45 minutes

PROJECT_DIR="$HOME/Desktop/cni-comparison"
EXPERIMENTS_DIR="$PROJECT_DIR/experiments"

echo "CNI Benchmark Suite: Flannel -> Calico -> Cilium"

# ---- PRE-FLIGHT: make sure all tools are available ----
echo ""
echo "[pre-flight] Checking required tools..."

check_tool() {
  if ! command -v $1 &>/dev/null; then
    echo "  ERROR: $1 not found. Please install it first."
    exit 1
  fi
  echo "  $1 ok"
}

check_tool docker
check_tool kind
check_tool kubectl
check_tool helm
check_tool python3

# ---- PRE-FLIGHT: clean up any leftover clusters ----
echo ""
echo "[pre-flight] Removing any leftover clusters..."
kind delete cluster --name flannel-cluster 2>/dev/null && echo "  flannel-cluster deleted" || true
kind delete cluster --name calico-cluster  2>/dev/null && echo "  calico-cluster deleted"  || true
kind delete cluster --name cilium-cluster  2>/dev/null && echo "  cilium-cluster deleted"  || true
sleep 3

# ---- PRE-FLIGHT: ensure results directories exist ----
mkdir -p "$PROJECT_DIR/results/flannel"
mkdir -p "$PROJECT_DIR/results/calico"
mkdir -p "$PROJECT_DIR/results/cilium"
echo "[pre-flight] Result directories ready"

# ---- EXPERIMENT 1: FLANNEL ----
echo ""
echo "--- Experiment 1/3: Flannel ---"
bash "$EXPERIMENTS_DIR/01_run_flannel.sh"
kind delete cluster --name flannel-cluster
echo "[flannel] Cluster deleted. Waiting 10s..."
sleep 10

# ---- EXPERIMENT 2: CALICO ----
echo ""
echo "--- Experiment 2/3: Calico ---"
bash "$EXPERIMENTS_DIR/02_run_calico.sh"
kind delete cluster --name calico-cluster
echo "[calico] Cluster deleted. Waiting 10s..."
sleep 10

# ---- EXPERIMENT 3: CILIUM ----
echo ""
echo "--- Experiment 3/3: Cilium ---"
bash "$EXPERIMENTS_DIR/03_run_cilium.sh"
kind delete cluster --name cilium-cluster
echo "[cilium] Cluster deleted."

# ---- FINAL: COMPARE ALL RESULTS ----
echo ""
echo "--- Final Comparison ---"
python3 "$PROJECT_DIR/analysis/analyze.py"

echo ""
echo "Charts: $PROJECT_DIR/results/{latency,bandwidth,radar}_comparison.png"
echo "Raw results: $PROJECT_DIR/results/{flannel,calico,cilium}/"