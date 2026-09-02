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
- No public DNS records. Browser-facing names use the reserved `.test` TLD and
  are resolved from the operator machine's hosts file.
- A K3s `coredns-custom` fragment resolves those same names to Traefik only
  inside the cluster, so Argo CD and Grafana can complete OIDC exchanges.
- Traefik runs on the control-plane node and binds host ports 80 and 443.
- Browser TLS certificates are issued by the cluster-local CA. Nothing uses
  ACME or Let's Encrypt.
- Authentik uses local login and enrollment only; social OAuth sources are
  disabled because they require a publicly registered callback hostname.
- The frontend deliberately runs with `appEnv: prod` so nonprod exercises the
  real backend and authentication paths rather than development mocks.
- Argo CD Applications read only this repository:
  `https://github.com/freecloudinitiative/nonprod-k3s-manifests.git`.
- Secrets remain in the nonprod OpenBao instance and are materialized by
  External Secrets. Never reuse the production OpenBao data or commit secrets.

## DNS-free browser access

After the cluster is installed, replace `<MASTER_PUBLIC_IP>` and add this line
to the hosts file of each operator workstation:

```text
<MASTER_PUBLIC_IP> nonprod.freecloudinitiative.test auth.nonprod.freecloudinitiative.test argocd.nonprod.freecloudinitiative.test grafana.nonprod.freecloudinitiative.test prometheus.nonprod.freecloudinitiative.test alloy.nonprod.freecloudinitiative.test longhorn.nonprod.freecloudinitiative.test traefik.nonprod.freecloudinitiative.test
```

The endpoints are then:

- Frontend: `https://nonprod.freecloudinitiative.test`
- Authentik: `https://auth.nonprod.freecloudinitiative.test`
- Argo CD: `https://argocd.nonprod.freecloudinitiative.test`
- Grafana: `https://grafana.nonprod.freecloudinitiative.test`
- Prometheus: `https://prometheus.nonprod.freecloudinitiative.test`
- Alloy: `https://alloy.nonprod.freecloudinitiative.test`
- Longhorn: `https://longhorn.nonprod.freecloudinitiative.test`
- Traefik: `https://traefik.nonprod.freecloudinitiative.test`

The names deliberately do not resolve on the public Internet. This keeps the
production DNS zone untouched while preserving the stable hostnames required
by OIDC issuers and redirect URIs.

### Trust the nonprod CA

Once cert-manager has created the CA, export it with the nonprod kubeconfig:

```bash
kubectl -n cert-manager get secret selfsigned-ca-secret \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode > nonprod-k3s-ca.crt
```

Import `nonprod-k3s-ca.crt` into the workstation/browser trust store before
testing login flows. The CA is environment-local and must not be replaced by
or imported from production.

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
