# Translation brief — Oases Chat (iOS)

## The product
Oases Chat is an iPhone/iPad AI assistant app. Modes: text chat, voice (TTS), image generation, and
**Ogent**, an on-device engineering agent that operates a persistent Linux computer (iSH, Alpine) on
the phone. Ogent runs shell commands, browses the web, reads and writes files, uses skills and MCP
servers, and delivers files (videos, images, web pages, code). Users are general consumers and
power users. The source language is Simplified Chinese; many older strings were written in English.

## What you get
A JSON array of units: `{"key", "file", "source", "note", "hints"}`.
- `source` is the text to translate (Chinese or English). For round-2 languages you also get
  `zh` and `en` (the Simplified Chinese and English versions of the same string): translate the
  meaning they share. When they differ, trust `zh` unless it is clearly an abbreviation.
- `note` is the developer comment (context). `hints` holds legacy translations, which you may reuse if correct.
- `file` tells you where the string lives: `InfoPlist.xcstrings` = system permission prompts and
  app display names; `AgentWidget` = Live Activity / widget; `AppShortcuts.strings` = Siri/Shortcuts phrases.

## What you return
One JSON object mapping `key` → translated text, covering every unit. UTF-8, no comments.

## Hard rules
1. **Placeholders** must be kept exactly, same count and types: `%@`, `%lld`, `%d`, `%1$@`, `%2$lld`,
   `%%`, `%.1f`, `${applicationName}` etc. You may reorder positional ones (`%1$@`, `%2$@`) but
   never drop, add or change a specifier. Keep `\n` line breaks.
2. **Never translate:** brand/product names (Oases, Oases Chat, Ogent, Ogent Computer), protocol and
   tech names (MCP, API, API Key, OAuth, URL, HTTP, JSON, iSH, Alpine, Linux, SSH, GitHub, Face ID,
   Touch ID, iCloud, Siri), model names, file names, paths (`/var/minis/…`), commands, code, units
   like `KB`/`MB`, keyboard key names (Esc, Tab, Ctrl) and anything inside backticks.
3. Use `scripts/i18n/glossary.json` terms consistently.
4. **Style:** iOS system style; short labels stay short (buttons ≤ ~2 words where possible);
   complete sentences end with the language's punctuation. Sentence case for en/fr/de/ru labels
   (title case only for en navigation titles/buttons, following Apple HIG). ja: です/ます for full
   sentences, noun phrases for labels. ko: 해요체 for messages, noun phrases for labels. zh-Hant:
   Taiwan-standard vocabulary (檔案, 設定, 網路, 資料夾, 預設, 訊息, 帳號, 裝置, 連結, 程式).
   fr: non-breaking space rules are not required; use “’” apostrophes. de: “du” form (casual, like iOS apps).
   ru: neutral polite forms, imperative for buttons (Удалить, Отправить).
5. Strings that are single words (“Off”, “Low”, “Max”) are labels, see `note` for context.
6. Don't add explanations, quotes or markdown that the source doesn't have.
