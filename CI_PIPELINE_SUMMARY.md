# CI/CD Pipeline Walkthrough

This pipeline takes a push to `main` through validation → build → deploy → verification, with automatic rollback if deployment fails.

## Prerequisites
- **Runtime:** Python 3.12 (declared in workflow env; app content served by nginx)
- **Base image:** `nginx:alpine`
- **System packages in image:** `curl` (used by in-container health checks)
- **Exposed port:** container port `80`, mapped to host port `80` on EC2
- **Entrypoint:** `nginx -g 'daemon off;'` (foreground, required for Docker)
- **Required secrets:**
  - `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC for SSM deploy
  - `EC2_INSTANCE_ID` — target instance for SSM commands
  - `GHCR_USER` / `GHCR_TOKEN` — GHCR pull credentials on the host (falls back to `GITHUB_TOKEN`)
  - `DEPLOYMENT_NAME` — optional container name (defaults to `app`)
- **AWS OIDC:** repo must be trusted by the IAM role (`id-token: write` permission)
- **EC2 host:** SSM agent running, Docker installed (auto-installed if missing), port 80 open
- **GHCR:** `packages: write` permission for publishing

## Job-by-Job

### 1. `validate` — Validate & Security Scans
Runs on every push and PR. Checks out full history, runs **gitleaks** (secret detection) and **Trivy** twice (filesystem + dependency scans), failing on CRITICAL/HIGH findings. Gate for everything downstream.

### 2. `build` — Build, Scan & Publish
Only on push/dispatch. Builds the image tagged `latest` and `<sha>`, runs a local smoke test (container must answer on port 80 within ~30s), scans the image with Trivy, tags the prior `latest` as `previous` (rollback anchor), then pushes all tags to GHCR. Uploads `Dockerfile` and any `reports/`/`dist/` artifacts.

### 3. `deploy` — Deploy to EC2 via SSM
Assumes the AWS role via OIDC, then sends a shell script to the EC2 instance over SSM: ensures Docker is running, logs into GHCR, pulls the new image, starts it as `<app>-new`, health-checks it in place, and only then stops/removes the old container and starts the new one on port 80. Polls SSM until the command succeeds or fails.

### 4. `health-check` — Staging Health Check
Polls the public URL (`http://54.198.44.198:80/`) up to 2.5 minutes, then verifies the response contains `OK`.

### 5. `post-deploy` — Post-Deploy Verification
Second SSM command confirming the container is running and the host responds on port 80.

### 6. `rollback` — Automatic Rollback
Runs only if `deploy` fails. Redeploys the `previous` image tag via SSM and verifies the host responds — restoring the last known-good version.

## Flow
```
validate → build → deploy → health-check → post-deploy
                      ↓ (on failure)
                  rollback
```
PRs only run `validate`; deployment happens only on merge to `main` or manual dispatch. Concurrency is per-branch, so a new push cancels an in-flight run.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
