# Design Document — Reusable CI/CD Pipeline Framework

**Author:** M.L.
**Status:** Locked for build
**Companion to:** REQUIREMENTS.md
**Audience:** Implementation (Claude Code)

---

## 1. Architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│ aws-cicd-framework (public repo)                                    │
│                                                                     │
│  .github/workflows/          .github/actions/                       │
│    pipeline-python.yml         build-python/                        │
│    pipeline-node.yml           build-node/                          │
│    promote.yml                 lint-dockerfile/                     │
│    rollback.yml                docker-build-push-ecr/               │
│                                 render-task-definition/             │
│  infra/ (Terraform)            write-manifest-s3/                   │
│    oidc-provider.tf            promote-artifact/                    │
│    iam-roles.tf                rollback-from-manifest/              │
│    s3.tf                       record-deployment-cloudwatch/        │
│    ecr.tf                      assume-role-oidc/                    │
│    cloudwatch.tf                                                    │
└─────────────────────────────────────────────────────────────────────┘
                 ▲ uses: aws-cicd-framework/.github/workflows/...@v1
                 │
         ┌───────┴────────┐
         │                  │
┌────────┴─────────┐   ┌─────┴────────────┐
│ aws-cicd-demo-    │   │ aws-cicd-demo-   │
│ python-app        │   │ node-app         │
│ (thin caller)     │   │ (thin caller)    │
└───────────────────┘   └──────────────────┘
```

Each consumer repo's `.github/workflows/deploy.yml` is a **thin caller**: it checks out
nothing itself, declares the GitHub Environment (for the approval gate), and calls the
framework's reusable workflow with its own inputs and environment-scoped vars/secrets.

**Naming note:** GitHub repository names carry the `aws-cicd-` prefix purely for grouping
and discoverability on GitHub (profile listing, search, topics). AWS/manifest `app-name`
values are the shorter logical name (`python-app`, `node-app`) and are
intentionally decoupled from the GitHub repo name — see §5 and §6.

## 2. Reusable workflows (in `aws-cicd-framework`)

### 2.1 `pipeline-python.yml` / `pipeline-node.yml`

Two separate files, identical shape, language-specific steps only. No shared conditional
branching — this is a deliberate choice over a single parameterized `language` workflow, to
keep each workflow linear and independently evolvable.

```yaml
on:
  workflow_call:
    inputs:
      app-name: { type: string, required: true }
      environment: { type: string, required: true }   # dev | stage | prod
      aws-region: { type: string, required: true }
      s3-bucket: { type: string, required: true }
      ecr-repository: { type: string, required: true }
      build-command: { type: string, required: false }
      lint-command: { type: string, required: false }
    secrets:
      # none defined here directly — consumers use `secrets: inherit` so that
      # environment-scoped secrets (IAM_ROLE_ARN) resolve from the calling job's
      # declared `environment:`
```

Jobs, in order:

1. **`build`** — runs `build-python` (or `build-node`) composite action: install deps,
   run lint/syntax check. Fails fast before any Docker work begins.
2. **`lint-dockerfile`** — runs `lint-dockerfile` composite action (hadolint) against the
   consumer's `Dockerfile`. Blocking; a failing lint fails the pipeline. Runs in parallel
   with `build` (needs: nothing) since it doesn't depend on build output — only merges
   before `containerize`.
3. **`containerize`** — `needs: [build, lint-dockerfile]`. Runs `docker-build-push-ecr`:
   builds the multi-stage image, pushes to the per-app ECR repo, tags with Git SHA.
   Outputs `image-uri`, `image-digest`.
4. **`render-manifest`** — `needs: containerize`. Runs `render-task-definition` to produce
   the task-def JSON, then `write-manifest-s3` to assemble and upload the manifest
   (referencing the image digest and the rendered task-def).
5. **`notify`** — `needs: render-manifest`. Runs `record-deployment-cloudwatch` with
   `event-type: deploy`.

Every job that touches AWS begins with `assume-role-oidc` (or the equivalent inline
`aws-actions/configure-aws-credentials` step) — **jobs do not share credentials across job
boundaries**; each runs on a fresh runner and must authenticate independently. This is a
common trip point worth documenting explicitly in the framework README.

### 2.2 `promote.yml`

```yaml
on:
  workflow_call:
    inputs:
      app-name: { type: string, required: true }
      source-environment: { type: string, required: true }
      target-environment: { type: string, required: true }
      git-sha: { type: string, required: true }
      s3-bucket: { type: string, required: true }
```

Jobs:

1. **`promote`** — `promote-artifact`: reads the manifest at
   `<app>/<source-environment>/<git-sha>/manifest.json`, copies it (and its embedded
   references — it does not re-render or rebuild anything) to
   `<app>/<target-environment>/<git-sha>/manifest.json`. The image in ECR is untouched;
   only the pointer moves.
2. **`notify`** — `record-deployment-cloudwatch` with `event-type: promote`.

The **calling** consumer workflow (in `aws-cicd-demo-python-app` / `aws-cicd-demo-node-app`) declares
`environment: stage` or `environment: prod` on the job that invokes this — that's where the
GitHub Environment approval gate actually lives (see §4). `promote.yml` itself has no
knowledge of approval gates; it is gate-agnostic by design, which keeps it reusable for any
future consumer without assumptions about their approval policy.

### 2.3 `rollback.yml`

```yaml
on:
  workflow_call:
    inputs:
      app-name: { type: string, required: true }
      environment: { type: string, required: true }
      target-sha: { type: string, required: false }  # omit = roll back to previous
      s3-bucket: { type: string, required: true }
```

Triggered only via `workflow_dispatch` in the consumer (never automatic — no running
service exists to health-check in this phase). Jobs:

1. **`rollback`** — `rollback-from-manifest`: reads `_rollback-history/<app>/<environment>/`
   for the target (or most recent prior) manifest, re-points
   `<app>/<environment>/current.json` (or equivalent "current" pointer) to it.
2. **`notify`** — `record-deployment-cloudwatch` with `event-type: rollback`.

## 3. Composite actions (in `aws-cicd-framework/.github/actions/`)

| Action | Inputs | Outputs | Notes |
|---|---|---|---|
| `build-python` | `build-command`, `lint-command`, `working-directory` | — | `actions/setup-python`, install, lint. No Docker. |
| `build-node` | `build-command`, `lint-command`, `working-directory` | — | `actions/setup-node`, install, lint. No Docker. |
| `lint-dockerfile` | `dockerfile-path` | `passed` | Runs `hadolint` (via its official Docker image or GitHub Action) against the consumer's Dockerfile. Fails the step on any error-level finding. |
| `docker-build-push-ecr` | `ecr-repository`, `aws-region`, `docker-context`, `git-sha` | `image-uri`, `image-digest` | Multi-stage build; tags `<git-sha>` and optionally `<env>-latest`. |
| `render-task-definition` | `app-name`, `environment`, `image-uri`, `container-port`, `cpu`, `memory`, `log-group` | `task-def-json-path` | **Pure templating — no AWS API calls.** Produces a syntactically valid ECS task-def JSON. `executionRoleArn` is a placeholder value, documented as required-before-registration. |
| `write-manifest-s3` | `s3-bucket`, `app-name`, `environment`, `image-uri`, `image-digest`, `task-def-json-path` | `manifest-s3-key` | Assembles manifest (see §5 schema) and uploads. Also updates the environment's "current" pointer and appends to rollback history. |
| `promote-artifact` | `s3-bucket`, `app-name`, `source-environment`, `target-environment`, `git-sha` | `promoted-manifest-key` | Copy-only. No rebuild, no re-render. |
| `rollback-from-manifest` | `s3-bucket`, `app-name`, `environment`, `target-sha` (optional) | `restored-manifest-key` | Reads rollback history; re-points "current". |
| `record-deployment-cloudwatch` | `environment`, `app-name`, `event-type`, `cloudwatch-log-group` | — | Emits a custom metric and/or structured log entry. |
| `assume-role-oidc` | `role-arn`, `aws-region` | — | Thin wrapper around `aws-actions/configure-aws-credentials` for consistency; used at the top of every AWS-touching job. |

## 4. GitHub Environments and approval gates

Three GitHub Environments exist in **each consumer repo** (not in the framework repo):
`dev`, `stage`, `prod`.

- `dev`: no required reviewers. Auto-triggered on push to the `dev` branch.
- `stage`: required reviewer(s) configured. Promotion job in the consumer's caller workflow
  declares `environment: stage`.
- `prod`: required reviewer(s) configured (recommend a distinct reviewer set from `stage`).
  Promotion job declares `environment: prod`.

**Critical mechanic:** the approval gate is enforced by GitHub at the **job level in the
calling workflow**, not inside the reusable workflow. A reusable workflow (`promote.yml`)
cannot itself declare an environment gate that governs the caller — the caller's job must
say:

```yaml
jobs:
  promote-to-prod:
    environment: prod
    uses: <your-username>/aws-cicd-framework/.github/workflows/promote.yml@v1
    with:
      app-name: python-app
      source-environment: stage
      target-environment: prod
      git-sha: ${{ inputs.git-sha }}
      s3-bucket: ${{ vars.S3_BUCKET }}
    secrets: inherit
```

`secrets: inherit` combined with the job's `environment: prod` is what allows
environment-scoped secrets (`IAM_ROLE_ARN` for the prod OIDC role) to resolve correctly
inside the reusable workflow's steps.

Because GitHub only mints the `environment:<env>` claim in the OIDC token when a job is
actually executing under that Environment's approval gate, this is also the mechanism that
makes IAM trust-policy scoping (§6) meaningful — approval isn't just a UI gate, it's a
precondition for the AWS role even being assumable.

## 5. S3 layout and manifest schema

**Naming note:** all identifiers below (`app-name`, S3 prefixes, ECR repo names, CloudWatch
log group paths) use the short logical name (`python-app`, `node-app`), not the
GitHub repository name (`aws-cicd-demo-python-app`). The `aws-cicd-` prefix exists only for
GitHub-side grouping (see §1) and is never propagated into AWS resource naming or the
manifest schema.

```
s3://<bucket>/
  <app-name>/
    dev/
      <git-sha>/
        manifest.json
        task-def.json
      current.json                 → pointer/copy of latest manifest
    stage/
      <git-sha>/manifest.json
      <git-sha>/task-def.json
      current.json
    prod/
      <git-sha>/manifest.json
      <git-sha>/task-def.json
      current.json
    _rollback-history/
      dev/   (last N manifests, newest first)
      stage/
      prod/
```

### `manifest.json` schema

```json
{
  "appName": "python-app",
  "environment": "stage",
  "gitSha": "a1b2c3d",
  "image": {
    "uri": "<account>.dkr.ecr.<region>.amazonaws.com/python-app:a1b2c3d",
    "digest": "sha256:...",
    "builtByRunId": "1234567890"
  },
  "taskDefinition": {
    "s3Key": "python-app/stage/a1b2c3d/task-def.json",
    "registered": false
  },
  "buildTimestamp": "2026-09-16T18:04:00Z",
  "triggeredBy": "github-actor-or-workflow",
  "workflowRunId": "1234567890",
  "eventType": "deploy",
  "previousManifestKey": "python-app/stage/9f8e7d/manifest.json"
}
```

`taskDefinition.registered` is always `false` in this phase — reserved for the future ECS
phase, where a `deploy-ecs-service` action would set it `true` and add a
`registeredArn`/`serviceUpdateId` field. This is the explicit forward-compatibility seam
called out in REQUIREMENTS.md §7 — no schema migration needed when that phase begins.

## 6. IAM design

### 6.1 Roles

Three roles, one per environment: `loria-gha-deploy-dev`, `loria-gha-deploy-stage`, `loria-gha-deploy-prod`.

### 6.2 Trust policy (per role — example for `prod`)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:<your-username>/aws-cicd-demo-python-app:environment:prod"
        }
      }
    }
  ]
}
```

Repeat for the second consumer (`aws-cicd-demo-node-app`) — multiple `sub` values via a
condition list on the same shared per-environment role, rather than 2×3 roles. Both demo
repos assume the same `loria-gha-deploy-prod` role; the trust policy's `StringEquals` condition
becomes a list of both repos' `sub` values for that environment.

The `:environment:prod` segment is the load-bearing part — it ties role assumption to the
GitHub Environment approval gate, not merely to the repository or branch.

### 6.3 Permissions policy (per role — example for `prod`, S3 + ECR + CloudWatch only)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ScopedToProdPrefix",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::<bucket>/*/prod/*",
        "arn:aws:s3:::<bucket>"
      ],
      "Condition": {
        "StringLike": { "s3:prefix": ["*/prod/*"] }
      }
    },
    {
      "Sid": "EcrPushPullSharedAcrossEnvs",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": [
        "arn:aws:ecr:<region>:<account-id>:repository/python-app",
        "arn:aws:ecr:<region>:<account-id>:repository/node-app"
      ]
    },
    {
      "Sid": "CloudWatchScopedToProdLogGroup",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents", "logs:PutMetricData"],
      "Resource": "arn:aws:logs:<region>:<account-id>:log-group:/aws-cicd/prod/*"
    }
  ]
}
```

**Explicitly absent in this phase:** any `ecs:*` action, any `iam:PassRole`. Do not add
these ahead of need — see REQUIREMENTS.md FR-23. Adding them later as a visible,
reviewable diff is itself a demonstrable least-privilege practice.

## 7. Dockerfile linting integration

`lint-dockerfile` composite action wraps `hadolint` (either the official Docker image
`hadolint/hadolint` run via `docker run`, or the `hadolint/hadolint-action` GitHub Action).
Configuration:

- Runs against the consumer repo's root `Dockerfile` (path parameterized via
  `dockerfile-path` input for flexibility).
- Fails the step (and therefore the pipeline) on any hadolint error-level finding.
- A `.hadolint.yaml` config MAY live in the framework repo and be referenced by consumers,
  to centrally control which rules are enforced/ignored — recommended so the discipline
  checklist in REQUIREMENTS.md §4.2.1 is enforced consistently rather than left to each
  consumer's interpretation.

## 8. Versioning

- SemVer tags on `aws-cicd-framework` (`v1.0.0`, `v1.1.0`, ...).
- A floating `v1` tag, re-pointed at the latest compatible release after validation.
- Consumers reference `@v1` by default; pin to an exact tag (`@v1.2.0`) only if isolating
  from an upcoming change.
- Breaking changes (input renames, removed outputs, changed manifest schema fields) require
  a major version bump and a new floating tag (`v2`) — existing consumers on `@v1`
  are unaffected until they deliberately move.

## 9. Repository layout reference

### `aws-cicd-framework`

```
aws-cicd-framework/
├── .github/
│   ├── workflows/
│   │   ├── pipeline-python.yml
│   │   ├── pipeline-node.yml
│   │   ├── promote.yml
│   │   ├── rollback.yml
│   │   └── ci-self-test.yml        # lints/validates the framework's own YAML
│   └── actions/
│       ├── build-python/action.yml
│       ├── build-node/action.yml
│       ├── lint-dockerfile/action.yml
│       ├── docker-build-push-ecr/action.yml
│       ├── render-task-definition/action.yml
│       ├── write-manifest-s3/action.yml
│       ├── promote-artifact/action.yml
│       ├── rollback-from-manifest/action.yml
│       ├── record-deployment-cloudwatch/action.yml
│       └── assume-role-oidc/action.yml
├── infra/                          # Terraform for supporting AWS resources
│   ├── oidc-provider.tf
│   ├── iam-roles.tf
│   ├── s3.tf
│   ├── ecr.tf
│   ├── cloudwatch.tf
│   ├── variables.tf
│   └── outputs.tf
├── .hadolint.yaml
├── README.md                       # includes the "why Docker/ECR exist pre-runtime" note
│                                    # and the "Roadmap / ECS phase" note
└── docs/
    ├── REQUIREMENTS.md
    └── DESIGN.md
```

### `aws-cicd-demo-python-app` / `aws-cicd-demo-node-app`

```
aws-cicd-demo-<lang>-app/
├── .github/workflows/deploy.yml    # thin caller: build/deploy + promote + rollback triggers
├── Dockerfile                      # multi-stage, meets discipline checklist
├── .dockerignore
├── src/ (or app.py / index.js)     # no-op entrypoint, no functional logic
├── requirements.txt | package.json # one real dependency
└── README.md
```

## 10. Terraform scope (framework repo `infra/`)

Provisions, once, shared across both demo consumers:

- GitHub OIDC provider in AWS (`aws_iam_openid_connect_provider`).
- Three IAM roles (dev/stage/prod) with trust and permission policies as in §6.
- One S3 bucket (shared, prefix-isolated per app/environment — see §5).
- Two ECR repositories (`python-app`, `node-app`) — per-app, per FR-22.
- Three CloudWatch log groups (per environment — `/aws-cicd/dev/*`, `/aws-cicd/stage/*`,
  `/aws-cicd/prod/*`; short logical prefix, consistent with S3/ECR naming per §5).

This is applied once via `terraform apply` as a bootstrap step, not part of any GitHub
Actions run in this phase (no pipeline job manages its own IAM/infra — that would be a
privilege-escalation smell worth avoiding even in a demo).
