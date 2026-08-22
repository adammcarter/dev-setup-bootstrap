#!/usr/bin/env bash
# dev-setup — the one command a brand-new Mac runs.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/adammcarter/dev-setup-bootstrap/main/bootstrap.sh)" -- setup personal
#
# It clones a private repo and hands over to it. Arguments pass straight through.
#
# Everything it needs, it gets by itself:
#
#   · the Command Line Tools, because a bare Mac has no real git
#   · a GitHub credential — from the environment, the GitHub CLI, the Keychain,
#     a browser sign-in, or a token you paste
#
# Every credential is checked against the API BEFORE it is used, and no single
# bad one can end the run: the search moves on to the next source. That matters
# because the Keychain is sticky — a token saved here once outlives its own
# validity, and a run that trusted it blindly could never be recovered from the
# same machine.
#
# Homebrew and everything downstream belong to dev-setup's own setup.sh. This
# script's job ends the moment that script can be executed.
set -uo pipefail

OWNER="adammcarter"
REPO="dev-setup"
DEST="$HOME/repos/$REPO"
KC_SERVICE="dev-setup-github"
API="https://api.github.com"

# The GitHub CLI's own public OAuth client id. Reusing it lets this script offer
# a browser sign-in, so a new machine needs no personal access token created,
# copied or stored anywhere.
OAUTH_CLIENT_ID="178c6fc778ccc68e1d6a"
OAUTH_SCOPES="repo read:org"

# Pre-selects the scopes and names the token, so the page that opens is already
# filled in and there is nothing to get wrong by hand.
PAT_URL="https://github.com/settings/tokens/new?scopes=repo,read:org&description=dev-setup%20bootstrap"

# How long to wait for the Command Line Tools install, in seconds.
BOOTSTRAP_CLT_WAIT="${BOOTSTRAP_CLT_WAIT:-1800}"

TOKEN=""
TOKEN_SRC=""

# ── output ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; Z=$'\033[0m'
else B=""; D=""; G=""; Y=""; R=""; Z=""; fi

say()  { printf '  %s\n' "$*"; }
note() { printf '  %s%s%s\n' "$D" "$*" "$Z"; }
good() { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*" >&2; }
fail() { printf '\n  %s✗ %s%s\n\n' "$R" "$*" "$Z" >&2; }
die()  { fail "$*"; exit 1; }
head2() { printf '\n  %s%s%s\n\n' "$B" "$*" "$Z"; }

# Flat-JSON field readers. The responses here are single objects of scalars, so
# this is enough — and it keeps the script free of any dependency (python3
# included) that a Mac without developer tools does not reliably have.
json_str() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$2" | head -1; }
json_num() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$2" | head -1; }

# ── the developer tools ─────────────────────────────────────────────────────
# A Mac with no Command Line Tools STILL has /usr/bin/git: a stub that exists
# only to trigger the installer. So `command -v git` succeeds on a machine with
# no git at all, and anything built on that check silently skips the install and
# fails later with a confusing error. Run it instead — the stub exits non-zero.
git_works() { git --version >/dev/null 2>&1; }

ensure_git() {
    git_works && return 0

    say "The Command Line Tools are missing. git comes with them, so they go first."
    note "A macOS dialog will appear — choose Install. It takes a few minutes."
    printf '\n'
    xcode-select --install >/dev/null 2>&1 || true

    local waited=0 spin='|/-\' i=0
    while ! git_works; do
        [ "$waited" -ge "$BOOTSTRAP_CLT_WAIT" ] && break
        if [ -t 1 ]; then
            i=$(( (i + 1) % 4 ))
            printf '\r  %s waiting for the Command Line Tools (%ss)' "${spin:$i:1}" "$waited"
        fi
        sleep 5; waited=$((waited + 5))
    done
    [ -t 1 ] && printf '\r%*s\r' 60 ''

    if git_works; then good "Command Line Tools installed"; return 0; fi

    fail "the Command Line Tools did not finish installing"
    say "If you dismissed the dialog, install them directly and run this again:"
    note "xcode-select --install"
    say "Or, without a dialog:"
    note "sudo xcode-select --install"
    return 1
}

# ── credentials ─────────────────────────────────────────────────────────────
# Ask the API what a token can actually do, rather than finding out from a git
# error. The three outcomes are genuinely different problems and each one gets
# said out loud, because "clone failed" told nobody anything.
#   0  works, and can see the repo
#   1  rejected outright — expired, revoked, or mistyped
#   2  valid, but cannot see this repo — wrong account, or no 'repo' scope
#   3  github.com could not be reached
token_check() {
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $1" \
        -H "Accept: application/vnd.github+json" \
        "$API/repos/$OWNER/$REPO" 2>/dev/null)" || code="000"
    case "$code" in
        200)     return 0 ;;
        401)     return 1 ;;
        403|404) return 2 ;;
        *)       return 3 ;;
    esac
}

# Try one candidate. Adopting it sets TOKEN for the rest of the run; refusing it
# says why and lets the search continue to the next source.
adopt() {
    local src="$1" tok="${2:-}" rc
    [ -n "$tok" ] || return 1
    token_check "$tok"; rc=$?
    case "$rc" in
        0) TOKEN="$tok"; TOKEN_SRC="$src"; good "signed in using $src"; return 0 ;;
        1) warn "$src: that token has expired or been revoked — trying the next option" ;;
        2) warn "$src: that token cannot see $OWNER/$REPO (wrong account, or it is missing the 'repo' scope) — trying the next option" ;;
        *) warn "$src: could not reach github.com to check the token" ;;
    esac
    return 1
}

# A machine can be signed in to the GitHub CLI and still not have it on PATH —
# a login shell that has never opened a new tab since Homebrew arrived has only
# the system directories. Look where it actually gets installed before deciding
# there is no CLI here.
# Take the first CLI that is actually signed in, not merely the first one that
# exists — an unauthenticated gh earlier on PATH must not hide a signed-in one
# installed somewhere else.
gh_token() {
    local c tok
    for c in gh /opt/homebrew/bin/gh /usr/local/bin/gh "$HOME/.local/bin/gh"; do
        command -v "$c" >/dev/null 2>&1 || continue
        tok="$("$c" auth token --hostname github.com 2>/dev/null)"
        if [ -n "$tok" ]; then printf '%s' "$tok"; return 0; fi
    done
    return 1
}

keychain_token() {
    command -v security >/dev/null 2>&1 || return 1
    security find-generic-password -s "$KC_SERVICE" -w 2>/dev/null
}

# Sign in through the browser, using GitHub's device flow. Nothing is created by
# hand and nothing is pasted: the code is shown, copied to the clipboard, and the
# page is opened.
browser_login() {
    local resp device_code user_code uri interval expires waited
    resp="$(curl -sS -X POST "https://github.com/login/device/code" \
        -H "Accept: application/json" \
        -d "client_id=$OAUTH_CLIENT_ID" -d "scope=$OAUTH_SCOPES" 2>/dev/null)" || resp=""
    device_code="$(json_str device_code "$resp")"
    user_code="$(json_str user_code "$resp")"
    uri="$(json_str verification_uri "$resp")"
    interval="$(json_num interval "$resp")"; interval="${interval:-5}"
    expires="$(json_num expires_in "$resp")"; expires="${expires:-900}"

    if [ -z "$device_code" ] || [ -z "$user_code" ]; then
        warn "could not start a browser sign-in"
        return 1
    fi

    printf '\n  %sYour code:  %s%s\n' "$B" "$user_code" "$Z"
    say "Enter it at $uri"
    command -v pbcopy >/dev/null 2>&1 && printf '%s' "$user_code" | pbcopy 2>/dev/null && note "(copied to your clipboard)"
    command -v open   >/dev/null 2>&1 && open "$uri" >/dev/null 2>&1
    printf '\n'

    waited=0
    while [ "$waited" -lt "$expires" ]; do
        local poll err tok
        poll="$(curl -sS -X POST "https://github.com/login/oauth/access_token" \
            -H "Accept: application/json" \
            -d "client_id=$OAUTH_CLIENT_ID" \
            -d "device_code=$device_code" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" 2>/dev/null)" || poll=""
        tok="$(json_str access_token "$poll")"
        if [ -n "$tok" ]; then
            TOKEN="$tok"; TOKEN_SRC="your browser sign-in"
            good "signed in as the GitHub account you approved with"
            return 0
        fi
        err="$(json_str error "$poll")"
        case "$err" in
            authorization_pending) : ;;
            slow_down)             interval=$((interval + 5)) ;;
            expired_token)         warn "the code expired before it was approved"; return 1 ;;
            access_denied)         warn "the sign-in was declined"; return 1 ;;
            "")                    warn "no answer from github.com — retrying" ;;
            *)                     warn "sign-in failed: $err"; return 1 ;;
        esac
        sleep "$interval"; waited=$((waited + interval))
    done
    warn "timed out waiting for the sign-in to be approved"
    return 1
}

paste_token() {
    say "Open this — the scopes and the name are already filled in:"
    note "$PAT_URL"
    command -v open >/dev/null 2>&1 && open "$PAT_URL" >/dev/null 2>&1
    printf '\n  Paste the token (it stays hidden): '
    local tok=""; ask tok -s || { warn "could not read the token"; return 1; }; printf '\n\n'
    [ -n "$tok" ] || { warn "nothing pasted"; return 1; }
    adopt "the token you pasted" "$tok"
}

# Whether there is anyone to ask. `test -r /dev/tty` answers a different
# question — it says the device node is readable, which stays true in a session
# that has no controlling terminal to open. Opening it is the real test, and
# getting this wrong sends an unattended run into a browser sign-in nobody can
# approve, where it blocks until the code expires.
can_ask() {
    { exec 3</dev/tty; } 2>/dev/null || return 1
    exec 3<&-
    return 0
}

ask() { # ask <varname> [-s]
    local __v="$1"; shift
    if ! read -r "$@" "$__v" </dev/tty; then return 1; fi
}

interactive_login() {
    if ! can_ask; then
        fail "no GitHub credential, and no terminal to ask on"
        say "Give it one and run the same command again:"
        note "export GH_TOKEN=…"
        say "Create the token here — the scopes are already filled in:"
        note "$PAT_URL"
        return 1
    fi

    while :; do
        printf '\n  %sHow would you like to sign in to GitHub?%s\n\n' "$B" "$Z"
        say "1) with your browser   ${D}— recommended, nothing to create or store${Z}"
        say "2) paste a token       ${D}— if you would rather manage it yourself${Z}"
        printf '\n  Choose [1]: '
        local choice=""; ask choice || { warn "could not read your answer"; return 1; }
        printf '\n'
        case "${choice:-1}" in
            1|"") browser_login && return 0 ;;
            2)    paste_token   && return 0 ;;
            *)    warn "pick 1 or 2"; continue ;;
        esac
        printf '\n  Try again? [Y/n]: '
        local again=""; ask again || return 1
        case "$again" in [Nn]*) return 1 ;; esac
    done
}

# Cheapest and least surprising first. Each source is verified, and a bad one is
# stepped over rather than being allowed to end the run.
resolve_token() {
    adopt "a token from the environment" "${GH_TOKEN:-${GITHUB_TOKEN:-}}" && return 0
    adopt "the GitHub CLI"               "$(gh_token       2>/dev/null)"  && return 0
    adopt "the token in your Keychain"   "$(keychain_token 2>/dev/null)"  && return 0
    interactive_login
}

# Save what worked, so no later machine or re-run has to ask. -U replaces any
# entry already there — which is what makes a stale token self-healing rather
# than something to be deleted by hand.
remember_token() {
    [ -n "$TOKEN" ] || return 0
    case "$TOKEN_SRC" in *Keychain*) return 0 ;; esac
    command -v security >/dev/null 2>&1 || return 0
    if security add-generic-password -U -s "$KC_SERVICE" -a "${USER:-$(id -un)}" \
         -l "dev-setup GitHub token" -w "$TOKEN" >/dev/null 2>&1; then
        note "saved to your Keychain — the next machine will not ask"
    fi
}

# ── the repo ────────────────────────────────────────────────────────────────
clone_or_update() {
    local auth_hdr clean_url
    auth_hdr="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
    clean_url="https://github.com/${OWNER}/${REPO}.git"
    local auth=(-c "http.https://github.com/.extraheader=$auth_hdr")

    # The token is known good by this point, so prompting can only ever hang or
    # produce a misleading "could not read Username". Keep it off and own the
    # error message instead.
    export GIT_TERMINAL_PROMPT=0

    if [ -d "$DEST/.git" ]; then
        say "updating the existing checkout at ~/repos/$REPO"
        git -C "$DEST" remote set-url origin "$clean_url" 2>/dev/null
        if ! git "${auth[@]}" -C "$DEST" fetch -q --all; then
            fail "could not fetch ${OWNER}/${REPO}"
            say "The credential works, so this is github.com or your network."
            return 1
        fi
        git -C "$DEST" checkout -q main && git -C "$DEST" reset -q --hard origin/main
        git -C "$DEST" remote set-url origin "$clean_url" 2>/dev/null
    else
        say "cloning into ~/repos/$REPO"
        mkdir -p "$(dirname "$DEST")"
        if ! git "${auth[@]}" clone -q "$clean_url" "$DEST"; then
            fail "could not clone ${OWNER}/${REPO}"
            say "The credential was accepted by github.com, so this is not the token."
            say "Check your network, then run the same command again."
            return 1
        fi
        git -C "$DEST" remote set-url origin "$clean_url" 2>/dev/null
    fi
    good "dev-setup is at ~/repos/$REPO"
}

usage() {
    printf '\n  %sdev-setup bootstrap%s\n\n' "$B" "$Z"
    say 'Clones adammcarter/dev-setup and runs it. Arguments pass through.'
    printf '\n'
    note '/bin/bash -c "$(curl -fsSL <this url>)" -- setup personal'
    note '/bin/bash -c "$(curl -fsSL <this url>)" -- setup work --dry-run'
    note '/bin/bash -c "$(curl -fsSL <this url>)" -- backup'
    printf '\n'
    say "Set GH_TOKEN to skip the sign-in. Create one at:"
    note "$PAT_URL"
    printf '\n'
}

main() {
    case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

    head2 "dev-setup"

    ensure_git   || exit 1
    resolve_token || die "cannot reach a private repo without a GitHub credential"
    remember_token
    clone_or_update || exit 1

    printf '\n'
    exec "$DEST/run.sh" "$@"
}

# Sourced by the test-suite as a library; run as a script by everyone else.
if [ "${BOOTSTRAP_LIB:-0}" != "1" ]; then
    main "$@"
fi
