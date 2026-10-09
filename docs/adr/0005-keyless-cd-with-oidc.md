# ADR 0005: CD assumes an AWS role through GitHub OIDC; SSH opens only during a deploy

- Status: accepted

## Context
CD has to push to ECR and reach the host over SSH. Long-lived AWS keys in GitHub secrets leak and outlive the
playground session; port 22 open to all GitHub runner addresses is open to the internet.

## Decision
Terraform `registry` creates an OIDC provider and the role `ems-github-deploy`, assumable only by this repository.
The role may push to `ems-app` and add/remove ingress rules on security groups tagged `Project=ems`. Each deploy adds
a /32 SSH rule for the runner's address and removes it in an `always()` step. The repository holds two secrets:
`EMS_HOST` and `EMS_SSH_KEY`; everything else is a non-secret variable.

## Consequences
+ no AWS key in GitHub; + SSH is closed except during a deploy; - the playground denies inline role policies and
policy tags, so policies are managed policies created through an untagged provider alias (docs/terraform/playground-quirks.md).
