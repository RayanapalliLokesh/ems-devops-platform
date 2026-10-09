# Incident: <short title>

Copy to an issue (label `incident`) or `docs/sre/incidents/YYYY-MM-DD-<slug>.md` as soon as an incident is
declared. Keep it updated while working; it becomes the timeline of the postmortem.

| Field | Value |
|---|---|
| Status | investigating / mitigated / resolved |
| Severity | page / ticket |
| Started (UTC) | YYYY-MM-DD HH:MM (first bad data point, not the alert) |
| Detected (UTC) | HH:MM - by alert `<AlertName>` / user report / CloudWatch alarm |
| Mitigated (UTC) | HH:MM |
| Resolved (UTC) | HH:MM |
| Incident lead | name |
| Environment | dev (EC2 Compose) / k8s |
| Version running | `curl -s http://$ALB/health \| jq -r .version` |
| Runbook used | docs/runbooks/<AlertName>.md |

## Impact (update as it becomes clear)

- Who / what is affected:
- Error ratio / latency at worst: (`ems:slo_errors:ratio_rate5m`, p95)
- Budget spent so far: (see [error-budget-policy.md](error-budget-policy.md))

## Current hypothesis

-

## Timeline (UTC, newest last; facts and actions, not opinions)

| Time | What happened / what was done | By |
|---|---|---|
| HH:MM | alert `<AlertName>` fired | Alertmanager |
| HH:MM | acknowledged | |
| HH:MM | | |

## Evidence

- Grafana panel links / screenshots:
- Example request IDs and trace IDs:
- Log excerpts (`docker logs ... | jq ...`):

## Mitigation steps taken

- [ ] e.g. rolled back to `<tag>` with `ansible/playbooks/rollback.yml`
- [ ] verified: `curl http://$ALB/health` 200, burn-rate alert resolved

## Communication

| Time | To | Message |
|---|---|---|
| | | |

## Follow-up

- [ ] Postmortem: docs/sre/postmortems/YYYY-MM-<slug>.md (due within 5 working days)
- [ ] Runbook updated if it was wrong or incomplete
