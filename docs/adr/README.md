# Architecture decision records

A decision that is hard to reverse gets one short file here **when it is made**: the context, the decision and what
follows from it. An ADR is never edited afterwards; a later decision that replaces it gets a new number and says so.

| # | Decision | Phase |
|---|---|---|
| 0001 | Flask instead of FastAPI | 11 |
| 0002 | Two versions: Full Local and Playground | 11 |

## Template
```
# ADR NNNN: <decision in a few words>

- Status: proposed | accepted | superseded by NNNN

## Context
<what forced a decision>

## Decision
<what was decided>

## Consequences
+ <what gets easier>; - <what gets harder>
```
