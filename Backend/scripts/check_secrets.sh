#!/usr/bin/env bash
set -euo pipefail

patterns='(sk-ant-api03-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'

if git grep -nEI "$patterns" -- \
  ':!Backend/scripts/check_secrets.sh' \
  ':!Backend/uv.lock'
then
  echo "Potential committed secret detected." >&2
  exit 1
fi

echo "No high-confidence committed secret patterns found."
