#!/bin/sh
# The whole gate: unit tests, typecheck, installer round trip, dependency audit, and (with --e2e)
# the real end-to-end suites against live Claude Code sessions.
#   sh scripts/test.sh          fast gate (~1 min)
#   sh scripts/test.sh --e2e    plus core + app E2E (~6 min, uses Haiku tokens)
set -eu
cd "$(dirname "$0")/.."
step() { printf '\n== %s\n' "$*"; }

step "channel: unit + integration (node:test)"
(cd channel && node --test --test-reporter=dot test/*.test.ts)
step "channel: typecheck (tsc --noEmit)"
(cd channel && npx --no-install tsc -p .)
step "supervisor + installer config edits (node:test)"
node --test --test-reporter=dot bin/test/*.test.mjs install/test/*.test.mjs
step "tts sidecar gate (unittest)"
(cd tts && python3 -m unittest -q test_server.py)
step "app: BossCore (Swift Testing)"
sh app/scripts/test.sh 2>&1 | tail -1
step "installer round trip (sandbox)"
sh install/test/install.test.sh
step "dependency audit: zero high/critical"
(cd channel && npm audit --audit-level=high --omit=dev && npm audit --audit-level=high)
if [ -x "${PIP_AUDIT:-}" ]; then "$PIP_AUDIT" -r tts/requirements.lock; else echo "pip-audit not set (PIP_AUDIT=/path/to/pip-audit to include the tts lockfile)"; fi
step "no secrets in the tree"
if git grep -n -I -E '(sk-ant-[A-Za-z0-9]|ghp_[A-Za-z0-9]{20}|BEGIN (RSA |EC )?PRIVATE KEY|bot[0-9]{8,}:[A-Za-z0-9_-]{30})' -- . ':!scripts/test.sh'; then echo "secret-looking string found"; exit 1; else echo "clean"; fi

if [ "${1:-}" = "--e2e" ]; then
  step "E2E core (real Boss + real worker sessions)"
  node --test --test-reporter=spec --test-timeout=900000 e2e/core.e2e.mjs
  step "E2E app (real Boss.app + whisper + Boss + workers)"
  node --test --test-reporter=spec --test-timeout=900000 e2e/app.e2e.mjs
fi
printf '\nALL GREEN\n'
