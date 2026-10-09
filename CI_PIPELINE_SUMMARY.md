# CI/CD Pipeline Walkthrough

This pipeline builds a static website Docker image, scans it, deploys it to an EC2 instance behind an ALB (staging → manual approval → production), verifies health, and rolls back automatically on failure.

## Prerequisites

- **Runtime:** Docker on the EC2 target instance; SSM Agent running; `jq` on the GitHub runner (preinstalled on ubuntu-latest).
- **Base image:** `nginx:alpine` (serves static content from `/usr/share/nginx/html`).
- **System packages (in image):** `curl` (used by health checks).
- **Exposed ports:** Container listens on **80**; smoke tests map host **8080 → 80**; production runs on host port **80**.
- **Required secrets:**
  - `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC for AWS API calls.
  - `GHCR_USER` / `GHCR_TOKEN` — credentials for the EC2 instance to pull from GHCR.
  - `GITHUB_TOKEN` — automatic; used for GHCR push (requires `packages: write`).
- **AWS resources (hardcoded in env):**
  - EC2 instance: `i-0a12c0b27ab3c6a08` (us-east-1)
  - Target group: `app-tg-b8b234` behind an ALB
- **Permissions:** `id-token: write` (OIDC), `packages: write` (GHCR), `security-events: write` (CodeQL).
- **Build args:** None.

## Job-by-Job

### 1. Validate
Runs on every PR/push to `main`. Verifies `index.html` exists. Type-checking is a no-op since this is a plain HTML/CSS site. Uploads any `reports/` or `dist/` artifacts.

### 2. Security
Runs in parallel with Validate. Two scans:
- **Secret scan:** greps the working tree for patterns like `api_key=...`, `password=...` with 16+ char values. Fails the job on a hit.
- **CodeQL:** analyzes JavaScript with results uploaded to the Security tab.

### 3. Build, scan and publish
Only on push/`workflow_dispatch` (not PRs). Needs Validate + Security to pass.
- Builds the image with Buildx (GHA cache enabled) and pushes to `ghcr.io/<owner>/static-website` tagged with both the commit SHA and `latest`.
- **Trivy** scans the image; the job fails on CRITICAL or HIGH vulnerabilities.
- **Smoke test:** runs the container locally on port 8080 and curls `/health`.

### 4. Staging deploy
Assumes the AWS deploy role via OIDC, then sends an SSM `RunShellScript` command to the EC2 instance. The remote script:
1. Logs into GHCR (password via stdin).
2. Pulls the SHA-tagged image.
3. Runs a canary container on port 8080 and polls until healthy (up to 60s).
4. Stops/removes the canary and the old `app` container.
5. Starts the new container as `app` on port 80 with `--restart always`.
6. Verifies with a local curl.

The workflow polls SSM command status (up to 150s) and fails with the remote stderr on error.

### 5. Staging verify
Resolves the ALB DNS name from the target group ARN, waits for the site to respond, then smoke tests `/`, `/plans.html`, `/projects.html`, `/courses.html`, and `/health` over HTTP.

### 6. Production approval
Manual gate — the repo owner must approve (minimum 1 approval) before production deploy.

### 7. Production deploy
Identical SSM deploy flow as staging, against the same EC2 instance (staging and production share the host; the "environment" distinction is the approval gate).

### 8. Production verify
Same ALB health + smoke test suite as staging, against production.

### 9. Promote stable
Pulls the SHA-tagged image and retags/pushes it as `:stable` — this becomes the rollback target.

### 10. Post-deploy verification
Confirms the ALB target group reports the instance as `healthy`.

### 11. Rollback (on failure)
If production deploy or verify fails, redeploys the `:stable` image via SSM (stop `app`, start fresh from `:stable`, verify locally).

## How It Connects

```
validate ─┐
          ├─→ build → staging-deploy → staging-verify
security ─┘                                  │
                                    production-approval
                                             │
                                  production-deploy → production-verify
                                             │                    │
                                  promote-stable ──┴── post-deploy
                                             
                    (on failure) rollback ← production-deploy/verify
```

- **PRs** run only validate + security (fast feedback).
- **Merges to main / manual runs** trigger the full build → staging → approval → production → promote chain.
- **Concurrency:** one run per branch/ref; new runs cancel in-progress ones.
- **All jobs** have a 30-minute timeout and upload `reports/**` / `dist/**` artifacts when present.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
