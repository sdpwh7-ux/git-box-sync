# git-box-sync

**Two-way sync between an agent's working machine ("the box") and a git repository, with an
allowlist, conservative conflict/deletion rules, and a secret scan that blocks every commit
containing something that looks like a credential.**

AI agents that live on a shared Linux box accumulate useful scripts, configs and skills. You want
those in git, so you can review them, edit them locally (e.g. with Codex) and push, and have the box
pick the changes up. But a naive `git add -A` from an agent's home directory is how API keys,
cookies, logs and personal files end up on GitHub.

git-box-sync is a single bash script meant for cron (e.g. hourly):

1. `git pull --rebase` the sync clone (retries; resets to upstream if local unpushed commits conflict, since the
   box is the source of truth and its changes are regenerated in step 3).
2. **Repo -> box**: apply upstream changes, but only overwrite a box file if it is unchanged since the last sync.
   If both sides changed, the box file is kept, the upstream version is saved as `<file>.upstream`, a conflict is
   logged, and pushing that file is frozen until you resolve it (delete the `.upstream` file).
3. **Box -> repo**: copy changed files that pass the **allowlist** (`filter.rules`, rsync filter syntax: text/source
   extensions only, at most 1 MB; logs, state, backups, `.env`, keys, certificates, cookies and `*token*`/`*secret*`
   names are excluded).
4. **Secret scan** of the whole working tree (`secret_scan.sh`): sensitive file names, private-key headers, common
   token prefixes (`sk-`, `ghp_`, `github_pat_`, `xox?-`, `AKIA`, `AIza`, Telegram bot tokens, JWTs), UUIDs, passwords
   embedded in URLs, literal password/token assignments, plus `gitleaks` if installed. **Any hit aborts the commit**;
   only `file:line:rule` is logged, never the value.
5. Commit and push (with retries).

Deletions are conservative: a file deleted *upstream* is never deleted from the box (it is logged and no longer
pushed; set `APPLY_UPSTREAM_DELETES=1` to move such files to a trash folder instead). A tracked file deleted *on the
box* is removed from the repo (still recoverable from history).

Requirements: bash 4+, git, rsync, flock (util-linux), coreutils `sha256sum`; Linux. Python 3 only for parsing
gitleaks output.

## Install

```bash
git clone https://github.com/sdpwh7-ux/git-box-sync.git ~/git-box-sync
git clone git@github.com:you/your-private-box-config.git ~/sync/my-box-config
cp ~/git-box-sync/examples/sync.conf.example ~/git-box-sync/sync.conf   # edit REPO / MAP_REPO / MAP_BOX
~/git-box-sync/sync.sh               # first run
crontab -e                           # 23 * * * * $HOME/git-box-sync/sync.sh
```

## Configuration

`sync.conf` is sourced by bash (see `examples/sync.conf.example`):

| Setting | Default | Meaning |
| --- | --- | --- |
| `REPO` | required | path of the local clone used for syncing (do not work in it by hand) |
| `MAP_REPO` / `MAP_BOX` | required | parallel arrays: repo top-level dir <-> box dir |
| `RULES` | `filter.rules` next to the script | rsync filter rules applied to each box dir |
| `STATE` | `~/.local/state/git-box-sync` | manifest, lock, trash, `upstream_deleted.txt` |
| `LOG` | `$STATE/sync.log` | rotated at 2 MB |
| `MAX_SIZE` | `1m` | larger files are never synced |
| `REMOTE` | `origin` | remote name |
| `APPLY_UPSTREAM_DELETES` | `0` | `1` = move upstream-deleted box files to `$STATE/trash/` |
| `NO_PUSH` | `0` | `1` = commit locally only |
| `NOTIFY_CMD` | - | run via `bash -c` when a sync aborts; gets `$TITLE` and `$BODY` |
| `SCANNER` | `secret_scan.sh` next to the script | replace the scanner |
| `SECRET_SCAN_ALLOWLIST` | `allowlist.txt` next to the scanner | fixed strings that suppress a hit on that line |

The scanner works on its own too: `./secret_scan.sh <dir>` exits 1 and prints `SECRET-HIT file:line:rule` lines.

## Security notes for agent tooling

- **Use a private repository** for box configs. The allowlist and scanner reduce risk, they do not
  make publishing a home directory safe.
- **Credentials.** git-box-sync never reads key files itself; it relies on your git credential setup (an SSH deploy key
  with write access to *only* this repo is recommended). Keep secrets outside the mapped directories
  (e.g. `~/.config/...`). The scanner reports locations only, never values, and both logs and notifications contain
  locations only.
- **File access.** The script writes only inside the mapped box directories (pulled changes, `.upstream` copies),
  `REPO`, and `STATE`. It never deletes box files because of upstream changes. Note the reverse: anyone who can push
  to the repo can change scripts on the box, which an agent may later execute. Protect the branch, and review
  pushes to it like code that runs with the agent's privileges.
- **Shell.** `sync.conf` is sourced as bash: keep it owned by you and not writable by others. `NOTIFY_CMD` is
  executed with `bash -c`.
- **Network.** Only `git pull`/`fetch`/`push` to the configured remote.
- **Scanner limits.** Regexes and gitleaks catch common formats, not everything (e.g. a bare password in a
  comment). Treat a clean scan as a safety net, not a guarantee.

## Tests

```bash
bash tests/test_sync.sh    # local bare repo; covers filtering, pull, conflict, secret block, deletions
```

## License

MIT
