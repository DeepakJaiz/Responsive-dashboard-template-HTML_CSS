# CI/CD Pipeline Walkthrough

This pipeline builds a static site served by nginx, scans it, publishes it to GHCR, and deploys it to AWS EC2 (staging → manual approval → production) via SSM, with automatic rollback on failure.

## Prerequisites

**Runtime & tooling**
- Static HTML site (no build toolchain required); `index.html` must exist at repo root.
- Docker + Buildx on runners (provided by `ubuntu-latest`).
- `gitleaks` v8.18.4 (installed in-pipeline), `jq`, `curl`, AWS CLI.

**Docker image**
- Base image: `nginx:alpine`
- Exposed port: **80** (mapped to host port 80 in deploys)
- System packages in image: `curl`
- Entrypoint: `nginx -g 'daemon off;'`, workdir `/usr/share/nginx/html`

**Ports**
- Container port: 80; Host port: 80 (smoke test locally maps 8080→80)

**Required GitHub secrets**
- `EC2_INSTANCE_ID` — target EC2 instance for SSM deploys
- `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC for AWS access
- `TARGET_GROUP_ARN` — ALB target group for health verification
- `GITHUB_TOKEN` (automatic) — GHCR push access

**Required GitHub environment**
- `production` with required reviewers (manual approval gate)

**AWS setup**
- Region: `us-east-1`
- EC2 instance with SSM agent, Docker (auto-installed if missing), and permission to pull from GHCR
- OIDC trust relationship allowing the workflow role

**Build args**: none required.

## Pipeline stages

### 1. Validate
Runs on every push/PR. Confirms `index.html` exists. No type-checking (no typed source). Uploads any `reports/` or `dist/` artifacts.

### 2. Security
Runs in parallel with Validate. Full-history checkout, then:
- **gitleaks** — fails the build if secrets are committed.
- **CodeQL** — JavaScript static analysis; results go to the Security tab.

### 3. Build & Scan (push/dispatch only)
Builds the Docker image with GHA layer caching, tags it `:sha` and `:latest`, then:
- **Trivy** scans the image — fails on CRITICAL/HIGH findings.
- **Smoke test** — runs the container locally on port 8080 and curls it until responsive.
- Saves image metadata as an artifact.

### 4. Publish
After validate + security + build succeed, rebuilds (cache-hit) and pushes both tags to `ghcr.io/<repo>`.

### 5. Staging deploy
Assumes the AWS deploy role via OIDC, then sends an SSM shell command to the EC2 instance that:
- Installs Docker if missing
- Retags current `:latest` → `:previous` (rollback target)
- Stops/removes `app-staging`, runs the new image on port 80

Waits for SSM success (up to 5 min), then health-checks `/health` and smoke-tests `/` on the instance.

### 6. Production approval
Manual gate — requires approval on the `production` GitHub environment.

### 7. Production deploy
Same SSM deploy pattern as staging (container name `app`), plus:
- **ALB target group health check** — fails if any target is unhealthy
- On-instance `/health` check and `/` smoke test

### 8. Rollback (on failure)
If production deploy fails, automatically redeploys the `:previous` image via SSM.

### 9. Post-deploy verification
Re-checks ALB target health and uploads a deploy summary artifact.

## How stages connect
```
validate ─┐
security ─┼→ build → publish → staging-deploy → production-approval → production-deploy → post-deploy
          ┘                                                    │
                                                        (on failure) rollback
```
PRs only run validate + security + build. Full deploy chain runs on push to `main` or manual dispatch. Concurrency groups cancel superseded runs on the same branch.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
- [x] `TARGET_GROUP_ARN`
