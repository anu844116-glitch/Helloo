#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(dirname -- "$(readlink -f -- "$0")")"
ENV_FILE="${NEXUS_DIR:-/opt/nexus}/tokens.env"
mkdir -p -- "$(dirname -- "$ENV_FILE")"
if [[ ! -f "$ENV_FILE" && -f "$ROOT/nexus.env" ]]; then
    cp -f "$ROOT/nexus.env" "$ENV_FILE"
    echo "(purana nexus.env import kiya)"
fi
TMP_FILE="$ENV_FILE.tmp"

declare -a TOKENS=()

cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup EXIT

if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^BOT_[0-9]+_TOKEN=(.*)$ ]] || continue
        token="${BASH_REMATCH[1]}"
        [[ -n "$token" ]] && TOKENS+=("$token")
    done < "$ENV_FILE"
fi

echo "================================"
echo "       NEXUS TOKEN MANAGER"
echo "================================"
echo "Saved unique tokens: ${#TOKENS[@]}"
echo

added=0
while true; do
    read -r -s -p "Enter Telegram Bot Token (Enter = save & exit): " TOKEN
    echo

    TOKEN="${TOKEN//[[:space:]]/}"

    if [[ -z "$TOKEN" ]]; then
        if (( ${#TOKENS[@]} == 0 )); then
            echo "Empty — kuch save nahi hua."
        elif (( added == 0 )); then
            echo "Kuch naya nahi — file waisi hi hai."
        else
            echo "Enter mila — ${#TOKENS[@]} token save ho rahe hain."
        fi
        break
    fi

    if [[ ! "$TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        echo "ERROR: Invalid token format."
        continue
    fi

    duplicate=false
    for saved in "${TOKENS[@]}"; do
        [[ "$TOKEN" == "$saved" ]] && { duplicate=true; break; }
    done
    if [[ "$duplicate" == true ]]; then
        echo "Already saved — skip. (Enter = exit)"
        continue
    fi

    TOKENS+=("$TOKEN")
    added=$((added + 1))
    echo "Added (#${#TOKENS[@]}). Enter = save & exit, ya next token paste karo."
done

if (( ${#TOKENS[@]} == 0 )); then
    echo "File empty — kuch save nahi."
    exit 0
fi

: > "$TMP_FILE"

for i in "${!TOKENS[@]}"; do
    printf 'BOT_%s_TOKEN=%s\n' "$((i + 1))" "${TOKENS[$i]}" >> "$TMP_FILE"
done

chmod 600 "$TMP_FILE"
mv -f "$TMP_FILE" "$ENV_FILE"
trap - EXIT

echo
echo "Saved ${#TOKENS[@]} unique tokens."
echo "Environment file permissions: 600"
echo "Token values were not displayed."

echo "nexus.sh in tokens ko utha kar har token ka alag instance chalayega."
