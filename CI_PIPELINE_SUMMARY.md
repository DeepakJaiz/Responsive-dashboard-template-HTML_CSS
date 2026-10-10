# CI/CD Pipeline Walkthrough

This pipeline runs on pushes and PRs to `main` (plus manual `workflow_dispatch`). Concurrent runs on the same branch are cancelled in favor of the newest. PRs only run the security job; the full build → publish → deploy chain runs on pushes to `main`.

## Job-by-Job

### 1. Security Scans (`security`)
Runs on every push and PR. Installs Trivy and gitleaks, then:
- **Trivy filesystem scan** — fails on HIGH/CRITICAL vulnerabilities in the repo.
- **gitleaks** — detects committed secrets (redacted output, fails the job).
- **CodeQL** — static analysis for JavaScript.

All scan steps are skipped when running locally via `act` (`ACT != 'true'` guard).

### 2. Build and Scan Image (`build`)
Only on push/manual dispatch, after security passes:
- Normalizes the repo name to lowercase for GHCR.
- Builds `./Dockerfile` with Buildx using GitHub Actions cache (`type=gha`), tagging `ghcr.io/<repo>:<sha>` and `:latest` (not pushed yet).
- **Smoke test**: runs the container locally on port 8080 and curls `/`.
- **Trivy image scan** — fails on HIGH/CRITICAL CVEs in the built image.
- Saves the image tarball and build reports as artifacts (1-day retention).

### 3. Publish Image to GHCR (`publish`)
Downloads the image artifact, loads it, and pushes both `:sha` and `:latest` tags to `ghcr.io` using `GITHUB_TOKEN`.

### 4. Deploy Staging (`deploy-staging`, environment: `staging`)
Assumes an AWS IAM role via OIDC (`AWS_DEPLOY_ROLE_ARN`), then sends an SSM `AWS-RunShellScript` command to the target EC2 instance that:
- Installs Docker if missing, logs into GHCR (using `GHCR_USER`/`GHCR_TOKEN` secrets).
- Tags the currently running image as `:previous` (rollback safety net) and pushes it.
- Pulls `:latest`, starts `app-new` on port 80, curls it, then swaps container names (`app-new` → `app`).

Followed by SSM-based health check (`/`) and smoke test (`/` and `/index.html`), each polling SSM command status.

### 5. Deploy Production (`deploy-production`, environment: `production`)
Identical deploy + health + smoke flow against the production EC2 instance. Runs only after staging succeeds.

### 6. Rollback (`rollback`)
Runs only if production deployment **fails**. Redeploys the `:previous` image tag via SSM to restore the last known-good container.

### 7. Post Deploy Cleanup (`post-deploy`)
Prunes dangling Docker images on the host via SSM. ⚠️ Note: this job's status-check loop contains a corrupted condition (Docker-install script text embedded in the shell test) — it should be fixed before relying on it.

## Prerequisites

Before CI can run successfully, the project/environment needs:

- **Runtime**: Docker (built with Buildx on `ubuntu-latest` runners); app serves via **nginx** (`nginx:alpine` base image, `CMD ["nginx", "-g", "daemon off;"]`).
- **Base image**: `nginx:alpine` (pulled from Docker Hub at build time).
- **System packages in image**: `curl` (installed in the Dockerfile).
- **Ports**: container exposes **80**; mapped to host port **80** (`HOST_PORT=80`, `CONTAINER_PORT=80`). Local smoke test uses host port 8080.
- **Workdir/content**: static site content served from `/usr/share/nginx/html`.
- **GitHub secrets**:
  - `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC for SSM deploys.
  - `EC2_INSTANCE_ID` — target instance for staging/production SSM commands.
  - `GHCR_USER` / `GHCR_TOKEN` — GHCR credentials used on the EC2 host.
  - `DEPLOYMENT_NAME` — used in SSM command comments.
- **AWS setup**: `us-east-1` region; EC2 instances must have the SSM agent running and IAM permissions allowing the deploy role to `ssm:SendCommand`/`ssm:GetCommandInvocation`; GHCR pull access from the host.
- **GitHub environments**: `staging` and `production` must exist (add required reviewers on `production` for a manual gate).
- **Permissions**: workflow needs `packages:write` (GHCR push), `id-token:write` (OIDC), `contents:read`.
- **Local testing**: `act` users — cloud/SSM steps are skipped via the `ACT` env guard; security scans also skip under `act`.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
