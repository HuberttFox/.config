#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REAL_HOME="$HOME"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export XDG_STATE_HOME="$TMP_ROOT/state"
export INSTALLER_STATE_DIR="$TMP_ROOT/state/dotfiles-installer"
export STUB_STATE="$TMP_ROOT/stub-state"
export STUB_LOG="$TMP_ROOT/commands.log"
mkdir -p "$HOME" "$TMP_ROOT/bin" "$STUB_STATE"
[[ "$HOME" != "$REAL_HOME" ]] || { printf 'Refusing real HOME\n' >&2; exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file $1"; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "expected absent $1"; }
assert_contains() { grep -Fq "$2" "$1" || fail "$1 missing $2"; }
assert_not_contains() { ! grep -Fq "$2" "$1" || fail "$1 unexpectedly contains $2"; }

cat > "$TMP_ROOT/bin/stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "$STUB_LOG"
case "$name" in
  uname) printf '%s\n' "${STUB_UNAME:-Darwin}" ;;
  brew)
    case "${1:-}" in
      shellenv) printf 'export PATH="%s/bin:$PATH"\n' "$(dirname "$STUB_STATE")" ;;
      list)
        kind="$2"; pkg="$3"; grep -Fqx "$kind:$pkg" "$STUB_STATE/packages" 2>/dev/null ;;
      tap)
        if [[ $# -eq 1 ]]; then cut -d: -f2- "$STUB_STATE/taps" 2>/dev/null || true
        else printf 'tap:%s\n' "$2" >> "$STUB_STATE/taps"; fi ;;
      install)
        if [[ "${2:-}" == --cask ]]; then printf '%s\n' "--cask:$3" >> "$STUB_STATE/packages"
        else printf '%s\n' "--formula:$2" >> "$STUB_STATE/packages"; fi ;;
    esac ;;
  git)
    if [[ "${1:-}" == clone ]]; then
      dest="$3"; mkdir -p "$dest/bin"; : > "$dest/tpm"; chmod +x "$dest/tpm"
      cat > "$dest/bin/install_plugins" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
      chmod +x "$dest/bin/install_plugins"
    fi ;;
  curl)
    out=""; while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { out="$2"; shift 2; continue; }; shift; done
    [[ -n "$out" ]] && { mkdir -p "$(dirname "$out")"; cat > "$out" <<'EOF'
if [[ "${1:-}" == init ]]; then
  mkdir -p "$HOME/.zim"
  printf '# init\n' > "$HOME/.zim/init.zsh"
fi
EOF
    } ;;
  zsh)
    if [[ "${1:-}" == -c ]]; then
      mkdir -p "$HOME/.zim"; printf '# init\n' > "$HOME/.zim/init.zsh"
    fi ;;
  ps) printf '%s\n' "${CURRENT_SHELL_PATH:-/bin/zsh}" ;;
  dscl) printf 'UserShell: /bin/zsh\n' ;;
  sudo|chsh) fail=1; printf 'unsafe command invoked: %s\n' "$name" >&2; exit 99 ;;
  tmux) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP_ROOT/bin/stub"
for name in uname brew git curl zsh ps dscl sudo chsh tmux fzf starship lazygit vim yazi; do
  ln -s stub "$TMP_ROOT/bin/$name"
done
export PATH="$TMP_ROOT/bin:/usr/bin:/bin:/usr/sbin:/sbin"

run_installer() { "$ROOT_DIR/install.sh" --no-shell-switch "$@"; }
run_zsh_installer() { CURRENT_SHELL_PATH=/bin/zsh "$ROOT_DIR/install.sh" --no-shell-switch "$@"; }

printf 'case: non-macOS rejection\n'
STUB_UNAME=Linux run_installer --only zsh >/dev/null 2>&1 && fail 'Linux accepted'
[[ ! -d "$INSTALLER_STATE_DIR/runs" ]] || fail 'transaction created before platform rejection'

printf 'case: non-Zsh gate and explicit bootstrap\n'
: > "$STUB_LOG"
CURRENT_SHELL_PATH=/bin/bash run_installer --only zsh,zim >/dev/null
assert_absent "$HOME/.zshenv"
assert_absent "$HOME/.zshrc"
assert_absent "$HOME/.zimrc"
assert_not_contains "$STUB_LOG" 'brew install zsh'
assert_not_contains "$STUB_LOG" 'sudo '
assert_not_contains "$STUB_LOG" 'chsh '

run_installer --configure-zsh --only zsh >/dev/null
assert_file "$HOME/.zshenv"
bootstrap_run="$(cat "$INSTALLER_STATE_DIR/latest")"
"$ROOT_DIR/install.sh" --rollback "$bootstrap_run" >/dev/null
assert_absent "$HOME/.zshenv"
assert_absent "$HOME/.zshrc"

printf 'case: shell-switch argument validation\n'
run_zsh_installer --only fzf --switch-shell >/dev/null 2>&1 && fail 'switch without zsh accepted'
run_zsh_installer --only zsh --switch-shell >/dev/null 2>&1 && fail 'conflicting shell flags accepted'

printf 'case: focused install and idempotency\n'
: > "$STUB_LOG"
run_zsh_installer --only zsh,fzf >/dev/null
assert_file "$HOME/.zshenv"
assert_file "$HOME/.zshrc"
assert_not_contains "$STUB_LOG" 'brew install zsh'
assert_not_contains "$STUB_LOG" 'sudo '
assert_not_contains "$STUB_LOG" 'chsh '
first_run="$(cat "$INSTALLER_STATE_DIR/latest")"
[[ "$(cat "$INSTALLER_STATE_DIR/runs/$first_run/status")" == completed ]] || fail 'run incomplete'
run_zsh_installer --only zsh,fzf >/dev/null
second_run="$(cat "$INSTALLER_STATE_DIR/latest")"
[[ ! -s "$INSTALLER_STATE_DIR/runs/$second_run/journal.tsv" ]] || fail 'idempotent run changed files'

printf 'case: Zim system-Zsh initialization\n'
rm -rf "$HOME/.zim" "$HOME/.zimrc"
run_zsh_installer --only zim >/dev/null
assert_file "$HOME/.zim/zimfw.zsh"
assert_file "$HOME/.zim/init.zsh"
[[ -L "$HOME/.zimrc" ]] || fail 'missing Zim config symlink'

printf 'case: created-file rollback\n'
"$ROOT_DIR/install.sh" --rollback "$first_run" >/dev/null
assert_absent "$HOME/.zshenv"
assert_absent "$HOME/.zshrc"

printf 'case: replaced-file rollback\n'
printf 'original\n' > "$HOME/.zshrc"
run_zsh_installer --only zsh >/dev/null
replace_run="$(cat "$INSTALLER_STATE_DIR/latest")"
"$ROOT_DIR/install.sh" --rollback latest >/dev/null
[[ "$(cat "$HOME/.zshrc")" == original ]] || fail 'original not restored'

printf 'case: conflict and force\n'
run_zsh_installer --only zsh >/dev/null
conflict_run="$(cat "$INSTALLER_STATE_DIR/latest")"
printf 'user edit\n' > "$HOME/.zshrc"
"$ROOT_DIR/install.sh" --rollback "$conflict_run" >/dev/null 2>&1 && fail 'conflict rollback succeeded'
[[ "$(cat "$HOME/.zshrc")" == 'user edit' ]] || fail 'conflict edit lost'
"$ROOT_DIR/install.sh" --rollback-force "$conflict_run" >/dev/null
[[ "$(cat "$HOME/.zshrc")" == original ]] || fail 'forced rollback did not restore pre-run state'
[[ -d "$INSTALLER_STATE_DIR/runs/$conflict_run/rollback-conflicts" ]] || fail 'conflict backup directory missing'
[[ -n "$(find "$INSTALLER_STATE_DIR/runs/$conflict_run/rollback-conflicts" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail 'conflict backup missing'

printf 'case: Raycast renderer\n'
cat > "$TMP_ROOT/test.env" <<'EOF'
RAYCAST_MODELSCOPE_API_KEY=dummy-model-key
RAYCAST_PERPLEXITY_API_KEY=dummy-perplexity-key
EOF
DOTFILES_ENV_FILE="$TMP_ROOT/test.env" RAYCAST_PROVIDERS_FILE="$TMP_ROOT/providers.yaml" "$ROOT_DIR/scripts/render-raycast-providers" > "$TMP_ROOT/render.out"
assert_file "$TMP_ROOT/providers.yaml"
assert_contains "$TMP_ROOT/providers.yaml" 'dummy-model-key'
! grep -Fq 'dummy-model-key' "$TMP_ROOT/render.out" || fail 'renderer leaked secret'
[[ "$(stat -f '%Lp' "$TMP_ROOT/providers.yaml")" == 600 ]] || fail 'renderer mode is not 600'

printf 'PASS\n'
