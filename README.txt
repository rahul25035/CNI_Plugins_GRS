CNI Plugin Performance Comparison
===================================
Kubernetes CNI Plugins: Flannel vs Calico vs Cilium
Project for: Performance Comparison of Kubernetes CNI Plugins


WHAT THIS PROJECT DOES
-----------------------
This project compares three Kubernetes CNI (Container Network Interface) plugins
by measuring real network performance metrics inside kind (Kubernetes-in-Docker) clusters.

Metrics measured:
  - Latency     : round-trip ping time between pods (ms)
  - Bandwidth   : throughput between pods using iperf3 (Gbps)
  - CPU overhead: resource requests of CNI daemonset pods
  - HTTP success: microservice-style HTTP requests between pods

CNI Plugins compared:
  - Flannel : Simple VXLAN overlay. Wraps packets inside UDP envelopes.
  - Calico  : BGP-based direct routing + VXLAN. Supports network policy.
  - Cilium  : eBPF-based. Processes packets in the Linux kernel fast-path.


REQUIREMENTS
------------
All of these must be installed before running:
  - Docker    (sudo apt install docker-ce)
  - kind      (https://kind.sigs.k8s.io)
  - kubectl   (https://kubernetes.io/docs/tasks/tools)
  - helm      (https://helm.sh)
  - python3
  - pip packages: matplotlib numpy  (pip3 install matplotlib numpy --break-system-packages)

Check all tools are installed:
  docker --version && kind version && kubectl version --client && helm version && python3 --version


PROJECT STRUCTURE
-----------------
cni-comparison/
  run_all.sh                  <- runs all 3 experiments in sequence (30-45 min total)
  clusters/
    flannel-cluster.yaml      <- kind cluster config for Flannel
    calico-cluster.yaml       <- kind cluster config for Calico
    cilium-cluster.yaml       <- kind cluster config for Cilium
  workloads/
    iperf3-server.yaml        <- iperf3 server pod + service (bandwidth testing)
    microservice.yaml         <- nginx backend + busybox load generator (HTTP testing)
  experiments/
    01_run_flannel.sh         <- runs full Flannel benchmark
    02_run_calico.sh          <- runs full Calico benchmark
    03_run_cilium.sh          <- runs full Cilium benchmark
  analysis/
    analyze.py                <- parses results and generates comparison charts
  results/
    flannel/                  <- Flannel result files saved here
    calico/                   <- Calico result files saved here
    cilium/                   <- Cilium result files saved here
    latency_comparison.png    <- generated chart (after analyze.py runs)
    bandwidth_comparison.png  <- generated chart
    radar_comparison.png      <- generated radar chart


HOW TO RUN
----------

Option A: Run all experiments at once (recommended)
  chmod +x run_all.sh experiments/*.sh
  ./run_all.sh

Option B: Run each CNI one at a time
  chmod +x experiments/*.sh

  # Flannel
  ./experiments/01_run_flannel.sh
  kind delete cluster --name flannel-cluster

  # Calico
  ./experiments/02_run_calico.sh
  kind delete cluster --name calico-cluster

  # Cilium
  ./experiments/03_run_cilium.sh
  kind delete cluster --name cilium-cluster

  # Analyze results and generate charts
  python3 analysis/analyze.py

IMPORTANT: Run only one cluster at a time. 8GB RAM is not enough for all 3 simultaneously.


RESULT FILES
------------
Each CNI experiment saves:
  latency_ping.txt        - raw ping output (100 packets, 0.2s interval)
  bandwidth_iperf3.json   - raw iperf3 JSON output (30s test)
  cpu_overhead.txt        - kubectl resource requests of CNI pods
  http_latency.txt        - wget HTTP request results (50 requests)


KNOWN ISSUE AND FIX (already handled in scripts)
-------------------------------------------------
kind clusters do not include the 'bridge' CNI binary by default.
Flannel, Calico, and Cilium all need it to create pod network interfaces.

The scripts automatically fix this by downloading CNI binaries into each node:
  docker exec <node> bash -c "
    curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.4.0/...
    | tar -xz -C /opt/cni/bin
  "
You do not need to do anything - this is handled automatically.


ARCHITECTURE NOTES (for report)
---------------------------------
Flannel:
  - Uses VXLAN overlay: wraps every pod packet inside a UDP packet
  - Simple and stable, no network policy support
  - Overhead: one extra network hop per packet (encapsulation cost)

Calico:
  - Uses BGP routing by default, falls back to VXLAN for kind
  - Supports Kubernetes NetworkPolicy for pod-level firewall rules
  - calico-typha reduces API server load in larger clusters

Cilium:
  - Uses Linux eBPF programs loaded into the kernel
  - Bypasses iptables entirely - faster at high connection counts
  - Supports L7 (HTTP/gRPC-level) network policy
  - Most complex to operate but highest performance ceiling
