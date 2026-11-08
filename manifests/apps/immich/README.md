# Immich

Self-hosted photo and video library, deployed from the upstream Helm chart
(`immich/immich`, pinned in `application.yaml`).

    manifests/apps/immich/application.yaml   two Argo Applications: resources, then the release
    manifests/apps/immich/resources/         Postgres + the library PVC, owned outside the release

The chart deliberately ships **no database** and **will not create the library
volume**, so both live in `resources/`. Keeping them out of the release means a
`helm` re-template, a chart bump, or an accidental delete of the Application
cannot take the photos or the database with it.

## Setup

1. Create the database password. Both keys hold the same value - Postgres reads
   one, Immich reads the other. Do not commit it:

       kubectl create namespace immich
       PW=$(openssl rand -base64 24 | tr -d '/+=')
       kubectl -n immich create secret generic immich-db \
         --from-literal=POSTGRES_PASSWORD="$PW" \
         --from-literal=DB_PASSWORD="$PW"

2. Register the Applications with Argo:

       kubectl apply -f manifests/apps/immich/application.yaml

   Or, now that the Secret exists, drop `immich/*` from the `exclude` in
   `manifests/all_apps.yaml` and let app-of-apps register them on push.

   `immich-resources` brings up Postgres and the library claim;
   `immich` syncs the chart. The server crash-loops until Postgres finishes
   `initdb` - a minute or two on the first sync - and then recovers on its own.

3. Add a CNAME for `immich.aadarshadhakal.com.np` to
   `<tunnel-id>.cfargotunnel.com`. The wildcard tunnel route already points at
   ingress-nginx, so cloudflared itself needs no change.

4. Open the host and create the admin account. Immich's first user is whoever
   registers first, so do this before handing the URL out.

## Notes

- **Vector extension**: smart search needs VectorChord, which the shared
  PostgreSQL on `10.0.0.105` does not carry. Immich therefore runs its own
  instance from upstream's `ghcr.io/immich-app/postgres` image. Read the Immich
  release notes before bumping that tag - a vector extension major means a
  reindex of every embedding.
- **Postgres on NFS**: not ideal, but it is the only storage class here. The
  export is hard-mounted with `no_root_squash`, and this database holds metadata
  and embeddings that can be rebuilt from the library, so the risk is bounded.
  If it ever becomes the bottleneck, the move is a local volume on a worker.
- **Upload size**: Cloudflare's free plan caps request bodies at 100 MB and the
  mobile app uploads each asset in one request, so large videos fail over the
  public hostname however permissive the ingress annotations are. Upload those
  from the LAN or over WARP.
- **Machine learning**: CPU inference, with the model cache on a PVC so the CLIP
  and face-recognition models download once rather than on every restart. The
  first smart-search job after a fresh install is slow; that is the download.
- **Valkey**: chart-managed and unauthenticated inside the namespace, rather
  than the shared Redis, which is password-protected and firewalled to Beema.
  It holds job queues only and uses an `emptyDir`, so a restart re-queues work
  instead of fsyncing over NFS.
