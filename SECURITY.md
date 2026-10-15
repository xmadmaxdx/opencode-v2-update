# Security Policy

## This repository ships no credentials

There are no API keys, tokens or passwords in this repository, and CI fails the build if a credential-shaped value appears.

`payload/config/opencode.jsonc` reads every secret through OpenCode's own `{env:...}` substitution:

```jsonc
"Authorization": "Bearer {env:GITHUB_TOKEN}"
```

`.env.example` is a template with empty values. `.gitignore` excludes `.env`, so your filled-in copy cannot be committed by accident.

If you need a secret that does not belong in an environment variable at all, OpenCode also supports `{file:~/.secrets/provider-key}`.

## Supported versions

Only the current `main` branch is supported. This project is a thin installer around OpenCode itself — for anything in the OpenCode CLI or server, see [OpenCode's own security policy](https://github.com/anomalyco/opencode/security/policy).

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private reporting: **Security → Report a vulnerability** on this repository.

Include:

- what the issue is and which file/line is involved
- how to reproduce it
- the impact you believe it has

You can expect an acknowledgement within a few days. Fixes land in `main` and are released through the normal flow.

## The behaviour most worth reviewing

The installer's default contract is **non-destructive**: it must never overwrite or delete a file in the user's OpenCode config unless `-ReplaceConfig` is passed explicitly.

If you are reviewing this project, that is the property to attack. A useful test is to seed a config directory with sentinel files, run the installer against a sandboxed `USERPROFILE`, and compare SHA-256 hashes before and after.