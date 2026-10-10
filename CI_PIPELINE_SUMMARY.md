# CI/CD Pipeline Walkthrough

This pipeline takes the `app-slzj` app from code to a running container on an AWS EC2 instance, with security gates, a manual production approval, and automatic rollback.

## Prerequisites

Before CI can run, the project and environment must provide:

- **Runtime / base image:** Docker image based on `nginx:alpine`; app served by nginx (`CMD ["nginx", "-g", "daemon off;"]`), static content in `/usr/share/nginx/html`.
- **System packages in image:** `curl` (used by in-container health checks).
- **Exposed ports:** Container listens on **port 80**; mapped to host port **80** on the EC2 instance.
- **CI runners:** `ubuntu-latest` GitHub-hosted runners with Docker (Buildx, gitleaks/Trivy via Docker).
- **Required GitHub secrets:**
  - `GITHUB_TOKEN` (implicit) — GHCR push/pull
  - `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC for SSM deployment
  - `GHCR_USER` / `GHCR_TOKEN` — GHCR credentials used **on the EC2 instance** to pull the image
- **AWS setup:**
  - EC2 instance `i-0b8123fec53c25bc6` in `us-east-1` with SSM agent running
  - OIDC trust relationship allowing GitHub Actions to assume `AWS_DEPLOY_ROLE_ARN`
  - Docker installed on the instance (auto-installed by deploy script if missing)
- **GitHub environment:** `production` environment with required reviewer protection rules.
- **Networking:** Public access to `http://54.198.44.198:80` for health checks.
- **Build args:** None required.

## Pipeline Flow

```
security → build → deploy-staging → production-approval → deploy-production → post-deploy
                                                          ↘ (on failure) rollback
```

### 1. Security (secrets & code)
Runs on every push and PR to `main`. Uses **Gitleaks** to detect committed secrets and **CodeQL** for JavaScript static analysis. Uploads any `reports/**` / `dist/**` as artifacts. All later jobs depend on this passing.

### 2. Build, scan & publish image
Push/dispatch only. Builds the Docker image with **Buildx** using GHA layer caching, scans it with **Trivy** (fails on CRITICAL/HIGH findings), runs a local smoke test (`curl` on port 8080→80), then pushes to **GHCR** tagged `latest`. Also uploads the Dockerfile as metadata.

### 3. Deploy (staging)
Assumes the AWS deploy role via **OIDC**, then sends a shell script to the EC2 instance via **SSM Run Command**. The script: installs Docker if needed, logs into GHCR, pulls the image, starts a `app-new` container, health-checks it inside the instance, then swaps it in as `app` on port 80. The runner polls SSM status (up to ~5 min) and then verifies the public URL returns 200.

### 4. Production approval gate
A GitHub **environment protection rule** on `production` pauses the pipeline until a required reviewer approves. Nothing executes here except the wait.

### 5. Deploy (production)
First tags the currently deployed image as `previous` in GHCR (rollback point), then repeats the same SSM-based deploy and health/smoke checks. Emits a deployment status notification.

### 6. Rollback (on failure)
Triggered only if `deploy-production` fails. Redeploys the `previous` image tag to the instance via SSM and notifies of the rollback result.

### 7. Post-deploy verification
Final `curl` against `http://54.198.44.198/` to confirm the deployment is live.

## Key Operational Notes
- **Concurrency:** Runs are grouped per ref; new pushes cancel in-progress runs.
- **Local testing:** Steps guarded by `env.ACT != 'true'` are skipped when running with `act` locally.
- **Downtime:** The swap is stop-old-then-start-new on a single instance — expect a brief outage during deploys.
- **Rollback limits:** Rollback covers production deploy failures only; failures in post-deploy verification do not trigger it.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
