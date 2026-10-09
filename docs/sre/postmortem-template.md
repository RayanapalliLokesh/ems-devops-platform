# Postmortem: <title>

Blameless: describe what the system and the process allowed, not who made a mistake. Copy to
`docs/sre/postmortems/YYYY-MM-<slug>.md`.

| Field | Value |
|---|---|
| Date | YYYY-MM-DD |
| Authors | |
| Status | draft / reviewed / action items done |
| Severity | page / ticket |
| Duration | start -> resolved (UTC), total minutes |
| Time to detect / mitigate | minutes from start to alert / from alert to mitigation |
| SLO impact | availability: X failed requests = Y% of the weekly budget; latency: ... |
| Incident record | link to the incident issue / file |

## Summary

Two or three sentences: what broke, what users saw, how it was fixed.

## Impact

Users affected, requests failed, budget spent (with the PromQL used to compute it), data lost (yes/no).

## Timeline (UTC)

| Time | Event |
|---|---|
| | trigger (deploy, change, load) |
| | first bad data point |
| | alert fired |
| | acknowledged |
| | mitigation applied |
| | resolved |

## Root cause and trigger

The trigger (what changed) and the root cause (why that change could hurt). Use "5 whys" until you reach
something the team can change.

## Detection

Did the right alert fire? Fast enough? Was anything noisy or missing? Did the runbook match reality?

## Response

What helped, what slowed us down (access, missing commands, unclear dashboards).

## What went well

-

## What went wrong

-

## Where we got lucky

-

## Action items

| # | Action | Type (prevent / detect / mitigate / process) | Priority | Owner | Ticket | Status |
|---|---|---|---|---|---|---|
| 1 | | | P1 | | | open |

## Lessons

What to remember next time; link to runbook or doc changes made because of this incident.
