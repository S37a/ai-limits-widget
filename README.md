# ai-limits-widget

A terminal TUI that shows AI provider limits, remaining tokens, and reset time — for OpenRouter, Anthropic, OpenAI, Ollama Cloud, and Google providers configured in opencode.

## What it shows

For each provider:
- Provider name, type (oauth/api), and account label
- Limit and remaining credits (where the provider exposes it)
- Time until quota reset (where the provider exposes it)
- Progress bar showing how much of the limit is used
- Token usage for today / 7 days / 30 days
- Top 5 models with input/output/cache breakdown

## Requirements

- macOS 13+
- [opencode](https://opencode.ai) installed and configured
- Swift 6 (Xcode)

## Build

```sh
swiftc main.swift -o ai-limits-widget
```

## Run

```sh
./ai-limits-widget
```

Keys: `q` to quit, `r` to refresh. Auto-refreshes every 60 seconds.

## Where data comes from

| Provider      | Source                                                         |
| ------------- | ------------------------------------------------------------- |
| OpenRouter    | `GET https://openrouter.ai/api/v1/key` and `/api/v1/credits`  |
| Anthropic     | opencode SQLite (`~/.local/share/opencode/opencode.db`)       |
| OpenAI        | opencode SQLite                                               |
| Ollama Cloud  | opencode SQLite                                               |
| Google        | opencode SQLite                                               |

Keys are read from `~/.local/share/opencode/auth.json`. They never leave the machine.

## License

MIT