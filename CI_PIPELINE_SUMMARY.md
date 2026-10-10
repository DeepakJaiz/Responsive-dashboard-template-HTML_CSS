# CI Pipeline Walkthrough

This pipeline builds, scans, and deploys a static nginx site to a single EC2 instance via AWS SSM, with staging, gated production, and automatic rollback.

## Prerequisites

**Runtime & tooling**
- GitHub Actions `ubuntu-latest` runners
- Docker + Buildx (runner-provided)
- Trivy (installed in-pipeline via apt) and Gitleaks v8.18.4 (downloaded in-pipeline)
- `jq`, `curl`, AWS CLI (runner-provided)

**Docker image**
- Base image: `nginx:alpine`
- Exposed port: **80** (mapped to host port 80)
- System packages in image: `curl`
- Entrypoint: `nginx -g 'daemon off;'`, serving from `/usr/share/nginx/html`

**Exposed ports**
- Host `80` → container `80` (`HOST_PORT`/`CONTAINER_PORT` env vars)

**Required secrets**
- `GITHUB_TOKEN` (automatic; used for GHCR login, `packages: write`)
- `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC (`id-token: write`)
- `GHCR_USER`, `GHCR_TOKEN` — GHCR pull credentials on the EC2 instance
- `EC2_INSTANCE_ID` — target instance for SSM commands
- `DEPLOYMENT_NAME` — used in SSM command comments

**Environment / config**
- `REGISTRY=ghcr.io`, `IMAGE_TAG=latest`, `AWS_REGION=us-east-1`
- `PUBLIC_ENDPOINT=http://54.198.44.198:80` (hardcoded public IP)
- GitHub `production` environment must exist with required reviewers
- EC2 instance must have SSM agent, Docker (auto-installed if missing), and network access to GHCR

## Pipeline stages

1. **validate** — Lint and type-check. Currently no-ops (no linter/type checker in repo).
2. **test** — Unit/integration tests and coverage. Currently no-ops. Uploads `reports/**` and `dist/**` as `ci-artifacts`.
3. **security** — Installs Trivy + Gitleaks, then runs three gates that fail on HIGH/CRITICAL: filesystem dependency scan, secret scan, and repo code scan.
4. **build** (needs validate/test/security; push & manual-dispatch only) — Builds the image, tags it `latest` and with the commit SHA, scans it with Trivy (fails on HIGH/CRITICAL), preserves the old `latest` as `previous` (rollback target), and pushes to GHCR.
5. **staging-deploy** — Assumes the AWS deploy role via OIDC, then sends a shell script to the EC2 instance over SSM: pulls the image, runs a candidate container (`app-staging-new`), health-checks it, then swaps it in as `app-staging`. Waits up to 5 minutes for the SSM command result.
6. **staging-health-check** — Curls `/health` (with retries), `/`, and `/plans.html` against the public endpoint.
7. **production-deploy** — Same SSM blue-green pattern against the `production` environment, which **requires manual approval**. Runs `app-new`, health-checks, then replaces `app`.
8. **production-health-check** — Same smoke tests against production.
9. **rollback** (runs only if production deploy/health-check fails) — Redeploys the `previous` image tag via SSM.
10. **post-deploy cleanup** — Prunes dangling images on the instance after a successful production deploy.

## How stages connect

PRs run only validate → test → security (fast feedback). Pushes to `main` (or manual dispatch) continue through build → staging → approval gate → production. Artifacts are uploaded at test, build, and both health-check stages. Concurrency grouping cancels in-progress runs for the same ref, so only the latest commit deploys.

## Known issues to fix

- The health-check `if` condition in staging/production deploy scripts contains a docker-install command string instead of comparing `$STAGING_OK`/`$NEW_OK` — the gate is broken.
- In-container health probes target port **8080**, but the container listens on **80**.
- Staging and production share one EC2 instance; consider separating them.
- Lint/test/coverage are placeholders — add real tooling.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
