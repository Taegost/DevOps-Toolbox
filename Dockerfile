# =============================================================================
# DevOps Toolbox
# =============================================================================
# A self-contained development environment image providing consistent versions
# of common DevOps tooling across any machine or IDE that supports Dev Containers.
#
# Base image: Microsoft's official Dev Container base (Ubuntu 24.04 / Noble)
# Includes out of the box: git, zsh, oh-my-zsh, curl, a non-root 'vscode' user
# with sudo, pipx, and common build dependencies.
# =============================================================================

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# -----------------------------------------------------------------------------
# Architecture detection
# TARGETARCH is set automatically by Docker Buildx during multi-platform builds.
# Values are 'amd64' or 'arm64' — matching the convention used by most tools.
# Tools that use different naming conventions (AWS CLI, gcloud) remap inline.
# -----------------------------------------------------------------------------
ARG TARGETARCH

# -----------------------------------------------------------------------------
# Tool version pins
# Tool versions are pinned in their respective install section to cut down on
# the amount of layer rebuilds when updating a tool.
# -----------------------------------------------------------------------------

# Python version is in the System Packages section below

# -----------------------------------------------------------------------------
# System packages
# Installed in a single layer to minimize image size.
# -----------------------------------------------------------------------------

# Prevent interactive prompts during apt operations
ENV DEBIAN_FRONTEND=noninteractive

ARG PYTHON_VERSION=3.12

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    unzip \
    gnupg \
    software-properties-common \
    ca-certificates \
    lsb-release \
    # Editors and terminal multiplexing
    nano \
    screen \
    # Network and filesystem utilities
    net-tools \
    iputils-ping \
    dnsutils \
    traceroute \
    nmap \
    tcpdump \
    iproute2 \
    rsync \
    yq \
    # Disk usage analysis
    ncdu \
    # Python (explicit version from deadsnakes PPA for pinning control)
    python${PYTHON_VERSION} \
    python${PYTHON_VERSION}-venv \
    python3-pip \
    pipx \
    # Shell completion framework (required for kubectl/terraform completions)
    bash-completion \
    && rm -rf /var/lib/apt/lists/* 

# Ensure pipx binaries are on PATH for all subsequent RUN steps and terminals
ENV PATH="/root/.local/bin:/home/vscode/.local/bin:${PATH}"
ENV PIPX_HOME="/usr/local/pipx"
ENV PIPX_BIN_DIR="/usr/local/bin"


# -----------------------------------------------------------------------------
# .NET SDK
# Installed via Microsoft's official install script rather than the Ubuntu apt
# package. The Ubuntu archive only carries the .1xx feature band of the SDK,
# which can cause build failures when projects or extensions require a newer
# band. The install script allows pinning to the full three-part version
# (major.minor.patch, where patch encodes the feature band) so band
# requirements are explicit and fully under our control.
#
# DOTNET_INSTALL_DIR: Install to /usr/local/dotnet so the SDK is accessible
# to all users, not just the user that ran the install script.
# -----------------------------------------------------------------------------\
ARG DOTNET_VERSION=10.0.201

ENV DOTNET_INSTALL_DIR="/usr/local/dotnet"
ENV PATH="${DOTNET_INSTALL_DIR}:${PATH}"
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh \
        --version ${DOTNET_VERSION} \
        --install-dir ${DOTNET_INSTALL_DIR} \
    && rm /tmp/dotnet-install.sh \
    && dotnet --version

# DOTNET_CLI_TELEMETRY_OPTOUT: Disable Microsoft telemetry in the SDK.
# DOTNET_NOLOGO: Suppress the 'Welcome to .NET' banner on first run.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV DOTNET_NOLOGO=1

# -----------------------------------------------------------------------------
# gcloud CLI (Google Cloud SDK)
# Installed via Google's versioned archive for exact version pinning.
# gcloud uses x86_64/arm naming — does NOT match TARGETARCH directly.
# Remapped inline: amd64 -> x86_64, arm64 -> arm.
# -----------------------------------------------------------------------------
ARG GCLOUD_VERSION=564.0.0

ENV CLOUDSDK_ROOT_DIR="/usr/local/google-cloud-sdk"
RUN GCLOUD_ARCH=$([ "${TARGETARCH}" = "arm64" ] && echo "arm" || echo "x86_64") \
    && curl -fsSL \
    "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${GCLOUD_VERSION}-linux-${GCLOUD_ARCH}.tar.gz" \
    -o /tmp/google-cloud-sdk.tar.gz \
    && tar -xzf /tmp/google-cloud-sdk.tar.gz -C /usr/local \
    && rm /tmp/google-cloud-sdk.tar.gz \
    && ${CLOUDSDK_ROOT_DIR}/install.sh \
        --quiet \
        --usage-reporting=false \
        --path-update=false \
        --bash-completion=false \
    && ${CLOUDSDK_ROOT_DIR}/bin/gcloud version
ENV PATH="${CLOUDSDK_ROOT_DIR}/bin:${PATH}"
ENV CLOUDSDK_CORE_DISABLE_PROMPTS=1

# -----------------------------------------------------------------------------
# Terraform
# Installed via HashiCorp's official binary release (not apt) so we can pin
# to an exact patch version rather than relying on repo availability.
# URL: https://developer.hashicorp.com/terraform
# -----------------------------------------------------------------------------
ARG TERRAFORM_VERSION=1.14.8

RUN curl -fsSL \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" \
    -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && chmod +x /usr/local/bin/terraform \
    && terraform version

# -----------------------------------------------------------------------------
# GitHub CLI (gh)
# Installed via official GitHub binary release — single static binary.
# gh uses amd64/arm64 naming — maps directly from TARGETARCH.
# -----------------------------------------------------------------------------
ARG GH_VERSION=2.89.0

RUN curl -fsSL \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" \
    -o /tmp/gh.tar.gz \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && mv /tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz /tmp/gh_${GH_VERSION}_linux_${TARGETARCH} \
    && chmod +x /usr/local/bin/gh \
    && gh version

# -----------------------------------------------------------------------------
# Ansible
# Installed via pipx into an isolated virtualenv so its dependencies cannot
# conflict with project-level Python packages.
# PIPX_HOME/PIPX_BIN_DIR are set above so binaries land in /usr/local/bin,
# making them available to all users including the non-root 'vscode' user.
# -----------------------------------------------------------------------------
ARG ANSIBLE_VERSION=13.5.0

RUN pipx install  --include-deps ansible==${ANSIBLE_VERSION}

# -----------------------------------------------------------------------------
# Ansible Galaxy collections
# Baked in at build time so they are available immediately on container start.
# See dependencies/ansible-requirements.yml for the full list and rationale.
# Project-specific collections should be installed via postCreateCommand using
# a project-level requirements file, not added here.
# -----------------------------------------------------------------------------
COPY dependencies/ansible-requirements.yml /tmp/ansible-requirements.yml
RUN ansible-galaxy collection install \
    -r /tmp/ansible-requirements.yml \
    && rm /tmp/ansible-requirements.yml

# -----------------------------------------------------------------------------
# Azure Ansible collection Python dependencies
# The azure.azcollection ships its own requirements file inside the installed
# collection directory. These must be installed separately after the collection
# is installed — they cannot be pre-listed in python-ansible-requirements.txt
# because the file doesn't exist until the collection is installed, and the
# package versions are tightly managed by the collection itself.
# -----------------------------------------------------------------------------
RUN pipx runpip ansible install \
    -r /usr/local/pipx/venvs/ansible/lib/python${PYTHON_VERSION}/site-packages/ansible_collections/azure/azcollection/requirements.txt

# -----------------------------------------------------------------------------
# Python toolbox packages for Ansible
# Injected into Ansible's pipx virtualenv so Ansible modules (e.g. cloud
# inventory plugins, k8s module) can import them directly.
# See dependencies/python-requirements.txt for the full list and rationale.
# -----------------------------------------------------------------------------
COPY dependencies/python-ansible-requirements.txt /tmp/python-ansible-requirements.txt
RUN pipx runpip ansible install \
    -r /tmp/python-ansible-requirements.txt \
    && rm /tmp/python-ansible-requirements.txt

# -----------------------------------------------------------------------------
# Azure CLI
# Installed via Microsoft's official apt repository rather than a raw binary.
# Azure CLI is a Python application with many components — the apt package
# handles all dependencies cleanly and is the officially recommended method
# for Ubuntu. This is an exception to the binary-install pattern used by
# other tools in this image.
#
# Telemetry is disabled via environment variable at the end of this block.
# -----------------------------------------------------------------------------
ARG AZURE_CLI_VERSION=2.85.0

RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/microsoft.gpg > /dev/null \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/microsoft.gpg] \
    https://packages.microsoft.com/repos/azure-cli/ \
    $(lsb_release -cs) main" \
    | tee /etc/apt/sources.list.d/azure-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    azure-cli=${AZURE_CLI_VERSION}-1* \
    && rm -rf /var/lib/apt/lists/* \
    && az version
ENV AZURE_CORE_COLLECT_TELEMETRY=false

# -----------------------------------------------------------------------------
# AWS CLI v2
# Installed via AWS's official versioned zip installer.
# AWS CLI uses x86_64/aarch64 naming — does NOT match TARGETARCH directly.
# Remapped inline: amd64 -> x86_64, arm64 -> aarch64.
# -----------------------------------------------------------------------------
ARG AWS_CLI_VERSION=2.34.28

RUN AWS_ARCH=$([ "${TARGETARCH}" = "arm64" ] && echo "aarch64" || echo "x86_64") \
    && curl -fsSL \
    "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWS_CLI_VERSION}.zip" \
    -o /tmp/awscliv2.zip \
    && unzip /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
        --bin-dir /usr/local/bin \
        --install-dir /usr/local/aws-cli \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && aws --version

# -----------------------------------------------------------------------------
# kubectl
# Installed via official Kubernetes binary release for exact version pinning.
# URL: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
# -----------------------------------------------------------------------------
ARG KUBECTL_VERSION=v1.35.3

RUN curl -fsSL \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# -----------------------------------------------------------------------------
# k9s
# Terminal UI for Kubernetes cluster management. Installed via GitHub release
# binary — no official apt package exists. Pinned for the same reproducibility
# reasons as all other binary tools in this image.
# URL: https://github.com/derailed/k9s
# -----------------------------------------------------------------------------
ARG K9S_VERSION=v0.50.18

RUN curl -fsSL \
    "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${TARGETARCH}.tar.gz" \
    -o /tmp/k9s.tar.gz \
    && tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s \
    && rm /tmp/k9s.tar.gz \
    && chmod +x /usr/local/bin/k9s \
    && k9s version

# -----------------------------------------------------------------------------
# kubeseal
# Tool used to manage SealedSecrets in a Kubernetes cluster. Installed via
# GitHub release binary — no official apt package exists. 
# URL: https://github.com/bitnami-labs/sealed-secrets
# -----------------------------------------------------------------------------
# The kubeseal version specifically does NOT have the v prefix
ARG KUBESEAL_VERSION=0.36.6

RUN curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-${TARGETARCH}.tar.gz" \
    && tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-${TARGETARCH}.tar.gz kubeseal \
    && install -m 755 kubeseal /usr/local/bin/kubeseal \
    && rm kubeseal \
    && rm kubeseal-${KUBESEAL_VERSION}-linux-${TARGETARCH}.tar.gz

# -----------------------------------------------------------------------------
# Helm
# Package manager for Kubernetes.
# Helm uses amd64/arm64 naming — maps directly from TARGETARCH.
# -----------------------------------------------------------------------------
ARG HELM_VERSION=v4.1.4

RUN curl -fsSL \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
    -o /tmp/helm.tar.gz \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tar.gz /tmp/linux-${TARGETARCH} \
    && chmod +x /usr/local/bin/helm \
    && helm version

# -----------------------------------------------------------------------------
# kubelogin (Azure/kubelogin)
# Kubernetes credential plugin implementing Azure AD authentication.
# Required for authenticating kubectl against AKS clusters using Azure AD /
# OIDC. Note: this is Azure/kubelogin, not int128/kubelogin (which is a
# general OIDC plugin). Uses amd64/arm64 naming — maps directly from TARGETARCH.
# -----------------------------------------------------------------------------
ARG KUBELOGIN_VERSION=v0.2.17

RUN curl -fsSL \
    "https://github.com/Azure/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin-linux-${TARGETARCH}.zip" \
    -o /tmp/kubelogin.zip \
    && unzip /tmp/kubelogin.zip -d /tmp/kubelogin \
    && mv /tmp/kubelogin/bin/linux_${TARGETARCH}/kubelogin /usr/local/bin/kubelogin \
    && rm -rf /tmp/kubelogin.zip /tmp/kubelogin \
    && chmod +x /usr/local/bin/kubelogin \
    && kubelogin --version

# -----------------------------------------------------------------------------
# Kustomize
# Template-free Kubernetes configuration management. Installed as a standalone
# binary to get a newer version than the one bundled inside kubectl, which
# lags behind. Used natively by ArgoCD alongside Helm.
# Kustomize uses amd64/arm64 naming — maps directly from TARGETARCH.
# -----------------------------------------------------------------------------
ARG KUSTOMIZE_VERSION=v5.8.1

RUN curl -fsSL \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${TARGETARCH}.tar.gz" \
    -o /tmp/kustomize.tar.gz \
    && tar -xzf /tmp/kustomize.tar.gz -C /usr/local/bin kustomize \
    && rm /tmp/kustomize.tar.gz \
    && chmod +x /usr/local/bin/kustomize \
    && kustomize version

# -----------------------------------------------------------------------------
# ArgoCD CLI
# Command-line interface for ArgoCD, a GitOps continuous delivery tool for 
#Kubernetes. Installed via GitHub release binary — no official apt package exists.
# ArgoCD uses amd64/arm64 naming — maps directly from TARGETARCH.
# -----------------------------------------------------------------------------
ARG ARGOCD_VERSION=v3.3.8

RUN curl -fsSL \
    -o argocd-linux-${TARGETARCH} \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${TARGETARCH}" \
    && install -m 555 argocd-linux-${TARGETARCH} /usr/local/bin/argocd \
    && rm argocd-linux-${TARGETARCH} \
    && argocd version

# -----------------------------------------------------------------------------
# Stern
# Multi-pod and container log tailing for Kubernetes. Significantly better
# than 'kubectl logs' for watching logs across multiple pods simultaneously
# during troubleshooting. Supports regex pod/container filtering.
# Stern uses amd64/arm64 naming — maps directly from TARGETARCH.
# -----------------------------------------------------------------------------
# The stern version specifically does NOT have the v prefix
ARG STERN_VERSION=1.33.1

RUN curl -fsSL \
    "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_${TARGETARCH}.tar.gz" \
    -o /tmp/stern.tar.gz \
    && tar -xzf /tmp/stern.tar.gz -C /usr/local/bin stern \
    && rm /tmp/stern.tar.gz \
    && chmod +x /usr/local/bin/stern \
    && stern --version

# -----------------------------------------------------------------------------
# Python development tooling
# Installed into the base Python environment so they are available for
# general Python development work independent of Ansible.
# -----------------------------------------------------------------------------
COPY dependencies/python-dev-requirements.txt /tmp/python-dev-requirements.txt
RUN grep -v '^\s*#' /tmp/python-dev-requirements.txt \
    | grep -v '^\s*$' \
    | xargs -I {} pipx install {} \
    && rm /tmp/python-dev-requirements.txt

# -----------------------------------------------------------------------------
# Shell completions
# Written to the system-wide completions directory so they are available to
# all users and all terminal sessions without any per-user configuration.
# This avoids the fragility of writing to ~/.bashrc at build time.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Shell completions — kubectl
# -----------------------------------------------------------------------------
RUN kubectl completion bash > /etc/bash_completion.d/kubectl

# -----------------------------------------------------------------------------
# Shell completions — Terraform
# Exits non-zero if already present, hence || true
# -----------------------------------------------------------------------------
RUN terraform -install-autocomplete || true

# -----------------------------------------------------------------------------
# Shell completions — Ansible
# -----------------------------------------------------------------------------
RUN pipx inject ansible argcomplete \
    && activate-global-python-argcomplete --dest=/etc/bash_completion.d

# -----------------------------------------------------------------------------
# Shell completions — Azure CLI
# The apt package automatically installs the completion script to
# /etc/bash_completion.d/ during installation — no additional step needed.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Shell completions — gcloud
# Symlinked from within the SDK directory rather than generated
# -----------------------------------------------------------------------------
RUN ln -s ${CLOUDSDK_ROOT_DIR}/completion.bash.inc /etc/bash_completion.d/gcloud

# -----------------------------------------------------------------------------
# Shell completions — GitHub CLI
# -----------------------------------------------------------------------------
RUN gh completion -s bash > /etc/bash_completion.d/gh

# -----------------------------------------------------------------------------
# Shell completions — AWS CLI
# Uses aws_completer binary rather than a generated script
# -----------------------------------------------------------------------------
RUN aws_completer_path=$(which aws_completer) \
    && echo "complete -C '${aws_completer_path}' aws" \
        > /etc/bash_completion.d/aws

# -----------------------------------------------------------------------------
# Shell completion loading
# Ensures bash-completion is sourced for all interactive shell sessions
# -----------------------------------------------------------------------------
RUN echo '\n# Load bash completions\nif [ -f /usr/share/bash-completion/bash_completion ]; then\n    . /usr/share/bash-completion/bash_completion\nfi' \
    >> /etc/bash.bashrc

# Shell completions — Helm
RUN helm completion bash > /etc/bash_completion.d/helm

# Shell completions — Kustomize
RUN kustomize completion bash > /etc/bash_completion.d/kustomize

# Shell completions — Stern
RUN stern --completion bash > /etc/bash_completion.d/stern

# -----------------------------------------------------------------------------
# Final ownership and user setup
# The base image creates a non-root 'vscode' user. We ensure the pipx bin
# directory (set to /usr/local/bin) and completion files are accessible.
# VS Code Dev Containers will connect as this user.
# -----------------------------------------------------------------------------
USER vscode
