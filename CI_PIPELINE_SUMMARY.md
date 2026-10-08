# CI/CD Pipeline Walkthrough

This pipeline runs on every push and PR to `main`, plus manual dispatch. It scans for secrets, runs tests, builds and scans a Docker image, pushes it to AWS ECR, and deploys to ECS staging then production — with automatic rollback on failure.

## Prerequisites
- **Runtime:** Python 3.12 (installed via `setup-python`, pip-cached)
- **Base image:** `nginx:alpine` (Dockerfile)
- **System packages in image:** `curl`
- **Exposed port:** `80` (nginx serves from `/usr/share/nginx/html`)
- **Entrypoint:** `nginx -g "daemon off;"`
- **Python deps:** `requirements.txt` (optional), plus `pytest` and `pytest-cov`
- **AWS:** region `us-east-1`; OIDC role via `AWS_DEPLOY_ROLE_ARN` (requires `id-token: write`)
- **Required secrets:**
  - `AWS_DEPLOY_ROLE_ARN` — IAM role for AWS auth
  - `ECR_REPOSITORY_URL` — target ECR repo
  - `ECS_CLUSTER_NAME`, `ECS_SERVICE_NAME`, `ECS_TASK_FAMILY`, `CONTAINER_NAME` — ECS deploy targets
  - `GITHUB_TOKEN` (automatic) — for Gitleaks
- **Environments:** `staging` and `production` must exist in repo settings
- **jq** available on runners (used in task-definition download)

## Job-by-Job

### 1. Security Scan (`security-scan`)
Runs Gitleaks over full git history to catch committed secrets. Fails the pipeline if leaks are found. Runs in parallel with tests.

### 2. Tests (`test`)
Sets up Python 3.12 with pip caching, installs dependencies with retry logic (3 attempts), then runs `pytest` with JUnit XML output and coverage. Uploads test results, coverage, and report artifacts. Skipped locally when `ACT=true` (act compatibility).

### 3. Build, Push and Scan Image (`build-and-scan`)
Runs only on push/dispatch (not PRs), after tests and security scan pass.
- Authenticates to AWS via OIDC, logs into ECR
- Builds the image locally with Buildx using GitHub Actions cache
- Runs **Trivy** — fails on CRITICAL/HIGH vulnerabilities
- Pushes the image tagged with the commit SHA and `latest`

### 4. Deploy to Staging (`deploy-staging`)
Fetches the current ECS task definition, swaps in the new image, and deploys to the staging cluster/service, waiting for stability.

### 5. Deploy to Production (`deploy-production`)
Same ECS deploy flow against production, gated by the `production` environment (configure required reviewers here for a manual approval gate). Runs only after staging succeeds.

### 6. Rollback Jobs (`rollback-staging` / `rollback-production`)
Trigger only when the corresponding deploy fails. They force a new deployment of the existing task definition family (the last stable revision) and wait for the service to become stable.

## How It Connects

```
security-scan ─┐
               ├─► build-and-scan ─► deploy-staging ─► deploy-production
      test ────┘            │              │                │
                            ▼              ▼                ▼
                    (Trivy blocks)   rollback-staging  rollback-production
```

- PRs run only scan + tests (no build/deploy).
- Pushes to `main` run the full pipeline through production.
- Concurrency grouping cancels superseded runs on the same branch.

## Tips
- Add required reviewers to the `production` environment if you want a manual gate before prod deploys.
- Keep `requirements.txt` pinned for reproducible builds.
- Trivy failures: fix or add CVE suppressions before merging.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `CONTAINER_NAME`
- [x] `ECS_CLUSTER_NAME`
- [x] `ECS_SERVICE_NAME`
- [x] `ECS_TASK_FAMILY`

Unresolved / failed to provision (add manually in GitHub before merging):
- [ ] `ECR_REPOSITORY_URL`
