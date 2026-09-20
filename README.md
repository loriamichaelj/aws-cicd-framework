# aws-cicd-framework

A reusable, multi-environment CI/CD framework demonstrating enterprise release
engineering practice — build automation, containerization discipline, environment
promotion, approval-gated releases, rollback, and least-privilege IAM — built on
GitHub Actions, Docker, and AWS.

Consumer repositories do not copy this pipeline. They call it by reference:

```yaml
jobs:
  deploy:
    uses: loriamichaelj/aws-cicd-framework/.github/workflows/deploy.yml@dev
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
| **aws-cicd-framework** | Reusable workflows, composite actions, and Terraform for the supporting AWS resources. |
| [aws-cicd-demo-python-app](https://github.com/loriamichaelj/aws-cicd-demo-python-app) | Minimal Python containerization fixture that consumes the framework. |
| [aws-cicd-demo-node-app](https://github.com/loriamichaelj/aws-cicd-demo-node-app) | Minimal Node.js containerization fixture that consumes the framework. |

The demo repositories carry no functional application logic by design. They exist to
give the build and containerization steps a real artifact to operate on.

## How it works

```
push to dev  ──▶  build ──▶ hadolint ──▶ containerize ──▶ image saved to S3
                                                                  │
                                                                  ▼
                                    render task definition ──▶ manifest to S3 ──▶ CloudWatch event

dev ──[approval]──▶ stage ──[approval]──▶ prod
      artifact promoted by pointer; the image is never rebuilt
```

**Note:** images are currently saved to S3 as `docker save` tarballs rather than pushed to
ECR — the account's shared GitHub Actions role doesn't yet have ECR permissions. This is a
deliberate interim substitution, not a design change: swapping the S3 upload step for an
ECR push later is a contained change to one step.

Three ideas carry most of the weight:

**Promotion moves a pointer, not a build.** An image is built exactly once and tagged
with its Git SHA. Promoting `dev` to `stage` copies the deployment manifest to the
target environment's S3 prefix. The image digest referenced in `stage` and `prod` is
provably identical to the one built on `dev`.

**The approval gate is an AWS precondition, not a UI formality.** The shared deploy role's
trust policy accepts only the OIDC subject `repo:<owner>/<repo>:environment:<env>`.
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
| `main` | This README only. Entry point and signpost. |
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

Under active construction on `dev`. Authentication uses a pre-existing shared GitHub
Actions OIDC role for this AWS account rather than roles provisioned by this repo — IAM
role/provider creation is outside the current account permissions. The role's ARN is set
as the `AWS_DEPLOY_ROLE_ARN` GitHub Environment variable in each consumer repo; its trust
policy is managed directly in AWS, outside Terraform.

Completed so far: `deploy.yml` (the reusable build/lint/containerize pipeline) and the
thin caller workflows in both demo repos.
