# Drift (Phase 20, game day in Phase 25)

**Drift** = the real infrastructure no longer matches the code + state, because someone changed it outside Terraform
(console click, AWS CLI, another tool, AWS itself).

## Detecting it: `plan -detailed-exitcode`

```bash
terraform -chdir=terraform/envs/dev plan -detailed-exitcode -input=false -lock=false
echo $?
```

| Exit code | Meaning |
|---|---|
| 0 | no changes: AWS matches the code |
| 1 | error (credentials, syntax, provider) |
| 2 | changes pending: **drift** (or un-applied code changes) |

`plan` refreshes every resource from AWS first, then compares. A tag added in the console shows as
`~ tags = { - "ChaosDrift" = "..." }` - Terraform wants to remove it again. `-lock=false` makes the check read-only
and safe to run while nobody applies. Wrappers:

- `scripts/aws/aws-playground.sh drift` - exits 2 on drift
- `scripts/chaos/terraform-drift.sh --inject | --detect | --revert | --dry-run` - adds a tag to the ALB security
  group with the AWS CLI, proves the plan exits 2, removes it, proves it exits 0 (see `docs/sre/game-days.md`)

A scheduled CI job running the same plan with read-only credentials would turn this into an alert.

## Resolving it

| Situation | Action |
|---|---|
| The manual change was wrong (most cases) | `terraform apply` puts the infrastructure back to the code, after reading the plan |
| The manual change was right (hotfix during an incident) | put the change into the code, `plan` must then show no changes, commit |
| A resource was deleted by hand | `plan` shows `+ create`; apply recreates it (data inside it is gone) |
| A resource was created by hand and should be managed | an `import` block, reviewed in a plan |

**Never** use `terraform apply -refresh-only` to "fix" drift: it writes the manual change *into the state* and the
code is then wrong without anyone noticing.

## Drift we expect and ignore on purpose

`modules/host` has `lifecycle { ignore_changes = [ami] }`: a newer Amazon Linux AMI must not replace the running
host on the next plan. Rolling the AMI is a deliberate change.
