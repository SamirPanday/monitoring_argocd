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

1. Replace `REPLACE_WITH_GIT_REPOSITORY_URL` in the Argo CD manifests.
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

