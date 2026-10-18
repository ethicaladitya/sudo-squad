#!/usr/bin/env bash
# End-to-end test of the `wordpress` agent on a throwaway local WordPress (SQLite, php -S), checked by scripts.
# Needs: php, wp-cli, curl, unzip, network to wordpress.org. Usage: e2e-wordpress.sh [workdir]
# Env: MAX_BUDGET_USD (default 5), MODEL (main session, default sonnet), PORT (default 8899). Exit 0 = all passed.
set -euo pipefail
# Test this checkout as a plugin (agents load as sudo-squad:<name>). Set PLUGIN_DIR= (empty) to use installed agents.
PLUGIN_DIR="${PLUGIN_DIR-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -z "$PLUGIN_DIR" ] || [ -f "$PLUGIN_DIR/.claude-plugin/plugin.json" ] || { echo "no plugin at $PLUGIN_DIR" >&2; exit 2; }
WORK="${1:-$(mktemp -d)}"
PORT="${PORT:-8899}"
URL="http://127.0.0.1:$PORT"
LOG="$WORK/run.jsonl"
mkdir -p "$WORK"
[ ! -e "$WORK/site" ] || { echo "workdir $WORK already has a site" >&2; exit 2; }
cd "$WORK"

# --- fixture: local WordPress on SQLite ---
PHAR="$(readlink -f "$(command -v wp)")"
# Homebrew wp-cli runs out of memory unpacking core and floods deprecations on new PHP: wrap it.
printf '#!/bin/sh\nexec php -d memory_limit=1G -d error_reporting=1 -d display_errors=stderr "%s" --path="%s/site" "$@"\n' "$PHAR" "$WORK" > wp
chmod +x wp
./wp core download --quiet
curl -sSfL -o sqlite.zip https://downloads.wordpress.org/plugin/sqlite-database-integration.latest-stable.zip
unzip -q sqlite.zip -d site/wp-content/plugins && rm sqlite.zip
SQ=site/wp-content/plugins/sqlite-database-integration
sed -e "s#{SQLITE_IMPLEMENTATION_FOLDER_PATH}#$WORK/$SQ#" -e "s#{SQLITE_PLUGIN}#sqlite-database-integration/load.php#" "$SQ/db.copy" > site/wp-content/db.php
./wp config create --dbname=wp --dbuser=wp --dbpass=wp --skip-check --quiet
./wp core install --url="$URL" --title=E2E --admin_user=admin --admin_password="$(openssl rand -hex 12)" \
  --admin_email=e2e@example.test --skip-email --quiet
./wp post update 1 --post_excerpt='Fast "quotes" & more' --quiet
mkdir -p backups
cat > new-content.html <<'EOF'
<!-- wp:paragraph -->
<p>Block hotlinking of images in nginx:</p>
<!-- /wp:paragraph -->

<!-- wp:code -->
<pre class="wp-block-code"><code>location ~* \.(jpg|jpeg|png|webp)$ {
    valid_referers none blocked ~\.example\.com;
    if ($invalid_referer) { return 403; }
}</code></pre>
<!-- /wp:code -->
EOF
cat > AGENTS.md <<EOF
# Local test site
- WordPress root: ./site. Always run WP-CLI as \`./wp\` (a wrapper; plain \`wp\` fails here).
- Site URL: $URL (already running). This is a disposable local site: every change is approved.
- Backups go in ./backups (absolute path: $WORK/backups).
EOF
hash_tree() { (cd site && find wp-includes wp-admin wp-content/themes wp-content/plugins -type f -exec shasum {} + | sort | shasum); }
BEFORE="$(hash_tree)"
php -S "127.0.0.1:$PORT" -t site > server.log 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 1
curl -sf -o /dev/null "$URL/" || { echo "local site not serving" >&2; exit 2; }

TASK='Use the wordpress agent for this local site (read AGENTS.md). 1) Replace the content of post 1 ("Hello world!") with exactly the contents of new-content.html, byte for byte. 2) Add a site feature: on single posts, output <meta name="description"> in the head with the post excerpt. 3) Verify both on the running site and report.'
echo "== running wordpress agent in $WORK (log $LOG)"
claude -p "$TASK" --model "${MODEL:-sonnet}" \
  ${PLUGIN_DIR:+--plugin-dir "$PLUGIN_DIR"} --permission-mode acceptEdits \
  --allowedTools "Bash Read Write Edit Glob Grep Agent" \
  --max-budget-usd "${MAX_BUDGET_USD:-5}" \
  --output-format stream-json --verbose > "$LOG" 2>&1 || echo "claude exited non-zero (checks still run)"

# --- deterministic checks ---
./wp post get 1 --field=post_content > actual-content.html
AFTER="$(hash_tree)"
PAGE="$(curl -s "$URL/?p=1&nc=$(date +%s)")"
HOME_PAGE="$(curl -s "$URL/?nc=$(date +%s)")"
python3 - "$LOG" "$WORK" "$BEFORE" "$AFTER" "$PAGE" "$HOME_PAGE" <<'EOF'
import glob, json, os, re, sys
log, work, before, after, page, home = sys.argv[1:]
called, cost, result = [], None, ""
for line in open(log):
    try: m = json.loads(line)
    except ValueError: continue
    if m.get("type") == "result": cost, result = m.get("total_cost_usd"), m.get("result", "")
    for c in (m.get("message") or {}).get("content") or []:
        if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") in ("Agent", "Task"):
            called.append((c["input"].get("subagent_type") or "").split(":")[-1])
checks = []
def check(name, ok, detail=""): checks.append(ok); print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))
check("wordpress agent called", "wordpress" in called, str(called))
want = open(f"{work}/new-content.html").read().strip()
got = open(f"{work}/actual-content.html").read().strip()
check("post content byte-exact (backslashes kept)", want == got, f"backslashes want {want.count(chr(92))} got {got.count(chr(92))}")
check("live page shows the regex", r"~* \.(jpg|jpeg|png|webp)$" in page.replace("&#8217;", "'"))
mu = glob.glob(f"{work}/site/wp-content/mu-plugins/*.php")
check("feature is a must-use plugin", bool(mu), ", ".join(os.path.basename(p) for p in mu))
metas = re.findall(r'<meta name=["\']description["\'] content=["\']([^"\']*)["\']', page)
check("description meta on single post, escaped", any("&quot;quotes&quot;" in m and "&amp; more" in m for m in metas), str(metas))
check("one description meta only", len(metas) == 1, str(len(metas)))
check("no description meta on home (not a single post)", not re.search(r'<meta name=["\']description', home))
check("core/theme/plugin files untouched", before == after)
backups = [p for p in glob.glob(f"{work}/backups/**/*", recursive=True) if os.path.isfile(p) and os.path.getsize(p) > 0]
check("backup taken (non-empty file in ./backups)", bool(backups), f"{len(backups)} files")
check("original content in a backup", any("Welcome to WordPress" in open(p, errors="ignore").read() for p in backups))
print(f"agents called: {called}")
print(f"cost: ${cost}" if cost is not None else "cost: unavailable")
print("--- final report ---\n" + (result or "(none)")[:3000])
sys.exit(0 if all(checks) else 1)
EOF
