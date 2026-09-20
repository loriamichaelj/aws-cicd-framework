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
│  .github/workflows/                                                 │
│    deploy.yml                  build/test/deploy/notify jobs,       │
│                                 inlined steps (no composite actions  │
│                                 yet — see §3)                        │
│    promote.yml                 built — S3-to-S3 image copy          │
│    rollback.yml                planned, not yet built                │
│                                                                     │
│  infra/ (Terraform)                                                 │
│    s3.tf                       artifact bucket — the only AWS       │
│    variables.tf, outputs.tf    resource this repo currently         │
│    versions.tf                 provisions (see §10)                 │
└─────────────────────────────────────────────────────────────────────┘
                 ▲ uses: aws-cicd-framework/.github/workflows/deploy.yml@dev
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
nothing itself and calls the framework's reusable workflow with its own inputs. The
GitHub Environment declaration (for the approval gate) lives on the *called* workflow's
own job, not on the caller — see §4 for why.

**Naming note:** GitHub repository names carry the `aws-cicd-` prefix purely for grouping
and discoverability on GitHub (profile listing, search, topics). AWS/manifest `app-name`
values are the shorter logical name (`python-app`, `node-app`) and are
intentionally decoupled from the GitHub repo name — see §5 and §6.

## 2. Reusable workflows (in `aws-cicd-framework`)

### 2.1 `deploy.yml` (built)

One file, both languages, parameterized by a `language` input — chosen over two
near-duplicate files for minimalism (see REQUIREMENTS.md §8). Steps are inlined directly
rather than factored into composite actions; §3 covers why.

```yaml
on:
  workflow_call:
    inputs:
      app-name: { type: string, required: true }
      language: { type: string, required: true }       # python | node
      environment: { type: string, required: true }    # dev | stage | prod
      aws-region: { type: string, required: true }
```

Jobs, in order:

1. **`build`** — checkout, language-conditional `setup-python`/`setup-node`, install
   deps, run the lint/compile check. Fails fast before any Docker work begins.
2. **`test`** — checkout; language-conditional install + real unit test (`pytest` or
   `node --test`); a second checkout of `aws-cicd-framework@dev` (for `.hadolint.yaml`)
   and a hadolint run against the consumer's `Dockerfile`. Runs in parallel with `build`
   (needs: nothing) — both jobs only merge before `deploy`.
3. **`deploy`** — `needs: [build, test]`. Declares `environment: ${{ inputs.environment }}`
   (see §4). Assumes the shared AWS role via OIDC, `docker build`s the image, `docker
   run --rm`s it as a smoke test, then `docker save | gzip`s it and uploads the tarball to
   S3 (see §5 for the key layout and §8 in REQUIREMENTS.md for why S3 instead of ECR).
4. **`notify`** — `needs: deploy`. Currently an echo placeholder; CloudWatch recording is
   not yet built (see §7 in REQUIREMENTS.md).

Every job that touches AWS begins its own `configure-aws-credentials` step — **jobs do
not share credentials across job boundaries**; each runs on a fresh runner and must
authenticate independently. This is a common trip point worth documenting explicitly in
the framework README.

Not yet built at all: `render-task-definition` and `write-manifest-s3` equivalents (FR-8,
FR-9). Adding them is a new job between `deploy` and `notify`, not a redesign.

### 2.2 `promote.yml` (built)

```yaml
on:
  workflow_call:
    inputs:
      app-name: { type: string, required: true }
      source-environment: { type: string, required: true }
      target-environment: { type: string, required: true }
      git-sha: { type: string, required: true }
      aws-region: { type: string, required: true }
```

Jobs:

1. **`promote`** — a single `aws s3 cp` copying the image tarball from
   `<app-name>/<source-environment>/<git-sha>/image.tar.gz` to
   `<app-name>/<target-environment>/<git-sha>/image.tar.gz` — a server-side S3-to-S3 copy,
   no download, no rebuild. **Amended from the original plan**: the original design copied
   a `manifest.json` pointer rather than the image itself, but manifest writing (FR-9)
   isn't built yet, so there's no manifest to copy. Copying the image tarball directly is
   the real artifact that exists today and achieves the same guarantee (FR-11): the exact
   same bytes, just at a new key. Revisit once `write-manifest-s3` exists — at that point
   this job should copy the manifest (which references the image) instead, matching the
   original design.
2. **`notify`** — `if: always()`, echoes success or failure based on `needs.promote.result`.

Both jobs live inside `promote.yml`, so **the `promote` job itself** declares
`environment: ${{ inputs.target-environment }}` — that's where the GitHub Environment
approval gate actually lives (see §4). The consumer's *calling* job (in
`aws-cicd-demo-python-app` / `aws-cicd-demo-node-app`) must NOT declare `environment:` —
GitHub Actions doesn't allow that key on a job that only has `uses:`. It's a
`workflow_dispatch`-triggered thin caller with dropdown-constrained `source-environment`/
`target-environment` inputs (prevents typos like promoting *from* prod) and a free-text
`git-sha` — there's no way to look up "the latest dev build" automatically without the
manifest system, so the person triggering promotion supplies it directly.

### 2.3 `rollback.yml` (planned, not yet built)

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

## 3. Composite actions — not built; steps are inlined instead

The original plan factored each step into a named composite action under
`.github/actions/` (table below, kept for reference). In the actual build, `deploy.yml`
and `promote.yml` both inline every step directly rather than factoring out shared logic.

Worth noting: with `promote.yml` now built, the `configure-aws-credentials` OIDC
assume-role step is duplicated verbatim between `deploy.yml`'s `deploy` job and
`promote.yml`'s `promote` job — exactly the kind of repetition that would justify a
composite action. Not factored out yet since it's still only two occurrences and each is
three lines; revisit once `rollback.yml` adds a third, or if the assume-role step grows
more complex than it is today.

Planned action names, if/when this gets factored out:

| Action | Inputs | Outputs | Notes |
|---|---|---|---|
| `build-python` | `build-command`, `lint-command`, `working-directory` | — | `actions/setup-python`, install, lint. No Docker. |
| `build-node` | `build-command`, `lint-command`, `working-directory` | — | `actions/setup-node`, install, lint. No Docker. |
| `lint-dockerfile` | `dockerfile-path` | `passed` | Runs `hadolint` against the consumer's Dockerfile. Fails on any error-level finding. |
| `docker-build-push` | `aws-region`, `docker-context`, `git-sha` | `image-location`, `image-digest` | Multi-stage build; currently uploads to S3 (see REQUIREMENTS.md §8), ECR once available. |
| `render-task-definition` | `app-name`, `environment`, `image-location`, `container-port`, `cpu`, `memory`, `log-group` | `task-def-json-path` | **Pure templating — no AWS API calls.** Produces a syntactically valid ECS task-def JSON. `executionRoleArn` is a placeholder value, documented as required-before-registration. |
| `write-manifest-s3` | `s3-bucket`, `app-name`, `environment`, `image-location`, `image-digest`, `task-def-json-path` | `manifest-s3-key` | Assembles manifest (see §5 schema) and uploads. Also updates the environment's "current" pointer and appends to rollback history. |
| `promote-artifact` | `s3-bucket`, `app-name`, `source-environment`, `target-environment`, `git-sha` | `promoted-manifest-key` | Copy-only. No rebuild, no re-render. |
| `rollback-from-manifest` | `s3-bucket`, `app-name`, `environment`, `target-sha` (optional) | `restored-manifest-key` | Reads rollback history; re-points "current". |
| `record-deployment-cloudwatch` | `environment`, `app-name`, `event-type`, `cloudwatch-log-group` | — | Emits a custom metric and/or structured log entry. |

## 4. GitHub Environments and approval gates

Three GitHub Environments belong in **each consumer repo** (not in the framework repo):
`dev`, `stage`, `prod`.

- `dev`: no required reviewers. Auto-triggered on push to the `dev` branch. Created and in
  use today.
- `stage`: required reviewer(s) configured. The promotion job *inside* `promote.yml`
  declares `environment: stage` (not the consumer's caller job — see below). `promote.yml`
  itself is built; the `stage` Environment isn't created yet, so this path is untested.
- `prod`: required reviewer(s) configured (recommend a distinct reviewer set from `stage`).
  The promotion job declares `environment: prod`, same placement. Same status as `stage`
  — code is built, the Environment isn't created yet.

**Critical mechanic, corrected from the original spec:** GitHub Actions does not allow
`environment:` on a job that only has `uses:` (calls a reusable workflow) — `actionlint`
rejects it, and it's not in GitHub's documented list of supported keywords for that job
shape (`name`, `uses`, `with`, `secrets`, `needs`, `if`, `permissions`). The `environment:`
declaration has to live on the reusable workflow's *own* job — the one that actually has
`runs-on:` and does the AWS work. GitHub still resolves that environment against the
*calling* repository (that's how `secrets: inherit` and environment-scoped vars work at
all), so the mechanism holds; it's just declared in a different file than you'd expect:

```yaml
# In the consumer's caller workflow — no `environment:` here:
jobs:
  promote-to-prod:
    uses: <your-username>/aws-cicd-framework/.github/workflows/promote.yml@v1
    with:
      app-name: python-app
      source-environment: stage
      target-environment: prod
      git-sha: ${{ inputs.git-sha }}
    secrets: inherit
```

```yaml
# Inside promote.yml itself — the job that does the work declares it:
jobs:
  promote:
    runs-on: ubuntu-latest
    environment: ${{ inputs.target-environment }}
    steps: ...
```

`secrets: inherit` combined with the `promote` job's `environment:` is what allows
environment-scoped secrets (the shared role's ARN, per environment) to resolve correctly
inside the reusable workflow's steps — same effect as originally intended, corrected
placement. This is exactly what `deploy.yml`'s `deploy` job (§2.1) and `promote.yml`'s
`promote` job (§2.2) already do; apply the same pattern to `rollback.yml` when it's built.

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

### `manifest.json` schema (not yet built — see §2.1)

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

`image.uri` above shows the eventual ECR form; currently it would hold the S3 key from
`deploy.yml`'s image-save step instead (`<app-name>/<environment>/<git-sha>/image.tar.gz`)
— see REQUIREMENTS.md §8. This whole section is moot until write-manifest-s3 is actually
built (§2.1), at which point build it against whichever storage is current.

## 6. IAM design (amended — shared role, not per-environment. See REQUIREMENTS.md §8)

### 6.1 Role

One pre-existing shared GitHub Actions OIDC role, already in use by other projects in
this AWS account, before this project ever touched it. This repo does not create it and
does not manage its full policy — no `iam:CreateRole`/`iam:CreateOpenIDConnectProvider`
permissions were available. Its trust and permissions policies are edited directly in
AWS, not via this repo's Terraform (see §10).

### 6.2 Trust policy (statements added for this project)

This account's GitHub repos use **immutable subject claims** (GitHub Settings → Actions →
OIDC, enabled automatically for repos created after 2026-07-15): the `sub` claim embeds
each repo's immutable owner/repo IDs, not just their names, e.g.
`repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<env>` rather than the older
`repo:<owner>/<repo>:environment:<env>`. Each consumer repo's exact prefix is shown on its
own **Settings → Actions → OIDC** page — copy it from there rather than constructing it,
since the numeric IDs aren't guessable.

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": [
        "repo:<owner>@<owner-id>/aws-cicd-demo-python-app@<repo-id>:environment:dev",
        "repo:<owner>@<owner-id>/aws-cicd-demo-node-app@<repo-id>:environment:dev"
      ]
    }
  }
}
```

Only `dev` entries exist today. `promote.yml` is built and ready to use `stage`/`prod`,
but those GitHub Environments don't exist yet, so there's nothing yet for a `stage`/`prod`
trust entry to gate. Adding `stage`/`prod` later is two more list entries per repo,
appended to this same statement — not a new role.

The `:environment:<env>` segment is still the load-bearing part — it ties role assumption
to the GitHub Environment approval gate, not merely to the repository or branch. That
property holds regardless of whether the role is per-environment or shared: a workflow
run still can't assume the role unless it's executing under the matching GitHub
Environment.

### 6.3 Permissions policy (statement added for this project's artifact bucket)

This project's addition is scoped to its own dedicated bucket, appended as separate
statements alongside whatever else the shared role's policy already grants for other
projects — not a replacement of the existing policy:

```json
[
  {
    "Sid": "ListLoriaAwsCicdArtifacts",
    "Effect": "Allow",
    "Action": "s3:ListBucket",
    "Resource": "arn:aws:s3:::loria-aws-cicd-artifacts-<account-id>"
  },
  {
    "Sid": "ReadWriteLoriaAwsCicdArtifacts",
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"],
    "Resource": "arn:aws:s3:::loria-aws-cicd-artifacts-<account-id>/*"
  }
]
```

(Append these two objects into the existing policy's top-level `Statement` array — this
fragment is shown as its own array only for readability here.)

**Explicitly absent in this phase:** any `ecs:*` action, any `iam:PassRole`. Do not add
these ahead of need — see REQUIREMENTS.md FR-23. Adding them later as a visible,
reviewable diff is itself a demonstrable least-privilege practice.

## 7. Dockerfile linting integration

The `test` job (§2.1) runs `hadolint/hadolint-action` directly (inlined, no composite
action — see §3) against the consumer repo's root `Dockerfile`. Configuration:

- Fails the step (and therefore the pipeline) on any hadolint error-level finding
  (`.hadolint.yaml`'s `failure-threshold: style`).
- `.hadolint.yaml` lives in the framework repo, not each consumer. The `test` job checks
  out `aws-cicd-framework@dev` a second time (`path: .framework`) to reach it, since the
  reusable workflow's own repo checkout otherwise only gets the *calling* repo's files.
  This centrally controls which rules are enforced/ignored, so the discipline checklist
  in REQUIREMENTS.md §4.2.1 is enforced consistently rather than left to each consumer's
  interpretation.

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
│   └── workflows/
│       ├── deploy.yml              # built — build/test/deploy/notify, both languages
│       ├── promote.yml             # built — S3-to-S3 image copy between environments
│       └── rollback.yml            # planned, not yet built
├── infra/                          # Terraform — only what this account permits (§10)
│   ├── s3.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── versions.tf
├── .hadolint.yaml
├── README.md
└── docs/
    ├── REQUIREMENTS.md
    └── DESIGN.md
```

No `.github/actions/` directory — composite actions aren't built yet (§3).

### `aws-cicd-demo-python-app` / `aws-cicd-demo-node-app`

```
aws-cicd-demo-<lang>-app/
├── .github/workflows/deploy.yml    # thin caller: push-to-dev trigger
├── .github/workflows/promote.yml   # thin caller: workflow_dispatch, manual promotion
├── Dockerfile                      # multi-stage, meets discipline checklist
├── .dockerignore
├── src/ (or app.py / index.js)     # no-op entrypoint, one exported function for tests
├── tests/ | test/                  # one unit test exercising that function
├── requirements.txt | package.json # one real dependency
└── README.md
```

Rollback's trigger isn't in the caller yet — that's `rollback.yml`, not built.

## 10. Terraform scope (framework repo `infra/`) — amended, see REQUIREMENTS.md §8

This account's IAM permissions turned out not to include `iam:CreateRole` or
`iam:CreateOpenIDConnectProvider` (a shared role/provider already existed for other
projects), and no ECR access.

`infra/s3.tf` documents the artifact bucket's intended configuration
(`loria-aws-cicd-artifacts-<account-id>`, versioned, SSE-S3 encrypted, public access
fully blocked) but **the bucket itself was created manually via the AWS Console**, not by
running `terraform apply` — this account has no local CLI credentials, and getting a
CloudShell session usable for Terraform (private-VPC networking, no direct SSH access)
added enough friction that a one-off manual bucket creation was the pragmatic call. The
`.tf` file stays as the reference spec for what was actually configured, and as a
starting point if this ever gets reconciled with real Terraform state later (via
`terraform import`).

Not provisioned by this repo, and not planned to be unless account permissions change:

- The GitHub OIDC provider and the shared IAM role — pre-existing, managed directly in
  AWS by whoever administers this account.
- ECR repositories — no access to create them in this account currently.
- CloudWatch log groups — not yet needed, since CloudWatch recording (FR-17/FR-18) isn't
  built.

If Terraform-managed provisioning is revisited later (no pipeline job should ever manage
its own infra — that would be a privilege-escalation smell worth avoiding even in a demo),
it would be applied once as a bootstrap step, not as part of any GitHub Actions run.
