# Cloudflare Tunnel ingress

Exposes cluster services publicly without port forwarding or dynamic DNS.
`cloudflared` dials *out* to Cloudflare's edge, so the home connection's
changing public IP is irrelevant.

    internet -> Cloudflare edge -> tunnel -> cloudflared (Deployment)
             -> ingress-nginx-internal Service -> your Ingress resources

## Setup

1. Create a **remotely-managed** tunnel in the Cloudflare dashboard
   (Zero Trust -> Networks -> Tunnels -> Create -> Cloudflared) and copy the token.

2. Create the secret. Do not commit the token:

       kubectl create namespace cloudflare
       kubectl -n cloudflare create secret generic cloudflared-token \
         --from-literal=token='<TUNNEL_TOKEN>'

3. Apply:

       kubectl apply -f manifests/cloudflared/cloudflared.yaml
       kubectl -n cloudflare rollout status deploy/cloudflared

4. In the dashboard, add **one** public hostname routing everything at the
   ingress controller, so new apps never need a cloudflared change:

   | Field    | Value                                                          |
   |----------|----------------------------------------------------------------|
   | Hostname | `*.example.com`                                                |
   | Service  | `http://ingress-nginx-internal.kube-system.svc.cluster.local:80` |

5. Expose an app with an ordinary Ingress plus a CNAME to
   `<tunnel-id>.cfargotunnel.com`.

## Notes

- **TLS**: Cloudflare terminates at the edge, so cert-manager is not needed for
  public certs. Set the zone's SSL mode to Full. Plain HTTP inside the tunnel is
  fine because the tunnel itself is encrypted.
- **Non-HTTP traffic**: the free tunnel proxies HTTP/HTTPS and WebSockets only.
  Reaching the `database` node over raw TCP needs a WARP client, not a CNAME.
- **Upgrades**: the image is pinned and `--no-autoupdate` is set, so bump the tag
  here deliberately rather than letting upstream restart ingress unattended.
