#!/usr/bin/env bash
set -euo pipefail

: "${INSTALLER_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-installer}"
: "${TRANSACTION_RUN_ID:=}"
: "${TRANSACTION_RUN_DIR:=}"

transaction_hash_file() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

transaction_kind() {
  local path="$1"
  if [[ -L "$path" ]]; then printf 'symlink\n'
  elif [[ -f "$path" ]]; then printf 'file\n'
  elif [[ -d "$path" ]]; then printf 'directory\n'
  elif [[ ! -e "$path" ]]; then printf 'absent\n'
  else printf 'unsupported\n'
  fi
}

transaction_fingerprint() {
  local path="$1"
  local kind
  kind="$(transaction_kind "$path")"
  case "$kind" in
    absent) printf 'absent\n' ;;
    file) printf 'file:%s\n' "$(transaction_hash_file "$path")" ;;
    symlink) printf 'symlink:%s\n' "$(readlink "$path")" ;;
    directory) printf 'directory\n' ;;
    *) printf 'unsupported\n' ;;
  esac
}

transaction_path_allowed() {
  local path="$1"
  case "$path" in
    "$HOME"|"$HOME"/*|"$CONFIG_REPO"|"$CONFIG_REPO"/*) return 0 ;;
    *) return 1 ;;
  esac
}

transaction_validate_path() {
  local path="$1"
  [[ "$path" == /* ]] || die "Transaction path must be absolute: $path"
  [[ "$path" != *$'\t'* && "$path" != *$'\n'* ]] || die "Unsupported path in transaction: $path"
  transaction_path_allowed "$path" || die "Transaction path outside managed roots: $path"
}

transaction_start() {
  local components="$1"
  local now
  umask 077
  now="$(date -u +%Y%m%dT%H%M%SZ)"
  TRANSACTION_RUN_ID="${now}-$$-${RANDOM}"
  TRANSACTION_RUN_DIR="$INSTALLER_STATE_DIR/runs/$TRANSACTION_RUN_ID"
  mkdir -p "$TRANSACTION_RUN_DIR/backups" "$TRANSACTION_RUN_DIR/rollback-conflicts"
  cat > "$TRANSACTION_RUN_DIR/metadata" <<EOF
schema_version=1
run_id=$TRANSACTION_RUN_ID
started_at=$now
repo=$CONFIG_REPO
home=$HOME
components=$components
EOF
  : > "$TRANSACTION_RUN_DIR/journal.tsv"
  printf 'running\n' > "$TRANSACTION_RUN_DIR/status"
  mkdir -p "$INSTALLER_STATE_DIR"
  printf '%s\n' "$TRANSACTION_RUN_ID" > "$INSTALLER_STATE_DIR/latest"
  export TRANSACTION_RUN_ID TRANSACTION_RUN_DIR INSTALLER_STATE_DIR
}

transaction_set_status() {
  [[ -n "$TRANSACTION_RUN_DIR" ]] || return 0
  printf '%s\n' "$1" > "$TRANSACTION_RUN_DIR/status"
}

transaction_fail() {
  local code="$1"
  if [[ -n "$TRANSACTION_RUN_DIR" ]]; then
    transaction_set_status failed
    warn "Install failed. File rollback: ./install.sh --rollback $TRANSACTION_RUN_ID"
  fi
  exit "$code"
}

transaction_find_seq() {
  local path="$1"
  [[ -n "$TRANSACTION_RUN_DIR" && -f "$TRANSACTION_RUN_DIR/journal.tsv" ]] || return 1
  awk -F '\t' -v path="$path" '$1 == "PREPARED" && $4 == path { print $2; exit }' "$TRANSACTION_RUN_DIR/journal.tsv"
}

transaction_prepare() {
  local path="$1"
  local component="${2:-installer}"
  local existing_seq
  local seq
  local kind
  local backup_rel="-"
  transaction_validate_path "$path"
  if existing_seq="$(transaction_find_seq "$path")" && [[ -n "$existing_seq" ]]; then
    printf '%s\n' "$existing_seq"
    return 0
  fi
  seq="$(awk -F '\t' '$1 == "PREPARED" {n++} END {print n+1}' "$TRANSACTION_RUN_DIR/journal.tsv")"
  kind="$(transaction_kind "$path")"
  [[ "$kind" != unsupported ]] || die "Refusing to replace unsupported path: $path"
  if [[ "$kind" != absent ]]; then
    backup_rel="backups/$seq"
    cp -a "$path" "$TRANSACTION_RUN_DIR/$backup_rel"
  fi
  printf 'PREPARED\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$seq" "$component" "$path" "$kind" "$backup_rel" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> "$TRANSACTION_RUN_DIR/journal.tsv"
  printf '%s\n' "$seq"
}

transaction_applied() {
  local seq="$1"
  local path="$2"
  printf 'APPLIED\t%s\t%s\t%s\n' "$seq" "$(transaction_fingerprint "$path")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> "$TRANSACTION_RUN_DIR/journal.tsv"
}

transaction_resolve_run() {
  local selector="$1"
  case "$selector" in
    latest)
      [[ -f "$INSTALLER_STATE_DIR/latest" ]] || die "No installer run found"
      cat "$INSTALLER_STATE_DIR/latest"
      ;;
    *)
      [[ "$selector" != */* && "$selector" != *..* ]] || die "Invalid run ID: $selector"
      printf '%s\n' "$selector"
      ;;
  esac
}

transaction_rollback_one() {
  local selector="$1"
  local force="$2"
  local run_id
  local run_dir
  local seq component path pre_kind backup_rel prepared_at expected current conflict_dir
  run_id="$(transaction_resolve_run "$selector")"
  run_dir="$INSTALLER_STATE_DIR/runs/$run_id"
  [[ -f "$run_dir/journal.tsv" ]] || die "Unknown installer run: $run_id"
  printf 'rolling_back\n' > "$run_dir/status"

  while IFS=$'\t' read -r _ seq component path pre_kind backup_rel prepared_at; do
    transaction_validate_path "$path"
    expected="$(awk -F '\t' -v seq="$seq" '$1 == "APPLIED" && $2 == seq {value=$3} END {print value}' "$run_dir/journal.tsv")"
    [[ -n "$expected" ]] || continue
    current="$(transaction_fingerprint "$path")"
    if [[ "$current" != "$expected" ]]; then
      printf 'CONFLICT\t%s\t%s\t%s\n' "$seq" "$current" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$run_dir/journal.tsv"
      if [[ "$force" != 1 ]]; then
        printf 'rollback_conflict\n' > "$run_dir/status"
        warn "Rollback conflict: $path"
        return 1
      fi
      if [[ -e "$path" || -L "$path" ]]; then
        conflict_dir="$run_dir/rollback-conflicts/$seq"
        cp -a "$path" "$conflict_dir"
      fi
    fi

    if [[ -e "$path" || -L "$path" ]]; then
      rm -rf "$path"
    fi
    if [[ "$pre_kind" != absent ]]; then
      mkdir -p "$(dirname "$path")"
      cp -a "$run_dir/$backup_rel" "$path"
    fi
    printf 'ROLLED_BACK\t%s\t%s\n' "$seq" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$run_dir/journal.tsv"
  done < <(awk -F '\t' '$1 == "PREPARED"' "$run_dir/journal.tsv" | sort -t $'\t' -k2,2nr)

  printf 'rolled_back\n' > "$run_dir/status"
  log "Rolled back installer run: $run_id"
}

transaction_rollback() {
  local selector="$1"
  local force="$2"
  local run_dir
  if [[ "$selector" == all ]]; then
    while IFS= read -r run_dir; do
      [[ -f "$run_dir/status" ]] || continue
      [[ "$(cat "$run_dir/status")" != rolled_back ]] || continue
      transaction_rollback_one "$(basename "$run_dir")" "$force" || return 1
    done < <(find "$INSTALLER_STATE_DIR/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
    return 0
  fi
  transaction_rollback_one "$selector" "$force"
}
