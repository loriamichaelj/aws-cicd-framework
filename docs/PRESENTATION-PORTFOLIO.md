# Presentation Notes — Portfolio / Interview Walkthrough

Narrative notes for talking through `aws-cicd-framework` in an interview or portfolio
review. Prose you can read from or paraphrase live — not tied to a slide count.

---

## The one-line pitch

A reusable, multi-environment CI/CD framework — GitHub Actions, Docker, AWS — that two
independent demo applications (Python and Node.js) consume by reference, not by copying
pipeline code. It demonstrates release engineering discipline: containerization
standards, environment promotion, approval gates, rollback, least-privilege IAM via OIDC,
and deployment observability — released as `v1.0.0`, validated end-to-end with real runs,
not just written and assumed to work.

## What it's *not*

Deliberately not a production system serving traffic. The demo apps have no functional
logic — they exist purely to give the pipeline something real to build, containerize, and
push. That's on purpose: the thing being demonstrated is the release engineering
machinery, not application code. Worth saying explicitly, since it heads off the "why is
the app so simple" question before it's asked.

## Architecture, in one breath

One framework repo holds the reusable pipeline (`deploy.yml`, `rollback.yml`) as
`workflow_call` targets. Two consumer repos each have a thin caller — a few lines that
say "run the framework's pipeline with my app name and language." Push to `dev`
auto-deploys; merging a PR into `stage` or `prod` deploys those, gated by required
reviewers. No long-lived AWS credentials anywhere — authentication is GitHub OIDC,
federated to a shared IAM role whose trust policy only accepts tokens minted for a
specific repo executing under a specific GitHub Environment. The approval gate isn't a UI
formality — it's a precondition for the AWS role even being assumable.

## The part worth spending the most time on: this got rebuilt mid-project, on purpose

This is the strongest interview material, because it shows judgment under real
constraints, not just execution of a spec.

The original design promoted a single built artifact forward — build once on `dev`, then
*copy* that exact image (S3-to-S3, byte-identical) to `stage` and `prod` rather than
rebuilding. That's the harder, more sophisticated model, and **it was built and proven
working end-to-end** — a real `promote.yml` workflow, a real dispatched run, verified by
comparing the actual object at the new S3 key.

Then it was deliberately retired in favor of a simpler, more conventional branch-based
model — `stage`/`prod` as real branches, each independently rebuilding on PR merge — to
match a specific reference pattern requested mid-build. Worth naming directly: this was a
trade-off made with eyes open, not a walk-back from something broken. The "no rebuild"
guarantee was given up; the branch-based model is what most teams actually run. Both are
legitimate. Being able to say precisely what was traded away, and why, is the point.

## Real bugs found by actually running it — not hypothetical

Five genuine platform gotchas surfaced only by triggering real pipeline runs and reading
real failure logs, not by code review:

1. **`environment:` on the wrong job.** GitHub Actions doesn't allow the `environment:`
   key on a job that only calls a reusable workflow (`uses:`) — it has to live on the
   *called* workflow's own job. Caught by `actionlint`, not by GitHub's runtime (which
   would have just silently failed the OIDC claim).
2. **Permission cascade through `uses:`.** A reusable workflow's job can request
   `id-token: write`, but that's only honored if the *calling* job also grants it —
   permissions only narrow across a `uses:` boundary, never widen. Missing this produces
   a hard `startup_failure` before any job even runs, with a specific but easy-to-miss
   error message.
3. **S3 object tagging permission gap.** A promotion step doing an S3-to-S3 copy failed
   on `s3:GetObjectTagging` — the AWS CLI's `cp` command tries to preserve tags by
   default, which needs a permission nobody thinks to grant up front.
4. **`workflow_dispatch` requires the default branch.** A manually-triggered workflow
   (`rollback.yml`) can't be discovered or dispatched via the UI, API, or CLI unless its
   file exists on the repo's default branch — even though you then choose which branch's
   *version* of it actually runs. Not obvious, not documented anywhere prominent.
5. **The GitHub Actions runs API lies about which commit actually ran**, for
   `pull_request`-triggered workflows specifically — `head_sha` from the API didn't match
   the SHA the workflow itself used internally. Found because a rollback dispatch failed
   looking for a manifest that "should" have existed.

Every one of these is a real, citable, specific story — not "I debugged some CI issues."

## How "done" is proven, not asserted

Every claim of "this works" in this project's documentation is backed by something
concrete: an actual `upload:` confirmation from an S3 copy, an actual `nextSequenceToken`
from a CloudWatch API response, an actual download-then-upload log sequence from a
rollback run. The habit worth naming: distrust a green checkmark on its own, go find the
underlying API response that proves the *specific* thing actually happened.

## Where it landed

`v1.0.0` tagged and released, with a floating `v1` tag both demo repos now reference
instead of tracking the framework's live `dev` branch — meaning future framework changes
only reach them once a new version is deliberately released, which is the actual
discipline this project sets out to demonstrate, exercised for real (a `v1.0.1` docs
patch, and the floating tag moved forward to prove that mechanism too). Both apps
validated across all three environments: build, test, hadolint lint, containerize,
manifest/task-definition rendering, CloudWatch event recording, and manual rollback.

## What's deliberately not built, and why that's a feature

No ECS cluster, no running service, no container ever actually serves traffic in this
phase. That's scoped out on purpose — the manifest schema and rendered task definitions
are shaped so that phase can be added later without a redesign, but building it now would
add infrastructure cost and networking surface without strengthening what's actually
being demonstrated (release *engineering*, not a runtime). Similarly, ECR is the intended
image registry, but the shared AWS account doesn't currently grant that access — so images
are stored in S3 as `docker save` tarballs instead, a documented, one-step-to-reverse
substitution, not a design compromise. Knowing exactly where the edges of scope are, and
being able to explain why, is itself part of what's being demonstrated.
