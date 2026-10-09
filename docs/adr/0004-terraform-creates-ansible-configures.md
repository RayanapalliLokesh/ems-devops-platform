# ADR 0004: Terraform creates the machine, Ansible configures it

- Status: accepted (replaces the AWS CLI scripts of Phases 14-15 and the shell installer of Phase 12)

## Context
The CLI scripts had no state: a second run created duplicates and a teardown had to be checked by hand. The shell
installer could not say whether a host matched the expected state.

## Decision
Terraform (remote state in S3, lock in DynamoDB) owns every AWS resource and writes the Ansible inventory as its only
hand-over. Ansible owns everything inside the host (Docker, the stack, secrets, backups). Neither reaches into the other's area.

## Consequences
+ `terraform plan` shows drift, a second Ansible run reports `changed=0`; + the hand-over is one generated file;
- two tools to learn; - user data stays minimal on purpose, so a host is not usable until Ansible has run.
