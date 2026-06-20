# fy — terminal translator (EN ⇄ 中文)

A tiny, self-owned translator for the terminal and the macOS right-click menu, powered by
your own OpenAI key. Built to translate Claude Code's English output (or anything else)
without leaving the terminal or pasting into Google Translate.

## Why

- **GPT-quality**, not the free Google/Bing engines — natural Chinese, real nuance.
- **Lives in your terminal** — `fy <text>`, or `fy` to translate the clipboard.
- **Gesture-accessible** — two-finger-tap (right-click) any selected text → **翻译 (fy)**.
- **Yours** — ~120 lines of bash, your key stays in `~/.openai/keys.env`. No third-party app,
  no Accessibility permissions, nothing phoning home but the OpenAI API.

## Install

```bash
./install.sh
```

This symlinks `fy` into `~/.local/bin` and registers the **翻译 (fy)** Quick Action.

Requires: `bash`, `curl`, `jq` (`brew install jq`), and `OPENAI_API_KEY` — read from
`~/.openai/keys.env` by default.

## Use

```bash
fy                      # translate whatever is on the clipboard (auto EN⇄ZH)
fy <text...>            # translate the given text
echo "some text" | fy   # translate piped stdin
fy -e ubiquitous        # also show part-of-speech / pinyin / a usage example
fy -i                   # interactive REPL (blank line or Ctrl-D quits)
fy -m gpt-4o "…"        # override the model for one call
```

Direction is auto-detected: mostly-English → Simplified Chinese, mostly-Chinese → English.

### System-wide (the "two-finger tap")

Select text in any app, **two-finger-tap → Services → 翻译 (fy)**. The translation appears in
a dialog and is copied to your clipboard. Bind a hotkey under
*System Settings → Keyboard → Keyboard Shortcuts → Services → Text → 翻译 (fy)*.

## Config

| Variable | Default | Meaning |
|----------|---------|---------|
| `OPENAI_API_KEY` | (from key file) | your OpenAI key |
| `FY_MODEL` | `gpt-4o-mini` | model id |
| `FY_KEY_FILE` | `~/.openai/keys.env` | file that exports `OPENAI_API_KEY` |

## Uninstall

```bash
rm ~/.local/bin/fy
rm -rf ~/Library/Services/"Translate with fy.workflow"
/System/Library/CoreServices/pbs -flush
```
