# Contributing

Thank you for helping improve LeetLens. Bug reports, focused feature
proposals, documentation fixes, and tested pull requests are welcome. Chinese
and English are both accepted in issues and pull requests.

## Before opening an issue

- Search existing issues first.
- Remove API keys, cookies, account names, submission identifiers, private code,
  server addresses, and local filesystem paths from screenshots and logs.
- For a bug, include the macOS version, Node.js version, application commit, a
  minimal reproduction, expected behavior, and actual behavior.
- For a feature, explain the learning problem it solves and the evidence that
  should change. Avoid proposals that only add another passive dashboard.

## Development workflow

```bash
git clone https://github.com/huaxx-lab/LeetLens.git
cd LeetLens
npm install
npm test
npm start
```

Keep changes scoped and follow the existing module boundaries under `src/`.
New learning behavior should preserve evidence traceability, append submission
history instead of overwriting it, and include focused tests where practical.

Before opening a pull request:

```bash
npm test
```

Do not commit generated builds, local application data, credentials, cookies,
private keys, or real server configuration. By contributing, you agree that
your work is licensed under the repository's MIT License.
