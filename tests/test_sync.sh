#!/usr/bin/env bash
# End-to-end test with a local bare repository (no network).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null RETRY_SLEEP=0
fail(){ echo "FAIL: $*"; [ -f "$T/state/sync.log" ] && tail -20 "$T/state/sync.log"; exit 1; }
ok(){ echo "ok - $*"; }

git init -q --bare -b main "$T/remote.git"
git clone -q "$T/remote.git" "$T/other" 2>/dev/null
( cd "$T/other" && git checkout -q -b main && echo "# box config" > README.md && git add . && git commit -qm init && git push -q origin main )
git clone -q -b main "$T/remote.git" "$T/repo"
mkdir -p "$T/box/tools/sub" "$T/box/skills"
cat > "$T/sync.conf" <<C
REPO="$T/repo"
MAP_REPO=(tools skills)
MAP_BOX=("$T/box/tools" "$T/box/skills")
STATE="$T/state"
C
SYNC=("$HERE/sync.sh" -c "$T/sync.conf")
pull_other(){ ( cd "$T/other" && git pull -q origin main ); }

# 1. box -> repo, with filtering
echo 'echo hi' > "$T/box/tools/a.sh"; chmod +x "$T/box/tools/a.sh"
echo 'notes' > "$T/box/tools/sub/n.md"
echo 'noise' > "$T/box/tools/run.log"
echo 'X=1' > "$T/box/tools/app.env"
echo 'skill' > "$T/box/skills/s.md"
"${SYNC[@]}" >/dev/null || fail "first sync"
pull_other
[ -f "$T/other/tools/a.sh" ] && [ -x "$T/other/tools/a.sh" ] && [ -f "$T/other/tools/sub/n.md" ] && [ -f "$T/other/skills/s.md" ] || fail "files not pushed"
[ ! -e "$T/other/tools/run.log" ] && [ ! -e "$T/other/tools/app.env" ] || fail "excluded files pushed"
ok "box changes pushed; logs and .env excluded; exec bit kept"

# 2. repo -> box
( cd "$T/other" && echo 'echo upstream' > tools/a.sh && echo new > tools/new.txt && git commit -qam up && git add . && git commit -qm add && git push -q origin main )
"${SYNC[@]}" >/dev/null || fail "second sync"
grep -q upstream "$T/box/tools/a.sh" && [ -f "$T/box/tools/new.txt" ] || fail "upstream change not applied"
ok "upstream changes applied to the box"

# 3. conflict: both sides changed
echo 'echo box-edit' > "$T/box/tools/a.sh"
( cd "$T/other" && git pull -q origin main && echo 'echo upstream-edit' > tools/a.sh && git commit -qam conflict && git push -q origin main )
"${SYNC[@]}" >/dev/null || fail "conflict sync"
grep -q box-edit "$T/box/tools/a.sh" && grep -q upstream-edit "$T/box/tools/a.sh.upstream" || fail "conflict handling"
pull_other; grep -q upstream-edit "$T/other/tools/a.sh" || fail "frozen file was pushed during conflict"
ok "conflict keeps box version, saves .upstream, freezes push"

# 4. secret scan aborts the commit
printf 'TOKEN = "%s"\n' "ghp_$(printf 'a%.0s' $(seq 1 36))" > "$T/box/tools/leak.py"
set +e; "${SYNC[@]}" >/dev/null; rc=$?; set -e
[ $rc -eq 2 ] || fail "expected exit 2 on secret, got $rc"
pull_other; [ ! -e "$T/other/tools/leak.py" ] || fail "secret was pushed"
grep -q "SECRET-HIT ./tools/leak.py" "$T/state/sync.log" || fail "hit not logged"
! grep -q "aaaaaaaaaaaaaaaaaaaa" "$T/state/sync.log" || fail "secret value written to log"
ok "secret scan blocks the commit and never logs the value"
rm -f "$T/box/tools/leak.py"

# 5. box deletion propagates; upstream deletion does not delete box files
rm "$T/box/tools/sub/n.md"
"${SYNC[@]}" >/dev/null || fail "delete sync"
pull_other; [ ! -e "$T/other/tools/sub/n.md" ] || fail "box deletion not propagated"
( cd "$T/other" && git rm -q skills/s.md && git commit -qm del && git push -q origin main )
"${SYNC[@]}" >/dev/null || fail "upstream delete sync"
[ -f "$T/box/skills/s.md" ] && grep -qx skills/s.md "$T/state/upstream_deleted.txt" || fail "upstream deletion handling"
ok "deletions handled conservatively"
echo "all tests passed"
