#!/usr/bin/env bash
# End-to-end test of the agent fleet: real `claude -p` run on a throwaway repo, checked by scripts, not a model.
# Usage: e2e.sh [workdir] (default: mktemp). Env: MAX_BUDGET_USD (default 8), MODEL (main session, default sonnet).
# Exit 0 = all checks passed. Costs real money (typically $2-6).
set -euo pipefail
# Test this checkout as a plugin (agents load as sudo-squad:<name>). Set PLUGIN_DIR= (empty) to use installed agents.
PLUGIN_DIR="${PLUGIN_DIR-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -z "$PLUGIN_DIR" ] || [ -f "$PLUGIN_DIR/.claude-plugin/plugin.json" ] || { echo "no plugin at $PLUGIN_DIR" >&2; exit 2; }
WORK="${1:-$(mktemp -d)}"
REPO="$WORK/shop"
HIDDEN="$WORK/hidden_test.py"
LOG="$WORK/run.jsonl"
mkdir -p "$REPO"
[ -z "$(ls -A "$REPO")" ] || { echo "workdir $REPO not empty" >&2; exit 2; }

# --- fixture: tiny app with a seeded bug and a feature request ---
cat > "$REPO/cart.py" <<'EOF'
def total(items):
    """items: list of (unit_price, quantity). Returns the order total."""
    return round(sum(price * qty for price, qty in items), 2)
EOF
cat > "$REPO/test_cart.py" <<'EOF'
import unittest
from cart import total

class TestCart(unittest.TestCase):
    def test_total(self):
        self.assertEqual(total([(10, 2), (5, 1)]), 25)

    def test_empty(self):
        self.assertEqual(total([]), 0)

if __name__ == "__main__":
    unittest.main()
EOF
cat > "$REPO/AGENTS.md" <<'EOF'
# Rules
- Tests: `python3 -m unittest -v`.
- Work on a named branch. Never merge to main, never push (there is no remote).
EOF
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" -c user.name=e2e -c user.email=e2e@localhost commit -qm "initial"
MAIN_SHA="$(git -C "$REPO" rev-parse main)"

# --- hidden acceptance test: never shown to the agents ---
cat > "$HIDDEN" <<'EOF'
import sys, unittest
sys.path.insert(0, sys.argv.pop(1))
from cart import total

class Acceptance(unittest.TestCase):
    def test_existing(self):
        self.assertEqual(total([(10, 2), (5, 1)]), 25)
        self.assertEqual(total([]), 0)
    def test_negative_qty_rejected(self):
        with self.assertRaises(ValueError):
            total([(10, -1)])
    def test_coupon(self):
        self.assertEqual(total([(100, 1)], " save10 "), 90)
        self.assertEqual(total([(100, 1)], "SAVE10"), 90)
        self.assertEqual(total([(100, 1)], None), 100)
    def test_bad_coupon(self):
        with self.assertRaises(ValueError):
            total([(100, 1)], "BOGUS")

unittest.main(argv=["x"], verbosity=1)
EOF

TASK='Use the project-manager agent to deliver this in the current repo. Bug: negative quantities currently reduce the total; they must raise ValueError. Feature: total() takes an optional second argument `coupon`, a string straight from user input; "SAVE10" (case-insensitive, surrounding whitespace ignored) gives 10% off; None or empty means no coupon; any other value raises ValueError. Follow AGENTS.md.'

echo "== running fleet in $REPO (log $LOG)"
( cd "$REPO" && claude -p "$TASK" --model "${MODEL:-sonnet}" \
    ${PLUGIN_DIR:+--plugin-dir "$PLUGIN_DIR"} --permission-mode acceptEdits \
    --allowedTools "Bash Read Write Edit Glob Grep Agent" \
    --max-budget-usd "${MAX_BUDGET_USD:-8}" \
    --output-format stream-json --verbose > "$LOG" 2>&1 ) || echo "claude exited non-zero (checks still run)"

# --- deterministic checks ---
python3 - "$LOG" "$REPO" "$MAIN_SHA" "$HIDDEN" <<'EOF'
import json, subprocess, sys
log, repo, main_sha, hidden = sys.argv[1:]
git = lambda *a: subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True).stdout.strip()
called, cost, result = [], None, ""
owner, coordinator_writes = {}, []  # tool_use id -> subagent type; code writes by main/project-manager
for line in open(log):
    try: m = json.loads(line)
    except ValueError: continue
    if m.get("type") == "result":
        cost, result = m.get("total_cost_usd"), m.get("result", "")
    who = owner.get(m.get("parent_tool_use_id"), "main")
    for c in (m.get("message") or {}).get("content") or []:
        if not (isinstance(c, dict) and c.get("type") == "tool_use"): continue
        if c.get("name") in ("Agent", "Task"):
            owner[c["id"]] = (c["input"].get("subagent_type") or "").split(":")[-1]
            called.append((c["input"].get("subagent_type") or "").split(":")[-1])
        elif who in ("main", "project-manager"):
            cmd = c["input"].get("command", "")
            # ponytail: heuristic for shell-side writes; catches the patterns seen so far, not every possible write
            if c.get("name") in ("Edit", "Write") or "git commit" in cmd or ".write(" in cmd or "cat >" in cmd:
                coordinator_writes.append(f"{who}: {c.get('name')}")
checks = []
def check(name, ok, detail=""): checks.append(ok); print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))
for a in ["project-manager", "developer", "code-reviewer"]:  # tester/security-analyst are optional on a small task
    check(f"agent called: {a}", a in called)
check("only builders wrote code (not main or project-manager)", not coordinator_writes, "; ".join(coordinator_writes))
last = lambda a: max([i for i, x in enumerate(called) if x == a], default=-1)
check("a review ran after the developer's last change", last("code-reviewer") > last("developer") >= 0)
check("main untouched", git("rev-parse", "main") == main_sha)
branch = git("rev-parse", "--abbrev-ref", "HEAD")
branches = [b.strip("* ").strip() for b in git("branch").splitlines() if b.strip("* ").strip() != "main"]
work = branch if branch != "main" else (branches[0] if branches else "")
check("work on a named branch", bool(work), work or "none")
check("branch has commits", bool(work) and git("rev-list", "--count", f"main..{work}") not in ("", "0"))
check("working tree clean", git("status", "--porcelain") == "")
if work and branch != work: git("checkout", "-q", work)
r = subprocess.run([sys.executable, hidden, repo], capture_output=True, text=True)
check("hidden acceptance tests", r.returncode == 0, r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "")
r = subprocess.run([sys.executable, "-m", "unittest"], cwd=repo, capture_output=True, text=True)
check("repo's own tests", r.returncode == 0, r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "")
print(f"agents in call order: {called}")
print(f"cost: ${cost}" if cost is not None else "cost: unavailable")
print("--- final report ---\n" + (result or "(none)")[:3000])
sys.exit(0 if all(checks) else 1)
EOF
