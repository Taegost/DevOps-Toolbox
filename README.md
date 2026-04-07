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
| [Ansible](https://www.ansible.com) | See [Dockerfile](./Dockerfile) | Configuration management and automation |
| [.NET SDK](https://dotnet.microsoft.com) | See [Dockerfile](./Dockerfile) | .NET development |
| [Python](https://www.python.org) | See [Dockerfile](./Dockerfile) | Scripting and development |
| [ipython](https://ipython.org) | See [dependencies/python-dev-requirements.txt](./dependencies/python-dev-requirements.txt) | Enhanced Python REPL |
| [pytest](https://pytest.org) | See [dependencies/python-dev-requirements.txt](./dependencies/python-dev-requirements.txt) | Python testing |
| [black](https://black.readthedocs.io) | See [dependencies/python-dev-requirements.txt](./dependencies/python-dev-requirements.txt) | Python code formatting |

### Ansible Collections

| Collection | Purpose |
|---|---|
| `community.general` | General-purpose modules and plugins |
| `ansible.posix` | POSIX/Linux system management |
| `kubernetes.core` | Kubernetes and Helm management |
| `amazon.aws` | AWS resource management |

### Python Packages (Ansible)

| Package | Purpose |
|---|---|
| `boto3` | AWS SDK — required by `amazon.aws` collection |
| `kubernetes` | Kubernetes client — required by `kubernetes.core` collection |
| `netaddr` | Network address manipulation — required by network filters |
| `passlib` | Password hashing — required by Ansible `user` module |

---

## Using This Image in a Project

Add a `.devcontainer/devcontainer.json` to your project repository with the
following content. VS Code will detect it automatically and offer to reopen
the project inside the container.

```json
{
  "name": "My Project",
  "image": "taegost/devops-toolbox:latest",
  "workspaceFolder": "/workspace",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "mounts": [
    "source=${localEnv:HOME}/.kube,target=/home/vscode/.kube,type=bind,readonly",
    "source=${localEnv:HOME}/.ssh,target=/home/vscode/.ssh,type=bind,readonly"
  ],
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

All tool versions are pinned as `ARG` declarations at the top of the
[Dockerfile](./Dockerfile). To update a tool:

1. Update the relevant `ARG` value in the Dockerfile
2. Update the matching entry in [`.env.example`](./.env.example)
3. Open a pull request — the pipeline will build and validate the image
4. Merge and tag a new release (ex. `v1.1.0`) to publish semver tags

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
