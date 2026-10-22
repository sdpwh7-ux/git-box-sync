#!/usr/bin/env bash
# git-box-sync: two-way sync between local directories and a git repository (pure shell, no AI).
#
#   sync.sh [-c CONFIG]        (default config: $GIT_BOX_SYNC_CONFIG or ./sync.conf next to this script)
#
# Steps: 1 git pull --rebase  2 apply repo changes to the box (only if the box copy is unchanged since
#        the last sync; otherwise save as <file>.upstream and record a conflict)  3 copy box changes into
#        the repo (allowlist from filter.rules)  4 secret scan (abort on any hit)  5 commit + push
#        6 retry network steps up to 3 times; log to $LOG.
# Deletions (conservative): a file deleted upstream is only logged; the box copy is kept and no longer
#        pushed (APPLY_UPSTREAM_DELETES=1 moves it to $STATE/trash/ instead). A tracked file deleted on
#        the box is removed from the repo (recoverable from git history).
set -uo pipefail
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${GIT_BOX_SYNC_CONFIG:-$HERE/sync.conf}"
while getopts "c:" o; do case $o in c) CONFIG=$OPTARG;; *) echo "usage: $0 [-c config]" >&2; exit 2;; esac; done
[ -f "$CONFIG" ] || { echo "config not found: $CONFIG (copy examples/sync.conf.example)" >&2; exit 2; }
# shellcheck source=/dev/null
. "$CONFIG"

: "${REPO:?REPO (local clone path) must be set in the config}"
[ "${#MAP_REPO[@]}" -gt 0 ] && [ "${#MAP_REPO[@]}" -eq "${#MAP_BOX[@]}" ] || { echo "MAP_REPO and MAP_BOX must be non-empty arrays of equal length" >&2; exit 2; }
RULES=${RULES:-$HERE/filter.rules}
STATE=${STATE:-$HOME/.local/state/git-box-sync}
LOG=${LOG:-$STATE/sync.log}
MAXTRY=${MAXTRY:-3}
MAX_SIZE=${MAX_SIZE:-1m}
REMOTE=${REMOTE:-origin}
APPLY_UPSTREAM_DELETES=${APPLY_UPSTREAM_DELETES:-0}
SCANNER=${SCANNER:-$HERE/secret_scan.sh}
MANIFEST=$STATE/manifest.tsv        # sha256<TAB>repo path: content both sides agreed on at the last sync
LAST=$STATE/last_commit             # commit of the last successful sync
UPDEL=$STATE/upstream_deleted.txt   # deleted upstream, kept on the box, no longer pushed

mkdir -p "$STATE"; touch "$MANIFEST" "$UPDEL"
ts(){ date '+%F %T %z'; }
log(){ printf '%s [%s] %s\n' "$(ts)" "$$" "$*" >> "$LOG"; [ -t 1 ] && printf '%s\n' "$*"; return 0; }
die(){ log "ABORT: $1"
  if [ -n "${NOTIFY_CMD:-}" ]; then
    TITLE="git-box-sync aborted" BODY="reason: $1; log: $LOG" bash -c "$NOTIFY_CMD" >/dev/null 2>&1 || true
  fi
  exit "${2:-1}"; }

exec 9>"$STATE/lock"
flock -n 9 || { log "another sync is running; skipping"; exit 0; }
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 2097152 ] && mv -f "$LOG" "$LOG.1"
log "===== sync start ====="
cd "$REPO" || die "repository directory not found: $REPO"
BR=$(git rev-parse --abbrev-ref HEAD)

retry(){ # retry <description> <command...>
  local d=$1; shift; local i
  for i in $(seq 1 "$MAXTRY"); do
    if out=$("$@" 2>&1); then return 0; fi
    log "$d failed (attempt $i/$MAXTRY): $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-300)"
    [ "$i" -lt "$MAXTRY" ] && sleep $((i*${RETRY_SLEEP:-10}))
  done
  return 1
}

# box path <-> repo path
box_path(){ local i
  for i in "${!MAP_REPO[@]}"; do
    case "$1" in "${MAP_REPO[$i]}"/*) printf '%s/%s' "${MAP_BOX[$i]%/}" "${1#"${MAP_REPO[$i]}"/}"; return 0;; esac
  done; return 1; }
sha(){ [ -f "$1" ] && sha256sum "$1" | cut -d' ' -f1 || true; }
# allowlisted files (repo-path form)
wl_list(){ # wl_list <source dir> <repo prefix>
  local src=$1 pre=$2 tmp; [ -d "$src" ] || return 0
  tmp=$(mktemp -d)
  rsync -a -n -m --max-size="$MAX_SIZE" --filter="merge $RULES" --out-format='%n' "$src/" "$tmp/" 2>/dev/null | grep -v '/$' | sed "s|^|$pre/|"
  rmdir "$tmp"
}
all_wl(){ local i; for i in "${!MAP_REPO[@]}"; do wl_list "$1/${MAP_REPO[$i]}" "${MAP_REPO[$i]}"; done; }
box_wl(){ local i; for i in "${!MAP_REPO[@]}"; do wl_list "${MAP_BOX[$i]%/}" "${MAP_REPO[$i]}"; done; }

# ---------- 0. clean up an interrupted run (only touches the sync clone; unpushed commits are kept)
git rebase --abort >/dev/null 2>&1
git reset -q --hard HEAD && git clean -fdq

# ---------- 1. git pull --rebase
if git rev-parse --verify -q "$REMOTE/$BR" >/dev/null || git ls-remote --exit-code --heads "$REMOTE" "$BR" >/dev/null 2>&1; then
  if ! retry "git pull --rebase" git pull --rebase -q "$REMOTE" "$BR"; then
    git rebase --abort >/dev/null 2>&1
    # local unpushed commits conflict with upstream: reset to upstream (the box is the source; step 3 regenerates)
    if retry "git fetch" git fetch -q "$REMOTE" "$BR"; then
      log "pull --rebase conflicted; reset to $REMOTE/$BR, box changes will be recommitted in step 3"
      git reset -q --hard "$REMOTE/$BR"
    else
      die "cannot reach the remote; giving up for now"
    fi
  fi
fi

# ---------- load state
declare -A BASE UPD REPO_WL CONFLICT
while IFS=$'\t' read -r h p; do [ -n "$p" ] && BASE["$p"]=$h; done < "$MANIFEST"
while IFS= read -r p; do [ -n "$p" ] && UPD["$p"]=1; done < "$UPDEL"
while IFS= read -r p; do REPO_WL["$p"]=1; done < <(all_wl "$REPO")
OLD=$(cat "$LAST" 2>/dev/null || true)
git cat-file -e "${OLD:-x}^{commit}" 2>/dev/null || OLD=""

# ---------- 2. repo changes -> box
n_in=0; n_conf=0
if [ -n "$OLD" ]; then
  CHANGES=$(git diff --name-status --no-renames "$OLD" HEAD -- "${MAP_REPO[@]}")
else
  CHANGES=$(git ls-files -- "${MAP_REPO[@]}" | sed 's/^/A\t/')
fi
while IFS=$'\t' read -r st p; do
  [ -n "${p:-}" ] || continue
  b=$(box_path "$p") || continue
  if [ "$st" = D ]; then
    bs=$(sha "$b")
    if [ -z "$bs" ]; then :
    elif [ "$bs" = "${BASE[$p]:-}" ]; then
      if [ "$APPLY_UPSTREAM_DELETES" = 1 ]; then
        mkdir -p "$STATE/trash/$(dirname "$p")"; mv -f "$b" "$STATE/trash/$p"
        log "upstream deleted $p -> box copy moved to $STATE/trash/"
      else
        UPD["$p"]=1; log "upstream deleted $p -> logged only; box copy kept and no longer pushed (remove the line from upstream_deleted.txt to resume)"
      fi
    else
      log "conflict: upstream deleted $p but the box copy changed -> keeping and re-pushing the box version"
    fi
    continue
  fi
  if [ -z "${REPO_WL[$p]:-}" ]; then log "ignoring upstream file $p (not allowlisted or over $MAX_SIZE)"; continue; fi
  unset 'UPD[$p]'
  us=$(sha "$REPO/$p"); bs=$(sha "$b"); base=${BASE[$p]:-}
  if [ "$bs" = "$us" ]; then continue; fi
  if [ -z "$bs" ] || [ "$bs" = "$base" ]; then
    mkdir -p "$(dirname "$b")" && cp -f "$REPO/$p" "$b" && { n_in=$((n_in+1)); log "pulled $p -> $b"; }
  else
    cp -f "$REPO/$p" "$b.upstream"; CONFLICT["$p"]=1; n_conf=$((n_conf+1))
    log "conflict: $p changed on both sides -> box version kept, upstream saved as $b.upstream"
  fi
done <<< "$CHANGES"
# earlier conflicts: while .upstream exists, keep the file frozen
for p in "${!BASE[@]}"; do b=$(box_path "$p") && [ -f "$b.upstream" ] && CONFLICT["$p"]=1; done

# ---------- 3. box changes -> repo
declare -A BOX_WL
while IFS= read -r p; do BOX_WL["$p"]=1; done < <(box_wl)
for i in "${!MAP_REPO[@]}"; do
  pre=${MAP_REPO[$i]}; L=$(mktemp)
  for p in "${!BOX_WL[@]}"; do
    case "$p" in "$pre"/*) ;; *) continue;; esac
    [ -n "${CONFLICT[$p]:-}" ] && continue
    [ -n "${UPD[$p]:-}" ] && continue
    echo "${p#"$pre"/}" >> "$L"
  done
  mkdir -p "$REPO/$pre"
  [ -s "$L" ] && rsync -a --no-perms --chmod=ugo=rwX --files-from="$L" "${MAP_BOX[$i]%/}/" "$REPO/$pre/"
  rm -f "$L"
done
# keep the executable bit
for p in "${!BOX_WL[@]}"; do b=$(box_path "$p"); [ -f "$REPO/$p" ] && { if [ -x "$b" ]; then chmod +x "$REPO/$p"; else chmod -x "$REPO/$p"; fi; }; done
# tracked files deleted on the box (or no longer allowlisted) -> remove from the repo
for p in "${!BASE[@]}"; do
  [ -n "${BOX_WL[$p]:-}" ] && continue
  [ -n "${UPD[$p]:-}" ] && continue
  [ -n "${CONFLICT[$p]:-}" ] && continue
  b=$(box_path "$p") || continue
  [ ! -e "$b" ] && [ -z "${REPO_WL[$p]:-}" ] && continue
  if [ -f "$REPO/$p" ] && git ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    git rm -q -- "$p" && log "deleted/excluded on the box: $p -> removed from repo"
  fi
done
: > "$UPDEL"; for p in "${!UPD[@]}"; do echo "$p" >> "$UPDEL"; done; sort -o "$UPDEL" "$UPDEL"

# ---------- 4. secret scan of the whole working tree
if ! SCAN=$("$SCANNER" "$REPO" 2>&1); then
  log "secret scan hit; aborting commit:"; printf '%s\n' "$SCAN" | grep SECRET-HIT | while read -r l; do log "  $l"; done
  git reset -q --hard HEAD; git clean -fdq
  die "secret scan failed" 2
fi
log "$(printf '%s' "$SCAN" | tail -1)"

# ---------- 5. commit and push
git add -A -- "${MAP_REPO[@]}" 2>/dev/null
if ! git diff --cached --quiet; then
  n_out=$(git diff --cached --name-only | wc -l)
  git commit -q -m "box sync $(ts)" -m "$(git diff --cached --name-status | head -50)" || die "commit failed"
  log "committed $n_out file(s): $(git log -1 --format=%h)"
fi
if [ "${NO_PUSH:-0}" != 1 ] && { ! git rev-parse --verify -q "$REMOTE/$BR" >/dev/null || [ -n "$(git rev-list "$REMOTE/$BR..HEAD" 2>/dev/null)" ]; }; then
  pushed=0
  for i in $(seq 1 "$MAXTRY"); do
    if out=$(git push -q "$REMOTE" "$BR" 2>&1); then pushed=1; break; fi
    log "push failed (attempt $i/$MAXTRY): $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-300)"
    git pull --rebase -q "$REMOTE" "$BR" >/dev/null 2>&1 || git rebase --abort >/dev/null 2>&1
    sleep $((i*${RETRY_SLEEP:-10}))
  done
  [ $pushed = 1 ] || die "push failed $MAXTRY times; local commit kept, will retry next run"
  log "pushed $(git log -1 --format=%h)"
fi

# ---------- record the sync baseline (HEAD content)
TMPM=$(mktemp)
git ls-files -z -- "${MAP_REPO[@]}" | while IFS= read -r -d '' p; do
  [ -f "$p" ] && printf '%s\t%s\n' "$(sha256sum "$p" | cut -d' ' -f1)" "$p"
done > "$TMPM" && mv -f "$TMPM" "$MANIFEST"
git rev-parse HEAD > "$LAST" 2>/dev/null || true
log "===== sync done: pulled $n_in, conflicts $n_conf, HEAD $(git log -1 --format=%h 2>/dev/null || echo none) ====="
exit 0
