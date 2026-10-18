---
name: sudo-squad
description: A dev team of Claude Code subagents for any website or app (ceo, project-manager, developer, wordpress, tester, code-reviewer, security-analyst). The project-manager takes a task from the project's tracker or a given goal, hands it to the others strictly in sequence, loops fixes and reports back. Use when setting up multi-agent delivery in a project, choosing which squad agent to call, customizing an agent for one project, or proving the squad still works after editing it.
license: MIT
metadata:
  author: Aditya Shah
  version: "1.0.0"
  repository: https://github.com/ethicaladitya/sudo-squad
---

# sudo-squad

Seven subagents that work as one team. As a Claude Code plugin they load as `sudo-squad:<name>`. Copied into
`.claude/agents/` they keep plain names. Claude picks one when a request matches its description, or you can
name one directly ("use the project-manager to ...").

## Who does what

| Agent | Model | Job | Hands off to |
|---|---|---|---|
| `ceo` | Opus | What to do next and why. Risky calls become owner asks | project-manager |
| `project-manager` | Sonnet | Takes the next task from the tracker (Asana, tasks file, GitHub issues) or a given goal, sizes it, runs build → test → review in sequence, loops fixes (max 2), writes the result back | developer or wordpress, tester, code-reviewer, security-analyst |
| `developer` | Sonnet | Implements on a named branch with a test. No push, merge or deploy unless allowed | tester (sanity) |
| `wordpress` | Opus | WordPress site state and code, with verified backups, cache purges and live checks | none |
| `tester` | Sonnet | Runs the tests and the real app against the criteria. PASS/FAIL with proof | none |
| `code-reviewer` | Opus | Read-only correctness review. APPROVE/CHANGES | none |
| `security-analyst` | Opus | Read-only security review, only for risky changes. PASS/ISSUES | none |

**Hub and spoke.** Specialists report to the project-manager rather than calling each other. It calls them in
the foreground one at a time. Subagents run in the background by default, and in testing that let reviewers
check a commit that was still changing. Subagents can nest at most 3 levels below the main session
(`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`), so ceo → project-manager → developer is the deepest chain.

**Cost.** Most of the spend is each subagent's cold start, since it re-reads the system prompt, tools and project
docs. Opus is used only where its judgment catches bugs (reviews, WordPress on live sites). Small tasks skip the
separate tester and the security pass. Fix rounds resume the same agents with SendMessage instead of spawning
new ones. Measured on the bundled e2e task: $3.73 → $0.85 with identical results.

## Using it in a project
Every agent first reads the project's AGENTS.md, CLAUDE.md and LESSONS.md, which override the agent file. Put
these there:
- the task source, e.g. "Asana project X", a tasks file plus its sync script, or GitHub issues
- how to run the tests, and the branch naming
- what may be merged or deployed unattended, and what needs the owner's approval
- for WordPress: the SSH alias, WP root, active theme, SEO plugin and cache layers

To specialize an agent for one project, add `.claude/agents/<name>.md` in that project. New roles go the same
way, e.g. a `deployer` that knows one project's deploy.

Unattended (`claude -p`): allow the `Agent` tool (`--allowedTools "... Agent"`) or nothing can delegate, and cap
spend with `--max-budget-usd`.

## Changing an agent
Keep each file short: the role, ordered steps, hard limits, and a fixed return format the caller can check
(APPROVE/CHANGES, PASS/FAIL). Reviewers stay read-only (`disallowedTools: Edit, Write, NotebookEdit, Agent`).
Put domain knowledge in a skill and preload it with `skills:` rather than growing the agent file.

## Proving it works
Each run makes real `claude -p` calls, costs real money and is checked by scripts, not a model. Both scripts
test this checkout as a plugin by default. Set `PLUGIN_DIR=` (empty) to use the installed agents instead.

- `scripts/e2e.sh [workdir]` creates a throwaway repo with a seeded bug and a feature that takes user input,
  then runs the squad through the project-manager. It checks that the core chain was called, that only builders
  wrote code, that a review ran after the last change, that `main` is untouched, that the work is committed on a
  named branch with a clean tree, and that hidden acceptance tests pass. About $1. Cap with `MAX_BUDGET_USD`.
- `scripts/e2e-wordpress.sh [workdir]` runs the same kind of test for `wordpress` on a disposable local
  WordPress (SQLite + `php -S`, no Docker). It checks byte-exact content including backslashes, an escaped meta
  tag shipped as a must-use plugin, a verified backup, and that core, theme and plugin files are untouched. It
  needs `php`, `wp-cli`, `curl` and `unzip`. About $0.50.

Run both after editing any agent.
