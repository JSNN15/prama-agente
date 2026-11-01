#!/usr/bin/env bash
# lib/worktrees.sh — Isolated teams: one git worktree and branch per worker, and their integration
# Copyright 2026 Julian Neira Nova
# Licensed under the Apache License, Version 2.0
#
# In an isolated team (swarm --isolate, PRAMA_SWARM_ISOLATE=1) each executor works in its own git
# worktree on branch prama/<team>/<name>, created from the branch the zone's checkout is on (BASE,
# stored on the coordinator). The coordinator stays in the zone's directory on BASE and integrates:
#   worktree status   ahead/behind BASE, uncommitted files, last commit of every worker branch
#   worktree merge    merges a worker branch into BASE (aborts on conflict: BASE never stays broken)
#   worktree sync     merges BASE into a worker branch (keeps it current after other merges)
#   worktree clean    removes worktrees that are clean and fully merged (also on swarm stop)
# Unmerged or uncommitted work is never deleted.

# team_isolated <coordinator> → 0 when the team uses worktrees
team_isolated() { [ "$(state_get "$1" ISOLATE 0)" = 1 ]; }

# team_base <coordinator> → the integration branch of the team
team_base() {
  local b
  b=$(state_get "$1" BASE)
  [ -n "$b" ] || b=$(git -C "$(zone_dir "$(state_get "$1" ZONE)")" symbolic-ref --short -q HEAD 2>/dev/null)
  printf '%s' "${b:-main}"
}

# git_can_isolate <dir> → 0 when <dir> is a git checkout with at least one commit on a branch
git_can_isolate() {
  git -C "$1" rev-parse --verify -q HEAD >/dev/null 2>&1 && git -C "$1" symbolic-ref -q HEAD >/dev/null 2>&1
}

# _wt_ident <dir> → WT_ID: git -c flags giving merge commits an author when the repository has
# no identity configured (a fresh server or container); empty when it has one.
_wt_ident() {
  WT_ID=()
  if [ -z "$(git -C "$1" config user.email 2>/dev/null)" ] && [ -z "${GIT_COMMITTER_EMAIL:-}" ]; then
    WT_ID=(-c user.name=prama-agent -c user.email=prama-agent@localhost)
  fi
}

# worker_branch <team> <session> [base-name] → prama/<team>/<short name>
worker_branch() {
  local team=$1 s=$2 base=${3:-} short
  if [ -n "$base" ] && [[ $s == "$base-"* ]]; then short=${s#"$base-"}
  else short=${s#"${PRAMA_SESSION_PREFIX}"-}; fi
  printf 'prama/%s/%s' "$team" "$(slugify "$short")"
}

# _wt_members <coordinator> → WT_S WT_B WT_D (sessions with a worktree, their branch and directory)
_wt_members() {
  local c=$1 s b
  WT_S=() WT_B=() WT_D=()
  while IFS= read -r s; do
    [ "$(state_get "$s" PARENT)" = "$c" ] || continue
    b=$(state_get "$s" WORKTREE)
    [ -n "$b" ] || continue
    WT_S+=("$s") WT_B+=("$b") WT_D+=("$(state_get "$s" TARGET_DIR)")
  done < <(prama_sessions)
  return 0
}

# _wt_resolve_coord [<zone>|<coordinator>|<worker>] [--team T] → WT_COORD (an agent: its own team)
_wt_resolve_coord() {
  local arg=${1:-} team=${2:-} m
  WT_COORD=''
  if [ -z "$arg" ] && [ -n "${PRAMA_SESSION:-}" ]; then arg=$PRAMA_SESSION; fi
  [ -n "$arg" ] || die "$(_t 'Which team? Give a zone (--team T), a coordinator or a worker session.')"
  if valid_session_name "$arg" && [ -f "$(state_file "$arg")" ]; then
    if [ "$(session_role "$arg")" = coordinator ]; then WT_COORD=$arg
    else WT_COORD=$(session_team "$arg") || die "$(_t "'%s' does not belong to a team." "$arg")"; fi
  else
    m=$(match_zone "$arg") || die "$(_t "Unknown zone or session: '%s'" "$arg")"
    if [ -n "$team" ]; then WT_COORD=$(find_team "$m" "$team") || die "$(_t "There is no team \"%s\" in '%s'." "$team" "$m")"
    else
      local -a cs=()
      mapfile -t cs < <(zone_teams "$m")
      (( ${#cs[@]} == 1 )) || die "$(_t "Zone '%s' has %d teams: give --team <name>." "$m" "${#cs[@]}")"
      WT_COORD=${cs[0]}
    fi
  fi
  [ -n "$WT_COORD" ] || die "$(_t 'Team not found.')"
}

# _wt_authorize <coordinator> — an agent may act only on its own team (operator: anything)
_wt_authorize() {
  [ -n "${PRAMA_SESSION:-}" ] || return 0
  local own
  if [ "$(session_role "$PRAMA_SESSION")" = coordinator ]; then own=$PRAMA_SESSION
  else own=$(session_team "$PRAMA_SESSION") || own=''; fi
  [ "$own" = "$1" ] || die "$(_t "'%s' is another team's; you can only act on your own." "$1")"
}

# worktree status [<zone>|<session>] [--team T] [--json]
wt_status() {
  local arg='' team='' json=0 i dir base ab ahead behind dirty last first=1
  while (( $# )); do
    case $1 in
      --team|-T) team=${2:?}; shift 2 ;;
      --json) json=1; shift ;;
      *) arg=$1; shift ;;
    esac
  done
  _wt_resolve_coord "$arg" "$team"
  dir=$(zone_dir "$(state_get "$WT_COORD" ZONE)")
  base=$(team_base "$WT_COORD")
  _wt_members "$WT_COORD"
  if (( json )); then printf '['; fi
  if (( ! json )); then
    printf ' %s%s%s\n' "$C_BOLD" "$(_t 'Team %s · integration branch %s' "$(team_label "$WT_COORD")" "$base")" "$C_OFF"
    team_isolated "$WT_COORD" || printf ' %s%s%s\n' "$C_MUTED" "$(_t '(shared folder: the workers of this team have no worktrees)')" "$C_OFF"
  fi
  for i in "${!WT_S[@]}"; do
    ab=$(git -C "$dir" rev-list --left-right --count "$base...${WT_B[i]}" 2>/dev/null) || ab='0 0'
    behind=${ab%%[[:space:]]*} ahead=${ab##*[[:space:]]}
    dirty=$(git -C "${WT_D[i]}" status --porcelain 2>/dev/null | grep -c . || true)
    last=$(git -C "$dir" log -1 --format='%h %s (%cr)' "${WT_B[i]}" 2>/dev/null)
    if (( json )); then
      (( first )) || printf ','
      first=0
      printf '{"session":"%s","branch":"%s","dir":"%s","base":"%s","ahead":%d,"behind":%d,"uncommitted":%d,"last":"%s"}' \
        "$(json_escape "${WT_S[i]}")" "$(json_escape "${WT_B[i]}")" "$(json_escape "${WT_D[i]}")" "$(json_escape "$base")" \
        "${ahead:-0}" "${behind:-0}" "${dirty:-0}" "$(json_escape "$last")"
    else
      local mark="$C_MUTED·$C_OFF" note=''
      (( ahead > 0 )) && { mark="$C_LIVE↑$C_OFF"; note=$(_t '%d commit(s) to merge' "$ahead"); }
      (( dirty > 0 )) && note+="${note:+ · }$(_t '%d uncommitted' "$dirty")"
      (( behind > 0 )) && note+="${note:+ · }$(_t '%d behind %s' "$behind" "$base")"
      [ -n "$note" ] || note=$(_t 'up to date')
      printf ' %s %-30s %-34s %s\n     %s%s%s\n' "$mark" "${WT_S[i]}" "${WT_B[i]}" "$note" "$C_MUTED" "$last" "$C_OFF"
    fi
  done
  if (( json )); then printf ']\n'
  elif (( ${#WT_S[@]} == 0 )); then printf ' %s\n' "$(_t '(no worker worktrees)')"
  else printf '\n %s\n' "$(_t 'Review: git diff %s...<branch> · integrate: prama-agent worktree merge <session>' "$base")"
  fi
}

# _wt_worker <session> → WT_W (session) WT_WB (branch) WT_WD (dir) WT_COORD
_wt_worker() {
  local s=${1:-}
  [ -n "$s" ] || s=${PRAMA_SESSION:-}
  [ -n "$s" ] && valid_session_name "$s" && [ -f "$(state_file "$s")" ] || die "$(_t "Unknown session: '%s'" "$s")"
  WT_W=$s WT_WB=$(state_get "$s" WORKTREE) WT_WD=$(state_get "$s" TARGET_DIR)
  [ -n "$WT_WB" ] || die "$(_t "'%s' has no worktree (shared folder)." "$s")"
  WT_COORD=$(session_team "$s") || die "$(_t "'%s' does not belong to a team." "$s")"
}

# worktree merge <worker session> [--keep-conflicts] — merges its branch into the team's base,
# in the zone's checkout. The checkout must be clean and on the base branch.
wt_merge() {
  local s='' keep=0 dir base cur out conflicts test=${PRAMA_MERGE_TEST:-}
  while (( $# )); do
    case $1 in
      --keep-conflicts) keep=1; shift ;;
      --test) test=${2:?$(_t '--test requires a command')}; shift 2 ;;
      --no-test) test=''; shift ;;
      *) s=$1; shift ;;
    esac
  done
  [ -n "$s" ] || die "$(_t 'Usage: prama-agent worktree merge <worker session> [--test "<command>"] [--keep-conflicts]')"
  _wt_worker "$s"
  # Integrating into the base is the coordinator's job (or the operator's), never an executor's.
  if [ -n "${PRAMA_SESSION:-}" ] && [ "$PRAMA_SESSION" != "$WT_COORD" ]; then
    die "$(_t 'Only the coordinator of the team (%s) merges into the base branch.' "$WT_COORD")"
  fi
  dir=$(zone_dir "$(state_get "$WT_COORD" ZONE)")
  base=$(team_base "$WT_COORD")
  cur=$(git -C "$dir" symbolic-ref --short -q HEAD)
  [ "$cur" = "$base" ] || die "$(_t "The zone's checkout is on '%s', not on the team's base '%s': switch it first (git -C %s switch %s)." "$cur" "$base" "$dir" "$base")"
  [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] \
    || die "$(_t 'The checkout of %s has uncommitted changes: commit or stash them before merging.' "$dir")"
  local dirty
  dirty=$(git -C "$WT_WD" status --porcelain 2>/dev/null | grep -c . || true)
  (( dirty > 0 )) && warn "$(_t '%s has %d uncommitted file(s); only its commits are merged.' "$WT_W" "$dirty")"
  if [ -z "$(git -C "$dir" rev-list "$base..$WT_WB" 2>/dev/null)" ]; then
    info_msg "$(_t 'Nothing to merge: %s has no commits that %s lacks.' "$WT_WB" "$base")"; return 0
  fi
  _wt_ident "$dir"
  if out=$(git -C "$dir" "${WT_ID[@]}" merge --no-ff --no-edit -m "Merge $WT_WB (prama: $WT_W)" "$WT_WB" 2>&1); then
    # Tests between merges: a merge that breaks them is undone, so the base stays green.
    if [ -n "$test" ]; then
      info_msg "$(_t 'Running the tests: %s' "$test")"
      local tlog rc=0
      tlog=$( cd "$dir" && timeout "${PRAMA_MERGE_TEST_TIMEOUT:-1800}" bash -c "$test" 2>&1 ) || rc=$?
      if (( rc )); then
        git -C "$dir" reset --merge ORIG_HEAD >/dev/null 2>&1
        bus_event conflict "${PRAMA_SESSION:-operator}" "$WT_W" "tests failed after merging $WT_WB (rc=$rc)"
        printf '%s\n' "$tlog" | tail -n 25 >&2
        die "$(_t 'The tests failed after merging %s (code %d): the merge was undone, %s is unchanged. Send the failure to %s.' "$WT_WB" "$rc" "$base" "$WT_W")"
      fi
      ok "$(_t 'Tests passed.')"
    fi
    bus_event merged "${PRAMA_SESSION:-operator}" "$WT_W" "$WT_WB → $base"
    ok "$(_t 'Merged %s into %s.' "$WT_WB" "$base")"
    _wt_others_behind "$WT_COORD" "$WT_W"
    return 0
  fi
  conflicts=$(git -C "$dir" diff --name-only --diff-filter=U 2>/dev/null | paste -sd' ')
  if [ -n "$conflicts" ] && (( keep )); then
    warn "$(_t 'Conflicts left in %s for you to resolve (then git commit): %s' "$dir" "$conflicts")"
    return 1
  fi
  git -C "$dir" merge --abort >/dev/null 2>&1 || true
  bus_event conflict "${PRAMA_SESSION:-operator}" "$WT_W" "$WT_WB → $base: $conflicts"
  die "$(_t 'Merge of %s aborted, %s is unchanged. Conflicts: %s. Ask %s to run prama-agent worktree sync (merges %s into its branch), resolve them and commit; then merge again.' "$WT_WB" "$base" "${conflicts:-${out:0:200}}" "$WT_W" "$base")"
}

# After a merge, tell which other workers are now behind the base.
_wt_others_behind() {
  local c=$1 merged=$2 i dir base n
  dir=$(zone_dir "$(state_get "$c" ZONE)") base=$(team_base "$c")
  _wt_members "$c"
  for i in "${!WT_S[@]}"; do
    [ "${WT_S[i]}" = "$merged" ] && continue
    n=$(git -C "$dir" rev-list --count "${WT_B[i]}..$base" 2>/dev/null || echo 0)
    (( n > 0 )) && info_msg "$(_t '%s is %d commit(s) behind %s: prama-agent worktree sync %s' "${WT_S[i]}" "$n" "$base" "${WT_S[i]}")"
  done
  return 0
}

# worktree sync [<worker session>] — merges the team's base into the worker's branch. Run by the
# worker itself, conflicts are left for it to resolve; run by anyone else, they are aborted.
wt_sync() {
  local s=${1:-} base out conflicts self=0
  _wt_worker "$s"
  _wt_authorize "$WT_COORD"
  [ "${PRAMA_SESSION:-}" = "$WT_W" ] && self=1
  if [ -n "${PRAMA_SESSION:-}" ] && (( ! self )) && [ "$PRAMA_SESSION" != "$WT_COORD" ]; then
    die "$(_t "Only %s itself or its coordinator can sync its branch." "$WT_W")"
  fi
  base=$(team_base "$WT_COORD")
  if (( ! self )) && [ -n "$(git -C "$WT_WD" status --porcelain --untracked-files=no)" ]; then
    die "$(_t '%s has uncommitted changes: ask it to commit and run prama-agent worktree sync itself.' "$WT_W")"
  fi
  _wt_ident "$WT_WD"
  if out=$(git -C "$WT_WD" "${WT_ID[@]}" merge --no-edit "$base" 2>&1); then
    bus_event synced "${PRAMA_SESSION:-operator}" "$WT_W" "$base → $WT_WB"
    ok "$(_t '%s is up to date with %s.' "$WT_WB" "$base")"
    return 0
  fi
  conflicts=$(git -C "$WT_WD" diff --name-only --diff-filter=U 2>/dev/null | paste -sd' ')
  if (( self )) && [ -n "$conflicts" ]; then
    warn "$(_t 'Conflicts to resolve in your worktree (then git add + git commit): %s' "$conflicts")"
    return 1
  fi
  git -C "$WT_WD" merge --abort >/dev/null 2>&1 || true
  die "$(_t 'Sync of %s aborted (conflicts: %s); the worker has to run it and resolve them.' "$WT_W" "${conflicts:-${out:0:200}}")"
}

# wt_clean_team <coordinator> [include_live:0|1] — removes worktrees (and branches) that are clean
# and fully merged into the base; keeps and lists the rest. Live sessions are skipped unless asked.
wt_clean_team() {
  local c=$1 live=${2:-0} dir base i kept=0 removed=0
  dir=$(zone_dir "$(state_get "$c" ZONE)") base=$(team_base "$c")
  _wt_members "$c"
  for i in "${!WT_S[@]}"; do
    (( live )) || ! tmx_has "${WT_S[i]}" || continue
    _wt_clean_one "$dir" "$base" "${WT_B[i]}" "${WT_D[i]}" && removed=$(( removed + 1 )) || kept=$(( kept + 1 ))
  done
  (( removed )) && ok "$(_t '%d merged worktree(s) removed.' "$removed")"
  return 0
}

# _wt_clean_one <repo> <base> <branch> <dir> → 0 removed, 1 kept (with a message)
_wt_clean_one() {
  local dir=$1 base=$2 b=$3 d=$4
  if [ -d "$d" ] && [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
    warn "$(_t 'Kept %s: uncommitted changes in %s.' "$b" "$d")"; return 1
  fi
  if [ -n "$(git -C "$dir" rev-list "$base..$b" 2>/dev/null)" ]; then
    warn "$(_t 'Kept %s: it has commits not merged into %s (prama-agent worktree merge, or delete it by hand).' "$b" "$base")"; return 1
  fi
  [ -d "$d" ] && git -C "$dir" worktree remove "$d" >/dev/null 2>&1
  git -C "$dir" branch -d "$b" >/dev/null 2>&1 || true
  return 0
}

# Captured before swarm stop removes the state: the team's worktrees, to clean them afterwards.
# wt_snapshot_team <coordinator> → WT_SNAP ("repo|base|branch|dir" lines)
wt_snapshot_team() {
  local c=$1 dir base i
  WT_SNAP=()
  dir=$(zone_dir "$(state_get "$c" ZONE)" 2>/dev/null) || return 0
  base=$(team_base "$c")
  _wt_members "$c"
  for i in "${!WT_S[@]}"; do WT_SNAP+=("$dir|$base|${WT_B[i]}|${WT_D[i]}"); done
}

wt_clean_snapshot() {
  local line dir base b d removed=0
  for line in "${WT_SNAP[@]}"; do
    IFS='|' read -r dir base b d <<< "$line"
    _wt_clean_one "$dir" "$base" "$b" "$d" && removed=$(( removed + 1 ))
  done
  (( removed )) && ok "$(_t '%d merged worktree(s) removed.' "$removed")"
  return 0
}
