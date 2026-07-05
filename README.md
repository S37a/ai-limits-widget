# ai-limits-widget

A tiny macOS menu bar widget that shows connected AI model limits, remaining
tokens, and time until quota reset — for OpenRouter, Anthropic, OpenAI,
Ollama Cloud, and Google providers configured in opencode.

## What it shows

- Provider name and account label
- Currently connected models
- Usage for today / this week / this month
- Limit and remaining credits (where the provider exposes it)
- Time until quota resets (where the provider exposes it)
- Local cumulative token usage from opencode sessions (for providers that do
  not expose quota via API)

## Requirements

- macOS 13+ (uses `NSStatusItem`, `NSPopover`, SwiftUI)
- [opencode](https://opencode.ai) installed and configured (providers list)
- Swift 6 (shipped with Xcode 15+/16)

## Build

```sh
swiftc main.swift -o ai-limits-widget
```

Run the binary directly:

```sh
./ai-limits-widget
```

Or wrap it as a `.app` bundle:

```sh
./build-app.sh
open ai-limits-widget.app
```

Add to Login Items to have it always in the menu bar.

## Where data comes from

| Provider         | Source                                                         |
| ---------------- | ------------------------------------------------------------- |
| OpenRouter       | `GET https://openrouter.ai/api/v1/key` and `/api/v1/credits`  |
| Anthropic        | opencode SQLite (`~/.local/share/opencode/opencode.db`)       |
| OpenAI           | opencode SQLite                                               |
| Ollama Cloud     | opencode SQLite                                               |
| Google           | opencode SQLite                                               |

Keys are read from `~/.local/share/opencode/auth.json`. They never leave the
machine.

## Status

- [x] Read auth.json and detect providers
- [x] Query OpenRouter /key and /credits endpoints
- [x] Read opencode SQLite for cumulative per-provider usage
- [x] Menu bar popover with a table of providers
- [x] Auto-refresh every 60s
- [ ] Per-account rotation (future — not in scope of v1)

## License

MIT