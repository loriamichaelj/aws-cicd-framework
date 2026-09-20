# Presentation Notes — Technical Talk

Slide-by-slide outline for a conference-style talk. Each `##` is one slide; bullets are
what goes on it. Build actual slides from this.

---

## 1. Title

`aws-cicd-framework` — a reusable multi-environment CI/CD pipeline, and everything that
broke building it

- GitHub Actions · Docker · AWS · OIDC
- Subtitle: "What actually failed when I ran it for real"

## 2. The problem statement

- Demonstrate real release-engineering discipline, not a toy pipeline
- Two independent consumer apps (Python, Node.js) must consume *one* pipeline by
  reference — no copy-pasted workflow files
- Constraints: shared/locked-down AWS account, limited IAM, no ECR access, requirements
  changed mid-build

## 3. Architecture overview (diagram slide)

- One framework repo: reusable `workflow_call` targets (`deploy.yml`, `rollback.yml`)
- Two consumer repos: thin callers, a few lines each
- `push` → `dev` auto-deploys; PR-merge → `stage`/`prod`, reviewer-gated
- No long-lived credentials — GitHub OIDC → one shared IAM role, trust-scoped per
  repo+environment

## 4. Design decision #1 — one workflow, not one per language

- Originally spec'd as two near-identical files (`pipeline-python.yml`,
  `pipeline-node.yml`)
- Collapsed to one `deploy.yml`, parameterized by a `language` input
- Trade-off named explicitly: simpler surface area vs. strict "no shared branching"
  purity

## 5. Design decision #2 — the promotion model, built twice

- **V1 of the idea:** build once on `dev`, promote the *same* artifact forward
  (S3-to-S3 copy, byte-identical, no rebuild) — genuinely harder to get right
- Built. Tested. Proven working end-to-end with a real dispatched run.
- **Then deliberately retired** in favor of a branch-based model — `stage`/`prod` as real
  branches, independent rebuild on PR merge — to match a specific reference pattern
- Both are legitimate CI/CD philosophies. This is the trade-off, stated plainly, not
  hidden.

## 6. Design decision #3 — least-privilege IAM without owning the account

- No permission to create IAM roles or an OIDC provider in this account
- Used a **pre-existing shared role** instead — trust policy scoped per repo+environment
  via immutable subject claims (`repo:<owner>@<id>/<repo>@<id>:environment:<env>`)
- The approval gate is an AWS *precondition*, not a UI checkbox: GitHub only mints that
  OIDC claim once a job is genuinely executing under an approved Environment

## 7. Five real bugs, found by running it — not by review

One slide per bug, or one dense slide with all five as a table:

| # | Bug | Where it showed up |
|---|---|---|
| 1 | `environment:` on the wrong job (must be on the *called* workflow, not the caller) | Caught by `actionlint` |
| 2 | Permissions only narrow across `uses:`, never widen — caller must also grant `id-token: write` | `startup_failure`, zero jobs run |
| 3 | S3 copy needs `s3:GetObjectTagging` — the CLI tries to preserve tags by default | `AccessDenied` mid-copy |
| 4 | `workflow_dispatch` workflows must exist on the default branch to be dispatchable at all | Workflow invisible to `gh`/API/UI |
| 5 | GitHub's runs API reports the wrong `head_sha` for `pull_request`-triggered runs | Rollback couldn't find a manifest that existed |

- Callout: every one of these came from an actual failed run, read from the actual log —
  not predicted in advance

## 8. Proof over assertion

- Every "this works" claim in the docs is backed by a specific API response, not a green
  checkmark:
  - S3 `upload:` confirmation lines
  - CloudWatch `nextSequenceToken` in the raw API response
  - Rollback's own download-then-upload log sequence
- The habit: distrust the checkmark, go find the underlying evidence

## 9. Live demo transition

- (Switch to terminal / GitHub UI — see `PRESENTATION-HANDOFF.md` for the run-through)
- Suggested beats: trigger a `dev` deploy → show the S3 manifest → merge a promotion PR
  → show the approval gate → dispatch a rollback → show the CloudWatch event

## 10. Where it landed

- `v1.0.0` released, floating `v1` tag
- Both consumer repos switched from tracking `dev` live to referencing `@v1` — validated
  with real runs on every branch
- `v1.0.1` cut later as a docs-only patch — exercising the "move the floating tag forward"
  mechanic for real, not just describing it

## 11. What's deliberately out of scope

- No ECS, no running service, no container ever serves traffic this phase
- Manifest schema and rendered task definitions are shaped so that phase drops in without
  a redesign later
- ECR is the intended target; S3 is a documented, reversible substitute given current
  account access

## 12. Takeaways

- A "should work" pipeline and a "proven working" pipeline are different claims — this
  project only makes the second one, and only after checking
- Constraints (locked-down account, mid-build requirement changes) aren't obstacles to
  route around quietly — they're worth naming as design inputs
- Reusable workflows have sharp edges GitHub doesn't surface until you actually run them

## 13. Q&A
