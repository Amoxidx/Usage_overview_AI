# Data adapters

Read-only adapters inspired by public patterns from [vinzdg/codenotch](https://github.com/vinzdg/codenotch) (MIT).

## Claude
1. Locate `claude` in `~/.local/bin`, `~/.claude/local`, Homebrew paths.
2. Run `claude /usage` with stdin discarded and a 20s timeout.
3. Parse `Current session:` / `Current week (...):` lines into windows.
4. TODO fallback: keychain OAuth → `GET https://api.anthropic.com/api/oauth/usage`.

## Codex
1. Read `~/.codex/auth.json` → `tokens.access_token` + `tokens.account_id`.
2. Also discover `~/.codex-*` directories (default profile is polled).
3. `GET https://chatgpt.com/backend-api/wham/usage` with Bearer + ChatGPT-Account-Id.
4. Map `rate_limit.primary_window` / `secondary_window` (`used_percent`, resets).

## Grok
1. Read `~/.grok/auth.json`, pick trusted `https://auth.x.ai` entry (`key`).
2. `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with Bearer + `X-XAI-Token-Auth: xai-grok-cli`.
3. Prefer `config.creditUsagePercent`; else productUsage; else weekly period at 0%.

Never write credentials. Failures → status, not invented percentages.
