# Monitoring GitOps Repository

This repository is the desired state for the shared monitoring platform and its tenants.

## Repository model

```text
clusters/rke2-prod/root-application.yaml
  -> clusters/rke2-prod/applicationsets/platform-applicationset.yaml
  -> clusters/rke2-prod/applicationsets/tenant-applicationset.yaml
```

Platform applications are installed once per cluster. Tenant directories are inputs to
the tenant `ApplicationSet`; do not create tenant Applications manually in the Argo CD UI.

## First use

1. Replace `https://github.com/SamirPanday/monitoring_argocd` in the Argo CD manifests.
2. Review the platform chart versions and values under `apps/platform/`.
3. Review the example tenant under `tenants/example/`.
4. Install the root Application:

   ```sh
   kubectl apply -f clusters/rke2-prod/root-application.yaml
   ```

5. Before onboarding a real tenant, test namespace ownership, NetworkPolicies, quotas,
   service-account token behavior, and Grafana/Loki access with the example tenant.

Grafana organizations and users are intentionally not created by this initial scaffold.
Add SSO or a controlled provisioning workflow before automating user lifecycle management.

## How the directories fit together

This repository contains three different kinds of files:

1. **Kubernetes manifests**: ordinary resources such as `Namespace`,
   `NetworkPolicy`, and Argo CD custom resources.
2. **Helm chart files**: reusable templates that generate Kubernetes manifests.
3. **Helm values**: input data supplied to those templates or to an upstream chart.

```text
monitoring-argocd/
├── apps/       Shared platform chart values
├── charts/     Helm charts owned by this repository
├── clusters/   Argo CD wiring for each Kubernetes cluster
├── tenants/    One values file per tenant
├── policies/   Policies outside the tenant chart
└── README.md
```

### `apps/`

`apps/platform/` contains values for shared applications installed once per cluster:

```text
apps/platform/
├── kube-prometheus-stack/values.yaml
├── loki/values.yaml
└── alloy/values.yaml
```

These are not the charts themselves. The platform `ApplicationSet` installs the
upstream charts and passes these files as their values. For example, the Loki
Application uses the upstream Loki chart and `apps/platform/loki/values.yaml`.

### `charts/tenant/`

This is one reusable Helm chart. It contains the implementation common to every
tenant: namespaces, quotas, limit ranges, service accounts, and NetworkPolicies.
Do not copy this chart for each tenant.

#### `Chart.yaml`

`charts/tenant/Chart.yaml` is Helm metadata, not a Kubernetes object:

```yaml
apiVersion: v2       # Helm chart format, not a Kubernetes API version
name: tenant         # Chart name
type: application    # The chart renders installable Kubernetes resources
version: 0.1.0       # Version of this chart's implementation
```

Increase `version` when the chart implementation changes. It is not a Kubernetes
version, tenant version, or Grafana version.

#### `values.yaml`

`charts/tenant/values.yaml` contains default input values. It is not directly
applied to Kubernetes. A tenant-specific values file overrides these defaults.

#### `templates/`

Files in `charts/tenant/templates/` are Helm templates. They become ordinary
Kubernetes YAML after Helm renders them. For example:

```gotemplate
{{- range .Values.namespaces }}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ . }}
---
{{- end }}
```

If the input contains two namespaces, Helm emits two `Namespace` objects.

### `templates/_helpers.tpl`

`_helpers.tpl` defines reusable template functions; it does not create a
Kubernetes object. The tenant chart defines:

```gotemplate
{{- define "tenant.name" -}}
{{- required "tenant.id is required" .Values.id
    | lower | replace "_" "-" | trunc 63 | trimSuffix "-" -}}
{{- end -}}
```

Another template calls it like this:

```gotemplate
name: {{ include "tenant.name" $ }}-quota
```

For `id: Acme_Prod`, the helper produces `acme-prod`, which is then used in
resource names and labels. `required` makes rendering fail instead of silently
creating resources with an empty tenant ID.

### `tenants/`

Create one directory per tenant, not per user, Grafana organization, or namespace:

```text
tenants/
├── _template/tenant.yaml
├── example/tenant.yaml
└── acme/tenant.yaml
```

The tenant file is input data for `charts/tenant`. It may list multiple namespaces:

```yaml
id: samir
displayName: Samir's tenant
namespaces:
  - samir-production
  - samir-staging
  - customer-workloads
```

The chart then creates all three namespaces and applies the tenant's policies and
quotas to each one. The namespace names do not need to follow a naming pattern,
but each namespace should belong to only one tenant.

This does not create a Grafana organization. The current scaffold only creates
Kubernetes resources. Grafana organization and user creation remains a separate
manual operation until SSO, Grafana provisioning, an operator, or a controlled
provisioning service is added.

### `clusters/`

`clusters/rke2-prod/` is a repository label for one cluster's Argo CD configuration.
The name does not automatically identify a Kubernetes cluster. The actual target is
the `destination.server` field, currently:

```yaml
server: https://kubernetes.default.svc
```

That means the Argo CD instance applies the generated Applications to the cluster
where that Argo CD instance is running. A future cluster can have its own directory:

```text
clusters/
├── rke2-dev/
└── rke2-prod/
```

Each directory can use a different Argo CD destination server or cluster name.
Argo CD must first know/register those clusters. The directory name alone does not
register a cluster or choose a destination.

### `policies/`

Use `policies/` for policies that are not generated separately for every tenant,
such as cluster-wide admission rules or platform NetworkPolicies. Policies that
must exist in every tenant namespace belong in `charts/tenant/templates/`.

## What the Argo CD files do

### Root `Application`

`clusters/rke2-prod/root-application.yaml` is the entry point. It tells Argo CD:

```text
Watch this Git repository.
Read clusters/rke2-prod.
Apply the Argo CD resources found there.
```

You apply this one object once:

```sh
kubectl apply -f clusters/rke2-prod/root-application.yaml
```

After that, Argo CD watches Git. You push to the Git repository, not directly to
Argo CD.

### `AppProject`

`platform-project.yaml` and `tenant-project.yaml` are Argo CD permission policies.
They are not workloads and do not create namespaces.

An `AppProject` limits what an Argo CD Application may:

- read from Git;
- deploy to;
- create by resource kind.

`monitoring-platform` protects the shared platform Applications. `monitoring-tenants`
protects the generated tenant Applications. Separating them prevents a tenant
Application from automatically gaining the same permissions as the platform.

### `ApplicationSet`

An `ApplicationSet` generates Argo CD `Application` objects.

The platform ApplicationSet has a fixed list:

```text
kube-prometheus-stack
loki
alloy
```

For each item it creates one Application, installs the upstream chart, and passes
the matching file under `apps/platform/` as values.

The tenant ApplicationSet scans `tenants/*`. If it finds `tenants/samir/`, it
generates an Application named `tenant-samir`. That generated Application runs:

```text
charts/tenant
```

with:

```text
tenants/samir/tenant.yaml
```

as its values file.

The generated tenant Application's `destination.namespace: argocd` is the
namespace where the Application object is associated with Argo CD. It does not
mean tenant resources are created in the `argocd` namespace. The tenant chart
explicitly creates and targets the namespaces listed in `tenant.yaml`.

## Complete tenant onboarding flow

For a tenant called Samir:

```text
1. Create tenants/samir/tenant.yaml
2. List Samir's Kubernetes namespaces in that file
3. Open and merge a Git pull request
4. Argo CD notices the Git change
5. Tenant ApplicationSet generates tenant-samir
6. Argo CD runs the tenant Helm chart
7. Helm renders Namespace, ResourceQuota, LimitRange,
   ServiceAccount, and NetworkPolicy objects
8. Argo CD applies those objects to the cluster
9. Create/configure Samir's Grafana organization separately
10. Add Samir's users or SSO group separately
```

So there are three distinct identities:

```text
Git tenant directory  = desired Kubernetes tenant configuration
Argo CD Application    = deployment automation for that configuration
Grafana organization   = user-facing observability access boundary
```

The current chart creates the first two indirectly. It does not yet create the
third.

## Useful local commands

Render the tenant chart without changing the cluster:

```sh
helm template tenant charts/tenant \
  --values tenants/example/tenant.yaml
```

Validate the chart:

```sh
helm lint charts/tenant \
  --values tenants/example/tenant.yaml
```

The rendered output is ordinary Kubernetes YAML. Helm-specific expressions such as
`.Values`, `range`, `if`, and `include` are gone after rendering.

## Argo CD itself

Argo CD is installed into a Kubernetes cluster, normally in an `argocd` namespace.
It is not one single pod. Its main components are separate workloads:

```text
argocd-server       API and web UI
argocd-repo-server  Clones Git repositories and renders Helm/Kustomize sources
argocd-application-controller
                    Compares desired state with the cluster and syncs resources
argocd-applicationset-controller
                    Generates Applications from ApplicationSets
argocd-redis        Internal cache
```

The exact workloads depend on the Argo CD version and installation method. The
important flow is:

```text
Git → repo-server → rendered manifests
                         ↓
              application-controller → Kubernetes API
ApplicationSet controller → generated Application objects
argocd-server → UI/API
```

The root Application is not discovered automatically. Bootstrap it once:

```sh
kubectl apply -f clusters/rke2-prod/root-application.yaml
```

That creates the root `Application` custom resource. The controllers then read
its `repoURL`, `targetRevision`, and `path`.

### `repoURL`, `targetRevision`, and `path`

```yaml
source:
  repoURL: https://github.com/example/monitoring-argocd.git
  targetRevision: main
  path: clusters/rke2-prod
```

These mean:

```text
repoURL        Git repository to clone
targetRevision Git branch, tag, or commit to use
path           directory inside that Git revision
```

`targetRevision: main` means Argo CD watches the `main` branch. It selects a Git
revision; it does not select a Helm chart version.

## Multiple Kubernetes clusters

With one Argo CD installation per cluster, the simple model is:

```text
dev cluster  → its Argo CD → clusters/rke2-dev/
prod cluster → its Argo CD → clusters/rke2-prod/
```

Both installations may watch the same Git repository but different paths.

One central Argo CD can also manage multiple registered clusters. An Application
then selects a registered cluster explicitly:

```yaml
destination:
  name: rke2-prod
  namespace: monitoring
```

or by API server URL:

```yaml
destination:
  server: https://the-prod-api-server.example
  namespace: monitoring
```

The cluster must first be registered with Argo CD. A directory name such as
`rke2-prod` does not register or select a cluster by itself.

## Argo CD project whitelists

An `AppProject` is a permission boundary for Applications. It is not a search
path and does not create resources by itself.

### `sourceRepos`

```yaml
sourceRepos:
  - https://github.com/example/monitoring-argocd.git
  - https://grafana.github.io/helm-charts
```

This is an allowlist of repositories that Applications in the project may use.
It is not a list of directories for Argo CD to scan.

### `destinations`

```yaml
destinations:
  - namespace: monitoring
    server: https://kubernetes.default.svc
```

This is an allowlist of cluster and namespace destinations.

### Resource allowlists

```yaml
clusterResourceWhitelist:
  - group: ""
    kind: Namespace

namespaceResourceWhitelist:
  - group: ""
    kind: ResourceQuota
```

These control which Kubernetes resource kinds an Application may create:

```text
clusterResourceWhitelist
  cluster-scoped resources, such as Namespace, ClusterRole, and CRD

namespaceResourceWhitelist
  namespaced resources, such as Deployment, Service, ConfigMap,
  NetworkPolicy, ResourceQuota, and ServiceAccount
```

The empty group (`group: ""`) means the Kubernetes core API group. For example:

```text
group: ""                → Namespace, Service, ConfigMap
group: networking.k8s.io → NetworkPolicy
group: apps              → Deployment
```

If a generated tenant Application tries to create a kind not permitted by its
AppProject, Argo CD rejects or marks that resource as forbidden.

## How `$values` works

The platform ApplicationSet uses two sources:

```yaml
sources:
  - repoURL: https://grafana.github.io/helm-charts
    chart: loki
    targetRevision: 0.0.0
    helm:
      valueFiles:
        - $values/apps/platform/loki/values.yaml
  - repoURL: https://github.com/example/monitoring-argocd.git
    targetRevision: main
    ref: values
```

The second source is not another chart. It is the Git repository containing the
values file. `ref: values` names that source `values`, so:

```text
$values/apps/platform/loki/values.yaml
```

means:

```text
From the source named "values", read apps/platform/loki/values.yaml.
```

The complete platform flow is:

```text
upstream Loki chart
  + apps/platform/loki/values.yaml
  → rendered Loki Kubernetes resources
```

The same mechanism is used for Prometheus and Alloy.

## Chart defaults versus tenant values

The tenant ApplicationSet uses the same two-source pattern:

```yaml
sources:
  - repoURL: https://github.com/example/monitoring-argocd.git
    targetRevision: main
    path: charts/tenant
    helm:
      valueFiles:
        - $values/{{path}}/tenant.yaml
  - repoURL: https://github.com/example/monitoring-argocd.git
    targetRevision: main
    ref: values
```

For `tenants/samir/`, the generated values path is:

```text
$values/tenants/samir/tenant.yaml
```

The chart's own [values.yaml](./charts/tenant/values.yaml) is the default-values
file packaged with the chart. The tenant file overrides those defaults:

```text
charts/tenant/values.yaml
  defaults for every tenant

tenants/samir/tenant.yaml
  Samir-specific values
```

The default values file is still used. Helm merges the tenant values on top of
the defaults; when a key exists in both, the tenant-specific value wins.

## Why `_template` is excluded

The tenant generator uses:

```yaml
directories:
  - path: tenants/*
  - path: tenants/_template
    exclude: true
```

The first pattern matches every immediate directory below `tenants/`, including
`tenants/_template/`. The second entry excludes the example scaffolding so Argo
CD does not generate an unwanted `tenant-_template` Application.

You may remove the exclusion only if you move the template outside the scanned
directory. Keeping it under `tenants/` is convenient, so retaining the exclusion
is clearer and safer.

## What triggers Helm

There is no separate `helm install` trigger. When a generated Application has:

```yaml
path: charts/tenant
```

and that path contains `Chart.yaml`, Argo CD recognizes it as a Helm chart. The
repo-server effectively performs the rendering step:

```text
helm template charts/tenant -f tenants/samir/tenant.yaml
```

The application-controller compares the rendered output to the live cluster and
applies the required changes. You do not need to run `helm install` yourself.

## What happens after a tenant push

For a new `tenants/samir/tenant.yaml`:

```text
Git push to main
  ↓
Root Application sees the repository revision changed
  ↓
Tenant ApplicationSet scans tenants/*
  ↓
It generates tenant-samir (an Argo CD Application)
  ↓
tenant-samir reads charts/tenant and tenants/samir/tenant.yaml
  ↓
Argo CD renders the Helm chart
  ↓
Argo CD applies Namespace, ResourceQuota, LimitRange,
ServiceAccount, and NetworkPolicy objects to Kubernetes
```

The current tenant chart creates Kubernetes namespaces and policies. It does not
create a Grafana organization or Grafana users; those remain a separate workflow.
