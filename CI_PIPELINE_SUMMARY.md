# CI/CD Pipeline Walkthrough

This pipeline takes a commit on `main` from lint → test → security scan → Docker build → GHCR publish → staging deploy → manual approval → production deploy, with rollback and post-deploy verification. Concurrent runs on the same ref are auto-cancelled.

## Job-by-job

1. **validate** — Detects Python (`.py`) and JS/TS (`.js`/`.ts`) files, then runs `ruff` + `mypy` (Python) and `eslint` (JS/TS). Type-check and lint failures are logged but don't fail the job.
2. **test** — Detects `requirements.txt`/`pyproject.toml` (Python) or `package.json` (Node). Runs `pytest --cov` and/or `npm test`; failures are non-blocking. Uploads `coverage.xml` and reports as artifacts.
3. **security** — Runs in parallel with `test` (both need `validate`):
   - **Trivy** filesystem scan — fails on CRITICAL/HIGH findings.
   - **Gitleaks** secret scan — blocks on leaked secrets.
   - **Semgrep** code scan — non-blocking.
4. **build** (pushes only) — Builds the Docker image (`nginx:alpine`-based static site), scans it with Trivy (blocking on CRITICAL/HIGH), and saves it as a 1-day artifact `app-image`.
5. **publish** — Loads the image artifact, logs into GHCR with `GITHUB_TOKEN`, and pushes `ghcr.io/<repo>:latest`.
6. **deploy-staging** — Assumes an AWS IAM role via OIDC, then uses SSM `send-command` to run a shell script on the target EC2 instance: installs Docker if missing, logs into GHCR, pulls the image, replaces the `app` container on port 80. Waits for command success, then health-checks and smoke-tests `http://localhost:80/` in-instance.
7. **production-approval** — A no-op job whose purpose is the GitHub `production` environment protection rule: a human must approve before proceeding.
8. **deploy-production** — Same SSM flow, but first tags the running `app` container as `app-previous` for rollback.
9. **rollback** — On production deploy failure, restarts the container from `app-previous` (or falls back to `ghcr.io/<repo>:latest`). ⚠️ Note: this job's command string appears corrupted in the YAML and should be verified.
10. **post-deploy** — Final verification: checks `docker ps` container status and curls the root endpoint via SSM.

## Prerequisites

Before CI can run successfully, the project/repo needs:

- **Runtime**: Python 3.12 (lint/test jobs); Node/npm if JS/TS sources exist.
- **Docker base image**: `nginx:alpine` (from the Dockerfile).
- **System packages in image**: `curl` (used by health checks).
- **Exposed port**: `80` (container and host; smoke tests hit `http://localhost:80/`).
- **Entrypoint**: `nginx -g "daemon off;"` serving `/usr/share/nginx/html`.
- **GitHub secrets**:
  - `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC for SSM deploys.
  - `GHCR_USER` / `GHCR_TOKEN` — GHCR credentials used on the EC2 instance to pull the image.
- **AWS infrastructure**:
  - EC2 instance `i-0834eea338b0a9db9` in `us-east-1` with SSM Agent running and the instance profile permitted by the deploy role.
  - OIDC trust configured between GitHub and AWS for `aws-actions/configure-aws-credentials`.
- **GitHub environments**: `staging` and `production` configured; `production` must have a required reviewer (this is the approval gate).
- **Permissions**: workflow needs `packages: write` (GHCR push) and `id-token: write` (OIDC).
- **Runner tools**: `jq` (available on `ubuntu-latest`), Docker/Buildx.

## How stages connect

`validate` → (`test` ∥ `security`) → `build` → `publish` → `deploy-staging` → `production-approval` → `deploy-production` → (`rollback` on failure ∥ `post-deploy` on success). Build/publish/deploy only run on pushes to `main`; PRs get validate/test/security only.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
