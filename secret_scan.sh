#!/usr/bin/env bash
# secret_scan.sh <dir> : pre-commit secret scan (pure shell + optional gitleaks).
# On suspected secrets prints "SECRET-HIT file:line:rule" (never the value) and exits 1; clean -> exit 0.
# Checks: 1) sensitive file names  2) regexes (private-key headers, common token prefixes, UUIDs,
# passwords embedded in URLs, literal password/token assignments)  3) gitleaks, if installed.
# False positives: add a fixed string to allowlist.txt (or $SECRET_SCAN_ALLOWLIST); a matching line is ignored.
set -uo pipefail
DIR="${1:?usage: secret_scan.sh <dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ALLOW="${SECRET_SCAN_ALLOWLIST:-$HERE/allowlist.txt}"
hits=0
report(){ echo "SECRET-HIT $1"; hits=$((hits+1)); }
cd "$DIR" || exit 2
mapfile -d '' FILES < <(find . -path ./.git -prune -o -type f -print0)
# 1) file names
for f in "${FILES[@]}"; do
  b=$(basename "$f")
  case "$b" in
    *.example) ;;
    .env|.env.*|*.env|*.pem|*.key|*.p12|*.pfx|*.crt|key|*_key|id_rsa*|id_ed25519*|hosts.yml|*cookie*|*secret*|*credential*|*token*|*password*)
      [ "$b" = secret_scan.sh ] || report "$f:0:sensitive-filename";;
  esac
done
# 2) regexes (the scanner's own rule files are skipped: they contain the patterns)
P='-----BEGIN [A-Z ]*PRIVATE'" KEY|"
P+='sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}|eyJ[A-Za-z0-9_-]{20,}\.eyJ|'
P+='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|'
P+='[a-z]+://[^/ :@"'"'"'$%{]+:[^/ @"'"'"'$%{]{3,}@|'
P+='(pass(word|wd)?|pwd|secret|token|api_?key|sendkey|private_?key|privateKey)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'$ {}<>/]{8,}["'"'"']|'
P+='"(password|privateKey|private_key|secret|token)"[[:space:]]*:[[:space:]]*"[^"]{4,}"'
for f in "${FILES[@]}"; do
  case "$(basename "$f")" in secret_scan.sh|filter.rules|allowlist.txt) continue;; esac
  grep -Iq . "$f" 2>/dev/null || continue
  while IFS= read -r line; do
    ln=${line%%:*}; txt=${line#*:}
    skip=0
    if [ -f "$ALLOW" ]; then
      while IFS= read -r a; do { [ -z "$a" ] || [[ "$a" == \#* ]]; } && continue; [[ "$txt" == *"$a"* ]] && { skip=1; break; }; done < "$ALLOW"
    fi
    [ $skip -eq 1 ] || report "$f:$ln:regex"
  done < <(grep -nIE -- "$P" "$f" 2>/dev/null)
done
# 3) gitleaks
if command -v gitleaks >/dev/null 2>&1; then
  R=$(mktemp); gitleaks dir . --no-banner --redact -f json -r "$R" >/dev/null 2>&1; rc=$?
  if [ $rc -ne 0 ]; then
    python3 - "$R" <<'PY' || report "gitleaks:0:report-unreadable"
import json, sys
for x in json.load(open(sys.argv[1])):
    print("SECRET-HIT %s:%s:gitleaks-%s" % (x["File"], x["StartLine"], x["RuleID"]))
PY
    hits=$((hits+1))
  fi
  rm -f "$R"
else
  echo "secret_scan: gitleaks not installed; regex scan only"
fi
if [ $hits -gt 0 ]; then echo "secret_scan: FOUND $hits hit(s)"; exit 1; fi
echo "secret_scan: clean (${#FILES[@]} files)"; exit 0
