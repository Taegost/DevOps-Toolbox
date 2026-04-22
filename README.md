# DevOps Toolbox

A self-contained development environment image providing consistent, versioned
DevOps tooling across any machine or IDE that supports the
[Dev Container specification](https://containers.dev).

Built and published automatically via GitHub Actions. Pull it on any machine
with Docker and VS Code — no local setup required.

---

## What's Inside

| Tool | Version | Purpose |
|---|---|---|
| [Terraform](https://www.terraform.io) | See [Dockerfile](./Dockerfile) | Infrastructure as code |
| [kubectl](https://kubernetes.io/docs/reference/kubectl/) | See [Dockerfile](./Dockerfile) | Kubernetes cluster management |
| [k9s](https://k9scli.io) | See [Dockerfile](./Dockerfile) | Kubernetes terminal UI |
| [kubeseal](https://github.com/bitnami-labs/sealed-secrets) | See [Dockerfile](./Dockerfile) | Kubernetes SealedSecrets CLI |
| [Helm](https://helm.sh) | See [Dockerfile](./Dockerfile) | Kubernetes package manager |
| [kubelogin](https://azure.github.io/kubelogin/) | See [Dockerfile](./Dockerfile) | Azure AD authentication for kubectl |
| [Kustomize](https://kustomize.io) | See [Dockerfile](./Dockerfile) | Kubernetes configuration management |
| [ArgoCD CLI](argocd.io) | See [Dockerfile](./Dockerfile) | ArgoCD CLI |
| [Stern](https://github.com/stern/stern) | See [Dockerfile](./Dockerfile) | Multi-pod log tailing |
| [Ansible](https://www.ansible.com) | See [Dockerfile](./Dockerfile) | Configuration management and automation |
| [.NET SDK](https://dotnet.microsoft.com) | See [Dockerfile](./Dockerfile) | .NET development |
| [Python](https://www.python.org) | See [Dockerfile](./Dockerfile) | Scripting and development |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/) | See [Dockerfile](./Dockerfile) | Azure resource management |
| [gcloud CLI](https://cloud.google.com/sdk/gcloud) | See [Dockerfile](./Dockerfile) | Google Cloud resource management |
| [GitHub CLI](https://cli.github.com) | See [Dockerfile](./Dockerfile) | GitHub workflow management |
| [AWS CLI](https://aws.amazon.com/cli/) | See [Dockerfile](./Dockerfile) | AWS resource management |
| [ipython](https://ipython.org) | See [dependencies/](./dependencies/) | Enhanced Python REPL |
| [pytest](https://pytest.org) | See [dependencies/](./dependencies/) | Python testing |
| [black](https://black.readthedocs.io) | See [dependencies/](./dependencies/) | Python code formatting |

### Ansible Collections

| Collection | Purpose |
|---|---|
| `community.general` | General-purpose modules and plugins |
| `ansible.posix` | POSIX/Linux system management |
| `kubernetes.core` | Kubernetes and Helm management |
| `amazon.aws` | AWS resource management |
| `azure.azcollection` | Azure resource management |

### Python Packages (Ansible)

| Package | Purpose |
|---|---|
| `boto3` | AWS SDK — required by `amazon.aws` collection |
| `kubernetes` | Kubernetes client — required by `kubernetes.core` collection |
| `netaddr` | Network address manipulation — required by network filters |
| `passlib` | Password hashing — required by Ansible `user` module |
| `google-auth` | Google authentication — required by `google.cloud.*` modules |
| `requests` | HTTP library — required by GCP inventory plugins |
| `PyGithub` | GitHub API client — required by `community.general` GitHub modules |
| `azure-*` | Azure SDK packages — required by `azure.azcollection` (installed from collection's own requirements file) |
---

## Cloud CLI Authentication

The four cloud CLIs require credentials to interact with their respective
platforms. None of these are baked into the image — credentials are always
provided at runtime via mounts or environment variables.

**AWS CLI** — mount your credentials file, or pass environment variables:
```json
"mounts": [
"source=${localEnv:HOME}/.aws,target=/home/vscode/.aws,type=bind,readonly"
]
```
Or use environment variables in `devcontainer.json`:
```json
"containerEnv": {
  "AWS_ACCESS_KEY_ID": "${localEnv:AWS_ACCESS_KEY_ID}",
  "AWS_SECRET_ACCESS_KEY": "${localEnv:AWS_SECRET_ACCESS_KEY}",
  "AWS_DEFAULT_REGION": "${localEnv:AWS_DEFAULT_REGION}"
}
```

**Azure CLI** — run `az login` interactively inside the container after it starts. The credentials are cached in `~/.azure` inside the container session.

**gcloud CLI** — run `gcloud auth login` interactively inside the container after it starts. The credentials are cached in `~/.config/gcloud` inside the container session. For service account authentication, mount your key file:
```json
"mounts": [
  "source=/path/to/sa-key.json,target=/home/vscode/sa-key.json,type=bind,readonly"
],
"containerEnv": {
  "GOOGLE_APPLICATION_CREDENTIALS": "/home/vscode/sa-key.json"
}
```

**GitHub CLI** — run `gh auth login` interactively inside the container after it starts, or mount your hosts configuration:
```json
"mounts": [
  "source=${localEnv:HOME}/.config/gh,target=/home/vscode/.config/gh,type=bind,readonly"
]
```

---

## Using This Image in a Project

Add the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension from Microsoft to VS Code.

**NOTE:** If you're running this in WSL through VS Code, you should change these settings:
```
Enable Dev › Containers: Execute In WSL
Enable Dev › Containers: Forward WSL Services if you use things like X, Wayland, or SSH Agents such as Bitwarden
```

Then, add a `.devcontainer/devcontainer.json` to your project repository with the. VS Code will detect it automatically and offer to reopen the project inside the container.

**NOTE:** This is just a quick example. For the latest, fully detailed version of the sample, please see [the devcontainer.json in source control](./.devcontainer/example/devcontainer.json)

```json
{
  "name": "My Project",
  "image": "taegost/devops-toolbox:latest",
  "workspaceFolder": "/workspace",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "remoteUser": "vscode",
  "customizations": {
    "vscode": {
      "extensions": [
        // Add project-specific extensions here
      ]
    }
  }
}
```

### Project-Specific Dependencies

The container provides the toolbox. Project-specific dependencies are
installed after the container starts using `postCreateCommand`:

**Python project:**
```json
"postCreateCommand": "pip install -r requirements.txt"
```

**Ansible project with additional collections:**
```json
"postCreateCommand": "ansible-galaxy collection install -r requirements.yml"
```

Both can be combined:
```json
"postCreateCommand": "pip install -r requirements.txt && ansible-galaxy collection install -r requirements.yml"
```

---

## Image Tags

Images are published to Docker Hub at `taegost/devops-toolbox`.

| Tag | When it's updated | Recommended use |
|---|---|---|
| `latest` | Every push to `main` and weekly scheduled rebuild | Day-to-day use, always current |
| `sha-<commit>` | Every build | Tracing a specific build back to a commit |
| `1.2.3` | When a `v1.2.3` Git tag is pushed | Pinning to a known stable version |
| `1.2` | When any `v1.2.x` Git tag is pushed | Pinning to a minor version |
| `1` | When any `v1.x.x` Git tag is pushed | Loose pinning to a major version |

### Why No Date or "Weekly" Tag?

A `weekly` tag would be a moving pointer, semantically identical to `latest`.
It would add noise to Docker Hub without adding meaning — anyone pinning to
`weekly` gets the same behavior as pinning to `latest`. The tags above cover
all real use cases:

- **Staying current**: use `latest`
- **Stability**: pin to a semver tag (`1.2.3`)
- **Traceability**: use the `sha-<commit>` tag to trace any image back to its
  exact source commit

The weekly scheduled pipeline rebuild ensures `latest` always incorporates
the most recent base image security patches, even without a code change.

---

## Updating Tool Versions

Tool versions are pinned as `ARG` declarations directly above each tool's
install block in the [Dockerfile](./Dockerfile), rather than grouped at the
top of the file. This is intentional — it ensures that changing one tool's
version only invalidates the Docker layer cache from that tool downward,
leaving unrelated tools fully cached.

1. Find the tool's `ARG` declaration in the Dockerfile — it will be
   immediately above its install block, with a comment header identifying
   the tool
2. Update the matching entry in [`.env.example`](./.env.example)
3. Open a pull request — the pipeline will build and validate the image
4. Merge and tag a new release (ex. `v1.1.0`) to publish semver tags

To find a tool's current version quickly without reading the full Dockerfile,
check [`.env.example`](./.env.example) — it mirrors all version pins and
includes links to each tool's release page.

---

## Local Builds

To build the image locally without pushing:

```bash
# Copy the example env file
cp .env.example .env

# Edit .env if you want to test different versions
# Then build:
docker build \
  $(grep -v '^#' .env | grep -v '^$' | sed 's/^/--build-arg /') \
  -t devops-toolbox:local .
```

---

## Repository Structure

```
devops-toolbox/
├── .github/
│   └── workflows/
│       └── build-and-push.yml    # CI/CD pipeline
├── .devcontainer/
│   └── devcontainer.json         # VS Code config for this repo
├── dependencies/
│   ├── ansible-requirements.yml  # Toolbox-level Ansible collections
│   ├── python-ansible-requirements.txt  # Packages injected into Ansible venv
│   └── python-dev-requirements.txt      # Python development tooling
├── Dockerfile                    # Image definition
├── .dockerignore                 # Build context exclusions
├── .env.example                  # Local build variable reference
├── .gitignore
└── README.md
```

---

## Required Secrets

The pipeline requires the following secrets configured in GitHub:

| Secret | Scope | Purpose |
|---|---|---|
| `DOCKERHUB_USERNAME` | Organisation | Docker Hub username |
| `DOCKERHUB_TOKEN` | Organisation | Docker Hub access token (not your password) |
| `DOCKERHUB_IMAGENAME` | Repository | Image name only, ex devops-toolbox |

Generate a Docker Hub access token at:
**hub.docker.com → Account Settings → Security → New Access Token**
