# nonprod-k3s-manifests

GitOps source of truth for the five-node AWS non-production K3s cluster.
It mirrors the production platform closely enough to exercise the real FCI
services, but it is isolated from the production domain and edge network.

## Environment contract

- One K3s control-plane node (`master-1`) and four workers (`worker-1` through
  `worker-4`). Cluster traffic must use the instances' private VPC addresses;
  the public address is only for operator access.
- No Cloudflare resources, tunnel token, namespace, or workload.
- No MetalLB and no Kubernetes `LoadBalancer` Services. K3s ServiceLB remains
  disabled by Ansible.
- Browser-facing names live under the real `*.nonprod.freecloudinitiative.com`
  subdomain, managed in `terraform-cloudflare-infra` as plain (non-proxied) A
  records pointing at the master's public IP. No hosts-file edits needed on
  operator machines.
- A K3s `coredns-custom` fragment resolves those same names to Traefik only
  inside the cluster, so Argo CD and Grafana can complete OIDC exchanges
  without hairpinning back out through the node's own public IP.
- Traefik runs on the control-plane node and binds host ports 80 and 443.
- Browser-facing TLS certificates are issued by Let's Encrypt
  (`letsencrypt-nonprod` ClusterIssuer, HTTP-01) - no CA import needed on
  operator machines. Internal-only TLS (Postgres, Valkey, Authentik's own
  cert) still uses the cluster-local `ca-cluster-issuer`.
- Authentik uses local login and enrollment only; social OAuth sources are
  disabled because they require a publicly registered callback hostname.
- The frontend deliberately runs with `appEnv: prod` so nonprod exercises the
  real backend and authentication paths rather than development mocks.
- Argo CD Applications read only this repository:
  `https://github.com/freecloudinitiative/nonprod-k3s-manifests.git`.
- Secrets remain in the nonprod OpenBao instance and are materialized by
  External Secrets. Never reuse the production OpenBao data or commit secrets.

## Browser access

No per-workstation setup is required. `*.nonprod.freecloudinitiative.com` is
real, publicly-resolvable DNS (managed in `terraform-cloudflare-infra`,
`nonprod.tf`), and every browser-facing host gets a Let's Encrypt certificate
that's trusted out of the box.

The endpoints are:

- Frontend: `https://nonprod.freecloudinitiative.com`
- Authentik: `https://auth.nonprod.freecloudinitiative.com`
- Argo CD: `https://argocd.nonprod.freecloudinitiative.com`
- Grafana: `https://grafana.nonprod.freecloudinitiative.com`
- Prometheus: `https://prometheus.nonprod.freecloudinitiative.com`
- Alloy: `https://alloy.nonprod.freecloudinitiative.com`
- Longhorn: `https://longhorn.nonprod.freecloudinitiative.com`
- Traefik: `https://traefik.nonprod.freecloudinitiative.com`

### After a full cluster teardown/rebuild

The master node has no Elastic IP, so a fresh cluster gets a new public IP.
Update `nonprod_ingress_ip` in `terraform-cloudflare-infra` to the new IP and
apply - that's the only step. DNS and Let's Encrypt certs pick up the change
on their own; no operator machine needs anything redone.

## Bootstrap handoff to Ansible

Do not run the current production inventory unchanged. The installation run
must use a nonprod inventory with one master and four workers, distinct
nonprod secrets, and these repository overrides:

```yaml
argocd_gitops_repo_url: https://github.com/freecloudinitiative/nonprod-k3s-manifests.git
argocd_gitops_repo_revision: main
openbao_helm_values_url: https://raw.githubusercontent.com/freecloudinitiative/nonprod-k3s-manifests/main/infrastructure/openbao/values.yaml
```

At least `worker-1` must belong to the Ansible `high_memory` group because
Argo CD and Authentik select `node-tier=high-memory`. Put the remaining workers
in suitable memory-tier groups for their EC2 sizes. The master join address
must be its private `10.x` address reachable across the peered VPCs, not its
public address.

The current `ansible-automation` OpenBao seeding role still treats the
production tunnel token as mandatory. Before the actual nonprod install, that
role must gain an environment switch that omits the tunnel secret and its
assertion. Do not satisfy the assertion with a fake token.

## What Argo CD installs

Infrastructure includes namespaces, the nonprod CoreDNS fragment, cert-manager,
Longhorn, External Secrets, CloudNativePG, Kyverno, PostgreSQL, Valkey, Garage,
Authentik, Traefik, Argo CD self-configuration, and the
Grafana/Prometheus/Loki/Tempo/Alloy/OpenTelemetry observability stack. OpenBao
itself is installed by Ansible before Argo CD.

Applications include the frontend plus api-gateway, iam-service,
compute-service, database-service, storage-service, and terminal-gateway. Image
tags are pinned in each `applications/*/app.yaml` file.

## Storage and scheduling

- Longhorn creates disks only on nodes carrying a `node-tier` label and keeps
  two replicas per volume.
- Garage runs three replicas and uses `longhorn-local`; Garage provides its own
  data replication.
- Platform PostgreSQL currently runs one CNPG instance on `local-path`, matching
  the source production manifests.
- The control-plane node remains tainted. Traefik explicitly tolerates that
  taint; general workloads run on workers.

## Validation

Install Helm, yamllint, kubeconform, and the Helm unittest plugin, then run:

```bash
make validate
```

`make environment-check` also guards the nonprod boundary: it rejects the
production GitOps URL, ACME issuer references, `LoadBalancer` Services, and
Cloudflare or MetalLB manifests.

The copied release Applications currently pin immutable release tags, as the
production source does, rather than registry digests. `make check-digests` is
therefore a separate hardening audit and will stay red until the image build
pipeline publishes and promotes digest values.

## Post-install verification

Before calling the environment healthy:

```bash
kubectl get nodes -o wide
kubectl -n argocd get applications.argoproj.io
kubectl get pods -A
kubectl get certificates -A
kubectl get externalsecrets -A
./scripts/garage-bootstrap.sh
```

Expect all five nodes `Ready`, every Argo CD Application `Synced/Healthy`, all
ExternalSecrets ready, browser certificates ready, and `storage-service` ready
after the idempotent Garage bootstrap completes.

See [CHARTS.md](CHARTS.md) for chart layout and local validation conventions.
