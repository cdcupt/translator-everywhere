# te — terminal translator (any language)

A tiny, self-owned translator for the terminal and the macOS right-click menu. Auto-detects the
source and translates into any of 130+ languages (Google-Translate-style), with **EN ⇄ 中文** kept
as the out-of-the-box default. Two engines: **AI** (OpenAI, high quality) and **Google Translate**
(free, no key). Built to translate Claude Code's English output (or anything else) without leaving
the terminal or pasting into a website.

## Why

- **Any language** — auto-detect the source, translate into any of 130+ targets (`te -l` to browse).
- **Two engines, your choice** — **AI** for quality/nuance, **Google** for instant & free.
- **Lives in your terminal** — `te <text>`, or `te` to translate the clipboard.
- **Gesture-accessible** — two-finger-tap (right-click) selected text → **翻译 (AI)** or **翻译 (Google)**.
- **Yours** — one self-contained bash script; your OpenAI key stays in `~/.openai/keys.env`. No
  third-party app, no Accessibility permissions. AI calls OpenAI; Google uses the public translate
  endpoint.

## Install

```bash
./install.sh
```

This symlinks `te` into `~/.local/bin` and registers the **翻译 (te)** Quick Action.

Requires: `bash`, `curl`, `jq` (`brew install jq`), and `OPENAI_API_KEY` — read from
`~/.openai/keys.env` by default.

## Use

```bash
te                      # translate the clipboard into your target (auto-detect source, AI)
te <text...>            # translate the given text
echo "some text" | te   # translate piped stdin
te -t ja <text...>      # translate into Japanese (source auto-detected)
te -f en -t fr <text>   # translate from English into French
te -l                   # list the language catalog (codes + names)
te -l japan             # search the catalog (case-insensitive, over code/names/aliases)
te --detect <text>      # print only the detected source language
te -g <text...>         # use the free Google Translate engine
te -e ubiquitous        # (AI) also show part-of-speech / pinyin / a usage example
te -i                   # interactive REPL (blank line or Ctrl-D quits)
te -m gpt-4o "…"        # override the AI model for one call
te -c                   # drag a screen region → OCR + translate it (AI; macOS)
te -c shot.png          # OCR + translate the text in an existing image file
```

Default engine is AI; set `TE_ENGINE=google` to flip the default, or pass `-g` per call.

### Languages

By default the source is auto-detected and the target is Simplified Chinese, so the classic
**EN ⇄ 中文** flow works out of the box. Pick any pair with codes from the shared catalog
(`languages.tsv`, 130+ languages — the macOS app reads the same file):

| Flag | Default | Meaning |
|------|---------|---------|
| `-f`, `--from <code>` | `auto` (`$TE_FROM`) | source language code — `auto` detects it |
| `-t`, `--to <code>` | `zh-CN` (`$TE_TO`) | target language code |
| `-l`, `--languages [query]` | — | list / search the catalog (codes, English + native names) |
| `--detect <text>` | — | print only the detected source language, then stop |

**Same-language guard:** with an auto source, if the text is already in your target language the
translation flips to the secondary (`$TE_SECONDARY`, default `en`). That is what keeps a `zh-CN`
target two-way: English flows to Chinese, Chinese flows back to English — the familiar EN ⇄ ZH flip.

### System-wide (the "two-finger tap")

Select text in any app, **two-finger-tap (right-click) → Services**, then pick **翻译 (AI)**
(high quality) or **翻译 (Google)** (free). The translation appears in a dialog and is copied
to your clipboard. Bind a hotkey to either under
*System Settings → Keyboard → Keyboard Shortcuts → Services → Text*.

### Translate anything on screen (capture → OCR → translate)

For a YouTube frame, an image, a PDF, or any text you can't select, use the **screen-region**
action: drag a box around it and `te` OCRs the text and translates it (AI engine).

- CLI: `te -c` drops a crosshair — drag a region, and the translation shows in a dialog and is
  copied to your clipboard. `te -c <image>` does the same for an existing image file.
- System-wide: the installer registers a no-input Quick Action **翻译 (截图)**. Give it a hotkey
  under *System Settings → Keyboard → Keyboard Shortcuts → Services → **General*** (e.g. ⌃⌥Y),
  then press it from anywhere to capture-and-translate.

OCR + translation happen in a single OpenAI vision call (`gpt-4o-mini`), so the AI engine
(an `OPENAI_API_KEY`) is required for this mode; the image is downscaled locally first to keep
the request small.

### Contextual selection translate (macOS app)

In the [macOS app](macos/), select a word or phrase in the result panel's **Recognized** pane and
an in-context dictionary card appears in place — contextual translation, part of speech, sense,
and an example — powered by the AI engine with the full recognized text as context. Long
selections get a plain contextual translation; Google-only setups get a labeled context-free
fallback. **⌘S** saves the card to the Notebook.

## Config

Set these via the environment, or in `~/.te/config` (sourced if present, so prefs persist
without env vars; CLI flags still win):

| Variable | Default | Meaning |
|----------|---------|---------|
| `TE_FROM` | `auto` | default source code (`auto` detects it) |
| `TE_TO` | `zh-CN` | default target code |
| `TE_SECONDARY` | `en` | same-language fallback target (the EN ⇄ ZH flip) |
| `TE_ENGINE` | `openai` | `openai` (AI) or `google` |
| `OPENAI_API_KEY` | (from key file) | your OpenAI key (AI engine only) |
| `TE_MODEL` | `gpt-4o-mini` | AI model id |
| `TE_KEY_FILE` | `~/.openai/keys.env` | file that exports `OPENAI_API_KEY` |

## Uninstall

```bash
rm ~/.local/bin/te
rm -rf ~/Library/Services/"Translate with te (AI).workflow" \
       ~/Library/Services/"Translate with te (Google).workflow" \
       ~/Library/Services/"Translate screen region (te).workflow"
/System/Library/CoreServices/pbs -flush
```
