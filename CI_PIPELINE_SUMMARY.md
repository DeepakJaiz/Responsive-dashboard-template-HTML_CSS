# CI Pipeline Walkthrough

This pipeline builds a static website served by nginx, scans it, publishes it to AWS ECR, and deploys it to an EC2 instance behind an Application Load Balancer — with a manual production approval gate and a rollback path.

**Triggers:** push/PR to `main`, or manual `workflow_dispatch` (with optional `rollback_tag`). Concurrent runs on the same ref are cancelled.

## Prerequisites

Before CI can run, the project/environment needs:

- **Runtime:** None locally — static HTML/CSS; CI runs on `ubuntu-latest` GitHub runners with Docker + AWS CLI + `jq` available.
- **Docker base image:** `nginx:alpine` (pulled from Docker Hub during build).
- **System packages in image:** `curl` (installed in the Dockerfile for health checks).
- **Exposed ports:** Container exposes **80**; host mappings used during deploy are **8080** (live) and **8081** (canary).
- **Required GitHub secrets:**
  - `ECR_REGISTRY` — ECR registry endpoint
  - `AWS_DEPLOY_ROLE_ARN` — IAM role assumed via OIDC (`id-token: write`)
  - `AWS_REGION` — deployment region (e.g. `us-east-1`)
  - `EC2_INSTANCE_ID` — target EC2 instance for SSM Run Command
  - `DEPLOYMENT_NAME` — label used in SSM command comments
- **AWS infrastructure:** ECR repository, EC2 instance with SSM agent, ALB (`app-alb-e4178a-...elb.amazonaws.com`) and target group (`app-tg-b8b234`) registered in `us-east-1`.
- **GitHub environment:** A protected `production` environment with required reviewers (approval gate).
- **Build args:** None.

## Job-by-job

### 1. Validate
Runs on PRs and pushes. Currently a no-op — no lint/type-check tooling is declared for this static HTML/CSS project.

### 2. Test
Also a no-op (no test framework present). Uploads `test-results/`, `coverage/`, `reports/`, and `dist/` as artifacts if they exist.

### 3. Security
Runs in parallel with validate/test:
- **Trivy** filesystem scan — fails on HIGH/CRITICAL findings.
- **Gitleaks** — detects committed secrets.
- **CodeQL** — JavaScript static analysis, results to Security tab.

### 4. Build
*(push / dispatch only; needs validate + test + security)*
Builds `app:<sha>` with Docker Buildx, scans the image with Trivy (fails on HIGH/CRITICAL), and uploads the image tarball as a 1-day artifact.

### 5. Publish
Assumes the AWS deploy role via OIDC, logs into ECR, and pushes the image as both `:<sha>` and `:latest`.

### 6. Staging deploy
Deploys to the EC2 instance via **SSM Run Command** using a blue/green pattern:
1. Pull the new image, run it as `app-new` on port 8081.
2. Poll `localhost:8081` up to 60s; dump logs and fail if unhealthy.
3. Stop/remove old `app`, then start the new image as `app` on port 8080.

Then verifies: no unhealthy ALB targets, health endpoint reachable via ALB, and smoke tests on `/` and `/index.html`.

### 7. Production approval
Manual gate — a required reviewer must approve the protected `production` environment before production deploy proceeds.

### 8. Production deploy
Identical SSM blue/green deploy + ALB health verification and smoke tests as staging, against the production target group.

### 9. Rollback
Manual only (`workflow_dispatch` after a failed production deploy). Requires a `rollback_tag` input; redeploys that ECR tag using the same blue/green swap and health checks.

### 10. Post-deploy summary
Always runs after production deploy; writes a deployment record (image, instance, ALB URL, timestamp) to the job summary.

## How stages connect

```
validate ─┐
test ─────┼─→ build → publish → staging-deploy → production-approval → production-deploy → post-deploy
security ─┘                                                            └→ rollback (manual, on failure)
```

PRs run only validate/test/security. Full build → deploy chain runs on push to `main` or manual dispatch, gated by human approval before production.

## Known gaps
- No linting, type-checking, or tests — validation stages pass trivially.
- Health checks and smoke tests use plain HTTP.
- Brief downtime during the container swap (stop old → start new is not atomic).

### Required GitHub Secrets

Auto-provisioned by this pipeline:
- [x] `AWS_DEPLOY_ROLE_ARN`
- [x] `AWS_REGION`
- [x] `DEPLOYMENT_NAME`
- [x] `EC2_INSTANCE_ID`
- [x] `GHCR_TOKEN`
- [x] `GHCR_USER`

Unresolved / failed to provision (add manually in GitHub before merging):
- [ ] `ECR_REGISTRY`
