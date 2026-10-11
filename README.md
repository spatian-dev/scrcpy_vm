# `scrcpy` Version Manager for Bash

A small, auditable Bash version manager for the official Linux x86-64 `scrcpy` release archives.

`scrcpy` is maintained by [Genymobile](https://github.com/Genymobile/scrcpy); this project is an independent installer and version manager, not an official Genymobile project.

`scrcpy_vm.sh` installs verified releases side by side, switches the active version through one symlink, and removes versions without disturbing the others.

- **Verified releases:** pins the maintainer's GPG fingerprint, verifies the signed checksum manifest, then checks the selected archive's SHA-256.
- **Predictable layout:** installs archive contents directly into `INSTALL_ROOT/VERSION/`.
- **Transactional changes:** stages installs before activation and attempts to restore a previous version if a managed replacement fails.
- **Explicit actions:** install, switch, uninstall, or list; actions are mutually exclusive.
- **Quiet by default:** progressive detail with `--verbose 0..2`, optional logs, and terminal-aware output.

> ℹ️ **AI Assistance Disclosure:**\
>  Portions of this codebase, documentation, and testing suite were developed with the assistance of AI tools

## Quick start

Review the script before running it, then install the latest upstream release:

```bash
chmod +x scrcpy_vm.sh
./scrcpy_vm.sh -h
```

Optionally:

```bash
mv ./scrcpy_vm.sh /usr/bin/scrcpy_vm.sh
scrcpy_vm -h
```

The default installation is system-wide and may prompt to install missing dependencies or ADB. The default paths are `/opt/scrcpy` and `/usr/bin/scrcpy`; administrative operations use `sudo` when the script is not run as root.

## Usage

```text
scrcpy_vm.sh [ACTION] [OPTIONS]

Actions (choose at most one; default: --install):
  -i, --install             Install a release and activate it
  -s, --switch              Switch to an installed release; ask before installing if missing
  -u, --uninstall           Uninstall the active version, or the version specified with -v
  -l, --list                List installed versions and their directories

Options:
  -v, --version VERSION     Version such as 5.0.1 or latest
  -p, --path PATH           Installation root for install/list (default: /opt/scrcpy)
  -d, --bin-dir PATH        Symlink directory during install (default: /usr/bin)
      --verbose LEVEL       Output detail: 0 (default), 1, or 2
      --log [DIR]           Log the run; DIR defaults to the script's directory
  -h, --help                Show help
```

### Examples

```bash
# Install latest (also the default when no action is supplied)
./scrcpy_vm.sh --install

# Install and activate a specific release
./scrcpy_vm.sh -i -v 5.0.1

# List installs under the default root, or another root
./scrcpy_vm.sh --list
./scrcpy_vm.sh --list --path "$HOME/.local/opt/scrcpy"

# Switch to the newest installed version, or a specific version
./scrcpy_vm.sh --switch
./scrcpy_vm.sh -s -v 5.0.1

# Switch to upstream latest; if it is missing, the script asks before installing it
./scrcpy_vm.sh --switch -v latest

# Uninstall the active version, or explicitly select a version
./scrcpy_vm.sh --uninstall
./scrcpy_vm.sh -u -v 5.0.1

# Show diagnostic detail and save a log beside the script
./scrcpy_vm.sh --install --verbose 2 --log

# Save the run log to an existing writable directory
./scrcpy_vm.sh --list --log "$HOME/logs"
```

## Version and path rules

| Action    | No `-v` supplied         | With `-v VERSION`                                                 | Path options                                     |
| --------- | ------------------------ | ----------------------------------------------------------------- | ------------------------------------------------ |
| Install   | Latest upstream release  | Install that release (`latest` resolves upstream)                 | `-p` and `-d` allowed                            |
| Switch    | Newest installed version | Switch to that release; if missing, ask before installing         | Paths discovered from the active managed symlink |
| Uninstall | Active managed version   | Remove that installed version; `-v latest` means newest installed | Paths discovered from the active managed symlink |
| List      | List valid installs      | `-v` is not applicable                                            | `-p` allowed; `-d` is not applicable             |

Switch and uninstall infer `INSTALL_ROOT` and the symlink directory from the `scrcpy` executable found on `PATH`. They refuse to modify anything when the active path is not a symlink resolving to a valid `INSTALL_ROOT/VERSION/scrcpy` layout. Use `--install` for first-time installs or deliberately repair the path yourself. `--path` and `--bin-dir` cannot be combined with switch or uninstall because the manager must use the discovered layout.

The install tree looks like this:

```text
/opt/scrcpy/
├── 5.0.1/
│   ├── scrcpy
│   ├── scrcpy-server
│   └── ...
└── 4.1/
    ├── scrcpy
    ├── scrcpy-server
    └── ...

/usr/bin/scrcpy -> /opt/scrcpy/5.0.1/scrcpy
```

Only directories containing an executable regular file at `VERSION/scrcpy` are considered managed installs. A pre-existing non-directory, symlinked version path, or unrecognized install directory is not replaced.

## Dependencies

The installer requires standard Linux utilities, `curl`, GnuPG, and core archive/hash tools. When a required command is missing, it offers to install the corresponding package through supported package managers (APT, DNF, YUM, Pacman, Zypper, or APK). Package names vary by distribution; if automatic installation is unavailable or declined, the script prints a suggested command.

ADB is optional for installing the binary but required to connect to Android devices. The script warns when ADB is absent and offers to install it. The downloaded scrcpy build is for Linux x86-64 only.

## Output and logs

- No flag and `--verbose 0` have the same output. Level `1` adds operational detail; level `2` includes diagnostics such as resolved paths and verification steps.
- `--log` creates a uniquely named log in the script directory; `--log DIR` uses an existing writable directory. The directory is validated before an action starts. Log messages use the selected verbosity level.
- Color and progress animation are disabled when output is redirected, `TERM=dumb`, or CI is detected. Set `NO_COLOR=1`, `NO_EMOJI=1`, or `NO_ANIMATION=1` to turn off those elements explicitly.

## Development checks

Run the local checks before submitting changes:

```bash
make check
make test
make lint  # requires ShellCheck
```

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
