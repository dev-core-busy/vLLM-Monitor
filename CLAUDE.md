# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

A toolkit of standalone Python 3 CLI tools for discovering and inspecting LLM
servers (vLLM, Ollama, LM Studio, llama.cpp, text-generation-webui, LocalAI,
KoboldCpp, TGI, …) on the network. Two tools form a discover → inspect pipeline:

- **`scan_for_llms.sh`** — *discovery*. Scans a target IP's ports and identifies
  which LLM service (if any) is behind each open port.
- **`monitor.sh`** — *deep inspection*. Given an IP (and optionally a port),
  extracts the maximum amount of information from a running LLM server: health,
  models, GPU/cache/token Prometheus metrics, endpoint support, and an
  interactive prompt test.

A second, standalone pair implements **continuous time-series monitoring** of
one or more vLLM instances (host via `VLLM_HOST`, ports/labels via
`VLLM_TARGETS`, e.g. `"8000:modelA,8001:modelB"`):

- **`vllm_collector.sh`** — long-running collector. Pulls both `/metrics`
  endpoints every 15 s, parses the Prometheus text, and appends per-model rows
  to a local SQLite DB (`vllm_metrics.db`). Purges data older than 30 days.
- **`vllm_dashboard.sh`** — `http.server` on `127.0.0.1:8899` serving an HTML +
  Chart.js dashboard and a `/api/series` JSON endpoint. Computes rates
  (tokens/s, requests/s), average latencies (TTFT/E2E/ITL from histogram
  `Δsum/Δcount`), and prefix-cache hit rate from the stored cumulative counters,
  graphed **per model over time**. Each chart has a 🔍 analysis panel: locally
  computed stats (min/max/avg/trend per series) plus an optional AI evaluation.
  The AI call is proxied server-side via `POST /api/analyze` → an
  OpenAI-compatible chat endpoint (e.g. one of the monitored vLLM instances).
  The connection is **configured in the UI** (⚙ → 🤖 *KI-Verbindung*, admin-only)
  and stored in `settings.json.ai` (`load_ai_config()`/`save_ai_config()`, 0600 —
  it holds the key); the `VLLM_AI_*` env vars are only the seed/default.
  `_normalize_ai_url()` accepts `host:port`, `…/v1`, or the full path;
  `ai_analyze(body, conn=None)` sets `chat_template_kwargs.enable_thinking=false`
  when `no_think` is on, and falls back to the `reasoning` field for reasoning
  models (Qwen3) when `content` is empty. **The connection never comes from the
  request body** — otherwise any logged-in user (incl. read-only) could use the
  server as a proxy to arbitrary URLs; `conn` exists solely for `ai_test()`
  (`POST /api/ai/test`, admin), which probes unsaved values by first fetching
  `/v1/models` (fills the model datalist) and then sending a tiny chat request.
  `ai_public()` is what the browser sees — key replaced by `key_set`, plus
  `configured` (url **and** model set). The analysis panel also shows deterministic anomaly
  detection (median/MAD) and a linear forecast; a "📋 KI-Report" button sends an
  aggregate prompt over all charts. `GET /api/alerts` serves the alert history,
  `GET /api/series?offset=…` returns a shifted window for period comparison, and
  `vllm_dashboard.sh report [seconds]` writes a scheduled shift report to
  `VLLM_REPORT_DIR` (systemd timer via `setup.sh`). **Timeline annotations**
  (deploy/restart markers) live in an `annotations` table: `GET/POST/DELETE
  /api/annotations` + `vllm_dashboard.sh annotate "label" [ts]`; they render as
  vertical lines in every chart.

The range selector additionally offers **„seit Beginn"** (`range=all`): every
`range=…` endpoint funnels through `_range_from()`, which resolves `all` via
`db_span()` (now − `MIN(ts)`, still capped at the 30-day retention) and returns
the effective span in the response, so the client learns the real window
(`windowSpan()`). Long windows switch the x-axis labels to date+time
(`tickLabel()`). **`GET /api/energy`** (`build_energy()`) integrates the DCGM
power readings over time (trapezoid, on the raw rows — not the downsampled chart
points) into **kWh per calendar day**; measurement gaps larger than 4× the median
scrape interval are skipped instead of extrapolated and reported as `coverage`.
The result renders in its own tile "GPU-Verbrauch" as a Chart.js
**bar** chart (`fetchEnergy()`/`renderEnergy()`, own instance `energyChart`, not
part of `charts{}`; the `barvals` plugin draws the value above each bar, inside
it when the bar reaches the top). That tile is a CHARTS entry carrying a `custom`
HTML string (head line + own canvas) instead of the standard canvas — such
entries get no time-series chart and no 🔍 analysis button, so every Chart.js
time-series iteration runs over `PLOTS = CHARTS.filter(s => !s.custom)` while
grid order, hide and maximize keep using the full `CHARTS` list. Days with a
measurement gap are drawn translucent (their kWh is a lower bound). The tile
preview shows **only** the daily average as a large figure (`.ebig`); the bar
chart, its labels and the Ø line appear when the tile is maximized. Note when
writing such rules: the surrounding "Diagramme" section is itself a `.card`, so
`.card:not(.maximized) …` always matches — use the child combinator
(`.card.maximized > …`).

The **"Token-Zähler"** tile is built the same way (a second `custom` CHARTS
entry, own instance `tokTileChart`, own `tokbarvals`/`tokavgline` plugins reusing
the `.ehead`/`.ebig`/`.energywrap` classes): **generated tokens per calendar day**
as a bar chart in the selected range, with an Ø/day line. Its preview shows the
**total** as the large figure (the "counter", `fmtBig`). Data comes from the
range-aware `build_tokens(range_s|start,end)` via `GET /api/tokens?range=…` —
**without** params `build_tokens()` returns all days since recording
(`_tokens_all()`, 60 s cached); that is what the Effizienz section fetches.

Both Effizienz token charts share that one full payload. The **daily** chart
(`tokchart`) is filtered **client-side** to the selected window
(`tokenWindow()`/`daysInWindow()`, mirroring the server's date filter in
`build_tokens()`), because a second range-aware request would only re-send a
subset of what `lastTokens` already holds — and the cumulative chart below needs
the *full* history at the same time. The heading `#tokdayhead` is written by
`renderTokenChart()` and names the window ("ganze Kalendertage im gewählten
Zeitraum" vs. "seit Aufzeichnungsbeginn" for `range=all`); the bars are whole
calendar days, so a 15-min window shows today's full-day bar — same semantics as
the Token-Zähler tile. Since `fetchTokens()` is throttled to the 60 s server
cache, its early return still re-renders when `tokWinKey()` (the window in *days*)
changed — otherwise a range switch would leave the old bars standing.

The Effizienz section carries a third chart, **"… seit Aufzeichnungsbeginn
(kumuliert)"** (`cumtokchart`/`cumTokChart`), fed from the very same
`lastTokens` payload — no extra request. `cumTokenSeries()` fills the **missing
calendar days** (days without measurements are simply absent from `days[]` and
would compress the category axis, i.e. distort the shape) by carrying the
running total forward. A "log. Achse" checkbox (`vllm_cumtok_log`, so it travels
with the user via `prefs.json`) switches the y axis to `logarithmic`, where
exponential growth becomes a straight line; only 1× and 3× decades are labelled,
otherwise the intermediate ticks overlap. `fitInfo()` regresses `ln(y)` and `y`
over the same points and names the better-fitting model with its R² in the
heading (growth %/day + doubling time, or "eher linear"); the **first recording
day is excluded** — it is a partial day and a massive outlier in log space
(measured on real data: R² 0.41 with it, 0.98 without).

Tile layout: every `.card` is a flex column and its canvas lives in a
`.chartwrap` (`flex:1`, `min-height:var(--card-h)`, canvas absolutely filling
it). That keeps the x-axes of all tiles in a grid row on one line regardless of
how many lines the heading wraps to, and makes `toggleMax()` free of manual
height math — the flex child fills the maximized card exactly, so nothing
scrolls. **New tiles must wrap their canvas in `.chartwrap`.**

Every tile carries four `.cbtn`s (`buildGrid()`/`wireCardButtons()`): 🔍 analyze,
⛶ maximize, `.close` = *hide the tile*, and `.unmax` = *close the fullscreen*.
`.unmax` is hidden by CSS unless the card is maximized — via the **child**
combinator (`.card.maximized > .cardbtns > .cbtn.unmax`), because a maximized
tile is a descendant of the section `.card` and a plain descendant selector
would reveal the button on every sibling tile too. Since both actions would
otherwise be a ✕, `toggleMax()` swaps the `.close` glyph to 🗑 while maximized.

**Numbers are always formatted.** With a `linear` x-axis Chart.js prints the raw
epoch value in the tooltip title (`1.770.844.123.000`) and the unrounded y value
— unreadable. `mkChart()` therefore always sets `tooltip.callbacks`
(`fmtTime()` for the title, `fmtNum()` + the spec's `unit` for the label,
`filter` drops `null` points) and `fmtAxis()` for the y ticks; comparison
datasets carry `cmpOff` so their real timestamp can be shown next to the
projected one. `fmtNum()`/`decFor()`/`fmtAxis()`/`fmtTime()` are **function
declarations** (hoisted — a tile may draw during boot) and use `de-DE`
formatting; `num()` and `fmtBig()` route through them. **A new tile needs a
`unit` in its CHARTS entry**, and any additional `new Chart(...)` needs its own
tooltip callbacks — the axis may abbreviate (Mio/Tsd), the tooltip shows the
exact value.

**Signals that only exist under load** (`hit_rate`, all latency percentiles) are
**not** derived from the delta to the previous chart bucket — over a single
bucket (~76 s in a 17 h window) they are undefined most of the time, because the
servers are idle, which yields a scatter of dots rather than a readable curve.
`build_series()` instead compares each point against `pts[i - kwin]`, a full
**sliding window** back (`_smooth_window()`: ~1/34 of the displayed span, min 4
buckets, max 1 h → 30 min at 17 h), and returns that length as `win`. Measured on
real data this turns 34 fragments averaging 1.8 points into 9 runs averaging 42
— an actual curve. The rates (`RATES`, tokens/s …) keep the short bucket delta;
they are dense anyway. Tiles whose fields are smoothed are labelled with the
window (`isSmoothed()` → `.wnote` in the card heading), otherwise the curve
cannot be interpreted.

**Gaps are not data.** Even after smoothing, the remaining gaps are real:
`hit_rate` stays `None` whenever `dq == 0` (no prefix queries at all → no
defined hit rate), and the percentiles whenever no request completed in the
window. A long run of exactly `0` is *not* a gap and not a bug — it means
queries happened with zero cache hits (verified: 26 870 queries / 0 hits in one
30 min window). `datasets()` therefore **keeps** those `null` points instead of
filtering them out, and `spanGaps` is a **time limit** (`gapMs()`, 2.5 × bucket)
rather than `true` — otherwise Chart.js draws a straight line across an
hours-long idle phase and invents a trend that was never measured. On top of
that, `renderMode(data)` decides per series how to draw it: the criterion is not
how many values there are but whether they *connect* — average length of a
contiguous run ≥ 5 points → line, below that → scatter plot with visible points.
Without this a run of one point is invisible at `pointRadius:0`, and a run of two
is a meaningless vertical stroke. Dense series (tokens/s, KV cache, running
requests, GPU) are unaffected and keep their line. `compareDatasets()` applies
the same logic, so the comparison overlay cannot contradict the main series.

The collector evaluates **configurable alert thresholds** (`VLLM_ALERT_KV/TEMP/
ERR/OFFLINE_MIN`, also read by the dashboard and exposed in `/api/config`) and
records state transitions (raised/cleared) into an `events` table — one row per
change, not per scrape.

`VLLM_TARGETS` entries may carry an optional host (`[host:]port[:label]`) so a
single collector can watch **multiple hosts/clusters**; the dashboard shows a
host filter when more than one host is present. **Self-monitoring:** the
collector writes a heartbeat into `collector_status` (surfaced in `/api/config`
and the header) and supports the **systemd watchdog** via `sd_notify`
(`READY=1`/`WATCHDOG=1`; `WatchdogSec=120` in the unit). The dashboard also
exposes a **Prometheus exporter** at `GET /metrics` (`build_prometheus()`,
prefix `vllm_monitor_`, labels host/port/model; cumulative values as counters)
for scraping by an existing Prometheus/Grafana — additive to the SQLite pipeline.

Omni models emit **no tokens**, so `gen_tps`/`gen_total` are a truthful 0 and
useless. Their throughput is the tile **„Abgeschlossene Requests/h"** (`req_ph`
= `req_ps × 3600`) plus `req_total`; `renderKPIs()` has its own `vllm-omni`
branch (aktiv · Requests/h · abgeschlossen · Dauer p95 · Fehler/s). Columns a
server type does not know show an italic **„n. v."**, never a dash and never a
made-up 0 — the same reason `kv` stays `None` instead of 0 % for servers without
a KV cache. And because every rate and percentile needs a delta,
`build_series()` gives models **without an anchor** (recording started inside
the window) their oldest raw row of the window as one: otherwise a freshly added
instance is entirely blank in long ranges, where one bucket is ~54 min and its
whole history collapses into a single point.

**vLLM-Omni** serves the same numbers under the prefix **`vllm_omni:`** and with
two different names (`requests_success_total`, `e2e_request_latency_s`).
`normalize_metric()` rewrites them to the vLLM spelling **while parsing**, so
`GAUGE_COUNTER`/`HISTOGRAMS`/`extract()` need no special case; KV cache, prefix
cache, TTFT, ITL and `cache_config_info` simply do not exist there and stay
NULL. The kind is decided by the **prefix found in `/metrics`**, not by the
configured target type (`scrape_vllm_target()` stores `kind="vllm-omni"`), so an
existing `vllm` entry keeps working when the server behind it is Omni — which is
also why `build_config()` maps instances to targets by **host:port** (not by
kind) and hands the UI the `target_id` from the file.

**UI-managed instances:** extra vLLM/**vLLM-Omni**/Ollama/**LM-Studio**/STT/DCGM targets can be
added, paused or removed from the ⚙ menu; they persist in `targets.json`
(`VLLM_TARGETS_FILE`) which the collector re-reads every scrape
(`load_extra_targets()` → `scrape_vllm_target()`/`scrape_ollama`/`scrape_lmstudio`/…)
on top of the env-defined targets. Dashboard write endpoints: `GET/POST/DELETE
/api/targets` (auth-guarded). **LM Studio** has no Prometheus `/metrics`; it is
scraped like Ollama via its REST API (`/api/v0/models` for the loaded model +
context length, and an optional generation probe on `/api/v0/chat/completions`
that runs **only against already-loaded models** to avoid cold-load stalls).
Config: `VLLM_LMSTUDIO_TARGETS` (`host:port:label`), `VLLM_LMSTUDIO_PROBE`,
`VLLM_LMSTUDIO_PROMPT`, `VLLM_LMSTUDIO_MAX_TOKENS`.

Renaming a target (type/host/port) happens **entirely inside `add_target()`**
(`prev_id` drops the old entry and carries its key over); the client must not
issue a `DELETE` afterwards, because `del_target()` also purges `config` and
`samples` for that port — changing only the *type* would otherwise wipe the
history of the very server that stays monitored. `add_target()` matches
existing entries by **host:port** (one port = one server), so a type change
replaces the entry instead of adding a second one that would be scraped twice.

Rows in the instance table carry **one ✕ each**, and which one depends on
`port_live`: a stale row on a port that still delivers data is a *swapped
model*, so it gets the entry-✕ (`DELETE /api/instances`, `del_instance()`) which
drops **only the `config` registration** and keeps the samples — deleting the
target there would take the running model with it. Everything else keeps the
target-✕ (`DELETE /api/targets`, which does purge samples). Active entries are
refused by `del_instance()`; the collector would recreate them anyway.

**API-Keys der überwachten Server:** jedes Ziel in `targets.json` kann ein Feld
`api_key` tragen (im ⚙-Dialog *Instanzen verwalten* als Passwortfeld gepflegt).
Der Collector baut daraus in `auth_headers(key, extra)` den Header
`Authorization: Bearer …` und gibt den Key durch alle Abrufe/Probes weiter
(`fetch_text`/`http_get`/`get_json`/`ollama_probe`/`lmstudio_probe`, jeweils
Parameter `key`); ohne Instanz-Key greift der globale `VLLM_API_KEY`. Keys mit
eigenem Schema (`Bearer …`/`Basic …`/`Token …`) werden unverändert übernommen.
Dashboard-Seite: `build_targets()` liefert nur `key_set` (Key **nie** an den
Browser), `add_target()` behandelt ein fehlendes `api_key`-Feld als *unverändert*,
`""` als *löschen* und übernimmt bei geänderter Host/Port-Kombination den Key des
Vorgängers (`prev_id`); `_save_targets()` schreibt 0600. Die CLI-Tools haben
denselben Mechanismus (`auth_header()` in `monitor.sh`/`scan_for_llms.sh`,
Quellen `--key=…` > `VLLM_API_KEY` > `~/.monitor_api_key` bzw.
`~/.scan_for_llms_api_key`, Eingabe via Menüpunkt mit `getpass`); bei `401/403`
weisen beide auf den fehlenden Key hin.

**Authentication & user management (always on):** the dashboard now *always*
requires a login. All accounts, roles and the LDAP config live in **`auth.json`**
(`VLLM_AUTH_FILE`, next to the DB, 0600, gitignored) — created on first start
with a default **admin/admin** whose password change is forced at first login
(`must_change`). Two roles: **admin** (full access + management) and
**readonly** (view + AI analysis, blocked from all writes/management).
Local passwords are **PBKDF2-HMAC-SHA256** (`_hash_pw`/`_verify_pw`, stdlib).
`resolve_login()` checks local users first, then LDAP. Login uses an **HTML
form** (`/api/login` → signed session cookie carrying user+role+source), not the
browser Basic-Auth popup; `/api/logout`, `/api/password`, `/api/me` round it out.
Basic-Auth is still accepted on every request (cookie-less scrapers like
Prometheus → `_basic_login`, short `VLLM_AUTH_TTL` cache). `_require_auth()`
guards everything except the page shell and `/api/me`; role/`must_change` are
enforced on `do_POST`/`do_DELETE`.

**Password managers** — the login is deliberately an **XHR login** (same pattern as
the Jarvis frontend, `frontend/js/chat.js`): the submit handler calls
`preventDefault()`, POSTs JSON to `/api/login`, and on success **hides the login
overlay and boots the dashboard in place** (`applyAuthState()`), optionally
declaring the credential through `navigator.credentials.store(new
PasswordCredential(...))` — deliberately **not** awaited, or an open save dialog
would block the boot. Rules learned from measuring Chrome via
`chrome://password-manager-internals`:

- **Never navigate after the XHR login.** A `location.replace()`/reload right
  after it makes Chrome log `No provisional save manager` — the pending save is
  discarded and the prompt never appears. The disappearing form is the entire
  "login succeeded" signal (`OnDynamicFormSubmission`).
- Do **not** clear the password field before that signal.
- Keep the real `<form>` with `name=` + `autocomplete=username/current-password`
  fields; `#authov` is opened server-side via the `__AUTHOPEN__` placeholder in
  `do_GET("/")` (`_auth_state()`) so the card is there from the first frame.
  Visibility itself is *not* an autofill factor — Chrome fills `display:none`
  forms too (measured A/B).
- Fields that must **not** be autofilled with the account password (API key
  `#tgt-key`, new-user `#nu-pass`) need `autocomplete="new-password"`;
  `autocomplete="off"` is ignored for password inputs.
- `doLogout()` does a real `location.replace("/")` (fresh form, no history entry).
- Independent of the browser, the last username is kept in a `monitor_lastuser`
  cookie (never the password) and prefills the field.

Test harness for all of this lives in the session scratchpad (`cdp.py` = stdlib
WebSocket/CDP client, `save_test.py` = real login + internals log, `boot_test.py`
= boot/JS-error check, works headless and headful via `xvfb-run`).

**LDAP/AD** is configured in the UI (⚙ → 👥 *Benutzer & Zugriff*), stored in
`auth.json.ldap`; the `VLLM_LDAP_*` env vars only **seed** it on first creation.
`ldap_login()` does a hand-rolled **simple bind** and then **always** resolves the
user's groups via `_ldap_user_groups()` (BER `SearchRequest`, stdlib) — never
conditionally, because the releases live in `auth.json.ad_groups`, not in the
legacy `group_admin`/`group_readonly` fields. `memberOf` alone is **not enough**:
it lists only *direct* groups and never the **primary group** (typically
„Domänen-Benutzer"/„Domain Users"), so `_ldap_user_groups()` additionally reads the
constructed AD attribute **`tokenGroups`** (SIDs of all groups incl. nested +
primary; only available on a **base-scope** search of the user object) and resolves
those SIDs to DNs in one `(|(objectSid=…)…)` search (`_f_eq_raw` passes raw SID
bytes; `_ldap_search(..., scope=…, binary=…)` keeps binary attrs undecoded). If
`tokenGroups` is unavailable, the primary group is reconstructed from
`objectSid` + `primaryGroupID` (`_sid_group()`). Besides the two legacy single
fields, **any number of AD groups can be released** in the UI (table
*Active-Directory-Gruppen (Freigabe)*, stored in `auth.json.ad_groups` as
`{name, role}`; `name` may be a CN or a full DN, matched by `_group_match()`).
A successful bind without any release fails the login with its own reason
(`resolve_login(..., info)` → `?login=norole` + stderr line), not the generic
"wrong password" message. Role resolution
(`resolve_ad_role`): explicit AD-user entry > released groups (admin beats
readonly) > legacy `group_admin`/`group_readonly` > `default_role`. Managed via
`POST/DELETE /api/users` with `kind: "adgroup"`; the directory search offers
"→ Admin"/"→ Read-only" per hit to release a group in one click. Admin endpoints:
`GET/POST/DELETE /api/users`, `POST /api/ldap`, `POST /api/ldap/test`. Only
meaningful with HTTPS. `setup.sh` no longer prompts for LDAP.

**Per-user view settings (server-side):** the frontend prefs that used to live only
in cookies (theme, density, tile order / collapse state, hidden models, model
colors, selected range/compare, host filter, notification toggle — all `vllm_*`
keys) are now mirrored **per user** into **`prefs.json`** (`VLLM_PREFS_FILE`, next
to the DB, 0600, gitignored) so switching machines shows the same view.
`GET/POST /api/prefs` (`load_user_prefs`/`save_user_prefs`) are allowed for **any**
logged-in user (they are personal, not management). The client `store` object
keeps cookies as a synchronous cache and batches (debounced) writes of `vllm_*`
keys to the server; `loadServerPrefs()` runs in `bootDashboard()` before the first
render, seeds the cookies from the server and re-applies them (`applyLoadedPrefs`).
On first login with an empty server profile, the existing local prefs are uploaded
once (seamless migration).

Both files are named `*.sh` but are **Python 3** (shebang `#!/usr/bin/env
python3`) and use **only the standard library** — no `pip install` needed.

## Running

```bash
python3 scan_for_llms.sh          # interactive menu (discovery)
python3 monitor.sh                # interactive menu (inspection)

# monitor.sh also has a non-interactive CLI:
python3 monitor.sh <IP>                 # full scan, auto-detects port
python3 monitor.sh <IP> <PORT>          # full scan on a specific port
python3 monitor.sh <IP> <PORT> health   # modes: health | models | metrics | prompt | json | all
python3 monitor.sh <IP> 8000 json       # machine-readable JSON export
python3 monitor.sh <IP> 8000 all --key=sk-…   # geschützter Server (auch VLLM_API_KEY)
python3 scan_for_llms.sh --key=sk-…           # dito (Menüpunkt 4 = Key eingeben)

# Continuous monitoring (two long-running processes):
python3 vllm_collector.sh               # permanent 15 s pull -> vllm_metrics.db
python3 vllm_collector.sh once          # single scrape (test)
python3 vllm_collector.sh status        # summary of stored series
python3 vllm_dashboard.sh               # dashboard on http://127.0.0.1:8899
python3 vllm_dashboard.sh 8080          # custom port
```

The collector and dashboard share `vllm_metrics.db` (SQLite, wide `samples`
table keyed by `(ts, port)`, one row per model per scrape storing raw gauges +
cumulative counters + histogram sum/count). Rates and averages are derived at
query time in the dashboard, never pre-aggregated — so counter resets (server
restart) are handled by dropping negative deltas.

GPU-hardware metrics (SM %, VRAM, temperature, watts) are collected via an
external **NVIDIA DCGM exporter** (`VLLM_DCGM_TARGETS=host:port`, default port
9400) — `scrape_dcgm()` parses the `DCGM_FI_DEV_*` Prometheus metrics per GPU
and stores them as `kind="gpu"` rows; the dashboard renders dedicated GPU panels
and a GPU KPI card. vLLM's own `/metrics` only exposes engine-level data, so this
is a separate collector source. **TODO (deferred):** GPU→model attribution
(which GPU runs which model) — only relevant once more than one GPU is present.

`session.sh` is not a tool — it is a one-line helper that resumes a specific
Claude Code session (`claude --resume <uuid>`).

## Conventions (apply to all new code and output)

- **All UI strings, comments, prompts, and output are in German** — keep new
  output consistent. (Note: `scan_for_llms.sh` avoids umlauts in output;
  `monitor.sh` uses them freely.)
- **Standard library only.** Do not introduce third-party dependencies.
- Last-used IP is persisted per-tool: `~/.scan_for_llms_last_ip` and
  `~/.monitor_last_ip`; the optional API key likewise in
  `~/.scan_for_llms_api_key` / `~/.monitor_api_key` (0600).
- TLS verification is intentionally disabled (`SSL_CTX` with `CERT_NONE`) so the
  tools can probe self-signed HTTPS endpoints.
- Both tools share the same known-LLM-port list (kept in sync manually):
  `STANDARD_PORTS` in `scan_for_llms.sh:39` and `ALL_LLM_PORTS` in
  `monitor.sh:60`. **Update both when adding a port.**

## Architecture: `scan_for_llms.sh` (discovery)

Detection happens inside `identify_service()` (`scan_for_llms.sh:162`) in
priority order:

1. **SSH** — raw TCP banner starts with `SSH-`.
2. **HTTP/HTTPS probe** — tries `http` then `https` on `/`; if neither responds,
   marks the port `"offen (unbekannt)"`.
3. **Squid proxy** — `Server:` header contains `squid`.
4. **OpenAI-compatible** — `GET /v1/models` returns `{"data": [...]}` (matches
   vLLM, llama.cpp, LocalAI, LM Studio); sub-classified via `owned_by` and the
   `Server` header (vLLM vs. uvicorn/FastAPI vs. generic).
5. **Ollama** — `GET /api/version` or `GET /api/tags` responds.
6. **Generic HTTP** — fallback when no LLM API is detected.

Key functions:
- `scan_ports()` (`scan_for_llms.sh:288`): parallel TCP scanner via
  `ThreadPoolExecutor` (`MAX_WORKERS = 200`).
- `report()` (`scan_for_llms.sh:346`): iterates open ports, calls
  `identify_service()`, prints results.
- `menu()` (`scan_for_llms.sh:427`): interactive loop — `1` standard scan,
  `2` full range scan, `3` change IP, `0` quit.

Tunable constants at the top of the file: `CONNECT_TIMEOUT = 2.0`,
`HTTP_TIMEOUT = 6.0`, `MAX_WORKERS = 200`.

Note: `host_alive()` (`scan_for_llms.sh:303`) is defined but never called.

## Architecture: `monitor.sh` (inspection)

The inspection flow is a **collect → parse → display** pipeline, orchestrated by
`full_monitor()` (`monitor.sh:1002`), which dispatches on `mode`:

1. **Port selection** — uses the given port, or `find_llm_ports()` /
   `guess_port()` to auto-discover one from `ALL_LLM_PORTS` (falls back to 8000).
2. **`detect_schemes()`** (`monitor.sh:172`) — determines whether the port
   speaks `http`, `https`, or both.
3. **`detect_server()`** (`monitor.sh:262`) — classifies the server type
   (vLLM / Ollama / generic OpenAI-compatible / …).
4. **`collect_vllm_info()`** (`monitor.sh:361`) — fires a broad set of probes in
   parallel via `fetch_all()`: `/v1/models`, `/v1/model_served_models`,
   `/health`, `/version`, `/metrics`, plus `OPTIONS /` for CORS/method support
   and existence checks for `/v1/embeddings`, `/v1/rerank`, etc. Returns raw
   per-endpoint results keyed by path.
5. **`parse_vllm_results()`** (`monitor.sh:423`) — interprets the raw results
   into a display-ready structure.
6. **Display** — `display_vllm_info()` (`monitor.sh:523`),
   `display_metrics()` (`monitor.sh:633`, parses Prometheus text into
   GPU/cache/request/token stats), or `display_ollama_info()`
   (`monitor.sh:836`) depending on server type.

Other entry points: `run_prompt_test()` (`monitor.sh:932`) sends a live
chat/generate request; `export_json()` (`monitor.sh:1106`) emits a cleaned JSON
document (timestamp, target, server, per-endpoint data) for external monitoring.

`monitor.sh` has both an interactive `menu()` (`monitor.sh:1145`) and the
non-interactive CLI in `main()` (`monitor.sh:1193`, `argv = ip [port] [mode]`).

Tunable constants: `CONNECT_TIMEOUT = 3.0`, `HTTP_TIMEOUT = 10.0`,
`METRICS_TIMEOUT = 15.0` (metrics can be slow), `MAX_WORKERS = 30`.

## Adding support for a new LLM service

1. Add its default port(s) to **both** `STANDARD_PORTS` (`scan_for_llms.sh:39`)
   and `ALL_LLM_PORTS` (`monitor.sh:60`).
2. In `scan_for_llms.sh`, add a detection block inside `identify_service()`,
   between the Ollama block and the generic-HTTP fallback. Follow the existing
   pattern: probe a characteristic endpoint, populate `result["type"]`,
   `result["models"]`, `result["api_base"]`, `result["endpoints"]`, then
   `return result`.
3. In `monitor.sh`, extend `detect_server()` to recognize it and, if its
   endpoints differ, add them to `collect_vllm_info()` and a corresponding
   `display_*` branch in `full_monitor()`.
