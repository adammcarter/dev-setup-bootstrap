#!/usr/bin/env bash
# Behavioural tests for bootstrap.sh.
#
# The script is sourced as a library (BOOTSTRAP_LIB=1) so each decision can be
# driven directly. Everything it shells out to — curl, git, xcode-select,
# security, open — is stubbed on PATH, so no test touches the network, the
# Keychain, or the real developer tools.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../bootstrap.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }

# ── stub scaffolding ────────────────────────────────────────────────────────
# Each test gets a private bin dir prepended to PATH plus a private HOME, so
# stubs and any state they record cannot leak between tests.
setup_sandbox() {
    SANDBOX="$(mktemp -d)"; BIN="$SANDBOX/bin"; mkdir -p "$BIN"
    export PATH="$BIN:$PATH"; export HOME="$SANDBOX/home"; mkdir -p "$HOME"
    LOG="$SANDBOX/calls.log"; : > "$LOG"; export LOG
}
teardown_sandbox() { PATH="$ORIG_PATH"; HOME="$ORIG_HOME"; rm -rf "$SANDBOX"; }
ORIG_PATH="$PATH"; ORIG_HOME="$HOME"

stub() { # stub <name> <body...>
    local n="$1"; shift
    { printf '#!/usr/bin/env bash\n'; printf 'echo "%s $*" >> "$LOG"\n' "$n"; printf '%s\n' "$@"; } > "$BIN/$n"
    chmod +x "$BIN/$n"
}

# A bare macOS ships /usr/bin/git as a stub that exits non-zero and tells you to
# install the developer tools. That is the exact shape this reproduces.
stub_git_shim_only() {
    stub git 'echo "xcode-select: note: No developer tools were found" >&2; exit 1'
}
stub_git_real() { stub git 'echo "git version 2.50.1"; exit 0'; }

load() { BOOTSTRAP_LIB=1 . "$SCRIPT"; }

# ── 1 · the developer-tools probe must run git, not merely find it ──────────
t_git_probe_not_fooled_by_shim() {
    setup_sandbox; stub_git_shim_only; load
    # command -v finds the shim and says "installed" — the mistake being fixed.
    command -v git >/dev/null && local found=yes || local found=no
    check "shim is on PATH (so command -v is not a usable probe)" "$found" "yes"
    git_works && local r=present || local r=absent
    check "git_works reports the shim as absent" "$r" "absent"
    teardown_sandbox
}

t_git_probe_accepts_real_git() {
    setup_sandbox; stub_git_real; load
    git_works && local r=present || local r=absent
    check "git_works reports a working git as present" "$r" "present"
    teardown_sandbox
}

# ── 2 · a missing toolchain is installed, not assumed ───────────────────────
t_ensure_git_triggers_install() {
    setup_sandbox; stub_git_shim_only
    stub xcode-select 'exit 0'
    load
    BOOTSTRAP_CLT_WAIT=0 ensure_git >/dev/null 2>&1
    grep -q 'xcode-select --install' "$LOG" && local r=yes || local r=no
    check "ensure_git requests the Command Line Tools install" "$r" "yes"
    teardown_sandbox
}

t_ensure_git_skips_when_present() {
    setup_sandbox; stub_git_real; stub xcode-select 'exit 0'; load
    ensure_git >/dev/null 2>&1
    grep -q 'xcode-select' "$LOG" && local r=yes || local r=no
    check "ensure_git does nothing when git already works" "$r" "no"
    teardown_sandbox
}

# ── 3 · every credential is verified before it is trusted ──────────────────
http() { stub curl "echo $1"; }   # token_check reads curl's http_code on stdout

t_token_check_codes() {
    setup_sandbox; load
    http 200; token_check tok; check "200 -> good (0)"          "$?" "0"
    http 401; token_check tok; check "401 -> bad credential (1)" "$?" "1"
    http 404; token_check tok; check "404 -> no access (2)"      "$?" "2"
    http 000; token_check tok; check "000 -> unreachable (3)"    "$?" "3"
    teardown_sandbox
}

t_adopt_rejects_dead_token() {
    setup_sandbox; load; http 401
    adopt "the Keychain" "stale-token" >/dev/null 2>&1 && local r=adopted || local r=rejected
    check "a revoked token is rejected, not used" "$r" "rejected"
    check "no token is adopted"                   "${TOKEN:-}" ""
    teardown_sandbox
}

t_adopt_explains_no_access() {
    setup_sandbox; load; http 404
    local out; out="$(adopt "the Keychain" "wrong-account" 2>&1)"
    grep -qi "cannot see" <<<"$out" && local r=yes || local r=no
    check "a 404 is explained as an access problem, not a bad password" "$r" "yes"
    teardown_sandbox
}

t_adopt_accepts_good_token() {
    setup_sandbox; load; http 200
    adopt "the environment" "good-token" >/dev/null 2>&1
    check "a working token is adopted"      "${TOKEN:-}"     "good-token"
    check "its source is recorded for the user" "${TOKEN_SRC:-}" "the environment"
    teardown_sandbox
}

# ── 4 · the trap that made this unrecoverable ──────────────────────────────
# A dead token in the Keychain used to win the search and end the run. A later,
# working source must be able to overtake it.
t_stale_keychain_is_recoverable_from() {
    setup_sandbox; load
    # The exact dead end this replaces: the only stored credential is a dead one.
    stub security 'case "$1" in find-generic-password) echo dead-keychain-token;; *) exit 0;; esac'
    stub curl 'echo 401'
    stub gh 'exit 1'
    interactive_login() { TOKEN=recovered-token; TOKEN_SRC="your browser sign-in"; }
    GH_TOKEN="" GITHUB_TOKEN="" resolve_token >/dev/null 2>&1
    check "a dead Keychain entry leads to sign-in, not to a dead end" "${TOKEN:-}" "recovered-token"
    teardown_sandbox
}

t_gh_preferred_over_keychain() {
    setup_sandbox; load
    stub gh 'echo gh-token'
    stub security 'case "$1" in find-generic-password) echo kc-token;; *) exit 0;; esac'
    stub curl 'echo 200'
    GH_TOKEN="" GITHUB_TOKEN="" resolve_token >/dev/null 2>&1
    check "the signed-in CLI is preferred over a stored token" "${TOKEN:-}" "gh-token"
    teardown_sandbox
}

t_gh_found_off_path() {
    setup_sandbox; load
    # Signed in, but the CLI lives somewhere a bare login shell's PATH misses.
    mkdir -p "$HOME/.local/bin"
    printf '#!/usr/bin/env bash\necho off-path-token\n' > "$HOME/.local/bin/gh"
    chmod +x "$HOME/.local/bin/gh"
    stub curl 'echo 200'
    stub security 'exit 1'
    GH_TOKEN="" GITHUB_TOKEN="" resolve_token >/dev/null 2>&1
    check "the CLI is found even when it is not on PATH" "${TOKEN:-}" "off-path-token"
    teardown_sandbox
}

t_resolution_order_env_first() {
    setup_sandbox; load
    stub gh 'echo gh-token'; stub security 'echo kc-token'
    stub curl 'echo 200'
    GH_TOKEN=env-token resolve_token >/dev/null 2>&1
    check "the environment is consulted before the CLI and Keychain" "${TOKEN:-}" "env-token"
    teardown_sandbox
}

t_good_token_is_saved_back() {
    setup_sandbox; load
    stub security 'case "$1" in find-generic-password) exit 1;; *) exit 0;; esac'
    stub curl 'echo 200'; stub gh 'echo gh-token'
    GH_TOKEN="" GITHUB_TOKEN="" resolve_token >/dev/null 2>&1
    remember_token >/dev/null 2>&1
    grep -q 'add-generic-password' "$LOG" && local r=yes || local r=no
    check "a working token is written back so the next run does not ask" "$r" "yes"
    grep -q -- '-U' "$LOG" && local r2=yes || local r2=no
    check "the write replaces any stale entry rather than colliding with it" "$r2" "yes"
    teardown_sandbox
}

# ── 5 · the token link carries its own scopes ──────────────────────────────
t_pat_url_is_prepopulated() {
    setup_sandbox; load
    grep -q 'scopes=' <<<"$PAT_URL" && local r=yes || local r=no
    check "the token link pre-selects the scopes" "$r" "yes"
    grep -q 'repo' <<<"$PAT_URL" && r=yes || r=no
    check "the 'repo' scope is among them"        "$r" "yes"
    grep -q 'description=' <<<"$PAT_URL" && r=yes || r=no
    check "the token is pre-named"                "$r" "yes"
    grep -q 'tokens/new' <<<"$PAT_URL" && r=yes || r=no
    check "it opens the create form, not the token list" "$r" "yes"
    teardown_sandbox
}

# ── 6 · a browser sign-in exists, so no token need be created at all ───────
t_device_flow_shows_code_and_opens_browser() {
    setup_sandbox; load
    stub curl 'for a in "$@"; do case "$a" in *device/code*)
          echo "{\"device_code\":\"dc\",\"user_code\":\"WXYZ-1234\",\"verification_uri\":\"https://github.com/login/device\",\"interval\":1,\"expires_in\":900}"; exit 0;; esac; done
        echo "{\"access_token\":\"browser-token\"}"'
    stub open 'exit 0'; stub pbcopy 'exit 0'
    # Not in a subshell: the point of the call is what it leaves behind in TOKEN.
    local out="$SANDBOX/browser.out"
    browser_login >"$out" 2>&1
    grep -q 'WXYZ-1234' "$out" && local r=yes || local r=no
    check "the one-time code is shown to the user" "$r" "yes"
    grep -q 'open https://github.com/login/device' "$LOG" && r=yes || r=no
    check "the verification page is opened for them" "$r" "yes"
    check "the resulting token is captured" "${TOKEN:-}" "browser-token"
    teardown_sandbox
}

t_device_flow_waits_while_pending() {
    setup_sandbox; load
    stub curl 'for a in "$@"; do case "$a" in *device/code*)
          echo "{\"device_code\":\"dc\",\"user_code\":\"AAAA-1111\",\"verification_uri\":\"https://github.com/login/device\",\"interval\":0,\"expires_in\":900}"; exit 0;; esac; done
        n=$(cat "$LOG.poll" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$LOG.poll"
        if [ $n -lt 3 ]; then echo "{\"error\":\"authorization_pending\"}"; else echo "{\"access_token\":\"late-token\"}"; fi'
    stub open 'exit 0'; stub pbcopy 'exit 0'
    browser_login >/dev/null 2>&1
    check "it keeps waiting until the user approves" "${TOKEN:-}" "late-token"
    teardown_sandbox
}

# ── 7 · nothing to ask on means fail fast, not hang ────────────────────────
# `test -r /dev/tty` is true whenever the device node is readable by permission,
# which it is even in a session that has no controlling terminal to open. Trust
# it and a piped or automated run walks into a browser sign-in nobody can
# approve, then blocks until the code expires.
t_no_terminal_fails_fast() {
    setup_sandbox; load
    can_ask() { return 1; }
    browser_login() { echo "BROWSER-LOGIN-RAN" >> "$LOG"; TOKEN=should-not-happen; }
    local out="$SANDBOX/nt.out"
    interactive_login >"$out" 2>&1 && local r=proceeded || local r=refused
    check "with nothing to ask on, it refuses"        "$r" "refused"
    grep -q 'BROWSER-LOGIN-RAN' "$LOG" && local b=yes || local b=no
    check "no unapprovable sign-in is started"        "$b" "no"
    grep -q 'GH_TOKEN' "$out" && local g=yes || local g=no
    check "it says how to supply a credential instead" "$g" "yes"
    teardown_sandbox
}

# ── 8 · failures say what actually went wrong ───────────────────────────────
t_clone_failure_names_the_cause() {
    setup_sandbox; stub_git_real; load
    stub git 'case "$*" in *clone*) exit 128;; *) exit 0;; esac'
    TOKEN=tok TOKEN_SRC="the environment"
    local out; out="$(clone_or_update 2>&1)"; local rc=$?
    check "a failed clone is a failure"        "$rc" "1"
    grep -qi 'network\|github.com\|reach' <<<"$out" && local r=yes || local r=no
    check "the message points at a real cause rather than a git prompt" "$r" "yes"
    grep -qi 'could not read Username' <<<"$out" && r=leaked || r=clean
    check "git's terminal-prompt noise is not what the user sees" "$r" "clean"
    teardown_sandbox
}

# ── run ─────────────────────────────────────────────────────────────────────
for t in $(declare -F | awk '{print $3}' | grep '^t_'); do
    printf '\n%s\n' "$t"; "$t"
done
printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
