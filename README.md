# dice-devops-finalproject-client

[![CI/CD - client](https://github.com/hammuneer/dice-devops-finalproject-client/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/hammuneer/dice-devops-finalproject-client/actions/workflows/ci-cd.yml)

Client half of a DevOps capstone project. A Python client, packaged as a Docker image, connects to the
file server, receives a 1 KB file plus its SHA-256 checksum, saves it to `/clientdata` and verifies the
file's integrity. The project covers the whole workflow around it: containers, infrastructure as code
on **Google Cloud (GCP)**, monitoring with Grafana, and a CI/CD pipeline that deploys to the VM through
a self-hosted GitHub runner.

| Component | Repository |
|---|---|
| Server | https://github.com/hammuneer/dice-devops-finalproject-server |
| Client (this repo) | https://github.com/hammuneer/dice-devops-finalproject-client |
| Docker images | [hammuneer/dice-devops-finalproject-server](https://hub.docker.com/r/hammuneer/dice-devops-finalproject-server), [hammuneer/dice-devops-finalproject-client](https://hub.docker.com/r/hammuneer/dice-devops-finalproject-client) |

> The original brief targets AWS EC2. This implementation uses the GCP equivalents:
> EC2 → Compute Engine, t2.micro → e2-micro, VPC/subnets → custom-mode VPC + subnet,
> security groups → VPC firewall rules.

---

## Table of contents

1. [Architecture](#1-architecture)
2. [Repository layout](#2-repository-layout)
3. [How the application works](#3-how-the-application-works)
4. [Prerequisites](#4-prerequisites)
5. [Run locally with Docker Compose](#5-run-locally-with-docker-compose)
6. [Create the infrastructure with Terraform (GCP)](#6-create-the-infrastructure-with-terraform-gcp)
7. [Monitoring stack (Grafana on port 3020)](#7-monitoring-stack-grafana-on-port-3020)
8. [CI/CD pipeline](#8-cicd-pipeline)
9. [Day-to-day usage](#9-day-to-day-usage)
10. [Cost control](#10-cost-control)
11. [Troubleshooting](#11-troubleshooting)
12. [Tear down](#12-tear-down)

---

## 1. Architecture

```
                 GitHub: dice-devops-finalproject-server / -client
                        │ git push (main)
                        ▼
        ┌───────── GitHub Actions ────────┐
        │ build + e2e test (GitHub-hosted)│──push──▶ Docker Hub (public images)
        │ deploy           (self-hosted)  │                │ pull
        │ notify           (GitHub-hosted)│──▶ Slack       │
        └───────────────┬─────────────────┘                │
                        │                                  │
  GCP project ── VPC "devops-vpc" ── subnet 10.10.1.0/24 (us-central1)
  ┌─────────────────────────────────────┐   ┌─────────────────────────────────────┐
  │ server-vm  10.10.1.10   e2-micro    │   │ client-vm  10.10.1.20   e2-micro    │
  │  • GitHub runner (label server-vm)  │   │  • GitHub runner (label client-vm)  │
  │  • file-server  :5000  ◀────────────┼───┼── file-client (every 60 s)          │
  │    volume servervol → /serverdata   │TCP│    volume clientvol → /clientdata   │
  │  • Grafana :3020, Prometheus,       │   │  • Grafana :3020, Prometheus,       │
  │    node-exporter, cAdvisor          │   │    node-exporter, cAdvisor          │
  └─────────────────────────────────────┘   └─────────────────────────────────────┘
  Firewall: internal traffic within 10.10.1.0/24 · SSH 22 · Grafana 3020 from the internet
```

The client reaches the server over the **private** VPC network (`10.10.1.10:5000`); the server port is
not exposed to the internet.

## 2. Repository layout

```
.
├── app/client.py              # TCP client: receive, save, verify checksum
├── Dockerfile                 # python:3.12-slim, non-root user, VOLUME /clientdata
├── docker-compose.yml         # service "client", named volume "clientvol"
├── .env.example               # SERVER_HOST / SERVER_PORT / FETCH_INTERVAL_SECONDS
├── monitoring/                # Prometheus + Grafana + node-exporter + cAdvisor
│   ├── docker-compose.yml
│   ├── prometheus/prometheus.yml
│   └── grafana/{provisioning,dashboards}/
├── terraform/                 # client VM (uses the network created by the server repo)
│   ├── versions.tf  variables.tf  client_vm.tf  outputs.tf
│   ├── terraform.tfvars.example
│   └── scripts/startup.sh     # VM bootstrap: swap + Docker + Compose
├── scripts/setup-runner.sh    # registers the VM as a self-hosted GitHub runner
└── .github/workflows/ci-cd.yml
```

## 3. How the application works

1. Connect to `SERVER_HOST:SERVER_PORT` (retries up to 10 times while the server starts).
2. Read the one-line JSON header sent by the server:
   `{"filename": "data_...txt", "size": 1024, "checksum": "<sha256>"}`
3. Read exactly `size` bytes and save them to `/clientdata/<filename>`
   (only the base name is used, so a malicious name cannot write outside the folder).
4. Re-read the saved file, compute SHA-256 and compare it to the received checksum:

```
[client] INFO Saved /clientdata/data_20261121T205840643828Z.txt (1024 bytes). Checksum VERIFIED: 1e9ff715...b3184
```

A mismatch is logged as `Checksum MISMATCH: expected=... actual=...`.

| Variable | Default | Meaning |
|---|---|---|
| `SERVER_HOST` | `host.docker.internal` (compose) | Server address; on GCP the server's private IP |
| `SERVER_PORT` | `5000` | Server port |
| `DATA_DIR` | `/clientdata` | Where received files are saved |
| `FETCH_INTERVAL_SECONDS` | `60` | Seconds between transfers; `0` = fetch once and exit (exit code 0 = verified, 1 = failed) |

The image uses the official `python:3.12-slim` base, installs `tini` (a minimal init so `docker stop`
works cleanly) and runs as a non-root user.

## 4. Prerequisites

| Tool / account | Used for | Check |
|---|---|---|
| Docker Desktop / Engine with Compose v2 | Local build & run | `docker compose version` |
| Git + GitHub account, GitHub CLI `gh` | Repos, secrets, runner tokens | `gh auth status` |
| Google Cloud account with billing enabled | VMs | — |
| Google Cloud SDK `gcloud` | Auth, SSH | `gcloud --version` |
| Terraform ≥ 1.6 | Infrastructure as code | `terraform version` |
| Docker Hub account + access token (Read & Write) | Image registry | — |
| Slack workspace + incoming webhook | Deployment notifications | — |
| **The server stack already applied** | VPC, subnet and firewall come from the server repo | `gcloud compute networks list` shows `devops-vpc` |

Install on macOS: `brew install --cask docker google-cloud-sdk && brew install gh hashicorp/tap/terraform`.

## 5. Run locally with Docker Compose

Start the server first (server repo), then:

```bash
git clone https://github.com/hammuneer/dice-devops-finalproject-client.git
cd dice-devops-finalproject-client
cp .env.example .env                 # optional: adjust SERVER_HOST / interval
docker compose up -d --build
docker logs -f file-client           # "... Checksum VERIFIED: <sha256>"
```

Fetch a single file and exit:

```bash
docker compose run --rm -e FETCH_INTERVAL_SECONDS=0 client; echo "exit code: $?"
```

Inspect the volume: `docker run --rm -v clientvol:/d alpine ls -l /d`

> **macOS note:** port 5000 is taken by AirPlay Receiver. Run the server with `SERVER_PORT=5050`
> and the client with `SERVER_PORT=5050 docker compose up -d`.

## 6. Create the infrastructure with Terraform (GCP)

> **Order matters:** apply the **server** repo's Terraform first. It creates the VPC `devops-vpc`,
> subnet `devops-subnet` and firewall rules. This repo only looks them up (`data` sources) and
> adds the client VM.

### 6.1 One-time GCP setup

Skip if already done for the server repo.

```bash
gcloud auth login
gcloud auth application-default login          # credentials Terraform uses
gcloud config set project dice-devops-finalproject
gcloud services enable compute.googleapis.com
```

(Creating the project, linking billing and the $5 budget alert are described in the server README.)

### 6.2 Apply

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set project_id
terraform init
terraform plan                                 # 1 resource to add
terraform apply
terraform output
```

| Resource | Details |
|---|---|
| `data.google_compute_network.vpc` / `data.google_compute_subnetwork.subnet` | Existing `devops-vpc` / `devops-subnet` |
| `google_compute_instance.client` | `client-vm`, e2-micro, Debian 12, 10 GB pd-standard, fixed IP `10.10.1.20`, ephemeral public IP, tags `ssh` + `grafana` (so the shared firewall rules apply) |

The VM metadata key `server-internal-ip` (default `10.10.1.10`) tells the deploy job where the server is.
On first boot `terraform/scripts/startup.sh` adds 2 GB swap and installs Docker Engine + Compose.

Check private connectivity: `gcloud compute ssh client-vm --zone us-central1-a --command 'ping -c2 10.10.1.10'`

> **State:** `terraform.tfstate` is kept locally and is git-ignored. Do not delete it.

## 7. Monitoring stack (Grafana on port 3020)

`monitoring/docker-compose.yml` runs four containers on the client VM:

| Container | Purpose |
|---|---|
| `node-exporter` | Host metrics: CPU, memory, swap, disk, network, load |
| `cadvisor` | Per-container metrics: CPU, memory, network |
| `prometheus` | Scrapes both every 15–30 s, keeps 3 days / 500 MB |
| `grafana` | Dashboards, published on **host port 3020** |

Dashboards (folder **DevOps Capstone**), provisioned automatically:

- **Host System Metrics**: CPU / memory / swap / disk gauges, uptime, load, CPU by mode, memory,
  disk space, network traffic, disk I/O.
- **Docker Container Metrics**: running containers, CPU, memory and network per container
  (including `file-client`), and a summary table.

Access: `http://<client-vm public IP>:3020` (`terraform output grafana_url`). Anonymous read-only
viewing is enabled; admin password:

```bash
gcloud compute ssh client-vm --zone us-central1-a --command 'sudo cat /opt/monitoring/.env'
```

The pipeline syncs `monitoring/` to `/opt/monitoring` and runs `docker compose up -d` on every deploy.

## 8. CI/CD pipeline

`.github/workflows/ci-cd.yml` runs on every push to `main` (except `*.md` and `terraform/**`) and on
manual dispatch.

| Job | Runs on | Steps |
|---|---|---|
| **build** | `ubuntu-latest` (GitHub-hosted) | Python syntax check → build image → **end-to-end test**: start the published server image and the new client image on a Docker network, require `Checksum VERIFIED` → log in to Docker Hub → push `:<short-sha>` and `:latest` |
| **deploy** | `[self-hosted, client-vm]` | Checkout → copy `docker-compose.yml` to `/opt/dice-client` and **rewrite the image tag to `<short-sha>`** → write `.env` with `SERVER_HOST` read from the VM metadata → `docker compose pull` → `docker compose up -d` → wait for `Checksum VERIFIED` in the logs → **automatic rollback** on failure → sync monitoring → `docker image prune -af` |
| **notify** | `ubuntu-latest` | Posts ✅/❌ to Slack with repo, image tag, target VM, job results, commit message, author and a link to the run |

### 8.1 Secrets (Settings → Secrets and variables → Actions)

| Secret | Value |
|---|---|
| `DOCKERHUB_TOKEN` | Docker Hub personal access token (Read & Write) for user `hammuneer` |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL |

```bash
# copy the value to the clipboard first
gh secret set DOCKERHUB_TOKEN   --body "$(pbpaste)" -R hammuneer/dice-devops-finalproject-client
gh secret set SLACK_WEBHOOK_URL --body "$(pbpaste)" -R hammuneer/dice-devops-finalproject-client
```

**Slack webhook:** api.slack.com/apps → *Create New App* → *From scratch* → *Pick features* →
*Incoming Webhooks* (bot scope `incoming-webhook`) → *Install to Workspace* → choose the channel →
*Allow* → *Incoming Webhooks* page → copy the URL.

### 8.2 Register the VM as a private runner

```bash
TOKEN=$(gh api -X POST repos/hammuneer/dice-devops-finalproject-client/actions/runners/registration-token -q .token)
gcloud compute scp scripts/setup-runner.sh client-vm:/tmp/ --zone us-central1-a
gcloud compute ssh client-vm --zone us-central1-a --command \
  "sudo bash /tmp/setup-runner.sh hammuneer/dice-devops-finalproject-client $TOKEN client-vm /opt/dice-client"
```

The script creates a `runner` user (in the `docker` group, no sudo), prepares `/opt/dice-client` and
`/opt/monitoring` (with a generated Grafana password), installs the latest GitHub Actions runner with the
label **`client-vm`** and runs it as a systemd service.

Require approval for workflows from outside contributors (public repo + self-hosted runner):

```bash
gh api -X PUT repos/hammuneer/dice-devops-finalproject-client/actions/permissions/fork-pr-contributor-approval \
  -f approval_policy=all_external_contributors
```

### 8.3 First deployment

The build job's end-to-end test pulls `hammuneer/dice-devops-finalproject-server:latest`, so run the
**server pipeline first**. Then push to `main` or use *Actions → CI/CD - client → Run workflow*:

```bash
gcloud compute ssh client-vm --zone us-central1-a --command 'docker ps; docker logs --tail 3 file-client'
```

## 9. Day-to-day usage

| Task | Command |
|---|---|
| Deploy a change | `git commit -am "..." && git push` |
| Redeploy without changes | `gh workflow run ci-cd.yml` |
| Watch the pipeline | `gh run watch` |
| Client logs | `gcloud compute ssh client-vm --zone us-central1-a --command 'docker logs --tail 20 file-client'` |
| Received files | `... --command 'docker run --rm -v clientvol:/d alpine ls -l /d'` |
| Deployed version | `... --command 'grep image: /opt/dice-client/docker-compose.yml'` |
| Change fetch interval | edit `FETCH_INTERVAL_SECONDS` in the deploy step, push |

## 10. Cost control

- One e2-micro per billing account is free (us-central1/us-west1/us-east1); the second VM ≈ $0.20/day.
- Two 10 GB `pd-standard` disks fit inside the 30 GB free tier.
- Ephemeral public IPs ≈ $0.12/day each while running.
- A $5 budget alert is configured (see server README).
- Stop the VMs when not working:

```bash
gcloud compute instances stop  server-vm client-vm --zone us-central1-a
gcloud compute instances start server-vm client-vm --zone us-central1-a
```

Public IPs change after a restart; private IPs (used between the VMs) do not.

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `terraform apply`: network `devops-vpc` not found | Apply the server repo's Terraform first. |
| `Connection attempt x/10 ... failed: Connection refused` | Server container not running: check `docker ps` on server-vm. |
| `... timed out` connecting to `10.10.1.10` | Server VM stopped, or the `devops-vpc-allow-internal` firewall rule is missing. |
| Locally: client times out on port 5000 (macOS) | AirPlay Receiver owns port 5000; run both with `SERVER_PORT=5050`. |
| `Checksum MISMATCH` | Data corrupted in transit or a server bug; the deploy verification step fails and rolls back. |
| Build job: e2e test fails pulling the server image | Run the server pipeline once so `:latest` exists on Docker Hub. |
| Build job: `unauthorized` on push | Reset the `DOCKERHUB_TOKEN` secret. |
| Deploy job stays *Queued* | Runner offline: VM stopped, or `sudo systemctl status 'actions.runner.*'` on the VM. |
| Deploy: `permission denied ... docker.sock` | `sudo usermod -aG docker runner && sudo systemctl restart 'actions.runner.*'` |
| Deploy: metadata `server-internal-ip` not found | Re-apply this repo's Terraform (it sets the metadata key). |
| Grafana not reachable on :3020 | Use the current public IP; `docker logs grafana`; firewall rule `devops-vpc-allow-grafana`. |
| Panels show *No data* | `docker exec prometheus wget -qO- localhost:9090/api/v1/targets` |
| VM slow / out of memory | `free -m`, `swapon --show` (2 GB swap expected). |
| No Slack message | Check the `SLACK_WEBHOOK_URL` secret; test with `curl -X POST -H 'Content-Type: application/json' -d '{"text":"test"}' <url>` |

## 12. Tear down

Destroy this stack **before** the server stack (the server stack owns the network):

```bash
cd terraform && terraform destroy
cd ../../dice-devops-finalproject-server/terraform && terraform destroy
```
