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
│                                 yet — see §3). Environment-agnostic  │
│                                 — the caller decides which env.      │
│    rollback.yml                built — re-points current.json via   │
│                                 the existing manifest chain          │
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
│ dev/stage/prod     │   │ dev/stage/prod   │
│ branches           │   │ branches          │
└───────────────────┘   └──────────────────┘
```

Each consumer repo's `.github/workflows/deploy.yml` is a **thin caller** with a branch-
based SDLC: `push` to `dev` triggers automatically; PR merges into `stage`/`prod` trigger
those environments. A `detect-environment` job resolves which environment name to pass
based on the trigger context, then a `deploy` job calls the framework's reusable workflow
with that name. The GitHub Environment declaration (for the approval gate) lives on the
*called* workflow's own job, not on the caller — see §4 for why. **Retired:**
`promote.yml` — see §2.2's history and REQUIREMENTS.md §8 for why.

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
   run --rm`s it as a smoke test, `docker save | gzip`s it and uploads the tarball to S3
   (see §5 for the key layout and §8 in REQUIREMENTS.md for why S3 instead of ECR), and
   outputs a `sha256` digest of the tarball for `render-manifest` to reference — this is
   the S3-era analog of an ECR image digest, computed since there's no registry assigning
   one.
4. **`render-manifest`** — `needs: deploy`. Also declares `environment: ${{ inputs.environment }}`
   (needed to resolve the same `vars.AWS_DEPLOY_ROLE_ARN`/`S3_BUCKET`, which are
   environment-scoped — see §4; this may prompt a second approval click on `stage`/`prod`
   beyond the one `deploy` already required, since GitHub doesn't always treat two jobs
   referencing the same environment as one gate). Renders a syntactically valid ECS
   task-def JSON (pure templating, no `ecs:*` calls — FR-8) and uploads it to S3, then
   assembles and uploads `manifest.json` (FR-9): reads the environment's existing
   `current.json` (if any) to populate `previousManifestKey`, writes the new manifest to
   `<git-sha>/manifest.json`, and overwrites `current.json` to point to it.
5. **`notify`** — `needs: [deploy, render-manifest]`. Echoes success only if both
   upstream jobs succeeded; CloudWatch recording is not yet built (see §7 in
   REQUIREMENTS.md), so this remains a placeholder.

Every job that touches AWS begins its own `configure-aws-credentials` step — **jobs do
not share credentials across job boundaries**; each runs on a fresh runner and must
authenticate independently. This is a common trip point worth documenting explicitly in
the framework README.

`render-manifest` only maintains `current.json`, not a separate rollback-history list —
`rollback.yml` (§2.3, built) doesn't need one: it reads the manifest chain
`render-manifest` already writes (each manifest's `previousManifestKey`) instead of a
parallel `_rollback-history/` structure. The `_rollback-history/` directory described in
§5's original S3 layout was never built; see §2.3 for why.

`deploy.yml` itself is **environment-agnostic** — it has no idea whether it's being
invoked for `dev`, `stage`, or `prod`; it just does what `inputs.environment` says. That's
what let the SDLC pivot below happen without touching this file at all — only the callers
changed.

### 2.2 `promote.yml` — built, tested working, then retired

For a window during the build, promotion was a separate `workflow_call` reusable workflow
that did a single `aws s3 cp`, copying the image tarball from
`<app-name>/<source-environment>/<git-sha>/image.tar.gz` to
`<app-name>/<target-environment>/<git-sha>/image.tar.gz` — a server-side S3-to-S3 copy, no
rebuild. This was built, and verified working end-to-end: a real dev→stage promotion run,
gated by `stage`'s required reviewer, produced the exact same object at the new key.

It has since been **deleted from all three repos**, as a deliberate pivot (not a walk-back
due to a problem — it worked) to a branch-based SDLC matching a specific reference
pattern: `dev`/`stage`/`prod` as real branches, each independently rebuilding on its own
trigger (push for `dev`, PR-merge for `stage`/`prod`). See REQUIREMENTS.md §8 for the full
reasoning and the trade-off being made. If a future need calls for the no-rebuild
guarantee again, the git history has a complete, working reference implementation to
restore from — this wasn't removed because it was broken.

### 2.3 `rollback.yml` (built)

```yaml
on:
  workflow_call:
    inputs:
      app-name: { type: string, required: true }
      environment: { type: string, required: true }
      target-sha: { type: string, required: false }  # omit = roll back to previous
      aws-region: { type: string, required: true }
```

Triggered only via `workflow_dispatch` in the consumer (never automatic — no running
service exists to health-check in this phase). Jobs:

1. **`rollback`** — declares `environment: ${{ inputs.environment }}`, same pattern as
   `deploy`/`render-manifest`. **Amended from the original plan**: rather than reading a
   separate `_rollback-history/<app>/<environment>/` directory (never built — see §2.1),
   this reads the manifest chain `render-manifest` already maintains. If `target-sha` is
   given, it points directly at `<app>/<environment>/<target-sha>/manifest.json`. If
   omitted, it reads the environment's current `current.json` and follows its own
   `previousManifestKey` field to find the one before it. Either way, once the target
   manifest is confirmed to exist (`s3api head-object`), its content is copied over
   `current.json` — the actual "re-point current to a prior manifest" FR-15 describes,
   just via the existing linked-list-of-manifests instead of a separate history structure.
2. **`notify`** — `if: always()`, echoes success or failure based on `needs.rollback.result`.

The consumer's caller is a `workflow_dispatch`-triggered thin caller, same shape as
`promote.yml`'s was before retirement: `environment` as a dropdown (`dev`/`stage`/`prod`)
and `target-sha` as optional free text.

## 3. Composite actions — not built; steps are inlined instead

The original plan factored each step into a named composite action under
`.github/actions/` (table below, kept for reference). In the actual build, `deploy.yml`
and `rollback.yml` both inline every step directly rather than factoring out shared logic.
`rollback.yml`'s `configure-aws-credentials` step now duplicates `deploy.yml`'s (a third
occurrence, counting `render-manifest`) — genuinely the point where a composite action
would start paying for itself, but still not factored out, since each occurrence stays
three lines and the duplication hasn't caused a real bug yet. Revisit if a fourth
reusable workflow gets built, or if this step grows more complex.

Planned action names, if/when this gets factored out:

| Action | Inputs | Outputs | Notes |
|---|---|---|---|
| `build-python` | `build-command`, `lint-command`, `working-directory` | — | `actions/setup-python`, install, lint. No Docker. |
| `build-node` | `build-command`, `lint-command`, `working-directory` | — | `actions/setup-node`, install, lint. No Docker. |
| `lint-dockerfile` | `dockerfile-path` | `passed` | Runs `hadolint` against the consumer's Dockerfile. Fails on any error-level finding. |
| `docker-build-push` | `aws-region`, `docker-context`, `git-sha` | `image-location`, `image-digest` | Multi-stage build; currently uploads to S3 (see REQUIREMENTS.md §8), ECR once available. |
| `render-task-definition` | `app-name`, `environment`, `image-location`, `container-port`, `cpu`, `memory`, `log-group` | `task-def-json-path` | **Built, inlined in `render-manifest` (§2.1)**, not a separate action. Pure templating — no AWS API calls. `executionRoleArn` is a placeholder value, documented as required-before-registration. |
| `write-manifest-s3` | `s3-bucket`, `app-name`, `environment`, `image-location`, `image-digest`, `task-def-json-path` | `manifest-s3-key` | **Built, inlined in `render-manifest` (§2.1)**, not a separate action. Assembles manifest (see §5 schema) and uploads; maintains `current.json`. No separate rollback-history append — `rollback.yml` (§2.3) reads the manifest chain instead. |
| ~~`promote-artifact`~~ | — | — | **Obsolete.** Belonged to the retired artifact-copy promotion model (§2.2); the branch-rebuild SDLC has no promotion step to factor out. |
| `rollback-from-manifest` | `s3-bucket`, `app-name`, `environment`, `target-sha` (optional) | `restored-manifest-key` | **Built, inlined in `rollback.yml`'s `rollback` job (§2.3)**, not a separate action. Follows `previousManifestKey` (or a given `target-sha`) instead of a separate history structure; re-points `current.json`. |
| `record-deployment-cloudwatch` | `environment`, `app-name`, `event-type`, `cloudwatch-log-group` | — | Emits a custom metric and/or structured log entry. |

## 4. GitHub Environments and approval gates

Three GitHub Environments belong in **each consumer repo** (not in the framework repo):
`dev`, `stage`, `prod`. `stage`/`prod` are also now real **branches** in each repo (a
deliberate pivot — see §2.2), receiving PR merges as their trigger.

- `dev`: no required reviewers. Auto-triggered on push to the `dev` branch. Created and
  tested working for both `python-app` and `node-app`.
- `stage`: required reviewer(s) configured. Triggered by a PR merged into the `stage`
  branch. Created and tested working for both `python-app` and `node-app`.
- `prod`: required reviewer(s) configured. Triggered by a PR merged into the `prod`
  branch. Created and tested working for both `python-app` and `node-app`.

**Critical mechanic, corrected from the original spec:** GitHub Actions does not allow
`environment:` on a job that only has `uses:` (calls a reusable workflow) — `actionlint`
rejects it, and it's not in GitHub's documented list of supported keywords for that job
shape (`name`, `uses`, `with`, `secrets`, `needs`, `if`, `permissions`). The `environment:`
declaration has to live on the reusable workflow's *own* job — the one that actually has
`runs-on:` and does the AWS work. GitHub still resolves that environment against the
*calling* repository (that's how `secrets: inherit` and environment-scoped vars work at
all), so the mechanism holds; it's just declared in a different file than you'd expect:

```yaml
# In the consumer's caller workflow (deploy.yml) — no `environment:` here,
# just a detect-environment job resolving which name to pass:
jobs:
  detect-environment:
    if: |
      github.event_name == 'push' ||
      (github.event_name == 'pull_request' && github.event.pull_request.merged == true)
    outputs:
      environment: ${{ steps.detect.outputs.environment }}
    steps:
      - id: detect
        run: |
          if [[ "${GITHUB_REF_NAME}" == "dev" ]]; then
            echo "environment=dev" >> "$GITHUB_OUTPUT"
          elif [[ "${{ github.event.pull_request.base.ref }}" == "stage" ]]; then
            echo "environment=stage" >> "$GITHUB_OUTPUT"
          elif [[ "${{ github.event.pull_request.base.ref }}" == "prod" ]]; then
            echo "environment=prod" >> "$GITHUB_OUTPUT"
          fi

  deploy:
    needs: detect-environment
    permissions:
      id-token: write
      contents: read
    uses: loriamichaelj/aws-cicd-framework/.github/workflows/deploy.yml@dev
    with:
      environment: ${{ needs.detect-environment.outputs.environment }}
      ...
    secrets: inherit
```

```yaml
# Inside deploy.yml itself — the job that does the work declares it:
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    steps: ...
```

`secrets: inherit` combined with the `deploy` job's `environment:` is what allows
environment-scoped secrets (the shared role's ARN, per environment) to resolve correctly
inside the reusable workflow's steps. This is exactly what `deploy.yml`'s `deploy` job
(§2.1) and `rollback.yml`'s `rollback` job (§2.3) both do.

Because GitHub only mints the `environment:<env>` claim in the OIDC token when a job is
actually executing under that Environment's approval gate, this is also the mechanism that
makes IAM trust-policy scoping (§6) meaningful — approval isn't just a UI gate, it's a
precondition for the AWS role even being assumable.

**A second, related gotcha caught in real testing:** permissions cascade downward through
`uses:` calls and can only be narrowed, never widened. `deploy.yml`'s `deploy` job requests
`permissions: { id-token: write, contents: read }` at the job level — but that request is
only honored if the *calling* job also grants it. The consumer repos' caller jobs
originally declared no `permissions:` at all, which defaults to `id-token: none` and
silently clamps the nested job down to that, regardless of what the reusable workflow
itself asks for. GitHub surfaces this as a hard failure at dispatch time
(`startup_failure`, zero jobs created), not a runtime permission error inside a job —
e.g.: `Error calling workflow '.../deploy.yml@dev'. The nested job 'deploy' is requesting
'id-token: write', but is only allowed 'id-token: none'.` The fix: every caller job that
invokes a reusable workflow needing OIDC must also declare
`permissions: { id-token: write, contents: read }` itself — `permissions` is one of the
legal keys on a job that only has `uses:`. `rollback.yml`'s caller already has this, since
it was written after the gotcha was caught.

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
```

`_rollback-history/<app>/<environment>/` from the original plan was never built —
`rollback.yml` (§2.3) reads the manifest chain (each manifest's `previousManifestKey`)
instead of a separate history structure, so there's no bounded-list directory to maintain.

### `manifest.json` schema (built — see §2.1)

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

`image.uri` above shows the eventual ECR form; the actual built manifest holds the S3 key
instead (`<app-name>/<environment>/<git-sha>/image.tar.gz`) — see REQUIREMENTS.md §8.
`image.digest` holds a `sha256:` checksum of the saved tarball (computed in `deploy`,
passed to `render-manifest` as a job output) rather than a registry-assigned digest, since
there's no registry in this phase — same verification purpose, different source. Swap both
back to their ECR forms once that access exists; no other schema change needed.

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
        "repo:<owner>@<owner-id>/aws-cicd-demo-node-app@<repo-id>:environment:dev",
        "repo:<owner>@<owner-id>/aws-cicd-demo-python-app@<repo-id>:environment:stage",
        "repo:<owner>@<owner-id>/aws-cicd-demo-node-app@<repo-id>:environment:stage",
        "repo:<owner>@<owner-id>/aws-cicd-demo-python-app@<repo-id>:environment:prod",
        "repo:<owner>@<owner-id>/aws-cicd-demo-node-app@<repo-id>:environment:prod"
      ]
    }
  }
}
```

`dev`, `stage`, and `prod` trust entries exist for both demo repos, and all three
Environments (reviewer-gated objects, not just trust entries) are confirmed created and
tested working for both `python-app` and `node-app` — a real PR merge into each of
`stage`/`prod`, reviewer-gated, produced a real S3 upload. Adding another environment is
always two more list entries per repo, appended to this same statement — not a new role.

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
│       ├── deploy.yml              # built — build/test/deploy/notify, both languages,
│       │                           # environment-agnostic (§2.1)
│       └── rollback.yml            # built — re-points current.json via manifest chain
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

No `.github/actions/` directory — composite actions aren't built yet (§3). No
`promote.yml` — retired (§2.2).

### `aws-cicd-demo-python-app` / `aws-cicd-demo-node-app`

```
aws-cicd-demo-<lang>-app/           # dev/stage/prod branches — main is README-only
├── .github/workflows/deploy.yml    # thin caller: push-to-dev, PR-merge to stage/prod
├── .github/workflows/rollback.yml  # thin caller: workflow_dispatch, manual rollback
├── Dockerfile                      # multi-stage, meets discipline checklist
├── .dockerignore
├── src/ (or app.py / index.js)     # no-op entrypoint, one exported function for tests
├── tests/ | test/                  # one unit test exercising that function
├── requirements.txt | package.json # one real dependency
└── README.md
```

Branches: `main` (default — README-only signpost, not the deliverable), `dev`, `stage`,
`prod` — the latter two real branches, not just GitHub Environments (§4).

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
