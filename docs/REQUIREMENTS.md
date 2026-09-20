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
- Demonstrate **environment promotion** (dev → stage → prod) as a branch-based SDLC:
  `dev` auto-deploys on push; `stage`/`prod` deploy on PR merge into those branches, each
  independently built and tested from that branch's own state at merge time.
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
  phase. **Built** — the `render-manifest` job templates it via shell heredoc, no
  composite action (see DESIGN.md §3).
- FR-9: The framework MUST write a **deployment manifest** to S3 for every build, containing
  at minimum: Git SHA, image storage location and digest (ECR URI, or the S3 key
  currently used per FR-5), pointer to the rendered task definition, build timestamp,
  triggering workflow run ID, triggering actor, and a reference to the previous manifest
  for that environment. **Built.** `previousManifestKey` is derived by reading the
  environment's existing `current.json` (if any) before overwriting it — see DESIGN.md §2.1.
- FR-10: S3 is the system of record for deployment history and rollback state. It is **not**
  a deploy target in this phase (no running workload consumes it). **Built** — `current.json`
  is the "state" pointer; "history" is the manifest chain (each manifest's
  `previousManifestKey`) rather than a separate `_rollback-history/` structure. See §8.

### 4.4 Environment promotion

- FR-11: The framework MUST support promoting code from one environment's branch to the
  next (dev → stage → prod) via pull request. Each environment independently builds,
  tests, containerizes, and deploys from its own branch at merge time — this is a
  deliberate pivot from the original "never rebuild" model. *Amended — see §8.*
- FR-12: ~~Promotion MUST be implemented as a distinct reusable workflow (`promote.yml`),
  separate from the build/containerize pipeline.~~ **Retired.** With each environment
  independently rebuilding from its own branch, there's no separate artifact-move step
  left to implement — the existing `deploy.yml` caller's `pull_request` trigger *is* the
  promotion mechanism. `promote.yml` has been deleted from all three repos. See §8.
- FR-13: Deploys to `stage` and `prod` (triggered by PR merge into those branches) MUST
  require GitHub Environment approval gates (required reviewers). Deploy to `dev` MUST NOT
  require approval.

### 4.5 Rollback

- FR-14: The framework MUST support rollback as a distinct, **manually-triggered**
  (`workflow_dispatch`) reusable workflow (`rollback.yml`). **Built.**
- FR-15: Rollback MUST read a prior manifest from S3 rollback history and re-point the
  target environment's "current" manifest to it. **Built** — "S3 rollback history" is the
  manifest chain (`previousManifestKey`) rather than a separate history structure; see §8.
- FR-16: Rollback MUST be recorded as an event in the deployment audit trail (CloudWatch and
  S3 history), indistinguishable in traceability from a forward deployment. **Partially
  built** — the S3 side is satisfied by `current.json`'s versioning (the bucket has S3
  versioning enabled, so every overwrite is already recoverable); the CloudWatch side
  isn't built yet (FR-17/18).

### 4.6 Observability

- FR-17: Every deploy and rollback event MUST emit a CloudWatch record (custom metric
  and/or log entry) tagged with environment, application name, and event type. *"Promote"
  is no longer a distinct event type — see §8; a deploy triggered by a `stage`/`prod`
  PR-merge is still just a `deploy` event, distinguished by its `environment` tag.*
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
  S3 → CloudWatch event, with no manual approval required. **Confirmed working** for both
  `python-app` and `node-app` through the write-manifest step; only the CloudWatch step is
  not yet built — see §8.
- A pull request merged into `stage` (or `prod`) triggers the `detect-environment` job to
  resolve the correct environment name from `github.event.pull_request.base.ref`, then
  runs the full build → test → containerize → S3-upload pipeline for that environment,
  succeeding only after the corresponding GitHub Environment's required reviewer approves.
  A pull request that's closed *without* merging MUST NOT trigger a deploy. **Confirmed
  working** for both apps, both `stage` and `prod` — real PR merges, real S3 uploads under
  each environment's own prefix.
- A manually dispatched rollback on any environment restores a prior manifest and is
  recorded as a distinct, auditable event. **Built, not yet exercised with a real run** —
  `rollback.yml` exists and validates cleanly (`actionlint`), but hasn't been triggered
  against real deployed manifests yet.
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
  are managed directly in AWS, outside this repo.
- **The S3 bucket was created manually, not via `terraform apply` (§10).** No local AWS
  CLI credentials, and CloudShell's networking setup added enough friction that a one-off
  manual creation in the console was the pragmatic call. `infra/s3.tf` stays as the
  reference spec for the bucket's intended configuration (versioning, encryption,
  public-access-block) — see DESIGN.md §10.
- **Promotion model pivoted from artifact-copy to branch-rebuild (FR-11, FR-12).**
  `promote.yml` (and its S3-to-S3 image-copy mechanism, briefly built and verified
  working dev→stage) has been deleted from all three repos. In its place: `stage`/`prod`
  are now real branches, and each demo repo's `deploy.yml` caller triggers on
  `pull_request: closed` into `stage`/`prod` (in addition to `push` on `dev`), with a
  `detect-environment` job resolving the target environment from the trigger context —
  same shape as a standard branch-per-environment SDLC. This was a deliberate choice to
  match a specific reference pattern, made with full awareness that it trades away the
  "same artifact, never rebuilt" guarantee FR-11 originally specified and that
  `promote.yml` had already proven working. Both models are legitimate; this project now
  uses the rebuild-per-branch one.
- **Manifest's `image.digest` is a SHA-256 checksum, not a registry digest (FR-9).**
  Computed via `sha256sum` on the saved tarball in the `deploy` job, passed to
  `render-manifest` as a job output. Serves the same "prove these are the same bytes"
  purpose as an ECR-assigned digest, just computed rather than registry-issued. Swap back
  once ECR access exists.
- **`render-manifest` declares its own `environment:` (FR-9, FR-13).** Needed to resolve
  the same environment-scoped `AWS_DEPLOY_ROLE_ARN`/`S3_BUCKET` vars `deploy` already
  uses. This may cost a second required-reviewer approval click on `stage`/`prod` beyond
  the one `deploy` already needs, since GitHub doesn't always treat two jobs referencing
  the same environment in one run as a single gate. Accepted as a minor UX cost rather
  than threading the ARN through job outputs, which would work around FR-25's intent
  (values that vary per environment should come from environment-scoped vars, not be
  passed between jobs as plain strings).
- **`rollback.yml` reads the manifest chain, not a separate `_rollback-history/` structure
  (FR-15).** The original plan maintained a bounded, per-environment list of prior
  manifests in a dedicated S3 prefix. Since `render-manifest` already writes each
  manifest's `previousManifestKey`, that chain already *is* a usable history — just a
  linked list instead of a flat directory listing. Building a second, parallel history
  mechanism would have been pure duplication for no added capability. Trade-off: walking
  further back than "the previous deploy" means following the chain manually (or passing
  an explicit `target-sha`) rather than browsing a bounded list; acceptable, since
  `target-sha` already covers that case.

None of this changes what's still deferred per §7 — ECS and CloudWatch recording remain
unbuilt, independent of these amendments.
