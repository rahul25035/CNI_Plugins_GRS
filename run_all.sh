#!/bin/bash
# ============================================================
# Run All CNI Benchmarks - Flannel, Calico, Cilium
#
# This script runs all 3 experiments one after another.
# Each cluster is deleted before the next one starts
# to free up RAM (8GB laptop cannot run all 3 simultaneously).
#
# Total estimated time: 30-45 minutes
# ============================================================

PROJECT_DIR="$HOME/Desktop/cni-comparison"
EXPERIMENTS_DIR="$PROJECT_DIR/experiments"

echo "============================================================"
echo "  CNI Comparison - Full Benchmark Suite"
echo "  Running: Flannel -> Calico -> Cilium"
echo "  Estimated time: 30-45 minutes"
echo "============================================================"

# ---- PRE-FLIGHT: make sure all tools are available ----
echo ""
echo "[Pre-flight] Checking required tools..."

check_tool() {
  if ! command -v $1 &>/dev/null; then
    echo "ERROR: $1 is not installed. Please install it first."
    exit 1
  fi
  echo "  $1 - ok"
}

check_tool docker
check_tool kind
check_tool kubectl
check_tool helm
check_tool python3

echo "All tools found."

# ---- PRE-FLIGHT: clean up any leftover clusters ----
echo ""
echo "[Pre-flight] Cleaning up any leftover clusters from previous runs..."
kind delete cluster --name flannel-cluster 2>/dev/null && echo "  Deleted flannel-cluster" || echo "  No flannel-cluster found"
kind delete cluster --name calico-cluster  2>/dev/null && echo "  Deleted calico-cluster"  || echo "  No calico-cluster found"
kind delete cluster --name cilium-cluster  2>/dev/null && echo "  Deleted cilium-cluster"  || echo "  No cilium-cluster found"
sleep 3

# ---- PRE-FLIGHT: ensure results directories exist ----
mkdir -p "$PROJECT_DIR/results/flannel"
mkdir -p "$PROJECT_DIR/results/calico"
mkdir -p "$PROJECT_DIR/results/cilium"
echo "Results directories ready."

# ============================================================
# EXPERIMENT 1: FLANNEL
# ============================================================
echo ""
echo "============================================================"
echo "  STARTING EXPERIMENT 1 OF 3: FLANNEL"
echo "============================================================"
bash "$EXPERIMENTS_DIR/01_run_flannel.sh"

# Delete flannel cluster to free RAM before starting Calico
echo ""
echo "[Transition] Deleting Flannel cluster to free RAM..."
kind delete cluster --name flannel-cluster
echo "Flannel cluster deleted. Waiting 10 seconds before starting Calico..."
sleep 10

# ============================================================
# EXPERIMENT 2: CALICO
# ============================================================
echo ""
echo "============================================================"
echo "  STARTING EXPERIMENT 2 OF 3: CALICO"
echo "============================================================"
bash "$EXPERIMENTS_DIR/02_run_calico.sh"

# Delete calico cluster to free RAM before starting Cilium
echo ""
echo "[Transition] Deleting Calico cluster to free RAM..."
kind delete cluster --name calico-cluster
echo "Calico cluster deleted. Waiting 10 seconds before starting Cilium..."
sleep 10

# ============================================================
# EXPERIMENT 3: CILIUM
# ============================================================
echo ""
echo "============================================================"
echo "  STARTING EXPERIMENT 3 OF 3: CILIUM"
echo "============================================================"
bash "$EXPERIMENTS_DIR/03_run_cilium.sh"

# Delete cilium cluster after benchmarks are done
echo ""
echo "[Transition] Deleting Cilium cluster..."
kind delete cluster --name cilium-cluster
echo "Cilium cluster deleted."

# ============================================================
# FINAL: COMPARE ALL RESULTS
# ============================================================
echo ""
echo "============================================================"
echo "  ALL EXPERIMENTS COMPLETE - FINAL COMPARISON"
echo "============================================================"

# Run the analysis script to print comparison and generate charts
python3 "$PROJECT_DIR/analysis/analyze.py"

echo ""
echo "Charts saved to: $PROJECT_DIR/results/"
echo "  - latency_comparison.png"
echo "  - bandwidth_comparison.png"
echo "  - radar_comparison.png"
echo ""
echo "Raw results are in:"
echo "  - $PROJECT_DIR/results/flannel/"
echo "  - $PROJECT_DIR/results/calico/"
echo "  - $PROJECT_DIR/results/cilium/"
echo "============================================================"
