# Security Policy

## Supported versions

Only the latest release of LensDB is supported with security updates. Please upgrade to the most recent release before reporting an issue.

## Reporting a vulnerability

Please report security vulnerabilities privately. Do not open a public issue for vulnerabilities.

You can report a vulnerability in either of these ways:

- Via GitHub's private security advisories: https://github.com/w3debugger/lensdb/security/advisories/new
- By email to w3debugger@gmail.com

You can expect an acknowledgement within a few days.

## Scope

LensDB runs the local psql and mysql clients and stores connection settings (including passwords you enter) only on your machine. It sends no telemetry and makes no network calls of its own beyond the database connections you configure.
