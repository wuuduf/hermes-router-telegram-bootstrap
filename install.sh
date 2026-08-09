#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="wuuduf/hermes-router-telegram-bootstrap"
BRANCH="${BOOTSTRAP_BRANCH:-main}"
URL="https://raw.githubusercontent.com/$REPO/$BRANCH/bootstrap-hermes-router-telegram.sh"
TMP_SCRIPT="$(mktemp /tmp/hermes-router-installer.XXXXXX.sh)"

cleanup() {
  rm -f -- "$TMP_SCRIPT"
}
trap cleanup EXIT

curl --proto '=https' --tlsv1.2 -fsSL "$URL" -o "$TMP_SCRIPT"
chmod 700 "$TMP_SCRIPT"
bash "$TMP_SCRIPT" "$@"
