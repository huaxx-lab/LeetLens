# Security Policy

## Reporting a vulnerability

Please do not disclose a suspected vulnerability in a public issue. Use the
repository's GitHub Security Advisory page to submit a private report with:

- affected version or commit;
- reproduction steps and impact;
- relevant logs with tokens, cookies, account names, and server addresses removed.

## Secret handling

- Provider API keys are configured in the application, not in source files.
- Keys are encrypted before being written to local settings through Electron
  `safeStorage` and the operating system credential service.
- `.env.local`, SSH keys, build output, and application data are ignored by Git.
- The optional Java completion server is disabled until a host is explicitly
  supplied through environment variables.

If a credential is accidentally committed or shared, revoke it first. Removing
it from the latest commit is not sufficient because Git history and external
logs may retain a copy.
