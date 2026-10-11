#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL='https://github.com/Genymobile/scrcpy'
KEY_URL='https://blog.rom1v.com/keys/rom1v.asc'
EXPECTED_KEY_FINGERPRINT='456958E85A185DD5C2D1E4E80C822B298461FA03'

DEFAULT_INSTALL_ROOT='/opt/scrcpy'
DEFAULT_BIN_DIR='/usr/bin'
ACTION=''
VERSION=''
VERSION_SET=0
ROOT_SET=0
BIN_SET=0
ACTION_SET=0
VERBOSE_LEVEL=0
VERBOSE_SET=0
LOG_ENABLED=0
LOG_DIR=''
LOG_FILE=''

INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
BIN_DIR="$DEFAULT_BIN_DIR"
LINK_PATH=''
ACTIVE_BIN=''
ACTIVE_VERSION=''

TMP_DIR=''
STAGE_DIR=''
BACKUP_PARENT=''
BACKUP_DIR=''
LINK_TMP=''
VERSION_DIR=''
TRANSACTION_ACTIVE=0
VERSION_CHANGED=0
LOG_ACTIVE=0

SCRIPT_PATH="${BASH_SOURCE[0]}"
case "$SCRIPT_PATH" in
*/*)
    SCRIPT_DIR="${SCRIPT_PATH%/*}"
    [[ -n "$SCRIPT_DIR" ]] || SCRIPT_DIR='/'
    ;;
*) SCRIPT_DIR="$PWD" ;;
esac
SCRIPT_DIR="$(cd -- "$SCRIPT_DIR" && pwd -P)"
SCRIPT_NAME="${SCRIPT_PATH##*/}"

# Respect common terminal/accessibility preferences. Output remains plain in
# redirected output, dumb terminals, CI, or when NO_COLOR/NO_EMOJI is set.
COLOR_ENABLED=0
EMOJI_ENABLED=0
ANIMATION_ENABLED=0
if [[ -t 1 && -z "${NO_COLOR+x}" && "${CLICOLOR:-1}" != '0' && "${TERM:-}" != 'dumb' ]]; then
    COLOR_ENABLED=1
fi
if [[ -t 1 && -z "${NO_EMOJI+x}" && "${TERM:-}" != 'dumb' ]]; then
    EMOJI_ENABLED=1
fi
if [[ -t 2 && -z "${NO_ANIMATION+x}" && -z "${CI:-}" && "${TERM:-}" != 'dumb' ]]; then
    ANIMATION_ENABLED=1
fi

if ((COLOR_ENABLED)); then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_DIM=$'\033[2m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_DIM=''
fi

usage() {
    cat <<'USAGE'
Usage: scrcpy_vm.sh [ACTION] [OPTIONS]

Actions (choose at most one; default: --install):
  -i, --install          Install a release and activate it
  -s, --switch           Switch to an installed release; offer to install if missing
  -u, --uninstall        Uninstall the active version, or a version specified with -v
  -l, --list             List installed versions and their directories

Options:
  -v, --version VERSION  Release to use (e.g. 5.0.1 or latest)
  -p, --path PATH        Installation root for install/list (default: /opt/scrcpy)
  -d, --bin-dir PATH     Directory for the scrcpy symlink during install (default: /usr/bin)
      --verbose LEVEL    Detail level 0, 1, or 2 (default: 0)
      --log [DIR]         Write a run log; DIR defaults to this script's directory
  -h, --help             Show this help

Installed layout:
  PATH/VERSION/<release files>
  BIN_DIR/scrcpy -> PATH/VERSION/scrcpy

Action/version defaults:
  install                 Latest upstream release
  switch                  Newest installed version; use -v latest for upstream latest
  uninstall               Active version; -v VERSION removes that version
                           -v latest is the newest installed version (not upstream)
  list                    List valid installed versions; -p may select another root

Switch and uninstall discover PATH and BIN_DIR from the active scrcpy symlink.
They refuse to make changes if that managed layout cannot be established. Do not
combine --path or --bin-dir with --switch/--uninstall. --bin-dir is install-only.

Terminal controls:
  NO_COLOR=1 disables color; NO_EMOJI=1 disables emoji; NO_ANIMATION=1 disables
  animated progress; TERM=dumb and CI also disable animation.
USAGE
}

# Logging is intentionally structured: only messages at the selected verbosity
# level are written, and the same threshold applies to terminal output.
log_line() {
    local level="$1" message="$2"
    ((LOG_ACTIVE)) || return 0
    ((level <= VERBOSE_LEVEL)) || return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >>"$LOG_FILE" || true
}

say() {
    local level="$1" kind="$2" message="$3" plain_icon='' color=''
    case "$kind" in
    info)
        plain_icon='i'
        color="$C_CYAN"
        ;;
    progress)
        plain_icon='>'
        color="$C_BLUE"
        ;;
    success)
        plain_icon='✓'
        color="$C_GREEN"
        ;;
    warn)
        plain_icon='!'
        color="$C_YELLOW"
        ;;
    error)
        plain_icon='x'
        color="$C_RED"
        ;;
    detail)
        plain_icon='·'
        color="$C_DIM"
        ;;
    *)
        plain_icon='-'
        color=''
        ;;
    esac

    log_line "$level" "$plain_icon $message"
    ((level <= VERBOSE_LEVEL)) || return 0

    if ((EMOJI_ENABLED)); then
        case "$kind" in
        info) plain_icon='ℹ️' ;;
        progress) plain_icon='➜' ;;
        success) plain_icon='✅' ;;
        warn) plain_icon='⚠️' ;;
        error) plain_icon='❌' ;;
        detail) plain_icon='•' ;;
        esac
    fi

    if [[ "$kind" == 'error' || "$kind" == 'warn' ]]; then
        printf '%b%s%b %s\n' "$color" "$plain_icon" "$C_RESET" "$message" >&2
    else
        printf '%b%s%b %s\n' "$color" "$plain_icon" "$C_RESET" "$message"
    fi
}

fail() {
    say 0 error "$*"
    exit 1
}

run_privileged() {
    if ((EUID == 0)); then
        "$@"
    else
        sudo "$@"
    fi
}

has_terminal() { [[ -t 0 || -t 1 || -t 2 ]] && [[ -r /dev/tty && -w /dev/tty ]]; }

ask_yes_no() {
    local prompt="$1" default_no="${2:-0}" answer suffix='[Y/n]'
    ((default_no)) && suffix='[y/N]'
    has_terminal || return 2
    printf '%s %s ' "$prompt" "$suffix" >/dev/tty 2>/dev/null || return 2
    IFS= read -r answer </dev/tty 2>/dev/null || return 2
    if [[ -z "$answer" ]]; then
        ((default_no == 0))
        return
    fi
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf 'apt'
    elif command -v dnf >/dev/null 2>&1; then
        printf 'dnf'
    elif command -v yum >/dev/null 2>&1; then
        printf 'yum'
    elif command -v pacman >/dev/null 2>&1; then
        printf 'pacman'
    elif command -v zypper >/dev/null 2>&1; then
        printf 'zypper'
    elif command -v apk >/dev/null 2>&1; then
        printf 'apk'
    else
        return 1
    fi
}

show_package_hint() {
    local kind="$1" pm=''
    pm="$(package_manager 2>/dev/null || true)"
    if [[ "$kind" == 'base' ]]; then
        case "$pm" in
        apt) printf 'Install core filesystem utilities: sudo apt-get install coreutils\n' >&2 ;;
        dnf) printf 'Install core filesystem utilities: sudo dnf install coreutils\n' >&2 ;;
        yum) printf 'Install core filesystem utilities: sudo yum install coreutils\n' >&2 ;;
        pacman) printf 'Install core filesystem utilities: sudo pacman -S coreutils\n' >&2 ;;
        zypper) printf 'Install core filesystem utilities: sudo zypper install coreutils\n' >&2 ;;
        apk) printf 'Install core filesystem utilities: sudo apk add coreutils\n' >&2 ;;
        *) printf 'Install coreutils (realpath, sort and related utilities).\n' >&2 ;;
        esac
    elif [[ "$kind" == 'adb' ]]; then
        case "$pm" in
        apt) printf 'Install ADB: sudo apt-get install adb\n' >&2 ;;
        dnf) printf 'Install ADB: sudo dnf install android-tools\n' >&2 ;;
        yum) printf 'Install ADB: sudo yum install android-tools\n' >&2 ;;
        pacman) printf 'Install ADB: sudo pacman -S android-tools\n' >&2 ;;
        zypper) printf 'Install ADB: sudo zypper install android-tools\n' >&2 ;;
        apk) printf 'Install ADB: sudo apk add android-tools\n' >&2 ;;
        *) printf 'Install Android SDK platform-tools (the package providing adb) with your distribution package manager.\n' >&2 ;;
        esac
    else
        case "$pm" in
        apt) printf 'Install dependencies: sudo apt-get install curl gnupg coreutils gawk tar findutils ca-certificates\n' >&2 ;;
        dnf) printf 'Install dependencies: sudo dnf install curl gnupg2 coreutils gawk tar findutils ca-certificates\n' >&2 ;;
        yum) printf 'Install dependencies: sudo yum install curl gnupg2 coreutils gawk tar findutils ca-certificates\n' >&2 ;;
        pacman) printf 'Install dependencies: sudo pacman -S curl gnupg coreutils gawk tar findutils ca-certificates\n' >&2 ;;
        zypper) printf 'Install dependencies: sudo zypper install curl gpg2 coreutils gawk tar findutils ca-certificates\n' >&2 ;;
        apk) printf 'Install dependencies: sudo apk add curl gnupg coreutils gawk tar findutils ca-certificates\n' >&2 ;;
        *) printf 'Install missing commands: curl, gpg, sha256sum, awk, tar, find, realpath, mktemp and coreutils.\n' >&2 ;;
        esac
    fi
}

run_package_command() {
    local output status=0
    if output="$(run_privileged "$@" 2>&1)"; then
        if ((VERBOSE_LEVEL >= 1)) && [[ -n "$output" ]]; then
            printf '%s\n' "$output"
            log_line 1 "Package manager output: $output"
        else
            log_line 2 "Package manager output: $output"
        fi
        return 0
    else
        status=$?
        [[ -n "$output" ]] && printf '%s\n' "$output" >&2
        log_line 0 "Package manager command failed (exit $status): $*; $output"
        return "$status"
    fi
}

install_packages() {
    local kind="$1" pm
    pm="$(package_manager 2>/dev/null)" || {
        show_package_hint "$kind"
        return 1
    }
    if ((EUID != 0)) && ! command -v sudo >/dev/null 2>&1; then
        printf 'Automatic package installation requires sudo or running as root.\n' >&2
        show_package_hint "$kind"
        return 1
    fi

    case "$kind:$pm" in
    base:apt) run_package_command apt-get install -y coreutils ;;
    base:dnf) run_package_command dnf install -y coreutils ;;
    base:yum) run_package_command yum install -y coreutils ;;
    base:pacman) run_package_command pacman -S --needed --noconfirm coreutils ;;
    base:zypper) run_package_command zypper --non-interactive install coreutils ;;
    base:apk) run_package_command apk add coreutils ;;
    required:apt) run_package_command apt-get update && run_package_command apt-get install -y curl gnupg coreutils gawk tar findutils ca-certificates ;;
    required:dnf) run_package_command dnf install -y curl gnupg2 coreutils gawk tar findutils ca-certificates ;;
    required:yum) run_package_command yum install -y curl gnupg2 coreutils gawk tar findutils ca-certificates ;;
    required:pacman) run_package_command pacman -S --needed --noconfirm curl gnupg coreutils gawk tar findutils ca-certificates ;;
    required:zypper) run_package_command zypper --non-interactive install curl gpg2 coreutils gawk tar findutils ca-certificates ;;
    required:apk) run_package_command apk add curl gnupg coreutils gawk tar findutils ca-certificates ;;
    adb:apt) run_package_command apt-get update && run_package_command apt-get install -y adb ;;
    adb:dnf) run_package_command dnf install -y android-tools ;;
    adb:yum) run_package_command yum install -y android-tools ;;
    adb:pacman) run_package_command pacman -S --needed --noconfirm android-tools ;;
    adb:zypper) run_package_command zypper --non-interactive install android-tools ;;
    adb:apk) run_package_command apk add android-tools ;;
    *)
        show_package_hint "$kind"
        return 1
        ;;
    esac
}

ensure_commands() {
    local kind="$1"
    shift
    local -a missing=()
    local cmd
    for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
    ((${#missing[@]} == 0)) && return 0

    say 0 warn "Missing required command(s): ${missing[*]}"
    if ask_yes_no 'Try to install the required packages now?'; then
        install_packages "$kind" || fail 'Could not install the required packages.'
    else
        show_package_hint "$kind"
        if ! has_terminal; then fail 'Cannot prompt in this session; install the packages above and rerun.'; fi
        fail 'Required packages were not installed.'
    fi

    missing=()
    for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
    ((${#missing[@]} == 0)) || fail "Commands remain missing after package installation: ${missing[*]}"
}

check_adb() {
    if command -v adb >/dev/null 2>&1; then
        say 1 info "ADB found: $(command -v adb)"
        return 0
    fi

    say 0 warn 'ADB is not installed; scrcpy cannot connect to Android devices without it.'
    if ask_yes_no 'Try to install ADB now?'; then
        if install_packages adb && command -v adb >/dev/null 2>&1; then
            say 0 success "ADB installed: $(command -v adb)"
            return 0
        fi
        say 0 warn 'Automatic ADB installation failed.'
    else
        say 1 info 'Continuing without ADB; device connection will not work until it is installed.'
    fi
    show_package_hint adb
    return 0
}

normalize_version_value() {
    local input="$1"
    input="${input#v}"
    [[ "$input" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail "Invalid version '$1'. Use e.g. 5.0.1 or latest."
    printf '%s' "$input"
}

resolve_latest_version() {
    local release_page_url
    say 0 progress 'Resolving the latest upstream scrcpy release.'
    release_page_url="$(curl --fail --silent --show-error --location \
        --output /dev/null --write-out '%{url_effective}' "$REPO_URL/releases/latest")" || fail 'Could not resolve the latest release.'
    VERSION="$(normalize_version_value "${release_page_url##*/}")"
    say 1 detail "Latest upstream version: $VERSION"
}

# Output installed versions as tab-separated VERSION and DIRECTORY, sorted
# numerically/semantically using sort -V. Only real directories with an
# executable directly at VERSION/scrcpy count as managed installs.
installed_version_rows() {
    local root="$1" directory version
    [[ -d "$root" ]] || return 0
    shopt -s nullglob
    for directory in "$root"/*; do
        [[ -d "$directory" && ! -L "$directory" ]] || continue
        version="${directory##*/}"
        [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || continue
        [[ -f "$directory/scrcpy" && ! -L "$directory/scrcpy" && -x "$directory/scrcpy" ]] || continue
        printf '%s\t%s\n' "$version" "$directory"
    done | sort -t $'\t' -k1,1V
    shopt -u nullglob
}

latest_installed_version() {
    local rows
    rows="$(installed_version_rows "$INSTALL_ROOT")"
    [[ -n "$rows" ]] || return 1
    printf '%s\n' "$rows" | tail -n 1 | awk -F '\t' '{print $1}'
}

print_installed_versions() {
    local rows="$1"
    if [[ -z "$rows" ]]; then
        printf 'No valid installed scrcpy versions found under %s.\n' "$INSTALL_ROOT"
        log_line 0 "No valid installed versions found under $INSTALL_ROOT"
        return 0
    fi
    printf '%-14s %s\n' 'VERSION' 'INSTALL DIRECTORY'
    printf '%-14s %s\n' '--------------' '-----------------'
    while IFS=$'\t' read -r version directory; do
        [[ -n "$version" ]] || continue
        printf '%-14s %s\n' "$version" "$directory"
        log_line 0 "Installed version $version at $directory"
    done <<<"$rows"
}

list_action() {
    local rows
    INSTALL_ROOT="$(realpath -m -- "$INSTALL_ROOT")"
    rows="$(installed_version_rows "$INSTALL_ROOT")"
    say 0 info "Installed scrcpy versions under $INSTALL_ROOT:"
    print_installed_versions "$rows"
}

discover_active_install() {
    local command_path target_link target_bin version_dir canonical_version_dir detected_version
    command_path="$(type -P scrcpy 2>/dev/null || true)"
    if [[ -z "$command_path" || ! -L "$command_path" ]]; then
        say 0 error 'Cannot discover a managed install: scrcpy on PATH is not a symlink.'
        say 0 info 'No installation changes were made. Use --install for an initial install or fix PATH/symlink first.'
        return 1
    fi

    command_path="$(realpath -m -s -- "$command_path")" || {
        say 0 error 'Could not normalize the active scrcpy symlink path.'
        say 0 info 'No installation changes were made.'
        return 1
    }
    target_link="$(readlink -- "$command_path" 2>/dev/null)" || {
        say 0 error 'Could not read the active scrcpy symlink.'
        say 0 info 'No installation changes were made.'
        return 1
    }
    if [[ "$target_link" != /* ]]; then
        target_link="$(dirname -- "$command_path")/$target_link"
    fi
    target_bin="$(realpath -m -s -- "$target_link")" || {
        say 0 error 'Could not normalize the active scrcpy target.'
        say 0 info 'No installation changes were made.'
        return 1
    }

    if [[ "${target_bin##*/}" != 'scrcpy' || ! -f "$target_bin" || -L "$target_bin" || ! -x "$target_bin" ]]; then
        say 0 error 'The active scrcpy symlink must target a regular executable named scrcpy.'
        say 0 info 'No installation changes were made.'
        return 1
    fi

    version_dir="$(dirname -- "$target_bin")"
    canonical_version_dir="$(realpath -e -- "$version_dir" 2>/dev/null)" || {
        say 0 error 'The active version directory does not exist.'
        say 0 info 'No installation changes were made.'
        return 1
    }
    if [[ "$canonical_version_dir" != "$version_dir" || -L "$version_dir" ]]; then
        say 0 error 'The active version path contains a symlinked directory; refusing to infer its install root.'
        say 0 info 'No installation changes were made.'
        return 1
    fi

    detected_version="${version_dir##*/}"
    if [[ ! "$detected_version" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
        say 0 error 'Unsupported install layout; expected INSTALL_ROOT/VERSION/scrcpy.'
        say 0 info 'No installation changes were made.'
        return 1
    fi

    INSTALL_ROOT="$(dirname -- "$version_dir")"
    BIN_DIR="$(realpath -m -- "$(dirname -- "$command_path")")"
    LINK_PATH="$BIN_DIR/scrcpy"
    ACTIVE_BIN="$target_bin"
    ACTIVE_VERSION="$detected_version"
    say 2 detail "Discovered active link: $LINK_PATH -> $ACTIVE_BIN"
    say 2 detail "Discovered install root: $INSTALL_ROOT (active version $ACTIVE_VERSION)"
}
assert_link_safe() {
    if run_privileged test -e "$LINK_PATH" && ! run_privileged test -L "$LINK_PATH"; then
        fail "$LINK_PATH exists and is not a symlink; move/remove it deliberately before continuing. No changes made."
    fi
}

create_link_atomic() {
    local target="$1"
    assert_link_safe
    LINK_TMP="$(run_privileged mktemp "$BIN_DIR/.scrcpy-link.XXXXXX")"
    run_privileged rm -f -- "$LINK_TMP"
    run_privileged ln -s -- "$target" "$LINK_TMP"
    if ! run_privileged mv -Tf -- "$LINK_TMP" "$LINK_PATH"; then
        run_privileged rm -f -- "$LINK_TMP" 2>/dev/null || true
        LINK_TMP=''
        return 1
    fi
    LINK_TMP=''
}

fetch_verify_extract() {
    local version="$1" asset tag release_url actual_fingerprint archive_dir
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scrcpy-vm.XXXXXX")"
    tag="v$version"
    asset="scrcpy-linux-x86_64-${tag}.tar.gz"
    release_url="$REPO_URL/releases/download/$tag"

    say 0 progress "Downloading scrcpy $version and its signed checksums."
    say 2 detail "Release URL: $release_url/$asset"
    say 2 detail "Temporary download directory: $TMP_DIR"
    local -a curl_common=(--fail --location --retry 3)
    if ((ANIMATION_ENABLED)); then
        curl_common+=(--progress-bar)
    else
        curl_common+=(--silent --show-error)
    fi
    curl "${curl_common[@]}" "$release_url/$asset" -o "$TMP_DIR/$asset" || fail "Could not download $asset."
    curl "${curl_common[@]}" "$release_url/SHA256SUMS.txt" -o "$TMP_DIR/SHA256SUMS.txt" || fail 'Could not download SHA256SUMS.txt.'
    curl "${curl_common[@]}" "$release_url/SHA256SUMS.txt.asc" -o "$TMP_DIR/SHA256SUMS.txt.asc" || fail 'Could not download SHA256SUMS.txt.asc.'
    curl "${curl_common[@]}" "$KEY_URL" -o "$TMP_DIR/rom1v.asc" || fail 'Could not download the maintainer public key.'

    say 0 progress 'Verifying the maintainer fingerprint, signature, and archive checksum.'
    actual_fingerprint="$(gpg --batch --with-colons --show-keys "$TMP_DIR/rom1v.asc" |
        awk -F: '$1 == "fpr" { print $10; exit }')" || fail 'Could not read the downloaded GPG public key.'
    [[ "${actual_fingerprint^^}" == "$EXPECTED_KEY_FINGERPRINT" ]] ||
        fail 'The downloaded GPG key fingerprint does not match the pinned maintainer fingerprint.'
    say 2 detail "Pinned maintainer fingerprint verified: $actual_fingerprint"

    export GNUPGHOME="$TMP_DIR/gnupg"
    mkdir -m 700 -- "$GNUPGHOME"
    gpg --batch --quiet --import "$TMP_DIR/rom1v.asc" || fail 'Could not import the pinned maintainer key.'
    if ! gpg --batch --verify "$TMP_DIR/SHA256SUMS.txt.asc" "$TMP_DIR/SHA256SUMS.txt" >/dev/null 2>"$TMP_DIR/gpg-verify.log"; then
        cat "$TMP_DIR/gpg-verify.log" >&2
        fail 'The official checksum-file signature is invalid.'
    fi
    say 2 detail 'Detached signature on the checksum manifest is valid.'

    if ! awk -v asset="$asset" '
        ($2 == asset || $2 == "*" asset) && length($1) == 64 && $1 ~ /^[[:xdigit:]]+$/ {
            print $1 "  " asset; count++
        }
        END { if (count != 1) exit 1 }
    ' "$TMP_DIR/SHA256SUMS.txt" >"$TMP_DIR/selected.sha256"; then
        fail "No unique valid SHA-256 entry found for $asset."
    fi
    (cd "$TMP_DIR" && sha256sum --check selected.sha256) >/dev/null || fail 'Archive SHA-256 verification failed.'
    say 1 success 'Signature and SHA-256 verification passed.'

    mkdir -- "$TMP_DIR/extracted"
    tar -xzf "$TMP_DIR/$asset" -C "$TMP_DIR/extracted" || fail 'Could not extract the verified archive.'
    mapfile -t ARCHIVE_DIRS < <(find "$TMP_DIR/extracted" -mindepth 1 -maxdepth 1 -type d -print)
    ((${#ARCHIVE_DIRS[@]} == 1)) || fail 'Expected exactly one top-level directory in the verified archive.'
    archive_dir="${ARCHIVE_DIRS[0]}"
    say 2 detail "Extracted archive root: $archive_dir"
    [[ -f "$archive_dir/scrcpy" && ! -L "$archive_dir/scrcpy" && -x "$archive_dir/scrcpy" ]] ||
        fail 'The verified archive does not contain an executable at its top-level scrcpy path.'
    EXTRACTED_ARCHIVE_DIR="$archive_dir"
}

install_release() {
    local version="$1"
    local previous_exists=0

    [[ "$(uname -m)" == 'x86_64' ]] || fail 'The official archive used by this script is for Linux x86_64 only.'
    VERSION_DIR="$INSTALL_ROOT/$version"
    LINK_PATH="$BIN_DIR/scrcpy"
    assert_link_safe
    if run_privileged test -L "$VERSION_DIR"; then
        fail "$VERSION_DIR is a symlink; refusing to replace it."
    fi
    if run_privileged test -e "$VERSION_DIR"; then
        run_privileged test -d "$VERSION_DIR" || fail "$VERSION_DIR exists and is not a directory."
        if ! run_privileged test -f "$VERSION_DIR/scrcpy" && ! run_privileged test -L "$VERSION_DIR/scrcpy" && run_privileged test -x "$VERSION_DIR/scrcpy"; then
            fail "$VERSION_DIR is not a recognized scrcpy installation; refusing to replace its contents."
        fi
    fi
    fetch_verify_extract "$version"
    run_privileged mkdir -p -- "$INSTALL_ROOT" "$BIN_DIR"
    INSTALL_ROOT="$(realpath -m -- "$INSTALL_ROOT")"
    BIN_DIR="$(realpath -m -- "$BIN_DIR")"
    LINK_PATH="$BIN_DIR/scrcpy"
    VERSION_DIR="$INSTALL_ROOT/$version"
    say 1 detail "Install root: $INSTALL_ROOT"
    say 1 detail "Symlink directory: $BIN_DIR"
    say 2 detail "Final executable path: $VERSION_DIR/scrcpy"

    assert_link_safe
    if run_privileged test -L "$VERSION_DIR"; then
        fail "$VERSION_DIR is a symlink; refusing to replace it."
    fi
    if run_privileged test -e "$VERSION_DIR"; then
        run_privileged test -d "$VERSION_DIR" || fail "$VERSION_DIR exists and is not a directory."
        if ! run_privileged test -f "$VERSION_DIR/scrcpy" && ! run_privileged test -L "$VERSION_DIR/scrcpy" && run_privileged test -x "$VERSION_DIR/scrcpy"; then
            fail "$VERSION_DIR is not a recognized scrcpy installation; refusing to replace its contents."
        fi
        previous_exists=1
    fi

    STAGE_DIR="$(run_privileged mktemp -d "$INSTALL_ROOT/.scrcpy-${version}.stage.XXXXXX")"
    say 2 detail "Staging verified release at $STAGE_DIR"
    run_privileged cp -a --no-preserve=ownership "$EXTRACTED_ARCHIVE_DIR/." "$STAGE_DIR/"
    # mktemp creates mode 0700 directories; the installed version must be traversable by normal users.
    run_privileged chmod 755 -- "$STAGE_DIR"
    if ! run_privileged test -f "$STAGE_DIR/scrcpy" && ! run_privileged test -L "$STAGE_DIR/scrcpy" && run_privileged test -x "$STAGE_DIR/scrcpy"; then
        fail 'The staged scrcpy executable is missing or not executable.'
    fi

    TRANSACTION_ACTIVE=1
    if ((previous_exists)); then
        BACKUP_PARENT="$(run_privileged mktemp -d "$INSTALL_ROOT/.scrcpy-${version}.backup.XXXXXX")"
        BACKUP_DIR="$BACKUP_PARENT/previous"
        say 1 detail "Preserving previous version temporarily at $BACKUP_DIR"
        run_privileged mv -- "$VERSION_DIR" "$BACKUP_DIR"
        VERSION_CHANGED=1
    fi

    run_privileged mv -- "$STAGE_DIR" "$VERSION_DIR"
    STAGE_DIR=''
    VERSION_CHANGED=1
    if ! run_privileged test -f "$VERSION_DIR/scrcpy" && ! run_privileged test -L "$VERSION_DIR/scrcpy" && run_privileged test -x "$VERSION_DIR/scrcpy"; then
        fail "Installed executable not found: $VERSION_DIR/scrcpy"
    fi
    create_link_atomic "$VERSION_DIR/scrcpy" || fail "Could not activate $VERSION_DIR/scrcpy. The previous install will be restored where possible."

    TRANSACTION_ACTIVE=0
    if [[ -n "$BACKUP_PARENT" ]]; then
        if ! run_privileged rm -rf -- "$BACKUP_PARENT"; then
            say 0 warn "Install succeeded, but old backup cleanup failed; review: $BACKUP_PARENT"
            BACKUP_PARENT=''
            BACKUP_DIR=''
        else
            BACKUP_PARENT=''
            BACKUP_DIR=''
        fi
    fi
    say 0 success "Installed and activated scrcpy $version."
    say 0 info "Executable: $VERSION_DIR/scrcpy"
    say 0 info "Symlink: $LINK_PATH -> $VERSION_DIR/scrcpy"
}

switch_action() {
    local requested="$1" rows
    rows="$(installed_version_rows "$INSTALL_ROOT")"
    say 1 detail "Install root discovered from the active symlink: $INSTALL_ROOT"

    if [[ "$requested" == 'latest-installed' ]]; then
        requested="$(latest_installed_version)" || fail "No installed versions found under $INSTALL_ROOT."
    fi

    if [[ -d "$INSTALL_ROOT/$requested" && ! -L "$INSTALL_ROOT/$requested" ]] &&
        [[ -f "$INSTALL_ROOT/$requested/scrcpy" && ! -L "$INSTALL_ROOT/$requested/scrcpy" && -x "$INSTALL_ROOT/$requested/scrcpy" ]]; then
        if [[ "$ACTIVE_BIN" == "$INSTALL_ROOT/$requested/scrcpy" ]]; then
            say 0 success "scrcpy $requested is already active ($LINK_PATH)."
            return 0
        fi
        create_link_atomic "$INSTALL_ROOT/$requested/scrcpy" || fail "Could not switch to scrcpy $requested."
        say 0 success "Switched to scrcpy $requested."
        say 0 info "Symlink: $LINK_PATH -> $INSTALL_ROOT/$requested/scrcpy"
        return 0
    fi

    if run_privileged test -e "$INSTALL_ROOT/$requested" || run_privileged test -L "$INSTALL_ROOT/$requested"; then
        say 0 error "$INSTALL_ROOT/$requested exists but is not a recognized managed install."
        say 0 info 'It was not overwritten; inspect or move that directory manually before retrying.'
        print_installed_versions "$rows"
        return 1
    fi

    say 0 warn "scrcpy $requested is not installed under $INSTALL_ROOT."
    print_installed_versions "$rows"
    if ! ask_yes_no "Install scrcpy $requested and switch to it?" 1; then
        if ! has_terminal; then
            say 0 warn 'Cannot ask for confirmation in this session; rerun in an interactive terminal to install the missing version.'
        else
            say 0 info 'Switch cancelled; no installation changes were made.'
        fi
        return 1
    fi

    ensure_commands required curl gpg sha256sum awk tar find cp chmod uname
    check_adb
    install_release "$requested"
}

uninstall_action() {
    local requested="$1" rows remaining_rows remaining_version
    rows="$(installed_version_rows "$INSTALL_ROOT")"
    say 1 detail "Install root discovered from the active symlink: $INSTALL_ROOT"
    if [[ -z "$rows" ]]; then
        say 0 warn "No valid installed versions found under $INSTALL_ROOT; nothing was uninstalled."
        return 1
    fi

    if [[ "$requested" == 'active' ]]; then
        requested="$ACTIVE_VERSION"
    elif [[ "$requested" == 'latest-installed' || "$requested" == 'latest' ]]; then
        requested="$(latest_installed_version)" || fail "Could not determine the latest installed version under $INSTALL_ROOT."
    fi
    requested="$(normalize_version_value "$requested")"
    VERSION_DIR="$INSTALL_ROOT/$requested"

    if ! run_privileged test -d "$VERSION_DIR" || run_privileged test -L "$VERSION_DIR" ||
        ! run_privileged test -f "$VERSION_DIR/scrcpy" || run_privileged test -L "$VERSION_DIR/scrcpy" || ! run_privileged test -x "$VERSION_DIR/scrcpy"; then
        say 0 warn "scrcpy $requested is not installed as a managed version; nothing was uninstalled."
        print_installed_versions "$rows"
        return 1
    fi

    remaining_rows="$(installed_version_rows "$INSTALL_ROOT" | awk -F '\t' -v v="$requested" '$1 != v')"
    remaining_version=''
    if [[ -n "$remaining_rows" ]]; then
        remaining_version="$(printf '%s\n' "$remaining_rows" | tail -n 1 | awk -F '\t' '{print $1}')"
    fi

    # Detach the selected directory first. If changing the active symlink fails,
    # the EXIT cleanup restores the directory from this temporary backup.
    BACKUP_PARENT="$(run_privileged mktemp -d "$INSTALL_ROOT/.scrcpy-${requested}.uninstall.XXXXXX")"
    BACKUP_DIR="$BACKUP_PARENT/removed"
    if ! run_privileged mv -- "$VERSION_DIR" "$BACKUP_DIR"; then
        run_privileged rmdir -- "$BACKUP_PARENT" 2>/dev/null || true
        BACKUP_PARENT=''
        BACKUP_DIR=''
        fail "Could not move $VERSION_DIR for safe removal; no version was uninstalled."
    fi
    TRANSACTION_ACTIVE=1
    VERSION_CHANGED=0

    if [[ -n "$remaining_version" ]]; then
        if [[ "$ACTIVE_BIN" != "$INSTALL_ROOT/$remaining_version/scrcpy" ]]; then
            if ! create_link_atomic "$INSTALL_ROOT/$remaining_version/scrcpy"; then
                fail "Could not activate fallback version $remaining_version; the removed version will be restored where possible."
            fi
        fi
        TRANSACTION_ACTIVE=0
        say 0 success "Uninstalled scrcpy $requested."
        say 0 info "Active version after uninstall: $remaining_version (latest installed version)."
        say 0 info "Symlink: $LINK_PATH -> $INSTALL_ROOT/$remaining_version/scrcpy"
    else
        # No managed versions remain, so remove the symlink rather than leave it
        # dangling. The only valid case here is removal of the active version.
        if ! run_privileged rm -f -- "$LINK_PATH"; then
            fail "Could not remove the obsolete active symlink $LINK_PATH; the version will be restored where possible."
        fi
        TRANSACTION_ACTIVE=0
        say 0 success "Uninstalled scrcpy $requested; no other installed versions remain."
        say 0 info "Removed the now-obsolete symlink $LINK_PATH."
    fi

    # The unlink/switch is now committed. A cleanup failure should preserve the
    # backup for manual recovery rather than restoring a version the user removed.
    TRANSACTION_ACTIVE=0
    if ! run_privileged rm -rf -- "$BACKUP_PARENT"; then
        say 0 warn "Version was detached, but cleanup failed. Remove this backup manually: $BACKUP_PARENT"
        BACKUP_PARENT=''
        BACKUP_DIR=''
    else
        BACKUP_PARENT=''
        BACKUP_DIR=''
    fi
    say 0 info "Install root: $INSTALL_ROOT"
}

cleanup() {
    local exit_status=$?
    if ((exit_status != 0)); then
        log_line 0 "Run exited with status $exit_status."
    fi
    if [[ -n "$LINK_TMP" ]]; then run_privileged rm -f -- "$LINK_TMP" 2>/dev/null || true; fi
    if [[ -n "$STAGE_DIR" ]]; then run_privileged rm -rf -- "$STAGE_DIR" 2>/dev/null || true; fi

    if ((TRANSACTION_ACTIVE)); then
        if ((VERSION_CHANGED)) && [[ -n "$VERSION_DIR" ]] &&
            { [[ -e "$VERSION_DIR" ]] || [[ -L "$VERSION_DIR" ]]; }; then
            run_privileged rm -rf -- "$VERSION_DIR" 2>/dev/null || true
        fi
        if [[ -n "$BACKUP_DIR" ]] &&
            { [[ -e "$BACKUP_DIR" ]] || [[ -L "$BACKUP_DIR" ]]; }; then
            if [[ -n "$VERSION_DIR" ]] && ! { [[ -e "$VERSION_DIR" ]] || [[ -L "$VERSION_DIR" ]]; }; then
                run_privileged mv -- "$BACKUP_DIR" "$VERSION_DIR" 2>/dev/null || true
            fi
        fi
    fi

    if [[ -n "$BACKUP_PARENT" ]] && [[ -e "$BACKUP_PARENT" ]]; then
        if [[ -n "$BACKUP_DIR" && -e "$BACKUP_DIR" ]]; then
            say 0 warn "Recovery backup was preserved at $BACKUP_DIR"
        else
            run_privileged rm -rf -- "$BACKUP_PARENT" 2>/dev/null || true
        fi
    fi
    [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR" 2>/dev/null || true
    return "$exit_status"
}

trap cleanup EXIT
# shellcheck disable=SC2154         # Static analysis limitation. Variable is set at the start of the trap.
trap 'cmd_status=$?; if [[ "$BASH_COMMAND" != exit* ]]; then log_line 0 "Command failed (exit ${cmd_status}): ${BASH_COMMAND}"; fi' ERR

set_action() {
    local candidate="$1"
    ((ACTION_SET == 0)) || fail 'Choose only one action: --install, --switch, --uninstall, or --list.'
    ACTION="$candidate"
    ACTION_SET=1
}

# Parse options manually to support long options without requiring GNU getopt.
while (($#)); do
    case "$1" in
    -i | --install)
        set_action install
        shift
        ;;
    -s | --switch)
        set_action switch
        shift
        ;;
    -u | --uninstall)
        set_action uninstall
        shift
        ;;
    -l | --list)
        set_action list
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -v | --version)
        ((VERSION_SET == 0)) || fail 'Specify the version only once with -v/--version.'
        (($# >= 2)) || fail "Option $1 requires a version."
        [[ -n "$2" && "$2" != -* ]] || fail "Option $1 requires a version value."
        VERSION="$2"
        VERSION_SET=1
        shift 2
        ;;
    --version=*)
        ((VERSION_SET == 0)) || fail 'Specify the version only once with -v/--version.'
        VERSION="${1#*=}"
        [[ -n "$VERSION" ]] || fail '--version requires a non-empty version.'
        VERSION_SET=1
        shift
        ;;
    -v?*)
        ((VERSION_SET == 0)) || fail 'Specify the version only once with -v/--version.'
        VERSION="${1#-v}"
        VERSION_SET=1
        shift
        ;;
    -p | --path)
        ((ROOT_SET == 0)) || fail 'Specify --path only once.'
        (($# >= 2)) || fail "Option $1 requires a path."
        [[ -n "$2" && "$2" != -* ]] || fail "Option $1 requires a non-empty path."
        INSTALL_ROOT="$2"
        ROOT_SET=1
        shift 2
        ;;
    --path=*)
        ((ROOT_SET == 0)) || fail 'Specify --path only once.'
        INSTALL_ROOT="${1#*=}"
        [[ -n "$INSTALL_ROOT" ]] || fail '--path requires a non-empty path.'
        ROOT_SET=1
        shift
        ;;
    -p?*)
        ((ROOT_SET == 0)) || fail 'Specify --path only once.'
        INSTALL_ROOT="${1#-p}"
        ROOT_SET=1
        shift
        ;;
    -d | --bin-dir)
        ((BIN_SET == 0)) || fail 'Specify --bin-dir only once.'
        (($# >= 2)) || fail "Option $1 requires a path."
        [[ -n "$2" && "$2" != -* ]] || fail "Option $1 requires a non-empty path."
        BIN_DIR="$2"
        BIN_SET=1
        shift 2
        ;;
    --bin-dir=*)
        ((BIN_SET == 0)) || fail 'Specify --bin-dir only once.'
        BIN_DIR="${1#*=}"
        [[ -n "$BIN_DIR" ]] || fail '--bin-dir requires a non-empty path.'
        BIN_SET=1
        shift
        ;;
    -d?*)
        ((BIN_SET == 0)) || fail 'Specify --bin-dir only once.'
        BIN_DIR="${1#-d}"
        BIN_SET=1
        shift
        ;;
    --verbose)
        ((VERBOSE_SET == 0)) || fail 'Specify --verbose only once.'
        (($# >= 2)) || fail '--verbose requires a level from 0 to 2.'
        [[ "$2" =~ ^[0-2]$ ]] || fail "Invalid verbosity level '$2'; use 0, 1, or 2."
        VERBOSE_LEVEL="$2"
        VERBOSE_SET=1
        shift 2
        ;;
    --verbose=*)
        ((VERBOSE_SET == 0)) || fail 'Specify --verbose only once.'
        VERBOSE_LEVEL="${1#*=}"
        [[ "$VERBOSE_LEVEL" =~ ^[0-2]$ ]] || fail "Invalid verbosity level '$VERBOSE_LEVEL'; use 0, 1, or 2."
        VERBOSE_SET=1
        shift
        ;;
    --log)
        ((LOG_ENABLED == 0)) || fail 'Specify --log only once.'
        LOG_ENABLED=1
        shift
        if (($#)) && [[ "$1" != -* ]]; then
            LOG_DIR="$1"
            shift
        fi
        ;;
    --log=*)
        ((LOG_ENABLED == 0)) || fail 'Specify --log only once.'
        LOG_ENABLED=1
        LOG_DIR="${1#*=}"
        shift
        ;;
    --)
        shift
        (($# == 0)) || fail 'Unexpected positional arguments.'
        ;;
    -*) fail "Unknown option: $1 (use --help for usage)." ;;
    *) fail "Unexpected positional argument: $1 (use --help for usage)." ;;
    esac
done

if ((ACTION_SET == 0)); then ACTION='install'; fi
if [[ "$ACTION" == 'list' ]]; then
    ((BIN_SET == 0)) || fail '--bin-dir does not apply to --list.'
    ((VERSION_SET == 0)) || fail '--version does not apply to --list.'
elif [[ "$ACTION" == 'switch' || "$ACTION" == 'uninstall' ]]; then
    ((ROOT_SET == 0 && BIN_SET == 0)) || fail "Do not combine --path or --bin-dir with --$ACTION; paths are discovered from the active symlink."
fi
if [[ "$ACTION" == 'uninstall' ]]; then
    # In uninstall context, 'latest' means newest installed; without -v,
    # 'active' means the release resolved from the managed symlink.
    if ((VERSION_SET)); then
        [[ "$VERSION" == 'latest' ]] || VERSION="$(normalize_version_value "$VERSION")"
    else
        VERSION='active'
    fi
elif [[ "$ACTION" == 'switch' ]]; then
    if ((VERSION_SET)); then
        [[ "$VERSION" == 'latest' ]] || VERSION="$(normalize_version_value "$VERSION")"
    else
        VERSION='latest-installed'
    fi
else
    if ((VERSION_SET)); then [[ "$VERSION" == 'latest' ]] || VERSION="$(normalize_version_value "$VERSION")"; else VERSION='latest'; fi
fi

# Validate/create the log before doing any requested action. The default log
# directory is the directory containing this script; it must already exist and
# be writable. A log is deliberately not opened for --help (which exited above).
if ((LOG_ENABLED)); then
    if [[ -z "$LOG_DIR" ]]; then LOG_DIR="$SCRIPT_DIR"; fi
    for log_cmd in realpath date mktemp; do
        command -v "$log_cmd" >/dev/null 2>&1 || {
            printf 'Error: %s is required to create the run log. No action was performed.\n' "$log_cmd" >&2
            exit 1
        }
    done
    LOG_DIR="$(realpath -m -- "$LOG_DIR")" || {
        printf 'Error: could not resolve log directory.\n' >&2
        exit 1
    }
    if [[ ! -d "$LOG_DIR" || ! -w "$LOG_DIR" ]]; then
        printf 'Error: log directory is missing or not writable: %s\nNo action was performed.\n' "$LOG_DIR" >&2
        exit 1
    fi
    LOG_TIMESTAMP="$(date '+%Y-%m-%d_%H:%M:%S')"
    LOG_FILE="$(mktemp "$LOG_DIR/${SCRIPT_NAME}_${LOG_TIMESTAMP}_XXXXXX.log")" || {
        printf 'Error: could not create a log in %s. No action was performed.\n' "$LOG_DIR" >&2
        exit 1
    }
    LOG_ACTIVE=1
    log_line 0 "Start: action=$ACTION version=$VERSION verbosity=$VERBOSE_LEVEL script=$SCRIPT_PATH"
    say 0 info "Run log: $LOG_FILE"
fi

# Switch/uninstall discover first. Besides reducing needless dependencies, this
# ensures no scrcpy install mutation can happen if the current link is unmanaged.
if [[ "$ACTION" == 'switch' || "$ACTION" == 'uninstall' ]]; then
    if ((EUID != 0)) && ! command -v sudo >/dev/null 2>&1; then
        fail 'sudo is required to manage this installation. No installation changes were made.'
    fi
    ensure_commands base realpath dirname basename readlink
    discover_active_install || exit 1
    if [[ "$ACTION" == 'switch' ]]; then
        ensure_commands required sort awk tail mktemp rm mv ln mkdir
        if [[ "$VERSION" == 'latest' ]]; then
            ensure_commands required curl
            resolve_latest_version
        fi
        switch_action "$VERSION"
        exit $?
    else
        ensure_commands required sort awk tail mktemp rm mv ln mkdir
        uninstall_action "$VERSION"
        exit $?
    fi
fi

if [[ "$ACTION" == 'list' ]]; then
    ensure_commands base realpath sort
    list_action
    exit 0
fi

# Install action.
if ((EUID != 0)) && ! command -v sudo >/dev/null 2>&1; then
    fail 'sudo is required for the default install paths; run as root or install sudo first.'
fi
ensure_commands required curl gpg sha256sum awk tar find cp realpath sort mktemp dirname basename rm mv ln mkdir chmod uname
INSTALL_ROOT="$(realpath -m -- "$INSTALL_ROOT")"
BIN_DIR="$(realpath -m -- "$BIN_DIR")"
[[ "$INSTALL_ROOT" != '/' && "$BIN_DIR" != '/' ]] || fail 'Install root and binary directory cannot be /. '
LINK_PATH="$BIN_DIR/scrcpy"
if [[ "$VERSION" == 'latest' ]]; then resolve_latest_version; fi
check_adb
install_release "$VERSION"
