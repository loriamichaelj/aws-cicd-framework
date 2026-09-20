# Presentation Notes — Internal Team Handoff

Speaker notes for a live walkthrough with teammates who'd maintain or extend this system.
Structured as **do this, then say this** — assumes you're actually running the pipeline
live, not just describing it. Ends with a troubleshooting cheat-sheet for gotchas you'll
hit if you touch this later.

---

## Before you start

Have open: this repo (`aws-cicd-framework`), one demo repo (`aws-cicd-demo-python-app`
is the more thoroughly-tested one), and the AWS Console on S3 + CloudWatch Logs.

## 1. Orient on the repo shape

**Do:** Open `aws-cicd-framework`'s `.github/workflows/` and one demo repo's.

**Say:** "One framework repo holds the actual pipeline logic as reusable
`workflow_call` targets — `deploy.yml`, `rollback.yml`. Each consumer repo has a thin
caller, maybe 30 lines, that just says 'run the framework's pipeline with my app name and
language.' Nobody copies pipeline code between repos — everyone references
`aws-cicd-framework@v1`."

**Do:** Open the demo repo's caller `deploy.yml`, point at the `uses:` line.

**Say:** "This `@v1` is a floating tag, not the framework's live branch. If I change the
framework's `dev` branch right now, nothing here changes until I actually cut a new
release and move that tag."

## 2. Trigger a real deploy

**Do:** `git commit --allow-empty -m "demo" && git push origin dev` in the demo repo (or
just point at a recent run in the Actions tab if you don't want to generate noise).

**Say:** "Push to `dev` — build, test, hadolint, then it assumes an AWS role via OIDC, no
stored credentials anywhere, builds the image, runs it as a smoke test, saves it, uploads
to S3."

**Do:** Watch the run. Point out the job sequence: `detect-environment` → `build`/`test`
(parallel) → `deploy` → `render-manifest` → `notify`.

**Say:** "`render-manifest` templates an ECS task definition and writes a deployment
manifest — git SHA, image location, a digest, who triggered it, and a pointer back to
whatever was deployed before this."

## 3. Show the actual S3 state

**Do:** In the AWS Console, navigate to
`loria-aws-cicd-artifacts-<account-id>/python-app/dev/`.

**Say:** "Every build lands here under its own git SHA. `current.json` always points at
the latest — that's what rollback reads."

## 4. Promote to stage — show the real gate

**Do:** `gh pr create --base stage --head dev ...` then merge it (or just show a past
PR).

**Say:** "Merging into `stage` is what triggers that environment's deploy — a whole
independent rebuild, not a copy of the `dev` artifact. It's gated: the job won't run until
`stage`'s required reviewer approves. That's not just a GitHub UI thing — until it's
approved, GitHub literally won't mint the OIDC claim the AWS role's trust policy checks
for. No approval, no way to even get credentials."

**Do:** If a reviewer is present, have them approve it live. Watch it deploy.

## 5. Roll it back

**Do:** `gh workflow run rollback.yml -f environment=dev` (or `stage`, if you want to show
the gate again).

**Say:** "This reads `current.json`, follows its `previousManifestKey` back one deploy,
and re-points `current.json` there. No separate rollback-history structure — the manifest
chain itself is already a linked-list history."

**Do:** Show the run log — the `download:`/`upload:` lines are the actual proof it moved
the pointer, not just a green checkmark.

## 6. Show the CloudWatch event

**Do:** CloudWatch Logs → `/aws-cicd/dev` → the app's log stream.

**Say:** "Every deploy and rollback writes a structured JSON event here — event type, app,
environment, result, who triggered it, the run ID. This is the audit trail."

## 7. Point at the docs

**Say:** "`docs/REQUIREMENTS.md` and `docs/DESIGN.md` are the actual spec and
implementation record — including every place the real build diverged from the original
plan, and why. If something here looks surprising, check `REQUIREMENTS.md` §8 first —
it's probably a documented, deliberate amendment, not an oversight."

---

## Troubleshooting cheat-sheet — gotchas you'll hit if you extend this

**"My new reusable workflow's job can't get an OIDC token."**
Check the *caller's* job has `permissions: { id-token: write, contents: read }` too.
Permissions only narrow across a `uses:` boundary, never widen — the callee can ask for
`id-token: write` all it wants, but if the caller didn't grant it, it's clamped to
`id-token: none`. Shows up as `startup_failure` with zero jobs run, not a normal step
failure.

**"`environment:` isn't resolving / my environment-scoped vars are empty."**
`environment:` is not a legal key on a job that only has `uses:`. It has to go on the
*called* workflow's own job (the one with `runs-on:`). `actionlint` catches this if you
run it — do that before pushing.

**"My new `workflow_dispatch` workflow doesn't show up to run manually."**
It has to exist on the repo's **default branch** (`main` here) to be
discoverable/dispatchable at all, even if you then choose to run a different branch's
version of it. That's why `main` in both demo repos carries `.github/workflows/` despite
otherwise being a README-only signpost branch.

**"An S3 copy step is failing with AccessDenied on GetObjectTagging."**
The AWS CLI's `s3 cp` tries to preserve object tags by default. Add
`s3:GetObjectTagging`/`s3:PutObjectTagging` to whatever role is doing the copy.

**"I'm trying to find which commit a `pull_request`-triggered run actually deployed, and
the runs API's `head_sha` doesn't match."**
Don't trust `head_sha` from `gh api .../runs/{id}` for `pull_request` events — pull the
real SHA from the job's own log (e.g. the S3 upload path), not the runs API.

**"I want to add a fourth environment."**
No new branch model needed. Create the GitHub Environment, add its `AWS_DEPLOY_ROLE_ARN`/
`S3_BUCKET` variables, add a trust-policy `sub` entry for it on the shared role, and (if
it should deploy via push/PR) extend the caller's trigger + `detect-environment` logic.
