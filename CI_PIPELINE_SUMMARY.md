# CI Pipeline Walkthrough

This pipeline builds, scans, and deploys a static website (nginx container) to AWS EC2 via SSM, with staging and gated production environments and automatic rollback.

**Trigger:** push or PR to `main`, plus manual `workflow_dispatch`. Concurrent runs on the same ref cancel in-progress runs.

## Prerequisites

- **Runtime:** Docker (nginx:alpine-based image); GitHub Actions `ubuntu-latest` runners.
- **Base image:** `nginx:alpine` (pulled from Docker Hub during build).
- **System packages in image:** `curl` (used for health checks).
- **Exposed ports:** container listens on **80**; mapped to host port **8080** (`HOST_PORT`).
- **Entrypoint:** `nginx -g "daemon off;"`, serving from `/usr/share/nginx/html`.
- **Registry:** GHCR (`ghcr.io`) — image published as `ghcr.io/<repo>:<sha>` and `:latest`.
- **AWS:** region `us-east-1`; OIDC deploy role; EC2 instance managed via SSM (`AWS-RunShellScript`); ALB target group `app-tg-b8b234`.
- **Required secrets:**
  - `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC for deploys
  - `EC2_INSTANCE_ID` — target instance for SSM commands
  - `DEPLOYMENT_NAME` — used in SSM command comments
  - `GHCR_TOKEN` / `GHCR_USER` — GHCR pull credentials on the EC2 host
  - `GITHUB_TOKEN` (automatic) — GHCR push, CodeQL SARIF upload
- **Environment:** `production` GitHub environment (provides approval gate for the production deploy).
- **Build args:** none.

## Job-by-job

### 1. `security` — Secret scan + CodeQL
- Checks out with `fetch-depth: 2` and greps **newly added files** for AWS access keys, private keys, and GitHub PATs.
- Runs CodeQL for JavaScript and uploads results to the Security tab.
- Runs on every push and PR. All later jobs depend on it passing.

### 2. `build` — Build, scan, publish (push/dispatch only)
- Normalizes the repo name to lowercase (GHCR requires lowercase image paths).
- Builds the image with two tags: `:<sha>` (immutable) and `:latest`.
- **Smoke test:** runs the container locally, `curl --fail http://localhost:8080/`, then removes it.
- **Trivy scan:** fails the job on CRITICAL or HIGH vulnerabilities.
- Pushes both tags to GHCR; uploads `reports/**` and `dist/**` as artifacts.

### 3. `deploy-staging` — Deploy `:latest` to EC2
- Assumes the AWS deploy role via OIDC (no long-lived AWS keys).
- Sends an SSM command to the EC2 instance: docker login to GHCR, pull `:latest`, stop/remove the old `app` container, run the new one with `--restart unless-stopped` on port 8080→80.
- Waits for the SSM command, then verifies:
  - Container health: `curl --fail http://localhost:8080/` on the instance.
  - ALB target health: every target in the target group must be `healthy`.

### 4. `deploy-production` — Deploy `:<sha>` (approval required)
- Runs in the `production` environment, so it **pauses for manual approval**.
- Same SSM deploy flow, but pulls the **pinned commit SHA tag** for reproducibility.
- Same health + ALB verification as staging.

### 5. `rollback` — Automatic recovery
- Triggers only if production deploy fails.
- Redeploys `:latest` (the tag staging just verified as healthy) via SSM, then prints diagnostics and fails the workflow so the failure is visible.

## How the stages connect

```
security ──► build ──► deploy-staging ──► [approval] ──► deploy-production
                │              │                            │
                │              │ (verifies :latest          │ (on failure)
                │              │  as known-good)            ▼
                └─ GHCR ◄──────┴──────────────────────── rollback (→ :latest)
```

- PRs only run `security` — builds/deploys happen on push to `main` or manual dispatch.
- `build` publishes both tags; staging validates `:latest`, production deploys the exact `:<sha>`.
- The rollback strategy relies on staging having verified `:latest` immediately before production.

## Operational notes
- **Downtime:** deploys are stop-then-run on a single container — expect a brief outage window.
- **Secret scan scope:** only the last commit's added files are scanned.
- **Debugging failed SSM steps:** the workflow prints command status, stdout, and stderr on failure.
- **Artifacts:** each deploy job uploads `reports/**` and `dist/**` if present (warns if none found).

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
