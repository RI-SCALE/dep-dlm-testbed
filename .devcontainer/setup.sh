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

install_yq() {
    local YQ_VERSION="v4.44.3"
    echo -e "${BLUE}Installing yq $YQ_VERSION...${NC}"
    curl -Lo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}"
    chmod +x /usr/local/bin/yq
    echo -e "${GREEN}yq: $(yq --version)${NC}\n"
}

install_diagrams() {
    echo -e "${BLUE}Installing Graphviz + diagrams (Python)...${NC}"

    if ! command -v dot > /dev/null 2>&1; then
        apt-get update
        apt-get install -y graphviz
    fi

    if ! command -v dot > /dev/null 2>&1; then
        echo -e "${RED}dot still not found after apt install — check PATH or package availability${NC}"
        return 1
    fi

    /opt/conda/envs/rucio/bin/pip install --no-cache-dir diagrams 2>/dev/null \
        || pip install --no-cache-dir diagrams

    python3 -c "from diagrams import Diagram; print('diagrams OK')" \
        || { echo -e "${RED}diagrams import failed${NC}"; return 1; }
    echo -e "${GREEN}diagrams: $(dot -V 2>&1)${NC}\n"
}

install_gcloud() {
    echo -e "${BLUE}Installing Google Cloud CLI...${NC}"

    if command -v gcloud > /dev/null 2>&1; then
        echo -e "${GREEN}gcloud already installed: $(gcloud --version | head -1)${NC}\n"
        return 0
    fi

    apt-get update -qq
    apt-get install -y -qq ca-certificates gnupg curl

    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list

    apt-get update -qq
    # gke-gcloud-auth-plugin: needed for `kubectl` to auth against GKE clusters
    # provisioned by infra/terraform (see modules/kubernetes) — kubectl auth
    # against GKE moved off static tokens onto this plugin in newer clusters.
    apt-get install -y -qq google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin

    if ! command -v gcloud > /dev/null 2>&1; then
        echo -e "${RED}gcloud install failed — check the apt output above${NC}"
        return 1
    fi

    echo -e "${GREEN}gcloud: $(gcloud --version | head -1)${NC}"
    echo -e "${YELLOW}Run 'gcloud init' manually to authenticate — this is interactive (browser sign-in) and intentionally not automated here.${NC}\n"
}

install_terraform() {
    echo -e "${BLUE}Installing Terraform...${NC}"

    if command -v terraform > /dev/null 2>&1; then
        echo -e "${GREEN}terraform already installed: $(terraform version | head -1)${NC}\n"
        return 0
    fi

    apt-get update -qq
    apt-get install -y -qq wget gnupg lsb-release

    wget -qO - https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/hashicorp.list

    apt-get update -qq
    apt-get install -y -qq terraform

    if ! command -v terraform > /dev/null 2>&1; then
        echo -e "${RED}terraform install failed — check the apt output above${NC}"
        return 1
    fi

    echo -e "${GREEN}terraform: $(terraform version | head -1)${NC}\n"
}

install_terraform_docs() {
    echo -e "${BLUE}Installing terraform-docs...${NC}"

    if command -v terraform-docs > /dev/null 2>&1; then
        echo -e "${GREEN}terraform-docs already installed: $(terraform-docs --version)${NC}\n"
        return 0
    fi

    local TFDOCS_VERSION="v0.24.0"
    curl -Lo ./terraform-docs.tar.gz https://github.com/terraform-docs/terraform-docs/releases/download/${TFDOCS_VERSION}/terraform-docs-${TFDOCS_VERSION}-$(uname)-amd64.tar.gz
    mv terraform-docs.tar.gz /tmp/terraform-docs.tar.gz
    tar -xzf /tmp/terraform-docs.tar.gz -C /tmp terraform-docs
    chmod +x /tmp/terraform-docs
    mv /tmp/terraform-docs /usr/local/bin/terraform-docs
    rm -f /tmp/terraform-docs.tar.gz

    if ! command -v terraform-docs > /dev/null 2>&1; then
        echo -e "${RED}terraform-docs install failed — check the curl/tar output above${NC}"
        return 1
    fi

    echo -e "${GREEN}terraform-docs: $(terraform-docs --version)${NC}\n"
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
install_yq
install_rucio_gfal
install_diagrams
install_gcloud
install_terraform
install_terraform_docs
print_summary
