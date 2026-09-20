# Requirements Document — Reusable CI/CD Pipeline Framework

**Author:** M.L.
**Status:** Locked for build
**Audience:** Implementation (Claude Code)

---

## 1. Purpose

Build a reusable, multi-environment CI/CD framework that demonstrates enterprise-grade
release engineering practices — build automation, containerization discipline, environment
promotion, approval gates, rollback, and least-privilege IAM — using GitHub Actions, Docker,
and AWS.

This is a **portfolio / capability demonstration project**, not a production system serving
real traffic. Scope decisions below reflect that: some capabilities (notably container
runtime deployment) are deliberately deferred rather than built, with clean seams left for a
follow-on phase.

## 2. Goals

- Produce a **reusable pipeline** that other repositories consume by reference
  (`uses: <your-username>/aws-cicd-framework/...@<version>`), not by copy-paste.
- Support **Python and Node.js** consumers via a single reusable workflow, parameterized
  by a `language` input.
- Demonstrate **environment promotion** (dev → stage → prod) where the same built artifact is
  promoted forward, never rebuilt per environment.
- Demonstrate **approval-gated releases** using native GitHub Environments.
- Demonstrate **rollback** as a first-class, manually-triggered operation with a real audit
  trail.
- Demonstrate **containerization discipline** (multi-stage builds, non-root users, pinned
  base images, linting) as the primary technical evidence of maturity — since the demo
  workloads themselves carry no functional weight.
- Demonstrate **least-privilege IAM** via GitHub OIDC federation, scoped per environment.
- Leave a **clean, documented seam** for future ECS deployment, without building ECS now.

## 3. Non-Goals (explicitly out of scope for this phase)

- No running container workload. No ECS cluster, service, task registration, or any
  `ecs:*` IAM permissions.
- No load balancer, VPC design, or networking beyond what OIDC/IAM/S3/ECR require.
- No functional application logic in the demo repos. They exist solely to exercise the
  pipeline's build/containerize/push mechanics.
- No automatic/health-triggered rollback. Rollback is manual-dispatch only, since there is
  no running service to health-check.
- No multi-cloud support. AWS only for this phase.
- No cost-optimization tuning, autoscaling, or capacity planning — not applicable without a
  running service.

## 4. Functional Requirements

### 4.1 Build

- FR-1: The framework MUST support building Python and Node.js projects via a single
  reusable workflow (`deploy.yml`), parameterized by a `language` input (`python` |
  `node`). *Amended from the original no-branching requirement — see §8.*
- FR-2: Each language's build job MUST run a fast-fail lint/syntax check before any Docker
  build is attempted.
- FR-3: Build steps MUST be parameterized (build/test commands, working directory) via
  `workflow_call` inputs.

### 4.2 Containerization

- FR-4: The framework MUST build a Docker image via a **multi-stage Dockerfile** for each
  consumer.
- FR-5: Images MUST be published to per-application storage, tagged with the Git SHA.
  *Currently: saved via `docker save` and uploaded to a dedicated S3 bucket, since the
  account's shared GitHub Actions role does not yet have ECR permissions. ECR (a
  per-application repository, floating `<env>-latest` tag optional) remains the target
  once that access exists — see §8.*
- FR-6: Every consumer Dockerfile MUST be validated by a **Dockerfile linter (hadolint)**
  as a required pipeline step. A failing lint MUST fail the pipeline.
- FR-7: Consumer Dockerfiles MUST satisfy the containerization discipline checklist in
  §4.2.1 as the linting bar.

#### 4.2.1 Dockerfile discipline checklist (linted / reviewed against)

- Multi-stage build; final stage excludes build tooling and dev dependencies.
- Non-root `USER` directive in the final stage, explicit UID.
- Minimal, pinned base image (e.g. `python:3.x-slim`, `node:20-alpine`) — no `:latest`.
- Dependency versions pinned/locked (`requirements.txt` pins or lockfile; `package-lock.json`
  committed).
- `.dockerignore` present and correct (excludes VCS metadata, local env files, dependency
  caches).
- No secrets or credentials baked into any layer.
- Dependency install ordered before source copy (cache efficiency).
- `HEALTHCHECK` directive present (forward-compatible with orchestration, even pre-runtime).
- OCI image labels present (`org.opencontainers.image.source`, version, etc.).

### 4.3 Deployment artifact and state (S3)

- FR-8: The framework MUST **render** (template) an ECS-compatible task definition JSON as
  a build output. It MUST NOT call `ecs:RegisterTaskDefinition` or any other ECS API in this
  phase.
- FR-9: The framework MUST write a **deployment manifest** to S3 for every build, containing
  at minimum: Git SHA, image storage location and digest (ECR URI, or the S3 key
  currently used per FR-5), pointer to the rendered task definition, build timestamp,
  triggering workflow run ID, triggering actor, and a reference to the previous manifest
  for that environment. *Not yet built — see §8.*
- FR-10: S3 is the system of record for deployment history and rollback state. It is **not**
  a deploy target in this phase (no running workload consumes it).

### 4.4 Environment promotion

- FR-11: The framework MUST support promoting an existing artifact (image + manifest + task
  definition) from one environment to the next (dev → stage → prod) **without rebuilding**.
- FR-12: Promotion MUST be implemented as a distinct reusable workflow (`promote.yml`),
  separate from the build/containerize pipeline.
- FR-13: Promotion to `stage` and `prod` MUST require GitHub Environment approval gates
  (required reviewers). Promotion/deploy to `dev` MUST NOT require approval.

### 4.5 Rollback

- FR-14: The framework MUST support rollback as a distinct, **manually-triggered**
  (`workflow_dispatch`) reusable workflow (`rollback.yml`).
- FR-15: Rollback MUST read a prior manifest from S3 rollback history and re-point the
  target environment's "current" manifest to it.
- FR-16: Rollback MUST be recorded as an event in the deployment audit trail (CloudWatch and
  S3 history), indistinguishable in traceability from a forward deployment.

### 4.6 Observability

- FR-17: Every deploy, promote, and rollback event MUST emit a CloudWatch record (custom
  metric and/or log entry) tagged with environment, application name, and event type.
- FR-18: CloudWatch log groups MUST be scoped per environment.

### 4.7 Identity and access

- FR-19: All AWS authentication MUST use GitHub OIDC federation. No long-lived AWS access
  keys anywhere in the framework or consumer repos.
- FR-20: Each workflow run MUST only be able to assume an AWS role while executing under
  a specific GitHub Environment (i.e., the OIDC trust condition matches on
  `...:environment:<env>`, not merely on repository). *Amended: this phase uses one
  pre-existing shared IAM role (not created by this repo) rather than one role created
  per environment — its trust policy holds a `sub` entry per repo+environment. See §8.*
- FR-21: IAM permissions MUST be scoped by resource ARN to the specific S3 bucket/prefix
  and CloudWatch log group the pipeline actually uses. *Amended: with a single shared
  role serving all environments (see FR-20), scoping is currently per-bucket rather than
  per-environment-prefix. Per-environment resource isolation is deferred until per-environment
  roles are possible — see §8.*
- FR-22: ECR permissions, if in use, MAY be shared across environments at the
  per-application repository level (the image is the same artifact promoted across
  environments; only the manifest pointer changes per environment). *Not currently
  applicable — see FR-5.*
- FR-23: No IAM role in this phase may hold `ecs:*` or `iam:PassRole` permissions. These are
  explicitly deferred to the future ECS phase (see §7).

### 4.8 Configuration

- FR-24: Values that vary **per invocation** (app name, environment name, region, S3 bucket,
  target SHA for rollback) MUST be passed as `workflow_call` `inputs`.
- FR-25: Values that vary **per environment but not per run** (IAM role ARN, CloudWatch log
  group name) MUST be sourced from GitHub Environment-scoped `vars`/`secrets`, not hardcoded
  or passed as plain inputs.

### 4.9 Versioning and consumption

- FR-26: The framework MUST be consumed by reference (`uses:`), never copied into consumer
  repositories.
- FR-27: The framework MUST be versioned using SemVer tags, with a floating major-version
  tag (e.g. `v1`) maintained to point at the latest compatible patch/minor release.

## 5. Repositories

| Repo | Purpose | Visibility |
|---|---|---|
| `aws-cicd-framework` | Reusable workflows, composite actions, IaC for supporting AWS resources | Public |
| `aws-cicd-demo-python-app` | Minimal Python containerization fixture consuming the framework | Public |
| `aws-cicd-demo-node-app` | Minimal Node.js containerization fixture consuming the framework | Public |

**Grouping (no GitHub org used):** all three repos share the `aws-cicd-` name prefix for
discoverability/sorting, and carry a shared GitHub Topic (`aws-cicd-framework`) so they
can be browsed as a set without requiring an organization. `aws-cicd-framework`'s README
cross-links both consumer repos as the canonical entry point into the relationship between
them.

**Naming decoupling:** GitHub repo names (above) are distinct from AWS/manifest `app-name`
values, which remain the short logical names `python-app` and `node-app`
throughout this document, DESIGN.md, and all IaC/IAM resources. See DESIGN.md §5 for the
explicit rationale.

Demo repos contain **no functional application logic**. They exist to give the build and
containerization steps a real, minimal artifact to operate on (one real dependency each, a
no-op entrypoint, a Dockerfile meeting the §4.2.1 checklist). They do not bind a port, serve
traffic, or need to run to be considered complete.

## 6. Acceptance Criteria

- A push to `dev` in either demo repo triggers build → test (unit tests + hadolint) →
  containerize → save image to S3 (see FR-5) → render task definition → write manifest to
  S3 → CloudWatch event, with no manual approval required. *The render-task-definition,
  write-manifest, and CloudWatch steps are not yet built — see §8.*
- A manually dispatched promotion from `dev` to `stage`, and from `stage` to `prod`, succeeds only
  after the corresponding GitHub Environment's required reviewer approves, and results in the
  **same image digest** being referenced in the promoted manifest (provable by comparing
  digests across environment manifests).
- A manually dispatched rollback on any environment restores a prior manifest and is
  recorded as a distinct, auditable event.
- Attempting to assume the `prod` OIDC role from a workflow run not executing under the
  `prod` GitHub Environment fails.
- Attempting to write to another environment's S3 prefix using a given environment's role
  fails (provable via a deliberate negative test).
- A Dockerfile violating the discipline checklist (e.g. running as root, using `:latest`)
  fails the pipeline at the hadolint step.
- No `ecs:*` permission exists in any IAM policy in this phase.

## 7. Deferred / Future Phase (explicitly out of scope now)

This is intentional sequencing, not an unfinished project. The manifest and rendered task
definition are structured so this phase can be added without redesigning the framework:

- ECS cluster, service, and networking (VPC/subnets/security groups, optionally an ALB)
  provisioning.
- A `deploy-ecs-service` composite action: registers the rendered task definition
  (`ecs:RegisterTaskDefinition`) and updates the target service (`ecs:UpdateService`).
- Addition of scoped `ecs:*` and narrowly-scoped `iam:PassRole` (limited to the task
  execution role ARN) permissions to the relevant environment IAM roles at that time.
- Health-check-driven automatic rollback, once a real running service exists to check.

## 8. Amendments to the Locked Spec (Current Build)

This account turned out to have tighter permissions than assumed when this spec was
locked: no ability to create IAM roles or an OIDC provider, and no ECR access. Rather
than block on that, the following amendments were made mid-build. All are reversible —
none change the manifest schema or the eventual ECS seam described in §7.

- **Single reusable workflow, not two (FR-1).** `deploy.yml` handles both languages via a
  `language` input instead of separate `pipeline-python.yml`/`pipeline-node.yml` files.
  Chosen for minimalism; revisit only if the two languages' steps diverge enough to
  justify a split.
- **Images stored in S3, not ECR, for now (FR-5, FR-9, FR-22).** The account's shared
  GitHub Actions role has no ECR permissions. Images are `docker save`'d, gzipped, and
  uploaded to a dedicated S3 bucket (`infra/s3.tf`) instead of pushed to a registry.
  Swapping this for an ECR push later is a contained change to one step in `deploy.yml`.
- **One shared IAM role, not one per environment (FR-20, FR-21).** This account already
  has a shared GitHub Actions OIDC role used by other projects; this repo does not create
  its own IAM roles or OIDC provider (no permissions to do so). The shared role's trust
  policy holds a `sub` condition entry per repo+environment (immutable subject claims:
  `repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<env>`), which preserves FR-20's
  actual security property — a workflow run still can't assume the role outside its
  declared GitHub Environment — even though the role itself isn't environment-exclusive.
  Per-environment resource isolation (FR-21) is correspondingly looser: permissions are
  scoped to specific buckets, not to an environment-specific prefix within them, since one
  role now serves all three environments.
- **No Terraform for IAM/OIDC (§10 as originally written).** `infra/iam-roles.tf` and
  `infra/oidc-provider.tf` were removed; the shared role's trust and permissions policies
  are managed directly in AWS, outside this repo. `infra/s3.tf` (the artifact bucket) is
  the only AWS resource this repo currently provisions.

None of this changes what's still deferred per §7 — ECS, `promote.yml`, `rollback.yml`,
CloudWatch recording, and manifest/task-definition rendering remain unbuilt, independent
of these amendments.
