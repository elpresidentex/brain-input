#!/bin/bash
# Links Vendor/whisper.xcframework to the prebuilt framework from VoiceInk's whisper.cpp build.
# Idempotent; safe to run any time. Override the source with WHISPER_XCFRAMEWORK=/path/to/whisper.xcframework.
#   scripts/setup-vendor.sh                 link the framework into this checkout
#   scripts/setup-vendor.sh --install-hook  also add a git post-checkout hook so every new
#                                           `git worktree add` (Claude Code worktrees too) runs this
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${WHISPER_XCFRAMEWORK:-$HOME/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework}"
DST=Vendor/whisper.xcframework

if [ "${1:-}" = "--install-hook" ]; then
  HOOKS="$(git rev-parse --git-path hooks)"
  HOOK="$HOOKS/post-checkout"
  MARK="# brain-input: setup-vendor"
  if [ -f "$HOOK" ] && grep -qF "$MARK" "$HOOK"; then
    echo "hook already installed: $HOOK"
  else
    mkdir -p "$HOOKS"
    [ -f "$HOOK" ] || printf '#!/bin/sh\n' > "$HOOK"
    cat >> "$HOOK" <<HOOK
$MARK (links Vendor/whisper.xcframework in new checkouts and worktrees; never blocks checkout)
[ -x scripts/setup-vendor.sh ] && scripts/setup-vendor.sh --quiet || true
HOOK
    chmod +x "$HOOK"
    echo "installed hook: $HOOK"
  fi
fi

if [ -d "$DST/" ] && [ -n "$(ls -A "$DST/" 2>/dev/null)" ]; then
  [ "${1:-}" = "--quiet" ] || echo "ok: $DST -> $(readlink "$DST" || echo '(directory)')"
  exit 0
fi
if [ ! -d "$SRC" ]; then
  echo "error: whisper.xcframework not found at $SRC" >&2
  echo "  Build it with VoiceInk's whisper.cpp (build-xcframework.sh) or point WHISPER_XCFRAMEWORK at a copy." >&2
  [ "${1:-}" = "--quiet" ] && exit 0 || exit 1
fi
mkdir -p Vendor
ln -sfn "$SRC" "$DST"
[ "${1:-}" = "--quiet" ] || echo "linked: $DST -> $SRC"
