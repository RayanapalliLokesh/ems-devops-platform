# Phase 11 - Baseline and Capstone Architecture

Builds on Phase 10. No new feature: this phase **freezes the application as the baseline** and writes down what
will be built on top of it, for which job, in which order, and how the repository will show it. Every later phase
is measured against these five pages.

| Added | Answers the question |
|---|---|
| `docs/capstone/target-role.md` | which job is this project evidence for, and which skill does each focus area prove? |
| `docs/capstone/scope.md` | what is built, what is left out, which constraints shape the design, when is a phase done? |
| `docs/capstone/architecture.md` | what does the finished platform look like, and in which order do the layers arrive? |
| `docs/capstone/repo-structure.md` | which folder holds what, and in which phase does it appear? |
| `docs/capstone/milestones.md` | twelve milestones with an exit check each; the first three planned to the task level |
| `docs/adr/` | decisions that are hard to reverse: Flask (0001), two versions from one codebase (0002) |
| `docs/learning-log/` | one page per phase in your own words; it becomes the release notes |
| `.github/ISSUE_TEMPLATE/phase.md`, `pull_request_template.md` | the same structure for every phase |
| `CHANGELOG.md`, `Makefile` | one entry per phase; `make venv`, `make run`, `make test` |

## Removed
`.env` is no longer in the repository. It was a copy of `.env.example` with a placeholder secret, but a file that
is listed in `.gitignore` and committed anyway teaches the wrong habit. Create it yourself: `cp .env.example .env`.

## Run it
```bash
make venv && source venv/bin/activate
cp .env.example .env
make run                         # http://127.0.0.1:5000/health
```

## Tests
```bash
make test                        # 20 tests (17 from Phase 10 + 3 that check the plan)
```
`tests/test_capstone_plan.py` stays in the project until the end. In every phase it compares
`docs/capstone/repo-structure.md` with the working tree: a folder must exist from the phase the plan names, and
must not exist earlier.

## The twelve focus areas
| # | Focus | Phases |
|---|---|---|
| 1 | Baseline + capstone architecture | 0-11 |
| 2 | Linux troubleshooting review | 12 |
| 3 | Networking + AWS VPC | 13-14 |
| 4 | AWS compute + load balancing | 15-16 |
| 5 | Docker + ECR | 17 |
| 6 | CI/CD | 18-19 |
| 7 | Terraform foundations | 20 |
| 8 | Terraform modules + environments | 21 |
| 9 | Kubernetes fundamentals | 22 |
| 10 | EKS + troubleshooting | 23 |
| 11 | Observability + SRE | 24-25 |
| 12 | Capstone + interviews | 26-30 |

## Not in this phase yet
The development server still listens on every network interface and stops when you close the terminal. Phase 12
turns the application into a Linux service and gives you the tools to find out why a server misbehaves.
