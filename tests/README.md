# Tests

The subscription page is a single Jinja2 template that is copied onto a panel by hand. Nothing else
in the repository builds it, so these checks are the only thing standing between an edit to
`index.html` and a broken page in production. They run in CI on every push and pull request
(`.github/workflows/checks.yml`) and they all read the repository's own `index.html` — there is no
path to configure and nothing to point them at.

## What each one covers

| File | Needs | Covers |
|---|---|---|
| `test_render_matrix.py` | Jinja2 | Renders 8 subscription scenarios and checks that every action button the template emits also has its matching modal, and that OpenVPN, L2TP and WireGuard appear exactly when their data and the user's status say they should. |
| `test_i18n.py` | nothing | Parses the `var STRINGS = {…};` table out of the page as JSON and checks it is valid, that the locales are exactly `fa`, `en`, `ru`, and that all three carry identical key sets. This is what catches a translation that was only half applied. |
| `test_browser.py` | Jinja2 + Chrome | Drives real Chrome over the DevTools protocol against 11 rendered fixtures: WireGuard extraction, the download of a single `.conf`, the download-all zip (opened and verified with Python's `zipfile`), malformed and duplicate links, the `#`-in-a-value and newline-injection refusals, and the OpenVPN and L2TP sheets. It also fails on any uncaught JavaScript error, console error, or failed request the page makes. |

`subrender.py` is the shared renderer: it loads `index.html` with a permissive Jinja2 environment,
stubs the `bytesformat` and `datetime` filters and the `now()` global the panel supplies, and feeds
the template a fake user. `cdp.py` is a small standard-library-only DevTools client (no Selenium, no
Playwright, no `pip install` beyond Jinja2).

Every fixture uses obviously fake data: `1.2.3.4`, `example.com`, `example.invalid`, and keys that
are the base64 of the words "privatekey" and "pubkey".

## Running them

From the root of the repository:

```bash
pip install jinja2

python3 tests/test_render_matrix.py
python3 tests/test_i18n.py
python3 tests/test_browser.py
```

Each one prints a line per case, then either `PASS` or a `FAIL:` line per failed assertion, and
exits non-zero if anything failed.

`test_browser.py` needs a Chrome or Chromium binary. It looks for one on `PATH`, in the usual macOS
and Linux locations, and in the GitHub runner's tool cache. If yours is somewhere else:

```bash
CHROME_BIN=/path/to/chrome python3 tests/test_browser.py
```

It runs headless, starts its own throwaway HTTP server on a random loopback port, and cleans up its
profile directories. The rendered fixtures go in a temporary directory that is deleted on success
and kept — with the downloaded zips — on failure, with the path printed at the end.
