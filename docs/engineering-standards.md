# Engineering Standards

> **Reusable document.** Defines the default working standards for any project — versioning, GitOps, IaC, and security. Imported by the project's `CLAUDE.md` via `@docs/engineering-standards.md`, so Claude Code loads these standards automatically in every session. Project-specific details (architecture, phases, state) **do not** belong in this file — they live in `CLAUDE.md`.

## 1. Philosophy

- **Official documentation is the primary source.** Every tool or framework in use is adopted and operated according to its **official documentation and best-practice guides** — this applies to development (branch organization, commits, repository root layout) as well as GitOps, Terraform, Kubernetes, and CI/CD (e.g., HashiCorp's Terraform Style Guide, Argo CD Best Practices, Kubernetes Configuration Best Practices, the Conventional Commits spec). When in doubt about "the right way," consult the tool's current documentation before implementing.
- **Community adoption guides tool choice.** When selecting tools, weigh current market practice; in the cloud-native ecosystem, the maturity reference is the CNCF (prefer *graduated* or *incubating* projects; *sandbox* only with justification).
- **Deviations are a documented exception.** When departing from market standards makes sense, the decision becomes a short ADR explaining the trade-off.
- **Convention over improvisation.** If an established standard exists (Conventional Commits, SemVer, recommended Kubernetes labels), it's adopted — no inventing a homegrown equivalent.

## 2. Languages

| Where | Language |
| ---- | ------ |
| Commits, branches, code, identifiers, code comments | **English** (the universal development standard) |
| **Names of every directory and file** in the repository | **English**, no exceptions — e.g., `docs/000-motivation.md`, `docs/adr/`, `docs/runbooks/` |
| **Content** of files under `docs/`, `README.md`, `CLAUDE.md`, and general communication | **English** |

> A project may deviate from this (e.g., writing documentation in the author's own language) when that better serves comprehension during development — record that choice explicitly in the project's own `CLAUDE.md` rather than assuming it silently.

> **Attention — a common ambiguity:** variable/output `description`s (Terraform), comments inside Kubernetes/Helm manifests, and any comment embedded in a code file (`.tf`, `.yaml`, `.sh`, `.py`, etc.) count as **code**, not "`docs/` content" — even when they're explanatory prose. They stay in **English**, always, regardless of where the file lives in the repository.

> **Code comments:** short, direct, one line whenever possible. They only explain what isn't obvious from the code itself (the "why," not the "what"). No paragraphs, no repeating what's already documented in `docs/adr/` or `docs/runbooks/` — link instead of re-explaining.

## 3. Branching strategy

**Trunk-based development** with short-lived branches — the community-standard model for CI/CD and GitOps workflows:

- `main` is the only long-lived branch and must **always be sound and deployable**. In GitOps, this is non-negotiable: `main` is what the cluster reconciles.
- All work starts on a short branch off `main`, integrated via Pull Request, and deleted after merge.
- Naming: `<type>/<kebab-case-description>`, using the same types as commits.
  - `feat/vpc-module`, `fix/nat-route-table`, `docs/adr-dns-zone`, `chore/pin-provider-versions`
- Branches live for **days, not weeks**. Large work is sliced into small, integrable deliverables.
- Small, focused PRs: one purpose per PR, with the `terraform plan` (or equivalent diff) reviewed in the description when applicable.

## 4. Commits — Conventional Commits

Format: `<type>(<scope>): <description>` — imperative mood, lowercase, no trailing period.

**Types:** `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`, `build`, `perf`, `revert`.

**Scopes:** reflect the repository's areas (e.g., `terraform`, `gitops`, `app`, `load`, `adr`).

```
feat(terraform): add vpc module with public and private subnets
fix(gitops): correct argocd sync policy for platform apps
docs(adr): record decision to persist route53 hosted zone
chore(terraform): pin aws provider to ~> 5.0
ci: add terraform fmt and validate checks
feat(app)!: change hls segment duration to 4s
```

- **Breaking changes:** `!` after the type/scope, plus a `BREAKING CHANGE:` footer describing the impact.
- **Atomic commits:** each commit represents one logical change that keeps the repository sound.
- **Versioning:** [SemVer](https://semver.org/) with annotated tags (`v1.2.0`) for milestones/releases. Commit types feed versioning (`fix` → patch, `feat` → minor, `!` → major).

## 5. GitOps

Follows the four [OpenGitOps](https://opengitops.dev/) principles (CNCF):

1. **Declarative:** the system's entire desired state is expressed declaratively (manifests, not imperative scripts).
2. **Versioned and immutable:** the desired state lives in Git — the single source of truth, with full history.
3. **Pulled automatically:** agents (e.g., Argo CD) pull state from Git; nobody "pushes" changes to the cluster.
4. **Continuously reconciled:** the agent observes and corrects drift between actual and declared state.

Practical consequences:

- **Manual `kubectl apply`/`kubectl edit` is forbidden** on any GitOps-managed resource. An emergency hand-made change must be codified and committed immediately afterward.
- **Rollback = `git revert`.** Never undo in the cluster what Git still declares.
- Manifest structure via **Kustomize** (base + overlays) or Helm; one directory per domain (platform vs. application).

## 6. Infrastructure as code (Terraform)

- **Remote state with locking** (e.g., versioned S3), created in a separate bootstrap. `*.tfstate` never in Git.
- **Mandatory flow:** `terraform fmt` → `validate` → lint (`tflint`) → **human-reviewed** `plan` → `apply`. Never `apply -auto-approve` on new resources.
- **Destructive commands always preceded by a dry-run:** `terraform plan -destroy` reviewed before any `destroy`.
- **Pinned versions:** explicit Terraform `required_version` and provider constraints (`~>`).
- **Small, cohesive modules**, with typed `variables` carrying `description`s, and documented `outputs`. Prefer writing your own modules when the goal is learning; use community modules (official registry) when the goal is productivity — record the decision in an ADR if relevant.
- **No magic values:** everything parameterized; standardized resource names and tags (project, environment, managed-by).

## 7. Kubernetes

- Resources always with **requests/limits**, **liveness/readiness probes**, and recommended labels (`app.kubernetes.io/name`, `app.kubernetes.io/part-of`, `app.kubernetes.io/managed-by`).
- Images with an **immutable tag** (never `latest` in versioned manifests).
- Namespaces per domain (platform vs. application); least-privilege RBAC.

## 8. Security

- **No secrets in Git** — never: credentials, tokens, kubeconfig, sensitive `*.tfvars`, Terraform state. A proper `.gitignore` is part of the repository's first commit.
- Secrets via appropriate mechanisms (local environment variables, secret managers, External Secrets/SOPS when the project requires it).
- **Least privilege** in IAM and RBAC; on AWS, prefer IRSA over static credentials in pods.
- Pipeline scanners when CI exists: `gitleaks` (secrets), `trivy` (images/IaC).

## 9. Documentation

- **README** answers: what it is, why it exists, how to run it in < 5 minutes.
- **ADRs** (`docs/adr/NNN-title.md`): short — context, decision, consequences. Every relevant architecture decision or standard deviation gets one.
- **Runbooks** (`docs/runbooks/`): step-by-step operational procedures (stand up, tear down, respond to an incident).
- Documentation is born **together** with the change, in the same PR — not after.

## 10. Automation and CI

- Automated checks (fmt, lint, validate, tests) run **before merge** — the human reviews intent, the machine reviews form.
- Anything run manually more than twice is a candidate for automation (a versioned script or pipeline).

## 11. Post-apply functional validation

A clean `terraform apply` and a resource with the right attributes prove it **exists as expected** — not that it **works**. Every relevant infrastructure deliverable (network, cluster, CDN, etc.) gets a functional test that exercises real behavior, not just an attribute read via `describe-*`.

- The test lives as a versioned script (`scripts/validate-*.sh`, next to the Terraform module it validates) plus a runbook at `docs/runbooks/validate-*.md` explaining what, why, and how to read the result.
- Tests are **ephemeral and self-cleaning**: any resource created just for the test (instance, workload) is destroyed at the end, even on failure — scripts that create resources use an `EXIT` cleanup `trap`, without exception.
- Each project phase's completion criterion (see `CLAUDE.md`) includes the corresponding functional validation, not just a clean `apply`.
