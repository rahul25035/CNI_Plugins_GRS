#!/bin/bash
# Run all CNI benchmarks: Flannel -> Calico -> Cilium
# Clusters are deleted between runs to free RAM.
# Estimated time: 30-45 minutes

PROJECT_DIR="$HOME/Desktop/cni-comparison"
EXPERIMENTS_DIR="$PROJECT_DIR/experiments"

echo "CNI Benchmark Suite: Flannel -> Calico -> Cilium"

# Pre-flight: check tools
echo ""
echo "[pre-flight] Checking required tools..."
for tool in docker kind kubectl helm python3; do
  if ! command -v $tool &>/dev/null; then
    echo "  ERROR: $tool not found. Please install it first."; exit 1
  fi
  echo "  $tool ok"
done

# Pre-flight: clean up leftover clusters
echo ""
echo "[pre-flight] Removing any leftover clusters..."
kind delete cluster --name flannel-cluster 2>/dev/null && echo "  flannel-cluster deleted" || true
kind delete cluster --name calico-cluster  2>/dev/null && echo "  calico-cluster deleted"  || true
kind delete cluster --name cilium-cluster  2>/dev/null && echo "  cilium-cluster deleted"  || true
sleep 3

# Pre-flight: ensure result directories exist
mkdir -p "$PROJECT_DIR/results/flannel" \
         "$PROJECT_DIR/results/calico" \
         "$PROJECT_DIR/results/cilium"
echo "[pre-flight] Result directories ready"

# Experiment 1: Flannel
echo ""
echo "--- Experiment 1/3: Flannel ---"
bash "$EXPERIMENTS_DIR/01_run_flannel.sh"
kind delete cluster --name flannel-cluster 2>/dev/null
echo "[flannel] Cluster deleted. Waiting 10s..."
sleep 10

# Experiment 2: Calico
echo ""
echo "--- Experiment 2/3: Calico ---"
bash "$EXPERIMENTS_DIR/02_run_calico.sh"
kind delete cluster --name calico-cluster 2>/dev/null
echo "[calico] Cluster deleted. Waiting 10s..."
sleep 10

# Experiment 3: Cilium
echo ""
echo "--- Experiment 3/3: Cilium ---"
bash "$EXPERIMENTS_DIR/03_run_cilium.sh"
kind delete cluster --name cilium-cluster 2>/dev/null
echo "[cilium] Cluster deleted."

# Final: analyze and print comparison
echo ""
echo "--- Final Comparison ---"
python3 "$PROJECT_DIR/analysis/analyze.py"

echo ""
echo "Charts: $PROJECT_DIR/results/{latency,bandwidth,radar}_comparison.png"
echo "Raw results: $PROJECT_DIR/results/{flannel,calico,cilium}/"