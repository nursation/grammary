# Grammary

Chrome extension that puts a small toolbar — **EN**, **RU** and a magic wand —
in the top-right corner of any `<textarea>`. The wand grammar-fixes the text in
place; EN and RU translate it in place into English or Russian. All of it is
done by Claude running through your **local** Claude Code login (the Claude
Agent SDK: no API key needed, covered by your Claude subscription).

Two parts:

| | |
|---|---|
| `server/` | HTTP server on `127.0.0.1:8917`; `POST /fix {text}` → `{fixed}` and `POST /translate {text, to: "en" \| "ru"}` → `{translated}`, each via its own **warm** Agent SDK streaming session with a forced tool call (`submit_fix` / `submit_translation`) |
| `extension/` | Manifest V3 extension: content script draws the toolbar, background service worker calls the server |

## Run the server (Docker, survives reboots)

```powershell
cd grammary
.\up.ps1              # builds on first run, then: container 'grammary', restart=unless-stopped
```

The container restarts automatically after a reboot as long as Docker Desktop
itself autostarts (Settings → General → "Start Docker Desktop when you sign in").

### Credentials: the container's own token

The container signs in with its own long-lived token — `CLAUDE_CODE_OAUTH_TOKEN`
from `claude setup-token`: valid for a year, covered by the subscription and
independent of the host login. The first `.\up.ps1` creates it: a browser
window asks you to approve, then you copy the token the CLI prints — all of its
lines, a narrow terminal wraps it — and press Enter; the script takes it from
the clipboard, glues the lines back together and saves it to `.env` next to
`docker-compose.yml` (gitignored). A token already in the clipboard (say, from
a run that failed) is reused instead of creating another one. Compose reads
`.env` by itself, so even a bare `docker compose up -d` keeps it. After a year,
or if the token was revoked, `.\up.ps1 -SetupToken` replaces it.

The host login (`%USERPROFILE%\.claude\.credentials.json`) is deliberately
**not** shared with the container: its access token lives about 8 hours and the
container cannot refresh it (`OAuth session expired and could not be
refreshed`), so a container borrowing it died every morning until the next
`claude` login on the host. Nor put the token into `~/.claude/settings.json`
(`env` block): it applies to every Claude Code session on the host and silently
downgrades them to the inference-only token.

`up.ps1` takes `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` from the shell
environment, else from `.env`, else from the legacy `~/.claude/settings.json`
`env` block, and runs `claude setup-token` only when none has one. Once the
server is up it asks Claude for one tiny fix, so a wrong or expired token shows
right away; later an auth failure shows in the extension's red tooltip together
with the command to run. A plain `docker restart grammary` is always safe.

Other commands:

```powershell
.\up.ps1 -SetupToken  # new token for the container (after a year, or if it was revoked)
.\up.ps1 -Rebuild     # rebuild the image (после правок server/src достаточно docker restart grammary)
.\up.ps1 -Down        # stop and remove
docker logs -f grammary
```

`GRAMMARY_MODEL` env var overrides the model (default
`claude-haiku-4-5-20251001` — fastest; `claude-sonnet-5` is slower but
stronger). Note: the extension calls port `8917` hardcoded — if you change
`GRAMMARY_PORT`, also change `SERVER` in `extension/background.js` **and**
`host_permissions` in `extension/manifest.json`, then reload the extension on
`chrome://extensions` (the manifest is only re-read on reload). `up.ps1` prints
a reminder when it sees a non-default port.

### Without Docker (dev)

```powershell
cd grammary\server
npm install
npm start
```

## Install the extension

- Chrome → `chrome://extensions` → enable **Developer mode**
- **Load unpacked** → pick the `extension/` folder of this repo
- after changes in `extension/`: press the reload icon on the extension's card
  and refresh the open tabs (old tabs keep the old content script, whose
  buttons then fail with "Extension context invalidated")

## Use

Hover or focus any textarea → the toolbar appears in its top-right corner:
**EN** — translate into English, **RU** — translate into Russian, the wand —
fix grammar. Click a button: it pulses while the request runs (the other two
wait), then the text is replaced in place (React-style pages get a proper
`input` event, so page state updates too). Green flash — done; red flash —
error, hover the button to see the message in its tooltip (most common one:
the server is not running). A textarea narrower than twice the toolbar shows
the wand alone.

The fix preserves language (Russian stays Russian), meaning, tone, line breaks
and markdown. Grammar, spelling and punctuation are corrected, and a word used
incorrectly (одеть/надеть, affect/effect, a wrong preposition, a broken idiom)
is replaced with the one that was meant — while slang, jargon, intentional
wordplay, quoted errors, names and code identifiers are left alone; no synonym
swaps or style rewrites.

The translation keeps meaning, tone and register (slang stays slang, a casual
chat message stays casual), line breaks, markdown and emoji, and does not add
end-of-line periods the source didn't have. Code, identifiers, paths, URLs,
@mentions and Latin-script product names are left as they are.

A mixed text — English with a Russian word or phrase in the middle, or the
other way round — is translated as a whole: the result is one grammatical text
entirely in the target language, and the errors of the parts that were already
in it are fixed too (`when user open the страницу оплаты` → `When the user
opens the payment page`). Only a text that is entirely in the target language
comes back unchanged, byte for byte: the model just names the source language
(`en`, `ru`, `mixed`, `other`) and the server decides, so the model never gets
to retype it.

Neither the fix nor a translation ever writes the letter ё — always е
(`ещё` → `еще`, `всё` → `все`). The prompts ask for it and the server enforces
it on every result the model returns, so the wand also turns the author's own
ё into е. Only a text that EN/RU hand back unchanged keeps its ё.

If the text was edited while a request was in flight, nothing is overwritten.

## Latency

Fixes and translations each have their own persistent agent session, both
pre-warmed at container start, so a request answers in a few seconds and a
fix never waits behind a translation. Each session is recycled every 50
requests to keep its context (and latency) bounded.

## Limitations

- Plain `<textarea>` only — no `contenteditable` editors (Google Docs, Slack),
  no textareas inside shadow DOM.
- Texts over 20 000 characters are rejected by the server.
- Each session runs one request at a time; concurrent clicks of the same kind
  queue up.
