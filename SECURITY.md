# Security policy

## Supported version

Security fixes are developed against the latest maintained release branch. Users should review changes and run an updated release when available.

## Reporting a vulnerability

Please do not publish an exploitable issue in a public issue tracker. Contact the repository maintainer privately using the security contact configured in the hosting profile. Include the affected commit or release, operating system, reproduction steps, and potential impact. Do not include credentials, private keys, or personal device data.

## Security-sensitive behavior

The installer uses a pinned GPG fingerprint, signed upstream checksum metadata, and a per-archive SHA-256 check. It uses `sudo` only for privileged file operations or package installation when required. Version directories are staged before they are activated, and an existing regular file at the `scrcpy` symlink path is never overwritten.

This is a best-effort shell utility, not a security boundary. Review the code before running it with administrative privileges.
