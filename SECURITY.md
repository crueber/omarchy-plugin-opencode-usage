# Security

This plugin does not store API keys or account credentials. It asks the
installed OpenCode service for the signed-in workspace's usage:

```bash
opencode api GET /api/experimental/usage/limits
```

The only file it writes is a small cache at
`~/.cache/opencode-usage/usage.json`, containing the workspace id/name, the
limit percentages and reset times, Console budgets, and the last attempt/error.
The directory is created with mode `700`. No prompts, messages, or credentials
are cached.

The plugin runs inside the Omarchy shell and therefore has the shell's user
privileges. It uses fixed commands, validates response sizes and field types,
and renders dynamic strings as plain text.

If you find a security issue, please use GitHub's private vulnerability
reporting on this repository rather than opening a public issue.
