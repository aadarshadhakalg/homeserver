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
    kubectl kustomize manifests/argocd                  # render Argo's self-managed install
    kubectl apply --dry-run=server -f <manifest>        # validate against the live API
    kubectl -n argocd get applications

## Architecture

### Node addressing is duplicated

VM IDs and IPs (`10.0.0.100`–`106`) are defined in both `infrastructure/data.tf` (`locals.vms`) and `configuration/hosts.ini`. Keep the two in sync. Two IPs are also hard-coded in manifests:
- `10.0.0.105`: the external PostgreSQL in Harbor's values.
- `10.0.0.106:/srv/nfs`: the NFS server in `manifests/storage/`.

Inventory groups: `master_nodes`, `worker_nodes`, `rke2_cluster` (both), `db`, `storage_nodes`. `storage_nodes` is named that way so it doesn't collide with the host called `storage`. Kubernetes-only kernel prep targets `rke2_cluster`, so the database and storage nodes don't get it.

### How manifests reach the cluster

- Argo CD manages itself. `manifests/argocd/` is a kustomization of the upstream `install.yaml` (pinned version), plus an ingress, the `server.insecure` patch and the AppProjects.
- `manifests/bootstrap/applications.yaml` was applied once by hand. It defines the `argocd`, `cloudflared`, `nfs-provisioner` and `redis` Applications, each pointing at a path in this repo on `main`. Changes under those paths take effect only after a push to `main`, because Argo reads from GitHub, not from the working tree.
- `manifests/{harbor,beema,immich}/application.yaml` are **not** referenced by any tracked Application. They are registered with `kubectl apply -f`, so editing one (for example, bumping a Beema image tag) does nothing until it is re-applied. The same goes for adding an Application to the bootstrap file.
- Third-party apps come from upstream Helm repos, with values inline in the Application. Beema's chart comes from the private `autoversehq/beema-deployments` repo, and an Alembic migration runs as a PreSync hook on every sync.
- Declare AppProjects in `manifests/argocd/` (as `project-beema.yaml` does) rather than creating them in the UI, where they escape self-management. The cluster also runs a `campinnepal` app and project that are not declared in this repo.

### Ingress and TLS

The request path is: Cloudflare edge → tunnel → `cloudflared` Deployment → `ingress-nginx-internal` Service (kube-system) → Ingress. Cloudflare routes a wildcard hostname at ingress-nginx, so exposing a new app needs only:
- an Ingress with `className: nginx`;
- a CNAME from `<name>.aadarshadhakal.com.np` to `<tunnel-id>.cfargotunnel.com`.

Cloudflare terminates TLS. There is no cert-manager, Ingress TLS is disabled, and apps serve plain HTTP inside the cluster (Argo `server.insecure`, Harbor `expose.tls.enabled: false`). Serving TLS inside the cluster as well causes redirect loops.

RKE2 runs ingress-nginx in **kube-system**. A NetworkPolicy that admits ingress traffic must select that namespace. Charts that default to an `ingress-nginx` namespace drop all traffic while every pod still reports healthy.

Cloudflare's free plan caps request bodies at 100 MB and proxies only HTTP and WebSockets.

### Storage and data services

- `nfs` is the only StorageClass and the default (nfs-subdir-external-provisioner on `storage:/srv/nfs`). It supports ReadWriteMany but doesn't enforce requested sizes. `archiveOnDelete` keeps the data when a PVC is deleted.
- Avoid fsync-heavy persistence over NFS. Redis and Valkey run with no RDB or AOF, or on `emptyDir`.
- Shared PostgreSQL runs on the `database` VM, not in the cluster. To add an app database:
  - add an entry to `postgresql_databases` in `postgresql.yml`;
  - add its password to `secrets.yml`;
  - re-run the playbook. Only roles whose passwords are supplied are touched, and each role may reach only its own database from `10.0.0.0/24` (canal SNATs pod traffic to the node IP).
- Immich is the exception. It needs VectorChord, so it runs its own Postgres from `manifests/immich/resources/`, a separate Application so that a chart change or delete can't take the data with it.
- The shared Redis in the `redis` namespace belongs to Beema (password auth, NetworkPolicy limited to the `beema` namespace). Harbor and Immich use chart-managed instances. Harbor forces DB index 0 and builds a `redis://:password@` URL, whose empty username Redis 8 rejects.

### Secrets

The repo is public. Kubernetes Secrets are created out of band with `kubectl create secret`. The manifests reference `cloudflared-token`, `redis-auth`, `harbor-db`, `harbor-admin`, `immich-db` and `beema-pull`. Per-component setup steps, including secret creation, are in that component's README (`manifests/cloudflared/README.md`, `manifests/immich/README.md`).

## Conventions

- Pin every version: image tags, chart versions, the Argo install URL, and `cloudflared --no-autoupdate`. Beema images use immutable `sha-` tags from `harbor.aadarshadhakal.com.np`. Upgrades are deliberate commits.
- Comments explain *why*: the constraint or failure mode behind a setting. New config should follow suit.
- Commit messages have an imperative, sentence-case subject. The body explains the reasoning, especially the failure that motivated the change.
