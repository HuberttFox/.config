#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rime-bootstrap-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 missing <$2>"; }
assert_not_contains() { if grep -Fq -- "$2" "$1"; then fail "$1 unexpectedly contains <$2>"; fi; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected <$2>, got <$1>"; }

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/fake-repo/windows-bootstrap"
cat > "$TMP_ROOT/fake-repo/install.sh" <<'EOF'
#!/usr/bin/env bash
printf 'darwin:%s\n' "$*" > "${BOOTSTRAP_LOG:?}"
exit "${BOOTSTRAP_EXIT:-0}"
EOF
cat > "$TMP_ROOT/fake-repo/windows-bootstrap/install.ps1" <<'EOF'
# fixture only
EOF
chmod +x "$TMP_ROOT/fake-repo/install.sh"
cp "$ROOT_DIR/bootstrap.sh" "$TMP_ROOT/fake-repo/bootstrap.sh"
chmod +x "$TMP_ROOT/fake-repo/bootstrap.sh"
DISPATCHER="$TMP_ROOT/fake-repo/bootstrap.sh"

cat > "$TMP_ROOT/bin/pwsh.exe" <<'EOF'
#!/usr/bin/env bash
printf 'pwsh:%s\n' "$*" > "${BOOTSTRAP_LOG:?}"
exit "${BOOTSTRAP_EXIT:-0}"
EOF
cat > "$TMP_ROOT/bin/cygpath" <<'EOF'
#!/usr/bin/env bash
printf 'C:\\fixture path\\windows-bootstrap\\install.ps1\n'
EOF
chmod +x "$TMP_ROOT/bin/pwsh.exe" "$TMP_ROOT/bin/cygpath"

printf 'case: Darwin delegates relative to dispatcher root\n'
: > "$TMP_ROOT/log"
BOOTSTRAP_LOG="$TMP_ROOT/log" RIME_BOOTSTRAP_UNAME=Darwin "$DISPATCHER" --x '中文 & value'
assert_contains "$TMP_ROOT/log" 'darwin:--x 中文 & value'

printf 'case: Windows shell converts root and forwards args\n'
: > "$TMP_ROOT/log"
PATH="$TMP_ROOT/bin:$PATH" BOOTSTRAP_LOG="$TMP_ROOT/log" RIME_BOOTSTRAP_UNAME=MINGW64 "$DISPATCHER" --root 'C:\Program Files\Rime' 'a;b'
assert_contains "$TMP_ROOT/log" 'pwsh:-NoProfile -ExecutionPolicy Bypass -File C:\fixture path\windows-bootstrap\install.ps1 --root C:\Program Files\Rime a;b'
assert_not_contains "$TMP_ROOT/log" 'darwin:'

printf 'case: Windows falls back to Windows PowerShell when pwsh is missing\n'
mkdir -p "$TMP_ROOT/bin51"
cat > "$TMP_ROOT/bin51/powershell.exe" <<'EOF'
#!/usr/bin/env bash
printf 'powershell:%s\n' "$*" > "${BOOTSTRAP_LOG:?}"
exit "${BOOTSTRAP_EXIT:-0}"
EOF
chmod +x "$TMP_ROOT/bin51/powershell.exe"
: > "$TMP_ROOT/log"
PATH="$TMP_ROOT/bin51:/usr/bin:/bin" BOOTSTRAP_LOG="$TMP_ROOT/log" RIME_BOOTSTRAP_WINDOWS_ROOT='C:\ps51 root' RIME_BOOTSTRAP_UNAME=MINGW64 "$DISPATCHER" -Profile Base 'x y'
assert_contains "$TMP_ROOT/log" 'powershell:-NoProfile -ExecutionPolicy Bypass -File C:\ps51 root/windows-bootstrap/install.ps1 -Profile Base x y'

printf 'case: missing PowerShell returns 127\n'
if PATH="/usr/bin:/bin" RIME_BOOTSTRAP_UNAME=MSYS_NT "$DISPATCHER" >/dev/null 2>&1; then
  fail 'missing PowerShell accepted'
else
  assert_eq "$?" '127'
fi

printf 'case: Linux rejects without invoking installer\n'
if RIME_BOOTSTRAP_UNAME=Linux "$DISPATCHER" >/dev/null 2>&1; then
  fail 'Linux accepted'
else
  assert_eq "$?" '2'
fi

printf 'case: Windows fallback uses dispatcher root, not caller cwd\n'
rm -f "$TMP_ROOT/bin/cygpath"
cat > "$TMP_ROOT/bin/pwd" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -W ]]; then printf 'C:\\fallback root\n'; else /bin/pwd "$@"; fi
EOF
chmod +x "$TMP_ROOT/bin/pwd"
: > "$TMP_ROOT/log"
PATH="$TMP_ROOT/bin:$PATH" BOOTSTRAP_LOG="$TMP_ROOT/log" RIME_BOOTSTRAP_WINDOWS_ROOT='C:\fallback root' RIME_BOOTSTRAP_UNAME=CYGWIN_NT "$DISPATCHER" --flag
assert_contains "$TMP_ROOT/log" 'pwsh:-NoProfile -ExecutionPolicy Bypass -File C:\fallback root/windows-bootstrap/install.ps1 --flag'

printf 'PASS\n'
