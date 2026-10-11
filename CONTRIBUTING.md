# Contributing

Small, reviewable changes are preferred. Please explain the problem being solved and include a reproducible test for behavioral changes.

## Before opening a pull request

1. Keep the script compatible with the Bash version available on current supported Linux distributions.
2. Preserve the release verification sequence: pinned public-key fingerprint, detached signature, exact archive checksum, then extraction.
3. Do not follow a symlink or overwrite an unrecognized version directory during install, switch, or uninstall.
4. Add or update tests in `tests/test_cli.sh` for changes to parsing or version-management behavior.
5. Run the checks below:

   ```bash
   bash -n scrcpy_vm.sh && bash -n tests/test_cli.sh
   bash tests/test_cli.sh
   shellcheck scrcpy_vm.sh tests/test_cli.sh
   ```

The repository also provides `make check`, `make test`, and `make lint` targets. `make lint` requires ShellCheck.

Keep output quiet by default, make destructive operations explicit, and ensure failure paths tell the user what was or was not changed. Do not add telemetry or download unverified executable content.

## Pull requests

- Describe user-visible behavior and compatibility implications.
- Include test output or explain which tests could not be run.
- Update `README.md` and `CHANGELOG.md` when behavior or usage changes.
