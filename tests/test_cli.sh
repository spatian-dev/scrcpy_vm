#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT_DIR/scrcpy_vm.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

echo "ℹ️ Temp dir: $TEMP_DIR"

fail() {
    printf '❌ FAIL: %s\n' "$*" >&2
    exit 1
}
pass() { printf '✅ ok - %s\n' "$*"; }
expect_failure() {
    local name="$1"
    shift
    if "$@" >"$TEMP_DIR/stdout" 2>"$TEMP_DIR/stderr"; then
        fail "$name (command unexpectedly succeeded)"
    fi
}
make_version() {
    local root="$1" version="$2"
    mkdir -p -- "$root/$version"
    cat >"$root/$version/scrcpy" <<'SCRCPY'
#!/bin/sh
printf 'scrcpy test fixture\n'
SCRCPY
    chmod 755 -- "$root/$version/scrcpy"
}

[[ -x "$SCRIPT" ]] || fail 'scrcpy_vm.sh is not executable'

expect_failure 'mutually exclusive actions' "$SCRIPT" --install --switch
grep -q 'Choose only one action' "$TEMP_DIR/stderr" || fail 'exclusive action error is clear'
pass 'action exclusivity'

expect_failure 'version is invalid for list' "$SCRIPT" --list --version 0.0.0
expect_failure 'path is invalid for switch' "$SCRIPT" --switch --path "$TEMP_DIR"
expect_failure 'bin directory is invalid for uninstall' "$SCRIPT" --uninstall --bin-dir "$TEMP_DIR"
pass 'action-specific option validation'

expect_failure 'invalid verbosity' "$SCRIPT" --verbose 3 --list
grep -q 'Invalid verbosity level' "$TEMP_DIR/stderr" || fail 'invalid verbosity error is clear'
pass 'verbosity validation'

mkdir -p "$TEMP_DIR/empty"
"$SCRIPT" --list --path "$TEMP_DIR/empty" >"$TEMP_DIR/default-list"
"$SCRIPT" --list --path "$TEMP_DIR/empty" --verbose 0 >"$TEMP_DIR/verbose-zero-list"
cmp -s "$TEMP_DIR/default-list" "$TEMP_DIR/verbose-zero-list" || fail '--verbose 0 must match default output'
pass 'verbosity level zero matches default output'

expect_failure 'unwritable/missing log directory' "$SCRIPT" --list --path "$TEMP_DIR/empty" --log "$TEMP_DIR/no-such-log-directory"
grep -q 'No action was performed' "$TEMP_DIR/stderr" || fail 'invalid log directory stops before action'
pass 'log directory validation happens before action'

# A fake sudo allows safe end-to-end lifecycle tests against temporary directories.
mkdir -p "$TEMP_DIR/fakebin" "$TEMP_DIR/managed-bin"
cat >"$TEMP_DIR/fakebin/sudo" <<'SUDO'
#!/usr/bin/env bash
exec "$@"
SUDO
chmod 755 "$TEMP_DIR/fakebin/sudo"

INSTALL_ROOT="$TEMP_DIR/opt/scrcpy"
BIN_DIR="$TEMP_DIR/managed-bin"
make_version "$INSTALL_ROOT" '1.0'
make_version "$INSTALL_ROOT" '2.0'
ln -s "$INSTALL_ROOT/1.0/scrcpy" "$BIN_DIR/scrcpy"

PATH="$BIN_DIR:$TEMP_DIR/fakebin:$PATH" "$SCRIPT" --switch --version 2.0 >"$TEMP_DIR/switch-output"
[[ "$(readlink "$BIN_DIR/scrcpy")" == "$INSTALL_ROOT/2.0/scrcpy" ]] || fail 'switch points to the requested version'
[[ -x "$INSTALL_ROOT/1.0/scrcpy" ]] || fail 'switch preserves other installed versions'
pass 'switching installed versions preserves other versions'

if PATH="$BIN_DIR:$TEMP_DIR/fakebin:$PATH" "$SCRIPT" --switch --version 3.0 \
    </dev/null >"$TEMP_DIR/missing-switch-output" 2>&1; then
    fail 'non-interactive switch to a missing version must not install it automatically'
fi
[[ ! -e "$INSTALL_ROOT/5.0" && ! -L "$INSTALL_ROOT/5.0" ]] || fail 'missing-version switch does not create an installation without confirmation'
grep -q 'Cannot ask for confirmation' "$TEMP_DIR/missing-switch-output" || fail 'non-interactive missing-version switch explains why it stopped'
pass 'switch does not auto-install a missing version without confirmation'

PATH="$BIN_DIR:$TEMP_DIR/fakebin:$PATH" "$SCRIPT" --list --path "$INSTALL_ROOT" >"$TEMP_DIR/installed-list"
grep -q "$INSTALL_ROOT/1.0" "$TEMP_DIR/installed-list" || fail 'list includes installed directories'
grep -q "$INSTALL_ROOT/2.0" "$TEMP_DIR/installed-list" || fail 'list includes all valid installed versions'
pass 'list includes versions and their installation directories'

mkdir -p "$TEMP_DIR/logs"
"$SCRIPT" --list --path "$INSTALL_ROOT" --log "$TEMP_DIR/logs" >"$TEMP_DIR/logged-list"
shopt -s nullglob
LOGS=("$TEMP_DIR/logs"/scrcpy_vm.sh_????-??-??_??:??:??_*.log)
shopt -u nullglob
((${#LOGS[@]} == 1)) || fail 'log uses script name, timestamp, unique suffix and .log extension'
grep -q 'Start: action=list' "${LOGS[0]}" || fail 'log records the selected action'
pass 'timestamped run logging'

# No -v must uninstall the active version, not merely the numerically newest version.
PATH="$BIN_DIR:$TEMP_DIR/fakebin:$PATH" "$SCRIPT" --switch --version 2.0 >"$TEMP_DIR/switch-output"
PATH="$BIN_DIR:$TEMP_DIR/fakebin:$PATH" "$SCRIPT" --uninstall >"$TEMP_DIR/uninstall-output"
[[ ! -e "$INSTALL_ROOT/2.0" && ! -L "$INSTALL_ROOT/2.0" ]] || fail 'uninstall without -v removes the active version'
[[ -x "$INSTALL_ROOT/1.0/scrcpy" ]] || fail 'uninstall preserves the other version'
[[ "$(readlink "$BIN_DIR/scrcpy")" == "$INSTALL_ROOT/1.0/scrcpy" ]] || fail 'uninstall activates the newest remaining version'
grep -q 'Uninstalled scrcpy 2.0' "$TEMP_DIR/uninstall-output" || fail 'uninstall reports the removed version'
pass 'uninstall defaults to active version and falls back to newest remaining version'

# An explicitly requested version is removed even when it is not active.
make_version "$INSTALL_ROOT" '5.0.3'
PATH="$BIN_DIR:$TEMP_DIR/fakebin:$PATH" "$SCRIPT" --uninstall -v 5.0.3 >"$TEMP_DIR/uninstall-explicit-output"
[[ ! -e "$INSTALL_ROOT/5.0.3" && ! -L "$INSTALL_ROOT/5.0.3" ]] || fail 'explicit uninstall removes selected version'
[[ "$(readlink "$BIN_DIR/scrcpy")" == "$INSTALL_ROOT/1.0/scrcpy" ]] || fail 'explicit uninstall leaves newest remaining version active'
pass 'explicit uninstall targets the requested version'

# An unmanaged executable must be a no-op, including for uninstall.
mkdir -p "$TEMP_DIR/unmanaged-bin"
cat >"$TEMP_DIR/unmanaged-bin/scrcpy" <<'UNMANAGED'
#!/bin/sh
exit 0
UNMANAGED
chmod 755 "$TEMP_DIR/unmanaged-bin/scrcpy"
expect_failure 'unmanaged scrcpy' env PATH="$TEMP_DIR/unmanaged-bin:$TEMP_DIR/fakebin:$PATH" "$SCRIPT" --uninstall
[[ -x "$INSTALL_ROOT/1.0/scrcpy" ]] || fail 'unmanaged discovery failure does not alter managed versions'
pass 'unmanaged installation discovery fails without changing the managed tree'

PATH="$BIN_DIR:$TEMP_DIR/fakebin:$PATH" "$SCRIPT" --uninstall >"$TEMP_DIR/uninstall-final-output"
[[ ! -e "$INSTALL_ROOT/1.0" && ! -L "$INSTALL_ROOT/1.0" ]] || fail 'final uninstall removes the last managed version'
[[ ! -e "$BIN_DIR/scrcpy" && ! -L "$BIN_DIR/scrcpy" ]] || fail 'final uninstall removes the now-obsolete symlink'
grep -q 'no other installed versions remain' "$TEMP_DIR/uninstall-final-output" || fail 'final uninstall explains that no versions remain'
pass 'last-version uninstall removes the obsolete symlink'

printf '\nAll tests passed.\n'
