#!/usr/bin/env bash
# =============================================================================
# bw-login.sh - Bitwarden CLI login + unlock helper
# =============================================================================
# What it does:
#   One step: checks `bw status`, runs `bw login` interactively if the CLI is
#   unauthenticated, unlocks the vault, and hands the session key to the
#   calling shell.
#
# How it is invoked:
#   eval "$(bw-login)"
#   eval is required: a child process cannot export variables into its
#   parent shell, so the export line must be evaluated by the calling shell.
#   Stdout carries ONLY `export BW_SESSION='<key>'` (single-quoted; the
#   session key is base64 and contains no quote characters). Every
#   human-facing note goes to stderr, so eval never sees it.
#
# FIDO2-only 2FA:
#   Password-based `bw login` is blocked for FIDO2-only accounts (the CLI
#   has no WebAuthn support), and the interactive API-key prompts of
#   `bw login --apikey` don't compose inside this generic flow - run
#   `bw login --apikey` manually first (it prompts for the personal API
#   key's client_id/client_secret, or reads BW_CLIENTID/BW_CLIENTSECRET
#   from your shell environment), then re-run this helper to unlock.
# =============================================================================
set -euo pipefail

# `bw status` prints a JSON object. BW_NOINTERACTION=true keeps any prompt
# from hanging a non-interactive call, and BW_RESPONSE=false pins plain
# output — a caller's BW_RESPONSE=true would wrap every bw call in a JSON
# envelope (upstream base-program.ts checks both against the string "true",
# and the envelope wins even over --raw). The status field is parsed with
# python3 so BW_PRETTY=true's spaced JSON ("status": "locked") parses the
# same as compact. An unparseable body yields an empty status, which the
# case statement below rejects loudly.
BW_STATUS_JSON=$(BW_NOINTERACTION=true BW_RESPONSE=false bw status)
BW_STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<< "${BW_STATUS_JSON}" 2>/dev/null || true)

case "${BW_STATUS}" in
    unlocked)
        echo "bw: vault already unlocked in this shell (BW_SESSION set) - nothing to do" >&2
        exit 0
        ;;
    unauthenticated)
        echo "bw: not logged in - starting interactive login" >&2
        bw login >&2
        key=$(BW_RESPONSE=false bw unlock --raw)
        ;;
    locked)
        echo "bw: vault locked - unlock to get a session key" >&2
        key=$(BW_RESPONSE=false bw unlock --raw)
        ;;
    *)
        echo "bw-login: unexpected bw status '${BW_STATUS}' (expected unlocked, unauthenticated or locked)" >&2
        exit 1
        ;;
esac

if [ -z "${key}" ]; then
    echo "bw-login: unlock produced no session key" >&2
    exit 1
fi

# Stdout only - the caller evals this output.
printf "export BW_SESSION='%s'\n" "${key}"
