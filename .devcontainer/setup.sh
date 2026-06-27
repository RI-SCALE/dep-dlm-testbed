#!/bin/bash
set -e

# Color definitions
BLUE='\033[0;34m'; RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

# --- Helper Functions ---

check_requirements() {
    echo -e "${CYAN}📋 System Requirements Check...${NC}"
    echo -e "${YELLOW} • Disk: 20-30+ GB | Memory: 8-16+ GB | Docker: Running${NC}"

    if [ $(uname -m) = x86_64 ]; then ARCH="amd64"; elif [ $(uname -m) = aarch64 ]; then ARCH="arm64"; else
        echo -e "${RED}Unsupported architecture: $(uname -m)${NC}"; exit 1
    fi
    echo -e "${BLUE}Detected architecture: $ARCH${NC}"

    echo -e "${BLUE}Waiting for Docker daemon...${NC}"
    timeout 30 bash -c 'until docker info > /dev/null 2>&1; do sleep 1; done' || {
        echo -e "${RED}Docker daemon failed to start${NC}"; exit 1
    }
    echo -e "${GREEN}Docker is ready${NC}\n"
}

install_kind() {
    local KIND_RELEASE="v0.29.0"
    echo -e "${BLUE}Installing Kind $KIND_RELEASE...${NC}"
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/$KIND_RELEASE/kind-linux-${ARCH}"
    chmod +x ./kind
    mv ./kind /usr/local/bin/kind

    kind delete cluster --name kind || true
    echo -e "${BLUE}Creating kind cluster...${NC}"
    kind create cluster --name kind --wait=180s
    kind get kubeconfig --name kind --internal=false > ~/.kube/config

    if ! kubectl get nodes > /dev/null 2>&1; then
        echo -e "${RED}Cluster failed to start${NC}"; docker logs kind-control-plane; exit 1
    fi
    echo -e "${GREEN}Kind cluster ready${NC}\n"
}

install_rucio_gfal() {
  echo -e "${BLUE}Installing gfal2 + rucio-clients via conda-forge...${NC}"

  # conda arch name differs from kind's amd64/arm64
  local CONDA_ARCH
  if [ "$ARCH" = "amd64" ]; then CONDA_ARCH="64"; else CONDA_ARCH="aarch64"; fi

  # micromamba (static, no system deps)
  if [ ! -x /usr/local/bin/micromamba ]; then
    curl -Ls "https://micro.mamba.pm/api/micromamba/linux-${CONDA_ARCH}/latest" \
      | tar -xvj -C /usr/local bin/micromamba
  fi
  export MAMBA_ROOT_PREFIX=/opt/conda

  # gfal2 + python binding + CLI tools, all API-matched from conda-forge
  /usr/local/bin/micromamba create -y -p /opt/conda/envs/rucio -c conda-forge \
    python=3.10 gfal2 python-gfal2 gfal2-util xrootd

  # rucio client pinned to the SERVER major (39.x); 40.x can misbehave vs a 39 server
  /opt/conda/envs/rucio/bin/pip install --no-cache-dir "rucio-clients[argcomplete]==39.*"

  # put the env first on PATH for this shell + future logins
  echo 'export PATH=/opt/conda/envs/rucio/bin:$PATH' >> /etc/profile.d/rucio_env.sh
  chmod +x /etc/profile.d/rucio_env.sh

  # sanity check — fail loudly if the binding didn't land
  /opt/conda/envs/rucio/bin/python -c "import gfal2; print('gfal2 binding OK')" || {
    echo -e "${RED}gfal2 python binding missing${NC}"; return 1; }
  echo -e "${GREEN}rucio: $(/opt/conda/envs/rucio/bin/rucio --version)  |  gfal CLIs: $(ls /opt/conda/envs/rucio/bin/gfal-* | wc -l) found${NC}\n"
}

print_summary() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    Sample Commands                           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}make certs${NC} (to generate certificates)"
    echo -e "${GREEN}Setup complete!${NC}"
}

# --- Execution ---

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                 Kind Cluster Setup Script                   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}\n"

check_requirements
install_kind
install_rucio_gfal
print_summary
