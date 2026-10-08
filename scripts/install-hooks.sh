#!/bin/bash
# Installs a pre-commit hook that runs the leak check on the files being committed.
set -euo pipefail
HOOK="$(git rev-parse --git-dir)/hooks/pre-commit"
cat > "$HOOK" <<'HOOKEOF'
#!/bin/bash
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git diff --cached --name-only --diff-filter=ACM -z | while IFS= read -r -d '' f; do
  mkdir -p "$T/$(dirname "$f")"; git show ":$f" > "$T/$f"
done
exec "$(git rev-parse --show-toplevel)/scripts/check-public.sh" "$T"
HOOKEOF
chmod +x "$HOOK"
echo "installed $HOOK"
