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
# Tool version pins
# All versions are declared here for visibility and ease of updating.
# To override during a local build:
#   docker build --build-arg TERRAFORM_VERSION=1.10.0 -t devops-toolbox .
# -----------------------------------------------------------------------------

# Cloud cli tools
ARG AWS_CLI_VERSION=2.34.28
ARG AZURE_CLI_VERSION=2.85.0
ARG GCLOUD_VERSION=564.0.0
ARG GH_VERSION=2.89.0

# Containerization tools
ARG K9S_VERSION=v0.50.18
ARG KUBECTL_VERSION=v1.35.3

# Infrastructure as code tools
ARG ANSIBLE_VERSION=13.5.0
ARG TERRAFORM_VERSION=1.14.8

# Programming languages
ARG DOTNET_VERSION=10.0.201
ARG PYTHON_VERSION=3.12

# -----------------------------------------------------------------------------
# System packages
# Installed in a single layer to minimize image size.
# -----------------------------------------------------------------------------

# Prevent interactive prompts during apt operations
ENV DEBIAN_FRONTEND=noninteractive

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
    rsync \
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
# -----------------------------------------------------------------------------
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

# Ensure pipx binaries are on PATH for all subsequent RUN steps and terminals
ENV PATH="/root/.local/bin:/home/vscode/.local/bin:${PATH}"
ENV PIPX_HOME="/usr/local/pipx"
ENV PIPX_BIN_DIR="/usr/local/bin"

# -----------------------------------------------------------------------------
# Terraform
# Installed via HashiCorp's official binary release (not apt) so we can pin
# to an exact patch version rather than relying on repo availability.
# -----------------------------------------------------------------------------
RUN curl -fsSL \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip \
    && chmod +x /usr/local/bin/terraform \
    # Verify the binary works and capture version in build log
    && terraform version

# -----------------------------------------------------------------------------
# kubectl
# Installed via official Kubernetes binary release for exact version pinning.
# -----------------------------------------------------------------------------
RUN curl -fsSL \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# -----------------------------------------------------------------------------
# k9s
# Terminal UI for Kubernetes cluster management. Installed via GitHub release
# binary — no official apt package exists. Pinned for the same reproducibility
# reasons as all other binary tools in this image.
# -----------------------------------------------------------------------------
RUN curl -fsSL \
    "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
    -o /tmp/k9s.tar.gz \
    && tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s \
    && rm /tmp/k9s.tar.gz \
    && chmod +x /usr/local/bin/k9s \
    && k9s version

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
# Ansible
# Installed via pipx into an isolated virtualenv so its dependencies cannot
# conflict with project-level Python packages.
# PIPX_HOME/PIPX_BIN_DIR are set above so binaries land in /usr/local/bin,
# making them available to all users including the non-root 'vscode' user.
# -----------------------------------------------------------------------------
RUN pipx install  --include-deps ansible==${ANSIBLE_VERSION}

# -----------------------------------------------------------------------------
# Python toolbox packages for Ansible
# Injected into Ansible's pipx virtualenv so Ansible modules (e.g. cloud
# inventory plugins, k8s module) can import them directly.
# See dependencies/python-requirements.txt for the full list and rationale.
# -----------------------------------------------------------------------------
COPY dependencies/python-ansible-requirements.txt /tmp/python-ansible-requirements.txt
RUN pipx inject ansible \
    $(grep -v '^\s*#' /tmp/python-ansible-requirements.txt | grep -v '^\s*$' | tr '\n' ' ') \
    && rm /tmp/python-ansible-requirements.txt

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
# Azure collection Python dependencies
# The azure.azcollection ships its own requirements file inside the installed
# collection directory. These must be installed separately after the collection
# is installed — they cannot be pre-listed in python-ansible-requirements.txt
# because the file doesn't exist until the collection is installed, and the
# package versions are tightly managed by the collection itself.
# -----------------------------------------------------------------------------
RUN pipx runpip ansible install \
    -r /usr/local/pipx/venvs/ansible/lib/python${PYTHON_VERSION}/site-packages/ansible_collections/azure/azcollection/requirements.txt

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
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/microsoft.gpg > /dev/null \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] \
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
# gcloud CLI (Google Cloud SDK)
# Installed via Google's versioned archive rather than the apt repository or
# the interactive installer script. The versioned archive is the recommended
# method for automated, reproducible installations where a specific version
# must be pinned.
#
# Installed to /usr/local/google-cloud-sdk. The bin directory is added to
# PATH so gcloud, gsutil, and bq are available system-wide.
#
# Note: gcloud is an SDK with a Python runtime and component manager —
# it is not a single binary. Completions are sourced from within the SDK
# directory rather than written to /etc/bash_completion.d.
# -----------------------------------------------------------------------------
ENV CLOUDSDK_ROOT_DIR="/usr/local/google-cloud-sdk"
RUN curl -fsSL \
    "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-${GCLOUD_VERSION}-linux-x86_64.tar.gz" \
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
# Disable gcloud's interactive update prompts and telemetry
ENV CLOUDSDK_CORE_DISABLE_PROMPTS=1

# -----------------------------------------------------------------------------
# GitHub CLI (gh)
# Installed via official GitHub binary release — single static binary,
# same pattern as kubectl and k9s.
# -----------------------------------------------------------------------------
RUN curl -fsSL \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    -o /tmp/gh.tar.gz \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && mv /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz /tmp/gh_${GH_VERSION}_linux_amd64 \
    && chmod +x /usr/local/bin/gh \
    && gh version

# -----------------------------------------------------------------------------
# AWS CLI v2
# Installed via AWS's official versioned zip installer. AWS CLI v2 is not a
# single static binary — it installs to /usr/local/aws-cli and creates a
# symlink at /usr/local/bin/aws. The versioned installer URL allows exact
# version pinning consistent with the other tools in this image.
#
# AWS CLI v2 ships its own embedded Python runtime and does not interact
# with the system Python or boto3 installations.
# -----------------------------------------------------------------------------
RUN curl -fsSL \
    "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip" \
    -o /tmp/awscliv2.zip \
    && unzip /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
        --bin-dir /usr/local/bin \
        --install-dir /usr/local/aws-cli \
    && rm -rf /tmp/awscliv2.zip /tmp/aws \
    && aws --version

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

# -----------------------------------------------------------------------------
# Shell completion loading
# Ensures bash-completion is sourced for all interactive shell sessions.
# The completion scripts in /etc/bash_completion.d/ are only automatically
# loaded if the bash-completion package is explicitly sourced at shell startup.
# -----------------------------------------------------------------------------
RUN echo '\n# Load bash completions\nif [ -f /usr/share/bash-completion/bash_completion ]; then\n    . /usr/share/bash-completion/bash_completion\nfi' \
>> /etc/bash.bashrc 

# -----------------------------------------------------------------------------
# Final ownership and user setup
# The base image creates a non-root 'vscode' user. We ensure the pipx bin
# directory (set to /usr/local/bin) and completion files are accessible.
# VS Code Dev Containers will connect as this user.
# -----------------------------------------------------------------------------
USER vscode
