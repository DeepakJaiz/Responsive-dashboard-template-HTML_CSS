# CI/CD Pipeline Walkthrough

This pipeline runs on pushes and PRs to `main` (and manually via `workflow_dispatch`). PRs run only quality gates; full deploy runs on push/dispatch.

## Pipeline stages

1. **Validate** — Lint and type-check placeholders (add `ruff`/`eslint`, `mypy`/`tsc` configs to make these real). Runs on all PRs.
2. **Test** — Unit/integration test placeholder; uploads `coverage/`, `test-results/`, `reports/`, `dist/` as artifacts regardless of outcome.
3. **Security** — Installs Trivy and gitleaks. Scans: dependency vulnerabilities, IaC misconfigurations + secrets (Trivy), committed secrets (gitleaks). All fail the build on HIGH/CRITICAL findings.
4. **Build** — After all three gates pass (push/dispatch only): builds `app:<sha>` with Docker Buildx, scans the built image with Trivy (CRITICAL/HIGH fails), saves the image as a 1-day artifact.
5. **Publish** — Downloads the image artifact, authenticates to AWS via **OIDC** (`AWS_DEPLOY_ROLE_ARN`), resolves the account's ECR repo, and pushes `:<sha>` and `:latest`.
6. **Staging deploy** — Uses SSM `SendCommand` on the staging EC2 instance to pull and run the container (`app`, port 8080, `--restart always`), waits for command success, then polls the ALB target group until healthy (up to 5 min).
7. **Staging verify** — Resolves the ALB DNS and curls the health endpoint + smoke tests with retries.
8. **Production approval** — GitHub `production` environment protection rule requires a manual approval.
9. **Production deploy** — Captures the currently running image tag (saved as a rollback artifact, 7-day retention), then deploys via SSM exactly like staging, and verifies ALB target health.
10. **Production verify** — Same health + smoke checks against the production ALB.
11. **Rollback** — If production deploy or verify fails: redeploys the previously captured image tag via SSM.
12. **Post-deploy** — Prints the production URL summary.

Concurrent runs on the same ref cancel older runs (`concurrency` with `cancel-in-progress`). Most steps are gated with `ACT != 'true'` so the pipeline can run locally with [`act`](https://github.com/nektos/act).

## Prerequisites

Before CI can run successfully, the project must provide:

### Tooling & runners
- GitHub-hosted `ubuntu-latest` runners with Docker (build, save/load), `jq`, `curl`, `aws` CLI.
- A `Dockerfile` at the repo root (present: base image `nginx:alpine`, installs `curl`, serves static content from `/usr/share/nginx/html`, exposes **port 80**).
- ⚠️ **Port mismatch**: pipeline deploys with `-p 8080:8080` but the image listens on 80. Align `APP_PORT`/Dockerfile or the health checks will fail.
- Language manifest + lint/test tooling for the placeholder Validate/Test jobs.

### AWS infrastructure
- ECR repository named `app` (auto-resolved by account ID).
- EC2 instances (staging & production) registered in SSM and as ALB targets, with an instance profile allowing ECR pulls.
- An ALB with target group.
- OIDC trust relationship between GitHub and `AWS_DEPLOY_ROLE_ARN` with permissions for ECR, SSM, ELB, and STS.

### Required GitHub secrets
| Secret | Purpose |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | OIDC role for AWS auth |
| `AWS_REGION` | AWS region (default env: `us-east-1`) |
| `EC2_INSTANCE_ID` | Target instance for SSM deploys |
| `ALB_TARGET_GROUP_ARN` | Health verification |
| `ALB_ARN` | Resolves deploy URL |

### Environment & variables
- GitHub environments: `staging` and `production` (production requires an approval protection rule).
- Env vars: `CONTAINER_NAME=app`, `APP_PORT=8080`, `IMAGE_TAG=<commit sha>`, `AWS_REGION=us-east-1`.
- Exposed port (container): **80** per Dockerfile (see mismatch note above). No build args are used.

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `ALB_ARN`
- [x] `ALB_TARGET_GROUP_ARN`
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`
