#!/bin/sh
#
#  box-app-credentials.sh
#  FinvestLens
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
#  Puts FinvestLens's own Box app — its client ID and secret — into a build,
#  without either one ever being in the source tree, in git, or in a log.
#
#  The values live in the login Keychain of the Mac that builds, as two items
#  (service com.hellotham.finvestlens.box-app, accounts client-id and
#  client-secret) that /usr/bin/security may read without asking. Store them
#  once per Mac. The ID and secret are read from the terminal, the secret
#  without being shown, or as two lines on standard input:
#
#      scripts/box-app-credentials.sh store
#
#  As the app target's "Embed Box App" build phase, it reads them and writes
#  $DERIVED_FILE_DIR/BoxAppCredentials.swift — in the build folder, compiled
#  with the app — masked (XOR with a key derived from them), so neither is plain
#  text in the binary. The file is rewritten only when its content would
#  change, so an unchanged build compiles nothing again. It prints only whether
#  the values were found.
#
#  Without them (CI, a build from the public source) the file says there is no
#  built-in Box app, and the app asks for a Box app of the person's own, as it
#  always did. A Release build stops instead, so that no published build asks,
#  unless FL_BOX_APP_OPTIONAL=1.

set -eu
# Never traced, whatever the caller exported (`SHELLOPTS=xtrace`, `sh -x`):
# a trace prints every assignment, the values included, into the build log.
set +x
set -o pipefail 2>/dev/null || true

SERVICE=com.hellotham.finvestlens.box-app

# Every value goes through shell builtins and pipes only — never into a
# command's arguments or environment, where any process on the Mac can read it.

lookup() {  # $1 = account → $found (the value, or empty) and $status (security's)
    if found=$(/usr/bin/security find-generic-password -s "$SERVICE" -a "$1" -w 2>/dev/null); then
        status=0
    else
        status=$?
        found=
    fi
}

is_box_token() {  # Box client IDs and secrets are letters and digits
    case $1 in
        '' | *[!A-Za-z0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

put() {  # $1 = account, $2 = value — fed to `security -i` on standard input
    printf 'add-generic-password -U -s %s -a %s -T /usr/bin/security -w %s\n' "$SERVICE" "$1" "$2" \
        | /usr/bin/security -i >/dev/null
}

store() {
    id=
    secret=
    if [ -t 0 ]; then
        printf 'Box client ID: '
        IFS= read -r id || true
        printf 'Box client secret (not shown): '
        # Echo comes back however the prompt ends — ⌃C included.
        trap 'stty echo; echo' INT TERM
        stty -echo
        IFS= read -r secret || true
        stty echo
        trap - INT TERM
        echo
    else
        IFS= read -r id || true
        IFS= read -r secret || true
    fi
    is_box_token "$id" || { echo "That is not a Box client ID (letters and digits)." >&2; exit 1; }
    is_box_token "$secret" || { echo "That is not a Box client secret (letters and digits)." >&2; exit 1; }
    put client-id "$id"
    put client-secret "$secret"
    lookup client-id; stored_id=$found
    lookup client-secret; stored_secret=$found
    if [ "$stored_id" = "$id" ] && [ "$stored_secret" = "$secret" ]; then
        echo "Stored in the login Keychain (service $SERVICE): a client ID of ${#id} characters and a secret of ${#secret}."
    else
        echo "The Keychain did not keep them." >&2
        exit 1
    fi
}

bytes() {  # $1 = a value → its bytes, one decimal a line
    printf '%s' "$1" | /usr/bin/od -An -v -tu1 | tr -s ' \t' '\n\n' | sed '/^$/d'
}

key_list() {  # 32 key bytes from both values — the same values, the same file —
              # in the shell itself: FNV-1a over the bytes seeds a linear
              # congruential stream. (`shasum` is a Perl script, which a stray
              # PERL5OPT breaks; it once left the key empty and the build said
              # "built in" over nothing.)
    seed=$( { bytes "$1"; echo 10; bytes "$2"; } | {
        hash=2166136261
        while read -r byte; do hash=$(( ((hash ^ byte) * 16777619) & 4294967295 )); done
        echo "$hash"
    })
    state=$seed
    sep=
    index=0
    while [ "$index" -lt 32 ]; do
        state=$(( (state * 1103515245 + 12345) & 2147483647 ))
        printf '%s%d' "$sep" $(( (state >> 16) & 255 ))
        sep=', '
        index=$(( index + 1 ))
    done
}

mask() {  # $1 = a value, $2 = the key list → the value's bytes XOR the key
    bytes "$1" | {
        set -- $(printf '%s' "$2" | tr -d ',')
        count=$#
        index=0
        sep=
        while read -r byte; do
            eval "key=\${$(( index % count + 1 ))}"
            printf '%s%d' "$sep" $(( byte ^ key ))
            sep=', '
            index=$(( index + 1 ))
        done
    }
}

mask_list() {  # $1 = a masked list, $2 = the key list → the bytes, comma-joined
    printf '%s\n' "$1" | tr ',' '\n' | sed '/^ *$/d' | {
        set -- $(printf '%s' "$2" | tr -d ',')
        count=$#
        index=0
        out=
        while read -r byte; do
            eval "key=\${$(( index % count + 1 ))}"
            out="$out${out:+,}$(( byte ^ key ))"
            index=$(( index + 1 ))
        done
        printf '%s' "$out"
    }
}

entries() {  # how many numbers a list holds (the newline counts the last)
    printf '%s\n' "$1" | tr ',' '\n' | sed '/^ *$/d' | wc -l | tr -d ' '
}

render() {  # from $KEY, $ID_LIST and $SECRET_LIST, which embed() has checked
    echo '// Generated by scripts/box-app-credentials.sh into the build folder for'
    echo '// this build. Never copy it into the source tree.'
    echo 'enum GeneratedBoxApp {'
    if [ -n "$ID" ] && [ -n "$SECRET" ]; then
        echo '    static let masked: (key: [UInt8], id: [UInt8], secret: [UInt8])? = ('
        echo "        key: [$KEY],"
        echo "        id: [$ID_LIST],"
        echo "        secret: [$SECRET_LIST])"
    else
        echo '    static let masked: (key: [UInt8], id: [UInt8], secret: [UInt8])? = nil'
    fi
    echo '}'
}

fail() {  # every configuration: a build that says "built in" must be
    echo "error: FinvestLens's Box app could not be built in: $1"
    exit 1
}

embed() {
    if [ -z "${DERIVED_FILE_DIR:-}" ]; then
        echo "Run as the app target's build phase; to store the values: $0 store" >&2
        exit 2
    fi
    lookup client-id; ID=$found; id_status=$status
    lookup client-secret; SECRET=$found; secret_status=$status
    if ! is_box_token "$ID" || ! is_box_token "$SECRET"; then
        ID=
        SECRET=
        if [ "$id_status" = 44 ] && [ "$secret_status" = 44 ]; then
            why="not in the login Keychain"
        else
            why="not to be read from the login Keychain (security exited $id_status and $secret_status: 44 is an item not there; others are a locked Keychain, a refused prompt, or a value not a Box ID)"
        fi
        if [ "${CONFIGURATION:-}" = Release ] && [ "${FL_BOX_APP_OPTIONAL:-}" != 1 ]; then
            echo "error: FinvestLens's Box app is $why. Store it with scripts/box-app-credentials.sh store, or set FL_BOX_APP_OPTIONAL=1 for a build that asks for a Box app of the person's own."
            exit 1
        fi
        echo "note: FinvestLens's Box app is $why: this build asks for a Box app of the person's own."
    else
        # Each list made and checked before anything is written: a step of the
        # masking that fails inside `$(…)` stops nothing by itself.
        KEY=$(key_list "$ID" "$SECRET") || fail "the key could not be made"
        ID_LIST=$(mask "$ID" "$KEY") || fail "the client ID could not be masked"
        SECRET_LIST=$(mask "$SECRET" "$KEY") || fail "the secret could not be masked"
        [ "$(entries "$KEY")" = 32 ] || fail "the key is not 32 bytes"
        [ "$(entries "$ID_LIST")" = "${#ID}" ] || fail "the masked client ID is the wrong length"
        [ "$(entries "$SECRET_LIST")" = "${#SECRET}" ] || fail "the masked secret is the wrong length"
        # Unmasked again here, as the app will: the bytes must come back.
        [ "$(mask_list "$ID_LIST" "$KEY")" = "$(bytes "$ID" | paste -sd, -)" ] \
            || fail "the client ID does not unmask to itself"
        [ "$(mask_list "$SECRET_LIST" "$KEY")" = "$(bytes "$SECRET" | paste -sd, -)" ] \
            || fail "the secret does not unmask to itself"
        echo "note: FinvestLens's Box app is built in."
    fi
    output="$DERIVED_FILE_DIR/BoxAppCredentials.swift"
    mkdir -p "$DERIVED_FILE_DIR"
    new=$(render)
    old=$(cat "$output" 2>/dev/null || true)
    [ "$new" = "$old" ] || printf '%s\n' "$new" > "$output"
}

case "${1:-embed}" in
    store) store ;;
    embed) embed ;;
    *) echo "usage: $0 [store]" >&2; exit 2 ;;
esac
