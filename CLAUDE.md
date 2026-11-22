# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Infrastructure-as-code for a homelab on a single Proxmox host, built in three layers that are applied in order:

1. `infrastructure/`: Terraform (Telmate `proxmox` provider) clones seven AlmaLinux VMs from the `alma-cloudinit` template.
2. `configuration/`: Ansible preps the OS, installs an RKE2 cluster (3 servers, 2 agents), PostgreSQL on the `database` node and an NFS export on the `storage` node.
3. `manifests/`: Kubernetes workloads, reconciled by Argo CD from `main` of this GitHub repo.

There is no build or test suite. Validation is done with each tool's own checks (below).

## Commands

**Terraform** must be run from `infrastructure/`, because `read_env.sh` reads `./.env` relative to the current directory. It needs `jq`, `terraform login` (state lives in Terraform Cloud, org `aadarshadhakalg`, workspace `homeserver`) and an `infrastructure/.env` with `PM_API_TOKEN_ID`, `PM_API_TOKEN_SECRET` and `SSH_KEY`.

    terraform fmt -check && terraform validate
    terraform plan
    terraform apply

**Ansible** must be run from `configuration/`. `ansible.cfg` uses `./hosts.ini` and resolves modules and collections from `../.venv/lib/python3.14/site-packages`, so it expects a Python 3.14 venv at the repo root with the full `ansible` package. The full package is needed, not `ansible-core`, because it bundles `community.postgresql`, `community.general` and `ansible.posix`.

    ansible-playbook playbooks/site.yml -e @secrets.yml --ask-vault-pass   # full build: setup -> rke2 -> postgresql -> nfs
    ansible-playbook playbooks/setup.yml                                    # one playbook (setup must precede rke2)
    ansible-playbook playbooks/postgresql.yml -e @secrets.yml --ask-vault-pass
    ansible-playbook playbooks/setup.yml --limit worker1 --check --diff     # dry run against one host
    ansible-playbook playbooks/rke2.yml --syntax-check

`secrets.yml` (gitignored, in `configuration/`) supplies `postgresql_passwords`, a map from role name to password. `rke2.yml` writes the kubeconfig to `~/.kube/homeserver.yaml`.

**Kubernetes**

    export KUBECONFIG=~/.kube/homeserver.yaml
    kubectl kustomize manifests/apps/argocd/resources   # render Argo's self-managed install
    kubectl apply --dry-run=server -f <manifest>        # validate against the live API
    kubectl -n argocd get applications

## Architecture

### Node addressing is duplicated

VM IDs and IPs (`10.0.0.100`–`106`) are defined in both `infrastructure/data.tf` (`locals.vms`) and `configuration/hosts.ini`. Keep the two in sync. Two IPs are also hard-coded in manifests:
- `10.0.0.105`: the external PostgreSQL in Harbor's values.
- `10.0.0.106:/srv/nfs`: the NFS server in `manifests/apps/storage/resources/`.

Inventory groups: `master_nodes`, `worker_nodes`, `rke2_cluster` (both), `db`, `storage_nodes`. `storage_nodes` is named that way so it doesn't collide with the host called `storage`. Kubernetes-only kernel prep targets `rke2_cluster`, so the database and storage nodes don't get it.

### How manifests reach the cluster

- App of apps. `manifests/all_apps.yaml` (`app-of-apps`) is the only manifest applied by hand. It renders every `manifests/apps/*/application.yaml` and nothing else, so adding an app means adding a folder with an `application.yaml`. Changes to those files, and under the paths they point at, take effect only after a push to `main`, because Argo reads from GitHub, not from the working tree. Changes to `all_apps.yaml` itself must be re-applied with `kubectl apply -f`.
- An app's own manifests live in `<app>/resources/`, and its Application points there, never at its own folder. A directory source pointed at the folder would also render the `application.yaml` that `app-of-apps` owns, and the two would fight over it.
- Argo CD manages itself. The `argocd` Application syncs `manifests/apps/argocd/resources/`, a kustomization of the upstream `install.yaml` (pinned version), plus an ingress and the `server.insecure` patch.
- Third-party apps come from upstream Helm repos, with values inline in the Application.
- Declare AppProjects in `manifests/apps/argocd/resources/` and list them in its `kustomization.yaml`, rather than creating them in the UI, where they escape self-management. The cluster also runs a `campinnepal` app and project that are not declared in this repo.

### Ingress and TLS

The request path is: Cloudflare edge → tunnel → `cloudflared` Deployment → `ingress-nginx-internal` Service (kube-system) → Ingress. DNS and the tunnel both route `*.aadarshadhakal.com.np` to ingress-nginx, so exposing a new app needs only an Ingress with `className: nginx`, with no DNS change. It also means an Ingress is on the public internet as soon as Argo syncs it, so any access control must be in place before the push.

Cloudflare terminates TLS. There is no cert-manager, Ingress TLS is disabled, and apps serve plain HTTP inside the cluster (Argo `server.insecure`, Harbor `expose.tls.enabled: false`). Serving TLS inside the cluster as well causes redirect loops.

RKE2 runs ingress-nginx in **kube-system**. A NetworkPolicy that admits ingress traffic must select that namespace. Charts that default to an `ingress-nginx` namespace drop all traffic while every pod still reports healthy.

Cloudflare's free plan caps request bodies at 100 MB and proxies only HTTP and WebSockets.

### Storage and data services

- `nfs` is the only StorageClass and the default (nfs-subdir-external-provisioner on `storage:/srv/nfs`). It supports ReadWriteMany but doesn't enforce requested sizes. `archiveOnDelete` keeps the data when a PVC is deleted.
- Avoid fsync-heavy persistence over NFS. The shared Redis runs with no RDB or AOF. FalkorDB is the exception: its data is the point, so it keeps RDB snapshots on NFS (`--save 60 1`, one file write and a rename), still without AOF.
- FalkorDB (`manifests/apps/knowledgeG/`, app and namespace `falkordb`) is the Claude Code knowledge graph. `falkor.aadarshadhakal.com.np` serves the MCP server at `/mcp` and the web console at everything else.
  - The MCP server and console keep sessions in the pod, so both stay at one replica with `Recreate`.
  - The console connects to any host typed into its login form. Keep its egress NetworkPolicy, and never give it the database password, because auto-connect would sign every visitor in.
  - The MCP server doesn't log to stdout. Debug it with `kubectl describe pod`, not `kubectl logs`.
- Shared PostgreSQL runs on the `database` VM, not in the cluster. To add an app database:
  - add an entry to `postgresql_databases` in `postgresql.yml`;
  - add its password to `secrets.yml`;
  - re-run the playbook. Only roles whose passwords are supplied are touched, and each role may reach only its own database from `10.0.0.0/24` (canal SNATs pod traffic to the node IP).
- The shared Redis in the `redis` namespace (password auth) currently has no consumers: its NetworkPolicy admits only a namespace that no longer exists, so a new consumer must be added there. Harbor uses a chart-managed instance. Harbor forces DB index 0 and builds a `redis://:password@` URL, whose empty username Redis 8 rejects.

### Secrets

The repo is public. Kubernetes Secrets are created out of band with `kubectl create secret`. The manifests reference `cloudflared-token`, `redis-auth`, `harbor-db`, `harbor-admin`, `falkordb-auth` (key `password`) and `falkordb-mcp` (key `api-key`; an empty value turns MCP auth off). Setup steps for the tunnel, including its Secret, are in `manifests/apps/cloudflared/README.md`.

## Conventions

- Pin every version: image tags, chart versions, the Argo install URL, and `cloudflared --no-autoupdate`. Upgrades are deliberate commits.
- Comments explain *why*: the constraint or failure mode behind a setting. New config should follow suit.
- Commit messages have an imperative, sentence-case subject. The body explains the reasoning, especially the failure that motivated the change.
