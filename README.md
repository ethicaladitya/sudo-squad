# sudo-squad

**A dev team of Claude Code subagents that plan, build, test, review and secure changes in any website or app.**

You give the project-manager a goal, or point it at your tracker. It hands the work to a developer, a tester, a
code reviewer and a security analyst one at a time, sends their findings back for fixes, and reports the
finished work back to the tracker. A WordPress specialist covers the WordPress side.

```
ceo ──> project-manager ──> developer | wordpress
                        ──> tester
                        ──> code-reviewer + security-analyst
             (fix loop: findings → developer → re-check, max 2 rounds)
```

| Agent | Model | Job |
|---|---|---|
| `ceo` | Opus | Decides what to do next and why. Risky calls (money, credentials, DNS, destructive changes) become questions for you |
| `project-manager` | Sonnet | Takes the next task from Asana, a tasks file or GitHub issues, or a goal you give it. Sizes the task, delegates in sequence, loops fixes, writes the result back |
| `developer` | Sonnet | Builds on a named branch with a test. Never pushes, merges or deploys unless your project allows it |
| `wordpress` | Opus | Changes WordPress sites safely: verified backups, `wp eval-file` traps, SEO plugins, cache layers, live verification |
| `tester` | Sonnet | Runs the tests and the real app against the acceptance criteria. PASS/FAIL with proof |
| `code-reviewer` | Opus | Read-only correctness review. APPROVE/CHANGES with file:line and the input that breaks |
| `security-analyst` | Opus | Read-only security review for risky changes. PASS/ISSUES with the attack path |

## Install

As a Claude Code plugin (recommended):

```
/plugin marketplace add ethicaladitya/sudo-squad
/plugin install sudo-squad@sudo-squad
```

From a shell:

```bash
claude plugin marketplace add ethicaladitya/sudo-squad && claude plugin install sudo-squad@sudo-squad
```

The agents load as `sudo-squad:project-manager` and so on. To give them plain names in a single project, copy
`agents/*.md` into that project's `.claude/agents/`.

The squad's guide is also a standalone [Agent Skill](https://agentskills.io). `npx skills add ethicaladitya/sudo-squad`
installs only the skill, not the agents.

## Use

```
> use the project-manager to add password reset to the login page
> project-manager: work the next task from the backlog
> ask the ceo what we should fix first this week
> have the security-analyst review this branch
```

The agents follow your project's rules. Each one reads `AGENTS.md`, `CLAUDE.md` and `LESSONS.md` first. Put these there:
- **Task source:** for example "Asana project X", a tasks file and its sync script, or GitHub issues.
- **Tests:** how to run them.
- **Branches:** the naming convention.
- **Unattended work:** what may be merged or deployed without asking, and what needs your approval.

## Why it's built this way

- **Hub and spoke, in sequence.** Specialists report to the project-manager rather than to each other, and it
  calls them in the foreground. Subagents run in the background by default, and in testing that let reviewers
  approve a commit that was still changing.
- **Done means the final commit is approved.** Every fix round goes back through the checkers that raised
  findings.
- **Cheap where it can be, Opus where it counts.** A subagent's cold start dominates cost. Small tasks skip the
  separate tester and security pass, and fix rounds resume the same agents instead of spawning new ones. On the
  bundled test task the cost dropped from $3.73 to $0.85 with identical results.
- **Safe by default.** Reviewers are read-only. Nobody pushes, merges or deploys unless the project says so. The
  WordPress rules come from real production incidents on live sites.

## Test it

These scripts run the squad end to end with real `claude -p` calls and check the results with plain scripts,
not a model. They test this checkout as a plugin.

```bash
skills/sudo-squad/scripts/e2e.sh            # seeded bug + feature, hidden acceptance tests (~$1)
skills/sudo-squad/scripts/e2e-wordpress.sh  # local WordPress on SQLite, no Docker (~$0.50)
```

Run both after you change any agent.

## License

MIT
