# aws-cicd-framework

A reusable, multi-environment CI/CD framework demonstrating enterprise release
engineering practice — build automation, containerization discipline, environment
promotion, approval-gated releases, rollback, and least-privilege IAM — built on
GitHub Actions, Docker, and AWS.

Consumer repositories do not copy this pipeline. They call it by reference:

```yaml
jobs:
  deploy:
    uses: loriamichaelj/aws-cicd-framework/.github/workflows/deploy.yml@v1
    with:
      app-name: python-app
      language: python
      environment: dev
      aws-region: us-east-1
    secrets: inherit
```

## The repository set

| Repository | Role |
| --- | --- |
| **aws-cicd-framework** | The reusable deploy workflow and a Terraform reference spec for the supporting AWS resources. |
| [aws-cicd-demo-python-app](https://github.com/loriamichaelj/aws-cicd-demo-python-app) | Minimal Python containerization fixture that consumes the framework. |
| [aws-cicd-demo-node-app](https://github.com/loriamichaelj/aws-cicd-demo-node-app) | Minimal Node.js containerization fixture that consumes the framework. |

The demo repositories carry no functional application logic by design. They exist to
give the build and containerization steps a real artifact to operate on.

## How it works

```
push to dev            ──▶  build ──▶ hadolint ──▶ containerize ──▶ image saved to S3
PR merged into stage    ──▶  (same pipeline, gated by stage's required reviewer)
PR merged into prod     ──▶  (same pipeline, gated by prod's required reviewer)
```

Each environment independently builds, tests, and containerizes from its own branch at
the moment of trigger — `dev` on every push, `stage`/`prod` on PR merge. A
`detect-environment` job in each caller resolves which environment name to pass based on
the trigger context (branch name for push, PR base ref for merge).

**Note:** images are currently saved to S3 as `docker save` tarballs rather than pushed to
ECR — the account's shared GitHub Actions role doesn't yet have ECR permissions. This is a
deliberate interim substitution, not a design change: swapping the S3 upload step for an
ECR push later is a contained change to one step.

Three ideas carry most of the weight:

**Every environment builds from its own branch, gated by review.** `dev`/`stage`/`prod`
are real branches; merging into `stage` or `prod` is what triggers that environment's
build. This project briefly used a different model — promoting a single built artifact
forward via a `promote.yml` copy step, with no rebuild at all — and proved it working
end-to-end before deliberately pivoting to this branch-based model to match a specific
reference pattern. Both are legitimate; this is the one currently in use.

**The approval gate is an AWS precondition, not a UI formality.** The shared deploy role's
trust policy accepts only specific OIDC subjects — one per consumer repo's environment,
using GitHub's immutable subject claim format (`repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<env>`).
GitHub mints that claim only once a job is genuinely executing under that Environment —
that is, after its required reviewer has approved. An unapproved job cannot assume the
role at all.

**No long-lived AWS credentials exist anywhere.** Authentication is GitHub OIDC
federation end to end. There are no access keys in any repository, secret store, or
runner.

## Why containers exist here before a runtime does

This phase builds and publishes images and renders ECS-compatible task definitions, but
registers nothing and runs nothing. That is deliberate sequencing rather than an
unfinished build.

The engineering being demonstrated is release discipline: multi-stage builds, non-root
users, pinned base images, enforced Dockerfile linting, immutable SHA-tagged artifacts,
and an auditable deployment record. None of that requires a running service, and adding
an ECS cluster would add infrastructure cost and networking surface without
strengthening the demonstration.

The manifest schema and rendered task definitions are shaped so the runtime phase drops
in without redesign — `taskDefinition.registered` is already present and set `false`.

## Roadmap — the ECS phase

Deferred, with the seams left open:

- ECS cluster, service, and supporting networking.
- A `deploy-ecs-service` composite action calling `ecs:RegisterTaskDefinition` and
  `ecs:UpdateService`.
- Scoped `ecs:*` and narrowly-scoped `iam:PassRole` added to the environment roles at
  that point, and not before.
- Health-check-driven automatic rollback, once a running service exists to check.

No IAM policy in the current phase holds `ecs:*` or `iam:PassRole`. Adding them later as
a reviewable diff is itself the least-privilege practice being demonstrated.

## Branches

| Branch | Contents |
| --- | --- |
| `main` | This README only. Entry point, signpost, and GitHub default branch. |
| `dev` | Active development. |
| `stage` | Promoted from `dev`. |
| `prod` | Promoted from `stage`. **The complete framework lives here.** |

Released versions are SemVer tags cut from `prod`, with a floating `v1` tag re-pointed
at the latest compatible release. Consumers reference `@v1`.

**➡ [Browse the full framework on the `prod` branch](https://github.com/loriamichaelj/aws-cicd-framework/tree/prod)**

## Documentation

- [Requirements](https://github.com/loriamichaelj/aws-cicd-framework/blob/prod/docs/REQUIREMENTS.md)
- [Design](https://github.com/loriamichaelj/aws-cicd-framework/blob/prod/docs/DESIGN.md)

## Status

**v1.0.0 released. Every functional requirement is built and validated with real runs,**
except what's explicitly deferred (ECS entirely; ECR pending account access). Both
`aws-cicd-demo-python-app` and `aws-cicd-demo-node-app` reference `@v1` and have real,
successful pipeline runs across `dev`, `stage`, and `prod` — build, test, hadolint,
OIDC-authenticated Docker build/run/save, S3 upload, manifest/task-def rendering,
CloudWatch event recording, and (on `dev` for both apps, `stage` for `python-app`) manual
rollback — each verified by inspecting the actual AWS API responses (S3 upload
confirmations, CloudWatch `nextSequenceToken`), not just green checkmarks.

**SDLC model pivoted mid-build.** `promote.yml` (a `workflow_dispatch`-triggered,
no-rebuild S3-copy promotion step) was built and verified working end-to-end first — a
real `dev`→`stage` promotion, gated by `stage`'s required reviewer, produced the exact
same S3 object at the new key. It was then deliberately retired in favor of the
branch-based SDLC now in use: `stage`/`prod` are real branches, and each demo repo's
`deploy.yml` caller triggers on PR-merge into them (in addition to push on `dev`),
independently rebuilding per environment. See `docs/REQUIREMENTS.md` §8 for the full
reasoning — both models work; this is the one currently in use.

Authentication uses a pre-existing shared GitHub Actions OIDC role for this AWS account
rather than roles provisioned by this repo — IAM role/provider creation is outside the
current account permissions. The role's trust policy trusts both demo repos' `dev`,
`stage`, and `prod` environments; its permissions policy grants access to this project's
dedicated artifact bucket and CloudWatch log groups. Both policies are managed directly in
AWS, outside Terraform. `AWS_DEPLOY_ROLE_ARN`/`S3_BUCKET` are set as Environment variables
on all three environments in both consumer repos.

The artifact bucket and the three CloudWatch log groups (`infra/s3.tf`,
`infra/cloudwatch.tf`) were both created manually in the AWS Console rather than via
`terraform apply` — no local CLI credentials, and CloudShell's VPC networking setup wasn't
worth the friction for one-off resources this small. Both `.tf` files stay as reference
specs for their actual configuration.

`deploy.yml` has a `render-manifest` job that templates an ECS-compatible task definition
(FR-8, pure JSON templating, no `ecs:*` calls) and writes a deployment manifest to S3
(FR-9) — image location, a `sha256` digest of the saved tarball standing in for a registry
digest, build metadata, and a `previousManifestKey` pointing at whatever `current.json`
held before this run.

`rollback.yml` re-points an environment's `current.json` to a prior manifest — either an
explicit `target-sha`, or (if omitted) whatever `previousManifestKey` the current manifest
points to. Deliberately doesn't use a separate `_rollback-history/` structure from the
original plan; the manifest chain `render-manifest` already writes serves the same
purpose. Getting it dispatchable surfaced a real GitHub constraint: `workflow_dispatch`
workflows must exist on a repo's *default branch* to be discoverable/triggerable at all —
both demo repos' `main` branches now carry `.github/workflows/` (just the two workflow
files, nothing else) for exactly this reason.

`notify` (in both `deploy.yml` and `rollback.yml`) writes a structured JSON event —
`eventType`, `appName`, `environment`, `result`, `workflowRunId`, `triggeredBy`, plus
`gitSha` or `targetSha` — to that environment's CloudWatch log group
(`/aws-cicd/<environment>`), fulfilling FR-17/FR-18.

`v1.0.0` is tagged from `prod` (fast-forwarded from `dev` — the framework's entire build,
promoted in one shot since `stage`/`prod` had never moved before), with a floating `v1`
tag at the same commit. Both demo repos switched their `deploy.yml`/`rollback.yml`
references from `@dev` to `@v1`, confirmed working with real runs on every branch.
