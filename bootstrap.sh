#!/usr/bin/env bash
# Clones a private repo and runs it. Arguments pass straight through.
# Credential order: $GH_TOKEN / $GITHUB_TOKEN, the GitHub CLI, the Keychain, prompt.
set -euo pipefail
OWNER="adammcarter"
REPO="dev-setup"
DEST="$HOME/repos/$REPO"
KC_SERVICE="dev-setup-github"
ARGS="${*:-}"

say()  { printf '  %s\n' "$*"; }
die()  { printf '\n  ✗ %s\n\n' "$*" >&2; exit 1; }

printf '\n  dev-setup\n\n'

TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$TOKEN" ] && say "using a token from the environment"

if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then
    TOKEN="$(gh auth token --hostname github.com 2>/dev/null || true)"
    [ -n "$TOKEN" ] && say "using the GitHub CLI's token"
fi

if [ -z "$TOKEN" ] && command -v security >/dev/null 2>&1; then
    TOKEN="$(security find-generic-password -s "$KC_SERVICE" -w 2>/dev/null || true)"
    [ -n "$TOKEN" ] && say "using the token from your iCloud Keychain"
fi

if [ -z "$TOKEN" ]; then
    say "No stored credential found."
    say "Create a token with 'repo' scope: https://github.com/settings/tokens"
    printf '\n  GitHub token: '
    read -rs TOKEN; printf '\n\n'
    [ -n "$TOKEN" ] || die "no token given — cannot reach a private repo"
    if command -v security >/dev/null 2>&1; then
        if security add-generic-password -U -s "$KC_SERVICE" -a "${USER:-$(id -un)}" \
             -l "dev-setup GitHub token" -w "$TOKEN" >/dev/null 2>&1; then
            say "saved to your Keychain — future machines will not ask"
        fi
    fi
fi

if ! command -v git >/dev/null 2>&1; then
    say "installing Command Line Tools (git) — accept the dialog if it appears"
    xcode-select --install 2>/dev/null || true
    until command -v git >/dev/null 2>&1; do sleep 5; done
fi

AUTH_HDR="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
CLEAN_URL="https://github.com/${OWNER}/${REPO}.git"
GIT_AUTH=(-c "http.https://github.com/.extraheader=$AUTH_HDR")

if [ -d "$DEST/.git" ]; then
    say "updating the existing checkout at ~/repos/$REPO"
    git -C "$DEST" remote set-url origin "$CLEAN_URL"
    GIT_TERMINAL_PROMPT=0 git "${GIT_AUTH[@]}" -C "$DEST" fetch -q --all || die "fetch failed — is the token still valid?"
    git -C "$DEST" checkout -q main && git -C "$DEST" reset -q --hard origin/main
    git -C "$DEST" remote set-url origin "$CLEAN_URL"
else
    say "cloning into ~/repos/$REPO"
    mkdir -p "$(dirname "$DEST")"
    GIT_TERMINAL_PROMPT=0 git "${GIT_AUTH[@]}" clone -q "$CLEAN_URL" "$DEST" \
        || die "clone failed — token rejected, or no access to ${OWNER}/${REPO}"
    git -C "$DEST" remote set-url origin "$CLEAN_URL"
fi
say "got it"

printf '\n'
exec "$DEST/run.sh" ${ARGS:+$ARGS}
