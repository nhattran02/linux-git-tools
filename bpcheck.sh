#!/usr/bin/env bash
# bpcheck.sh - list upstream commits and check whether a local branch has them.
#
# Works in any git repository (written for Linux kernel backports).
# Run "bpcheck.sh help" for usage.

set -euo pipefail

# Built-in remote aliases. Add your own with:
#   git config bpcheck.remote.<name> <url>
declare -A KNOWN_URL=(
	[mainline]=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
	[next]=https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git
	[stable]=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
)

usage() {
	cat <<'EOF'
bpcheck.sh - list upstream commits and check whether a local branch has them

Usage: bpcheck.sh <command> [options] [args] [-- <path>...]

Commands:
  list   <range>...        list commits in <range> (e.g. mainline/v6.12..mainline/master)
  check  <commit|range|->  check commits against the local branch ("-" = read shas from stdin)
  check  -L <list>         check every commit of a saved list
  since  <commit|range|->  when did a commit land (mainline release, linux-next, stable)
                           and should it be ported to the local version? (also -L <list>)
  pid    <commit>...       print the patch-id of commits
  lists                    show saved lists
  show   <list>            print a saved list
  rm     <list>...         delete saved lists
  fetch  <remote>[/<ref>]... fetch a branch or tag (or the whole remote)
  remotes                  show configured remotes and built-in aliases
  help                     this help

Options:
  -- <path>...   limit to these files/dirs/globs (quote globs: 'dir/renesas,*')
  -l <ref>       local branch to compare against          (default: HEAD)
  -s <name>      list: save result as <name>; check: save commits NOT found as <name>
  -a             with -s: append to an existing list instead of replacing it
  -L <name>      check: use a saved list (its saved paths are used unless -- is given)
  -m             check: hide commits already present (HAVE)
  -c             check/list/since: CSV output
  -r             check: add a RELEASE column (first mainline tag, or next-YYYYMMDD)
  -S             since: also look in stable/linux-X.Y.y (X.Y = version of the local branch,
                 read from its Makefile); fetches that branch and its tags if missing
  -F             always fetch remote refs before use (refresh)
  -N             never fetch (offline)

Refs:
  <remote>/<name> is fetched automatically if missing; <name> may be a branch OR a tag.
  The remote is added automatically when it is a built-in alias (mainline, next, stable)
  or configured with: git config bpcheck.remote.<name> <url>
  Plain local refs (HEAD, v6.12, my-branch, a sha) work as usual.

Check status:
  HAVE      same diff (patch-id) exists locally, or the commit is an ancestor
  TAG       a local commit says "commit <sha> upstream" / "[ Upstream commit <sha> ]" /
            "cherry picked from commit <sha>", but the diff differs
  SUBJ      same subject exists locally, diff differs -> compare with git range-diff
  MISSING   not found                                 -> backport candidate
  UNKNOWN   commit object not available locally

FIX column (from "Fixes:" tags):
  yes  the fixed commit IS in the local branch -> you are affected
  n/a  the fixed commit is not in the local branch
  ?    the fixed commit object is not available locally
  -    not a fix

Without "-- <path>", each commit is compared over the files it touches.
With "-- <path>", patch-ids are computed only over those paths (on both sides).

Saved lists live in $(git rev-parse --git-common-dir)/bpcheck/ (override: BPCHECK_DIR).

Examples:
  bpcheck.sh list -s sci mainline/v6.12..mainline/master -- drivers/tty/serial/sh-sci.c
  bpcheck.sh check -L sci -m
  bpcheck.sh check -L sci -m -s sci-todo          # keep only what is still missing
  bpcheck.sh check c3ca8a0aac83 92b1ea22454b
  bpcheck.sh check -r -L sci -m                   # with the release each commit landed in
  bpcheck.sh since c982f96e8684                   # when did it land, port it or not?
  bpcheck.sh since -S -L sci-todo                 # same, also looking into stable X.Y.y
  bpcheck.sh check -l g3s/dev mainline/master..next/master -- drivers/watchdog/rzg2l_wdt.c
  bpcheck.sh list stable/linux-6.12.y~50..stable/linux-6.12.y -- drivers/tty/serial/
  git log --format=%H --grep=sh-sci v6.12..v6.18 | bpcheck.sh check -
EOF
}

die()  { echo "bpcheck: $*" >&2; exit 1; }
info() { echo "bpcheck: $*" >&2; }

FETCH=auto LOCAL=HEAD MISSING_ONLY=0 CSV=0 SAVE= APPEND=0 LIST= SHOW_REL=0 WITH_STABLE=0
PATHS=() ARGS=()
declare -A FETCHED=()

parse() {
	while [ $# -gt 0 ]; do
		case $1 in
		-F) FETCH=always ;;
		-N) FETCH=never ;;
		-l) [ $# -ge 2 ] || die "-l needs a ref"; LOCAL=$2; shift ;;
		-s) [ $# -ge 2 ] || die "-s needs a name"; SAVE=$2; shift ;;
		-L) [ $# -ge 2 ] || die "-L needs a name"; LIST=$2; shift ;;
		-a) APPEND=1 ;;
		-m) MISSING_ONLY=1 ;;
		-c) CSV=1 ;;
		-r) SHOW_REL=1 ;;
		-S) WITH_STABLE=1 ;;
		-h|--help) usage; exit 0 ;;
		--) shift; PATHS=("$@"); break ;;
		-?*) die "unknown option '$1' (see: bpcheck.sh help)" ;;
		*) ARGS+=("$1") ;;
		esac
		shift
	done
}

# ---------------------------------------------------------------- refs/remotes

remote_url() {
	git config --get "bpcheck.remote.$1" 2>/dev/null || echo "${KNOWN_URL[$1]:-}"
}

is_remote() {
	git remote get-url "$1" >/dev/null 2>&1 || [ -n "$(remote_url "$1")" ]
}

ensure_remote() {
	git remote get-url "$1" >/dev/null 2>&1 && return
	local url
	url=$(remote_url "$1")
	[ -n "$url" ] || die "unknown remote '$1' (git remote add $1 <url>, or git config bpcheck.remote.$1 <url>)"
	[ "$FETCH" = never ] && die "remote '$1' is not configured and -N was given"
	info "adding remote '$1' -> $url"
	git remote add "$1" "$url"
}

# fetch_ref <remote> <name>: fetch branch or tag <name> into refs/remotes/<remote>/<name>
fetch_ref() {
	local r=$1 n=$2 refs src
	[ -n "${FETCHED[$r/$n]:-}" ] && return
	[ "$FETCH" = never ] && die "'$r/$n' is not available locally and -N was given"
	ensure_remote "$r"
	refs=$(git ls-remote "$r" "refs/heads/$n" "refs/tags/$n") || die "git ls-remote $r failed"
	if awk -v x="refs/heads/$n" '$2 == x { f = 1 } END { exit !f }' <<<"$refs"; then
		src=refs/heads/$n
	elif awk -v x="refs/tags/$n" '$2 == x { f = 1 } END { exit !f }' <<<"$refs"; then
		src=refs/tags/$n
	else
		die "'$n' is neither a branch nor a tag on remote '$r'"
	fi
	info "fetching $r $src (first time can take a while)"
	git fetch --no-tags "$r" "+$src:refs/remotes/$r/$n" >&2 || die "fetch $r $src failed"
	FETCHED[$r/$n]=1
}

# resolve_rev <rev>: make sure <rev> resolves, fetching <remote>/<name> if needed
resolve_rev() {
	local rev=$1 ref r n
	ref=${rev%%[~^@]*}
	if [[ $ref == */* ]]; then
		r=${ref%%/*} n=${ref#*/}
		if is_remote "$r"; then
			if [ "$FETCH" = always ] || ! git rev-parse -q --verify "$ref^{commit}" >/dev/null; then
				fetch_ref "$r" "$n"
			fi
		fi
	fi
	git rev-parse -q --verify "$rev^{commit}" >/dev/null || die "cannot resolve '$rev'"
}

# resolve_spec <rev | A..B | A...B>
resolve_spec() {
	local s=$1 a b
	if [[ $s == *...* ]]; then
		a=${s%%...*} b=${s#*...}
	elif [[ $s == *..* ]]; then
		a=${s%%..*} b=${s#*..}
	else
		resolve_rev "$s"
		return
	fi
	if [ -n "$a" ]; then resolve_rev "$a"; fi
	if [ -n "$b" ]; then resolve_rev "$b"; fi
}

# ---------------------------------------------------------------- saved lists

list_file() {
	[[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || die "bad list name '$1' (use letters, digits, . _ -)"
	echo "$DIR/$1.list"
}

# save_list <name> <description>; entries "<sha>\t<subject>" on stdin
save_list() {
	local f tmp sha rest p
	f=$(list_file "$1")
	mkdir -p "$DIR"
	tmp=$(mktemp)
	if [ "$APPEND" = 1 ] && [ -f "$f" ]; then
		cp "$f" "$tmp"
	else
		{
			echo "# bpcheck list"
			echo "# created: $(date '+%F %T')"
			for p in ${PATHS[@]+"${PATHS[@]}"}; do echo "# path: $p"; done
		} > "$tmp"
	fi
	echo "# source: $2" >> "$tmp"
	while IFS=$'\t' read -r sha rest; do
		[ -n "$sha" ] || continue
		grep -q "^$sha" "$tmp" || printf '%s\t%s\n' "$sha" "$rest" >> "$tmp"
	done
	mv "$tmp" "$f"
	info "saved list '$1': $(grep -cv '^#' "$f" || true) commits ($f)"
}

LIST_SHAS=() LIST_PATHS=()
read_list() {
	local f line
	f=$(list_file "$1")
	[ -f "$f" ] || die "no saved list '$1' (see: bpcheck.sh lists)"
	while IFS= read -r line; do
		case $line in
		"# path: "*) LIST_PATHS+=("${line#\# path: }") ;;
		\#* | "") ;;
		*) LIST_SHAS+=("${line%%$'\t'*}") ;;
		esac
	done < "$f"
}

# ---------------------------------------------------------------- local index

# local_index <path>...: build (once) patch-id/subject/tag indexes of LOCAL over <path>
local_index() {
	local k
	k=$(printf '%s\0' "$LOCAL" "$@" | md5sum | cut -c1-16)
	IDX=$TMP/$k
	[ -d "$IDX" ] && return
	mkdir "$IDX"
	git log -p --no-merges --format='commit %H' "$LOCAL" -- "$@" |
		git patch-id --stable > "$IDX/pid"
	git log --no-merges --format='%s%x09%h' "$LOCAL" -- "$@" > "$IDX/subj"
	git log --no-merges --format='@@ %h%n%B' "$LOCAL" -- "$@" | awk '
		/^@@ /                                           { l = $2; next }
		match($0, /^commit [0-9a-f]+ upstream/)          { print substr($2, 1, 12), l }
		match($0, /^\[ Upstream commit [0-9a-f]+ \]/)    { print substr($4, 1, 12), l }
		match($0, /cherry picked from commit [0-9a-f]+/) {
			s = substr($0, RSTART, RLENGTH); n = split(s, a, " "); print substr(a[n], 1, 12), l
		}' > "$IDX/tag"
}

# find_local <commit> [own]: sets ST and LM (matching local sha).
# "own" = always compare over the files the commit touches (used for Fixes: targets).
# (no "| head" anywhere: with pipefail, SIGPIPE in the writer would kill the script)
find_local() {
	local c=$1 mode=${2:-} pid line subj alt s
	local -a p=()
	ST=MISSING LM=
	git cat-file -e "$c^{commit}" 2>/dev/null || { ST=UNKNOWN; return; }
	if git merge-base --is-ancestor "$c" "$LOCAL" 2>/dev/null; then
		ST=HAVE LM=$(git rev-parse --short=12 "$c"); return
	fi
	if [ ${#PATHS[@]} -gt 0 ] && [ "$mode" != own ]; then
		p=("${PATHS[@]}")
	else
		mapfile -t p < <(git show --format= --name-only "$c")
	fi
	[ ${#p[@]} -gt 0 ] || { ST=UNKNOWN; return; }
	local_index "${p[@]}"

	pid=$(git show "$c" -- "${p[@]}" | git patch-id --stable | cut -d' ' -f1)
	if [ -n "$pid" ] && line=$(grep -m1 "^$pid " "$IDX/pid"); then
		ST=HAVE LM=${line#* } LM=${LM:0:12}; return
	fi

	# A stable backport carries the mainline sha; match on either one.
	alt=$(git log -1 --format=%B "$c" |
		sed -nE 's/^commit ([0-9a-f]{40}) upstream\.?$/\1/p; s/^\[ Upstream commit ([0-9a-f]{40}) \]$/\1/p')
	alt=${alt%%$'\n'*}
	for s in "$(git rev-parse --short=12 "$c")" "${alt:0:12}"; do
		[ ${#s} = 12 ] || continue
		if line=$(grep -m1 "^$s " "$IDX/tag"); then
			ST=TAG LM=${line#* }; return
		fi
	done

	subj=$(git log -1 --format=%s "$c")
	if line=$(grep -m1 -F -- "$subj"$'\t' "$IDX/subj"); then
		ST=SUBJ LM=${line##*$'\t'}
	fi
}

fix_status() {
	local c=$1 f fixes
	FIX=-
	fixes=$(git log -1 --format=%B "$c" | sed -nE 's/^Fixes: *([0-9a-f]{8,40}).*/\1/p')
	[ -n "$fixes" ] || return 0
	FIX=n/a
	for f in $fixes; do
		f=$(git rev-parse -q --verify "$f^{commit}" 2>/dev/null) || { FIX='?'; continue; }
		find_local "$f" own
		case $ST in
		MISSING) ;;
		UNKNOWN) FIX='?' ;;
		*) FIX=yes; return 0 ;;
		esac
	done
}

colors() {
	if [ "$CSV" = 0 ] && [ -t 1 ]; then
		R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' C=$'\e[36m' D=$'\e[2m' N=$'\e[0m'
	else
		R= G= Y= C= D= N=
	fi
}

# ---------------------------------------------------------------- commands

cmd_list() {
	local s n=0 sha date author subj out
	[ ${#ARGS[@]} -gt 0 ] || die "list: give a range, e.g. mainline/v6.12..mainline/master"
	for s in "${ARGS[@]}"; do resolve_spec "$s"; done
	out=$(git log --no-merges --format='%H%x09%cs%x09%an%x09%s' "${ARGS[@]}" -- ${PATHS[@]+"${PATHS[@]}"})
	colors
	[ "$CSV" = 1 ] && echo "sha,date,author,subject"
	while IFS=$'\t' read -r sha date author subj; do
		[ -n "$sha" ] || continue
		n=$((n + 1))
		if [ "$CSV" = 1 ]; then
			printf '%s,%s,"%s","%s"\n' "${sha:0:12}" "$date" "${author//\"/\"\"}" "${subj//\"/\"\"}"
		else
			printf '%s%s%s %s %-20.20s %s\n' "$Y" "${sha:0:12}" "$N" "$date" "$author" "$subj"
		fi
	done <<<"$out"
	info "$n commits"
	if [ -n "$SAVE" ]; then
		awk -F'\t' 'NF { print $1 "\t" $4 }' <<<"$out" | save_list "$SAVE" "list ${ARGS[*]}"
	fi
}

# collect_shas <cmd>: fill SHAS from -L <list>, ARGS (commits, ranges, "-" = stdin)
SHAS=()
collect_shas() {
	local a x rest
	if [ -n "$LIST" ]; then
		read_list "$LIST"
		SHAS+=(${LIST_SHAS[@]+"${LIST_SHAS[@]}"})
		[ ${#PATHS[@]} -gt 0 ] || PATHS=(${LIST_PATHS[@]+"${LIST_PATHS[@]}"})
	fi
	for a in ${ARGS[@]+"${ARGS[@]}"}; do
		if [ "$a" = - ]; then
			while read -r x rest; do
				[[ -z $x || $x == \#* ]] || SHAS+=("$x")
			done
		elif [[ $a == *..* ]]; then
			resolve_spec "$a"
			mapfile -t -O ${#SHAS[@]} SHAS < <(git log --no-merges --format=%H "$a" -- ${PATHS[@]+"${PATHS[@]}"})
		else
			resolve_rev "$a"
			SHAS+=("$(git rev-parse "$a^{commit}")")
		fi
	done
	[ ${#SHAS[@]} -gt 0 ] || die "$1: nothing to do (give commits, a range, '-' or -L <list>)"
	resolve_rev "$LOCAL"
}

# ---------------------------------------------------------------- versions

# local_version: LVER (e.g. 6.12) and LSUB (e.g. 59) from the Makefile of LOCAL
local_version() {
	local mk
	LVER= LSUB=
	mk=$(git show "$LOCAL:Makefile" 2>/dev/null) || return 0
	LVER=$(sed -n 's/^VERSION = //p' <<<"$mk").$(sed -n 's/^PATCHLEVEL = //p' <<<"$mk")
	LSUB=$(sed -n 's/^SUBLEVEL = //p' <<<"$mk")
	[ "$LVER" != . ] || LVER=
}

# ver_le <a> <b>: true if version a <= b
ver_le() { printf '%s\n%s\n' "$1" "$2" | sort -V -C; }

# release_of <commit>: REL (first mainline tag, e.g. v7.3-rc1), RELV (7.3) and,
# only when it is not in a release yet, NEXT (first next-YYYYMMDD tag).
# Stable tags are excluded: vX.Y.Z for X >= 3, v2.6.X.Y (v2.6.X itself is mainline).
release_of() {
	local d
	REL= RELV= NEXT=
	if d=$(git describe --contains --match 'v[0-9]*' --exclude 'v[3-9].*.*' \
		--exclude 'v[1-9][0-9].*.*' --exclude 'v2.6.*.*' "$1" 2>/dev/null); then
		REL=${d%%[~^]*} RELV=${REL#v} RELV=${RELV%%-rc*}
		return 0
	fi
	if d=$(git describe --contains --match 'next-*' "$1" 2>/dev/null); then
		NEXT=${d%%[~^]*}
	fi
}

# setup_stable: make stable/linux-<LVER>.y and its v<LVER>.* tags available
STABLE_REF=
setup_stable() {
	[ -n "$LVER" ] || die "cannot read the kernel version of $LOCAL (no Makefile?)"
	STABLE_REF=stable/linux-$LVER.y
	resolve_rev "$STABLE_REF"
	if [ "$FETCH" != never ] &&
	   { [ "$FETCH" = always ] || ! git rev-parse -q --verify "refs/tags/v$LVER.1" >/dev/null; }; then
		info "fetching stable tags v$LVER.*"
		git fetch --no-tags stable "+refs/tags/v$LVER.*:refs/tags/v$LVER.*" >&2 ||
			info "warning: could not fetch stable tags, versions will be missing"
	fi
}

# stable_of <commit>: STC (stable backport sha) and STB (first stable tag, e.g. v6.12.60)
stable_of() {
	local full d range=$STABLE_REF
	STC= STB=
	[ -n "$STABLE_REF" ] || return 0
	full=$(git rev-parse "$1^{commit}")
	git rev-parse -q --verify "v$LVER^{commit}" >/dev/null && range=v$LVER..$STABLE_REF
	STC=$(git log -1 --format=%h --abbrev=12 -F --grep="$full" "$range")
	[ -n "$STC" ] || return 0
	if d=$(git describe --contains --match "v$LVER.*" "$STC" 2>/dev/null); then
		STB=${d%%[~^]*}
	fi
}

cmd_check() {
	local c sha date subj total=0 todo= rel
	declare -A count=()

	collect_shas check
	[ "$SHOW_REL" = 1 ] && local_version

	colors
	if [ "$CSV" = 1 ] && [ "$SHOW_REL" = 1 ]; then
		echo "status,sha,date,release,fix,local,subject"
	elif [ "$CSV" = 1 ]; then
		echo "status,sha,date,fix,local,subject"
	elif [ "$SHOW_REL" = 1 ]; then
		printf '%s%-8s %-12s %-10s %-14s %-4s %-12s %s%s\n' "$D" STATUS SHA DATE RELEASE FIX LOCAL SUBJECT "$N"
	else
		printf '%s%-8s %-12s %-10s %-4s %-12s %s%s\n' "$D" STATUS SHA DATE FIX LOCAL SUBJECT "$N"
	fi

	for c in "${SHAS[@]}"; do
		total=$((total + 1))
		find_local "$c"
		local st=$ST lm=$LM col
		case $st in
		HAVE) col=$G ;; TAG) col=$C ;; SUBJ) col=$Y ;; *) col=$R ;;
		esac
		if [ "$st" = UNKNOWN ]; then
			sha=${c:0:12} date=- subj="(commit not available locally)" FIX='?'
		else
			sha=$(git rev-parse --short=12 "$c")
			date=$(git log -1 --format=%cs "$c")
			subj=$(git log -1 --format=%s "$c")
			fix_status "$c"
		fi
		count[$st]=$(( ${count[$st]:-0} + 1 ))
		[ "$st" != HAVE ] && todo+="$(git rev-parse -q --verify "$c^{commit}" 2>/dev/null || echo "$c")"$'\t'"$subj"$'\n'
		[ "$MISSING_ONLY" = 1 ] && [ "$st" = HAVE ] && continue

		rel=
		if [ "$SHOW_REL" = 1 ]; then
			release_of "$c"
			rel=${REL:-${NEXT:--}}
		fi
		if [ "$CSV" = 1 ]; then
			printf '%s,%s,%s,%s%s,%s,"%s"\n' "$st" "$sha" "$date" \
				"${rel:+$rel,}" "$FIX" "$lm" "${subj//\"/\"\"}"
		else
			local fc=$N
			[ "$FIX" = yes ] && fc=$R
			printf '%s%-8s%s %-12s %-10s %s%s%-4s%s %-12s %s\n' "$col" "$st" "$N" \
				"$sha" "$date" "${rel:+$(printf '%-14s ' "$rel")}" "$fc" "$FIX" "$N" "${lm:--}" "$subj"
		fi
	done

	local summary="local=$LOCAL total=$total" s
	for s in HAVE TAG SUBJ MISSING UNKNOWN; do summary+=" $s=${count[$s]:-0}"; done
	info "$summary"
	if [ -n "$SAVE" ]; then
		printf '%s' "$todo" | save_list "$SAVE" "check (not HAVE) against $LOCAL ${LIST:+of list $LIST }${ARGS[*]:-}"
	fi
}

cmd_since() {
	local c sha subj verdict where st lm
	collect_shas since
	local_version
	[ "$WITH_STABLE" = 1 ] && setup_stable

	colors
	[ "$CSV" = 1 ] && echo "sha,mainline,release,next,stable,stable_sha,fix,local,local_sha,verdict,subject"
	for c in "${SHAS[@]}"; do
		if ! git cat-file -e "$c^{commit}" 2>/dev/null; then
			info "$c: commit not available locally (fetch the tree that has it first)"
			continue
		fi
		sha=$(git rev-parse --short=12 "$c")
		subj=$(git log -1 --format=%s "$c")
		release_of "$c"
		stable_of "$c"
		fix_status "$c"
		find_local "$c"
		st=$ST lm=$LM

		if [ "$st" = HAVE ]; then
			verdict="already in $LOCAL"
		elif [ -z "$REL" ] && [ -n "$NEXT" ]; then
			verdict="only in linux-next, not released yet: wait or take it from next"
		elif [ -z "$REL" ]; then
			verdict="not in any mainline release tag (unreleased, or not a mainline commit)"
		elif [ -n "$LVER" ] && ver_le "$RELV" "$LVER"; then
			verdict="in v$RELV <= local v$LVER: should already be in the base (reverted/dropped locally?)"
		elif [ -n "$STC" ]; then
			verdict="in stable ${STB:-$STABLE_REF}: comes with the next stable/CIP update"
		elif [ "$st" = TAG ] || [ "$st" = SUBJ ]; then
			verdict="newer than v${LVER:-?}, backported with changes: compare with range-diff"
		else
			verdict="newer than v${LVER:-?} (since v$RELV): backport candidate, check API/deps"
		fi
		if [ "$st" = MISSING ] && [ -n "$REL" ]; then
			case $FIX in
			yes) verdict+="; FIX for code you have" ;;
			n/a) verdict+="; fix for code you do not have" ;;
			-)   verdict+="; not a fix (no Fixes: tag)" ;;
			esac
		fi

		if [ "$CSV" = 1 ]; then
			printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s","%s"\n' "$sha" "${REL:-}" "${RELV:-}" \
				"${NEXT:-}" "${STB:-}" "${STC:-}" "$FIX" "$st" "$lm" "$verdict" "${subj//\"/\"\"}"
			continue
		fi
		printf '%s%s%s %s\n' "$Y" "$sha" "$N" "$subj"
		if [ -n "$REL" ]; then
			printf '  mainline : %s (release v%s)\n' "$REL" "$RELV"
		else
			printf '  mainline : not in a release tag\n'
			printf '  next     : %s\n' "${NEXT:-not in a next-* tag}"
		fi
		printf '  fix      : %s\n' "$FIX"
		if [ -n "$STABLE_REF" ]; then
			where="not in $STABLE_REF"
			[ -n "$STC" ] && where="${STB:-in $STABLE_REF} ($STC)"
			printf '  stable   : %s\n' "$where"
		fi
		printf '  local    : %s%s%s%s (%s is v%s%s)\n' "$( [ "$st" = HAVE ] && echo "$G" || echo "$R")" \
			"$st" "$N" "${lm:+ $lm}" "$LOCAL" "${LVER:-?}" "${LSUB:+.$LSUB}"
		printf '  verdict  : %s\n\n' "$verdict"
	done
}

cmd_pid() {
	local a
	[ ${#ARGS[@]} -gt 0 ] || die "pid: give one or more commits"
	for a in "${ARGS[@]}"; do
		resolve_rev "$a"
		git show "$a" -- ${PATHS[@]+"${PATHS[@]}"} | git patch-id --stable
	done
}

cmd_lists() {
	local f name n src
	[ -d "$DIR" ] || { info "no saved lists ($DIR)"; return; }
	for f in "$DIR"/*.list; do
		[ -e "$f" ] || { info "no saved lists ($DIR)"; return; }
		name=$(basename "$f" .list)
		n=$(grep -cv '^#' "$f" || true)
		src=$(sed -n 's/^# source: //p' "$f" | tail -n1)
		printf '%-20s %5s commits  %s\n' "$name" "$n" "$src"
	done
}

cmd_show() {
	[ ${#ARGS[@]} = 1 ] || die "show: give one list name"
	local f
	f=$(list_file "${ARGS[0]}")
	[ -f "$f" ] || die "no saved list '${ARGS[0]}'"
	cat "$f"
}

cmd_rm() {
	local a f
	[ ${#ARGS[@]} -gt 0 ] || die "rm: give list names"
	for a in "${ARGS[@]}"; do
		f=$(list_file "$a")
		[ -f "$f" ] || die "no saved list '$a'"
		rm -- "$f"
		info "removed list '$a'"
	done
}

cmd_fetch() {
	local a
	[ ${#ARGS[@]} -gt 0 ] || die "fetch: give <remote> or <remote>/<branch|tag>"
	[ "$FETCH" = never ] && die "fetch with -N makes no sense"
	FETCH=always
	for a in "${ARGS[@]}"; do
		if [[ $a == */* ]]; then
			fetch_ref "${a%%/*}" "${a#*/}"
		else
			ensure_remote "$a"
			info "fetching all branches of $a"
			git fetch --no-tags "$a" >&2
		fi
	done
}

cmd_remotes() {
	local r n
	echo "Configured remotes:"
	git remote -v | awk '$3 == "(fetch)" { printf "  %-12s %s\n", $1, $2 }'
	echo "Aliases bpcheck.sh can add automatically:"
	for n in "${!KNOWN_URL[@]}"; do printf '  %-12s %s\n' "$n" "$(remote_url "$n")"; done
	git config --get-regexp '^bpcheck\.remote\.' 2>/dev/null |
		while read -r r n; do printf '  %-12s %s (git config)\n' "${r#bpcheck.remote.}" "$n"; done
}

# ---------------------------------------------------------------- main

[ $# -gt 0 ] || { usage; exit 1; }
CMD=$1
shift
case $CMD in
help | -h | --help) usage; exit 0 ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
# (not "rev-parse --path-format=absolute": git < 2.31 echoes unknown options back)
DIR=${BPCHECK_DIR:-$(cd "$(git rev-parse --git-common-dir)" && pwd)/bpcheck}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

parse "$@"
case $CMD in
list)    cmd_list ;;
check)   cmd_check ;;
since)   cmd_since ;;
pid)     cmd_pid ;;
lists)   cmd_lists ;;
show)    cmd_show ;;
rm)      cmd_rm ;;
fetch)   cmd_fetch ;;
remotes) cmd_remotes ;;
*)       die "unknown command '$CMD' (see: bpcheck.sh help)" ;;
esac
