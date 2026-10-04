# Claude Code prompt (Opus) - I3 Design QC App: production hardening and Ubuntu 24.04 deployment

Paste everything below the line into Claude Code (model: Opus), started in the repo root:
`C:\Users\decke\OneDrive - Network Management Group\Desktop\Claude\Code\i3-qc-app`

Before pasting: copy the supplied installer into the repo as `deploy/install-i3-qc.sh` (Section 7 says how to treat it).

---

You are picking up a working, in-production-use internal tool and continuing its development with me (Dan Eckert, deckert@troyergroup.com, Troyer Group / NMG). Read this whole brief first, then orient yourself in the repo before changing anything. Do not rewrite or "modernize" working code; extend it in the existing style.

This session's goal: make the app production ready on an Ubuntu Server 24.04 LTS machine that my team will use, and make it installable with one idempotent script.

## 0. Definition of done (the outcome I am buying)

1. The app runs unattended on Ubuntu 24.04 as a systemd service behind nginx (TLS plus login), starts on boot, restarts on failure, logs to the journal.
2. `sudo ./deploy/install-i3-qc.sh` installs everything (Node.js, nginx, service account, directories, build, service, proxy). Running it again is safe and upgrades in place. One command rolls back.
3. It is secure by default: confined to a projects root, no way to read or write outside it, workbook writes serialized and audited, and a switch to disable them.
4. It behaves exactly like dev: on the sample project the QC badges match the baselines in Section 4.
5. The Windows dev workflow is unchanged: `npm run dev` still works with no environment variables set.
6. A runbook exists (`deploy/DEPLOY.md`) and I have the exact commands to run on the real server.

## 1. What this app is

The I3 Design QC App is a browser-based QC tool for FTTH (fiber-to-the-home) designs that were built in ArcGIS Pro for i3 Broadband (Optical Tap design). It reads a real ArcGIS Pro project folder directly off disk, shows it on a Leaflet map, and runs QC checks against it. It is for NMG/Troyer Group design reviewers.

Hard architectural rules (long-standing, keep them):
- Zero Python, zero ArcGIS, zero AI/Claude call at runtime. Everything runs locally on the host; no project data leaves the machine; the server makes no outbound calls and sends no telemetry.
- Backend: Node.js + Express (`backend/`). Reads File Geodatabases via `gdal3.js` (GDAL compiled to WebAssembly) and splice-calc Excel workbooks via SheetJS (`xlsx`). Serves GeoJSON/JSON over a local HTTP API (port 4000 in dev).
- Frontend: React + TypeScript + Vite + Leaflet (`frontend/`, dev server on port 5173). All QC check logic lives in the frontend (`frontend/src/checks/*.ts`) as small pure functions (layers in, results out). The backend is a reader/writer of what is really on disk and holds no business logic.
- Per-browser-tab sessions: every request carries an `X-Session-Id` header; the backend keeps per-session project path/caches/overrides (`createSessionState` in `backend/src/server.js`). Do not reintroduce shared module-level project state.
- The backend can serve the built frontend (`frontend/dist`) from one port. In production that is the only mode: nginx proxies everything to the backend.

## 2. Repo map

- `backend/src/server.js` - Express routes (project, layers, domains, browse, splice-calc, splice-calc-dir, splice-calc/push, address-overrides, project-health, refresh, source-override).
- `backend/src/gdal.js`, `registry.js` (which layer lives in which .gdb, which are countywide "reference" layers to clip to the design area), `projectHealth.js`, `config.js` (writes `backend/project.config.json`, machine-specific, gitignored), `browse.js`, `geo-utils.js`.
- `backend/src/splicecalc.js` - parses `splice calc/*FIBER-<N><Branch>.xlsm` ("Link Budget (Mixed) " sheet - note the trailing space; header row found dynamically by "No. Terminals" in column B; terminal rows below it; each terminal carries `rowNumber`).
- `backend/src/spliceCalcWriter.js` - the ONLY place the app writes into a real source workbook (see Section 5).
- `backend/src/addressOverrides.js` - Dan's manual Address Type corrections, stored as `qc-overrides/address-type-overrides.json` inside the project folder (never written to the real geodatabase).
- `frontend/src/checks/`: `snapping.ts` (#3), `direction.ts` (#7), `roclength.ts` (#2), `terminalcalc.ts` + `terminalJoin.ts` (#1), `setback.ts` (#5), `rocRun.ts` (ROC run notes parsing), `addressSheet.ts`.
- `frontend/src/components/`: `MapView.tsx` (wires `mapview/*` modules), `LayerPanel.tsx`, `SelectionPanel.tsx`, `SpliceCalcPanel.tsx`, `PushSpliceCalcModal.tsx`, `AddressSheetPanel.tsx`, `AttributeTable.tsx`, `ProjectHealthModal.tsx`, `RefreshChangesModal.tsx`, folder pickers.
- Modal pattern: reuse `.refresh-popup-overlay` / `.refresh-popup` (App.css) for any new dialog. Do not invent a one-off modal style.
- `frontend/src/versionHistory.ts` - the app tracks its own user-facing version number (badge top right). Bump it and add an entry for any user-visible change.
- `scripts/dev.js` (`npm run dev` at repo root starts both servers), `scripts/verify/*.js` (Playwright regression scripts).
- New this session: `deploy/install-i3-qc.sh` (supplied), `deploy/DEPLOY.md` (you write it), `.gitattributes` (you add it).

## 3. Domain facts you must not get wrong

- Sample project: `NOTHMI1017 - PROJECT`. Databases: `i3_Schema_OpticalTap.gdb` (AccessPoint, Slack, Duct, Cable, SplicePoint, DropArrow, Splitter, TrunkRoute, Sectors, UtilityEasement, ...), `Splice Polygons.gdb` (TapPoly, SplitterPoly), `BaseData.gdb` (Parcels, Centerlines, ROW, ParcelPoints, Parcel_adds), `ParcelMarkers.gdb`. CRS is `USA_Contiguous_Equidistant_Conic` (meters); the backend always reprojects to EPSG:4326 for the map. `shape_Length` is meters (convert to feet for QC math).
- "ROC drop" = a `Cable` feature with `fibercount == 1`. Mainline = `fibercount > 1`. `DropArrow` is a different thing (address-to-handhole arrow) and is excluded from line-direction checks.
- "Terminal" is not its own layer: it is a `Slack` feature with `Splice_Num`, `Jumper_Branch`, `Terminal_Num`. Workbook `FIBER-4B` = Splice_Num 4, Jumper_Branch B.
- Power_Split coded values: 1=00/00, 2=60/40, 3=70/30, 4=80/20, 5=85/15, 6=90/10 (read live from the gdb domain, not hardcoded). Stocked ROC lengths (PrecutLengths domain): 50..500 by 50, then 600..1000 by 100. Valid splitter ports: 2, 4, 8.
- ROC length rule: a drop that STARTS at a splice case uses L = D + 80'; all others L = (D + 4') x 1.1; always round UP to a stocked length. Whether a drop starts at a splice case comes from its `notes` field when it parses, else from line[0] geometry.
- ROC run notes convention (confirmed by Dan): the Cable layer's `notes` holds `<Splice_Num>.<Jumper_Branch>.<N>` (e.g. `2.A.3`), N = the Terminal_Num the cable leads TO. N = 1 means it leaves a splice case; N > 1 means it leaves terminal N-1 in the same splice/branch. Authoritative when present, always cross-checked against real geometry, with fallback to geometry-only logic when blank. The sample project's notes are currently blank everywhere, so those code paths are covered only by synthetic tests.
- Snapping is exact coincidence (feet-based 0.01' tolerance), not "close enough". Duct is always required; Cable is checked only if a cable endpoint is within 15'.
- Setback: duct is expected at EXACTLY 3' from the nearest Parcels/ROW boundary (a band, too far and too close both flag).

## 4. How to run and verify

Development (Windows, unchanged):
1. Use native Windows Node (v18+), not WSL or a VM, so native binaries match the OS. First time or after any `package.json` change: `npm run install:all` from the repo root. `jszip` was added to `backend/package.json` recently, so install is required before the Splice Calculators push button works.
2. `npm run dev` (backend :4000, frontend :5173). Point the app at the project folder with the in-app "Choose project folder" picker.
3. Before declaring any change done: `cd frontend && npx tsc --noEmit -p .` and `npm run build` must be clean, then with both servers up run `node scripts/verify/mapview-smoke.js`, `map-selection-smoke.js`, `splice-calc-pdf-smoke.js` (first run needs `npx playwright install chromium`). On the sample project the expected baselines are: QC badges Snapping 4, Direction 27, ROC Length 28, Terminal Calc 2, Setback 44; zero console errors. If a change is supposed to alter those numbers, say so explicitly and explain why.
4. For new logic that the sample data cannot exercise, write synthetic unit tests against the check modules (run with `npx tsx`), mirroring a real documented case. Use `scripts/verify/helpers.js` for any new Playwright script instead of re-writing launch plumbing.
5. Never run a verification that writes into the real sample workbooks. Test writer changes against a throwaway copy of a workbook in a temp folder.

Production-style (new): the same Playwright verify scripts must be able to run against a deployed instance. Add support for `I3QC_BASE_URL` (default `http://localhost:5173`), `I3QC_BASIC_AUTH_USER` / `I3QC_BASIC_AUTH_PASSWORD` (read from the environment only, never from argv, never committed, never printed) and `ignoreHTTPSErrors` for self-signed certificates, in `scripts/verify/helpers.js`, so the baselines can be re-run through nginx.

## 5. Safety rules for the splice-calc push feature (do not weaken)

The "Push GIS -> Splice Docs" button writes GIS values into real `.xlsm` files. Constraints:
- Only column D (Distance BTW Terminals = ROC precut length) and column E (Modify Splitter Terminal as Needed = ports). NEVER column C (Power Split) or any other cell. The backend re-validates this; keep both layers of validation.
- Writes are a minimal surgical zip/XML patch via `jszip` of only the target sheet's `<c r="D56">`-style cell elements. Do NOT switch to a full-workbook round trip through SheetJS or ExcelJS: the workbooks contain real VBA (`vbaProject.bin`) and embedded images that those libraries do not reliably preserve.
- Before writing a cell, re-read that row's column B from disk and confirm it still equals the expected terminal number; on mismatch skip and report that one cell, never abort the file or guess.
- Back up the original to `<projectPath>/qc-overrides/splice-calc-backups/` first (outside the "splice calc" folder), and only when there is a real change to write.
- Pushable = a terminal-calc sub-check with status "fail" AND a known GIS value (ports additionally must be 2/4/8).
- If you touch this code, re-verify byte-level: only the target sheet XML differs, `vbaProject.bin` and media are hash-identical, `unzip -t` passes, and the file opens with `keep_vba` in an independent reader.

Additional rules for a shared server (work item H5 implements them):
- Writes to the same workbook are serialized (per absolute path) and applied atomically (temp file in the same folder, then rename). If the atomic replace is not possible on that filesystem, report the failure for that file; never silently fall back to an in-place overwrite.
- Every write attempt (applied or skipped) is appended to an audit log with who, when, file, cell, old value, new value, reason.
- `I3QC_ALLOW_WORKBOOK_PUSH=false` disables the feature server-side (403) and the UI explains why instead of failing.

## 6. Production target and deployment contract

This contract is shared between the app, the installer and the runbook. Do not change it casually; if you must, change all three together and tell me.

Platform: Ubuntu Server 24.04 LTS (amd64), systemd, nginx from the Ubuntu package (version 1.24: use `listen 443 ssl http2;`, not `http2 on;`), Node.js from NodeSource (Ubuntu's own apt Node is 18.19, which is end of life). Default Node major is 24 (current LTS as of this writing); 22 is the fallback via `--node-major 22` if gdal3.js or any dependency misbehaves on 24. Record the choice in `engines.node`.

Layout (fixed by the installer):
- `/opt/i3-qc/releases/<timestamp>/{backend, frontend/dist, RELEASE, .source-hash}`; `/opt/i3-qc/current` and `/opt/i3-qc/previous` are symlinks. The release tree is owned by root and read-only to the service.
- `/etc/i3-qc/i3-qc.env` runtime settings (root:i3qc 0640). `/var/lib/i3-qc` state and service HOME (owned by `i3qc`). Projects root `/srv/i3-projects` by default. Service account `i3qc`.
- `/etc/systemd/system/i3-qc.service` (runs `node src/server.js` with working directory `/opt/i3-qc/current/backend`; sandboxed with `ProtectSystem=strict`, writable only in the state dir and the projects root; `MemoryDenyWriteExecute` is deliberately not set because V8 and WebAssembly need it).
- `/etc/nginx/sites-available/i3-qc.conf` (TLS, optional basic auth, optional IP allow-list, gzip, proxy to `127.0.0.1:$PORT`). It always overwrites `X-Remote-User` with the authenticated user so clients cannot spoof it. `/api/healthz` is open (but still subject to the IP allow-list).
- Logs: the journal (`journalctl -u i3-qc`); installer log `/var/log/i3-qc-install.log`.

Process model: the backend listens on loopback only. nginx is the only thing exposed to the network.

Environment contract (the app must honor these; when a variable is unset the behavior must equal today's dev behavior):
- `NODE_ENV` (production on the server), `HOST` (production default 127.0.0.1), `PORT` (default 4000).
- `I3QC_PROJECTS_ROOT` - confinement root for every filesystem path the API accepts (H3).
- `I3QC_STATE_DIR` - where machine-specific state lives (the equivalent of `backend/project.config.json`, the audit log). In production the app must not write under `/opt`.
- `I3QC_TRUST_PROXY` (1 = trust `X-Forwarded-*` and `X-Remote-User` from nginx), `I3QC_ALLOWED_ORIGINS`, `I3QC_SESSION_TTL_MINUTES` (default 120), `I3QC_ALLOW_WORKBOOK_PUSH` (default true), `I3QC_LOG_LEVEL` (default info).

Health contract: `GET /api/healthz` (no session header, no disk or GDAL access) returns 200 JSON with status, version, release id (read from `../RELEASE` relative to `backend/`, "dev" when absent) and uptime. The installer's smoke test, post-deploy check and `status` command use it.

## 7. The supplied installer (`deploy/install-i3-qc.sh`)

It was written in a separate session and exercised in an Ubuntu 24.04 sandbox against a stub app with a stand-in for systemctl: fresh install, resume after a partial run, no-op re-run (no restart), upgrade, a bad release rejected by the pre-switch smoke test, automatic rollback after a post-switch failure, manual rollback, pruning, nginx auth gate and header spoofing, uninstall and purge. It has NOT been run against this repo, real systemd, a real NodeSource install, ufw, or IPv6 hosts. Treat it as a reviewed starting point, not gospel.

What it does: `install` (default, idempotent), `rollback`, `status`, `uninstall [--yes] [--purge]`. Options include `--server-name`, `--projects-root`, `--port`, `--node-major`, `--tls selfsigned|provided|none`, `--cert/--key`, `--auth-user`, `--no-auth`, `--reset-auth`, `--allow-cidr` (repeatable), `--configure-firewall`, `--keep-releases`, `--source`, `--force-rebuild`. It builds as the unprivileged service account, smoke-tests the new release on a spare port before switching the `current` symlink, restarts only when something changed, and rolls back automatically if the service is unhealthy after a switch.

Your job with it:
1. Review it end to end, run `shellcheck` on it (apt-get install shellcheck), and keep it clean.
2. Verify its assumptions against the real repo and fix the script or the repo, whichever is wrong:
   - `npm ci` works in `backend/` and `frontend/` (lockfiles in sync). The script falls back to `npm install` with a warning if not. My working tree has an unrelated modified `frontend/package-lock.json`: do not "fix" lockfiles as part of this work; tell me what you find.
   - `npm run build` in `frontend/` produces `frontend/dist/index.html`.
   - Everything the backend needs at runtime is in `backend/` dependencies (not devDependencies; `jszip` and `gdal3.js` in particular) or ships in the release. The release contains only `backend/` and `frontend/dist`. Hunt for runtime reads of anything else (for example the Address Sheet Excel export template, fonts, wasm/data files, anything under `scripts/` or the repo root) and extend the script's staging step if needed.
   - The backend finds the built frontend at `../../frontend/dist` relative to `backend/src`, and `node src/server.js` run from `backend/` starts it with no other arguments.
3. You may change the script to fit reality. Preserve: its CLI, the fixed layout in Section 6, idempotency, the build-as-unprivileged-user step, the smoke test before switching, the rollback behavior, and the sandboxing directives. Do not weaken sandboxing or broaden the service's write access without telling me why. If behavior changes, update `--help` and `DEPLOY.md`.
4. Housekeeping so it survives Windows and git: add `.gitattributes` with `*.sh text eol=lf` (a CRLF copy fails on Linux with "bad interpreter"); set the executable bit with `git update-index --chmod=+x deploy/install-i3-qc.sh`.

## 8. Production hardening work items (code)

Do these in small commits, each with tests or measurements as noted. Unset environment variables must leave dev behavior unchanged.

H1. Configuration from environment. Implement the Section 6 contract in `config.js`/`server.js`. Validate at startup and fail fast with a clear message. Log the effective (non-secret) configuration once at start. In production, do not persist the chosen project folder machine-wide (it would leak one user's choice into another user's tab); keep it per session in memory and let the frontend remember the last folder in its own localStorage. If you see a better approach, propose it first.

H2. Health endpoint and SPA fallback. Add `GET /api/healthz` as specified. Any other unknown `/api/*` path returns a JSON 404 and must never fall through to `index.html`.

H3. Filesystem confinement. When `I3QC_PROJECTS_ROOT` is set, every endpoint that accepts or derives a path (browse, project selection, splice-calc-dir, source-override, address-overrides, and anything else you find: grep for `req.query`, `req.body` and `fs.` usage) must resolve it with `fs.realpath` and require the result to be inside the root (compare with `path.relative`, never a string prefix). The folder picker starts at the root and cannot go above it. Errors are 403 with a generic message that does not echo paths. Tests: `..` traversal, symlink escape, sibling-prefix (`/srv/i3-projects-evil`), URL-encoded and double-encoded variants, null bytes, Windows-style separators and drive letters. Also re-validate any persisted or session-held path when it is used, not only when it is chosen.

H4. Session lifecycle. Idle TTL eviction (`I3QC_SESSION_TTL_MINUTES`), a maximum session count (default 50) with least-recently-used eviction, and strict validation of `X-Session-Id` (bounded length, safe characters) because it is a map key. In production a missing header is a 400. Test with synthetic sessions, including memory returning after eviction.

H5. Workbook write safety. Implement the shared-server rules at the end of Section 5: per-path async mutex, temp-file-plus-rename in the same folder preserving mode, JSONL audit log under `$I3QC_STATE_DIR/audit/` (size-rotated; the user comes from `X-Remote-User` only when `I3QC_TRUST_PROXY=1`, else "local"), and the `I3QC_ALLOW_WORKBOOK_PUSH` kill switch with a clear UI message. Re-verify byte-level per Section 5 on a throwaway copy, on Linux, and test two simultaneous pushes to one file.

H6. HTTP hardening. Remove `x-powered-by`; set sensible security headers in the app without duplicating or contradicting nginx's; body size limits; a single error handler returning JSON with a request id and no stack traces when `NODE_ENV=production`; no CORS in production (same origin). Write the narrowest Content-Security-Policy that works by inspecting what the frontend actually loads (basemap tile hosts, fonts, Leaflet inline styles, blob: URLs used by PDF export, workers) and prove it with a headless run showing zero CSP violations in the console. Prefer no new runtime dependency; if you add one (for example `helmet`), name it, justify it in one line and pin an exact version.

H7. Static serving and the frontend build. Hashed assets get long-lived immutable caching; `index.html` is `no-cache`. The production build uses a same-origin relative API base: no hardcoded `localhost:4000` or `5173` anywhere (grep for it). Confirm behavior behind a reverse proxy (cookies are not used; headers are).

H8. Logging and process lifecycle. One JSON line per request on stdout (timestamp, level, method, path without query string, status, duration, bytes, first 8 chars of session id, user), plus startup and error lines. Never log project contents or workbook cell values outside the audit log. SIGTERM/SIGINT: stop accepting, drain in-flight requests for up to 10 seconds, exit 0. `uncaughtException` and `unhandledRejection`: log and exit 1 so systemd restarts the service.

H9. Linux correctness. Windows is case-insensitive and Linux is not (and SMB shares usually are not either, depending on mount options), and project folders are authored on Windows. Check: import path casing (the Vite/tsc build must pass on Linux); discovery of `.gdb` folders, layer names and the `splice calc` folder; matching of `*FIBER-<N><Branch>.xlsm` (including `.XLSM`) must be case-insensitive on directory listings; path separators and drive-letter handling only on win32 in `browse.js`; temp files via `os.tmpdir()`; no reliance on the process working directory except where the service guarantees it; date formatting must not depend on the server's time zone (the server is probably UTC), for example in export and backup file names.

H10. Capacity, measure first. Add `scripts/verify/load-smoke.js` (Node's built-in `fetch`, no new dependency): N concurrent sessions (default 5), each loading the sample project's layers and calling the check-related endpoints; report p50/p95 per endpoint, time to first layer, peak RSS and event-loop lag. Run it on the Ubuntu test box. Gate: if p95 for a layer load exceeds 5 s at 5 concurrent sessions, or peak RSS exceeds 1.5 GB, stop and propose options cheapest first (de-duplicate identical in-flight reads; share parsed layer caches across sessions keyed by project path plus file mtime; then worker_threads for GDAL; then hard limits), and ask before building any of them. Either way, report a recommended minimum server size (vCPU and RAM) from the measurements.

H11. Runtime pinning and supply chain. Set `engines.node` in both package.json files. Run `npm audit --omit=dev` and report the result (the `xlsx` advisory is accepted as before because it only opens local files; do not run `npm audit fix`). If you add a dependency, commit only that package's own lockfile change.

## 9. Working conventions (organization policy - mandatory)

- Languages: JS, TS, JSX/TSX, HTML, CSS, SQL, AutoLISP, PowerShell, Bash only (Bash is permitted here because the target is Linux). Python is approved for me personally, but this app is deliberately Python-free; keep it that way. nginx, systemd and env files are configuration, not a language: keep them ASCII and commented. Anything else: stop and say "Contact NMG IT department to discuss further."
- Do not put invalid or non-standard characters in code, comments or docs: no em dashes, en dashes, or arrow glyphs. Use `-` and `->`. Plain ASCII.
- Every code file gets a header in its language's comment syntax, and you must update it when you edit the file (`#` for Bash):
  ```
  // =====================
  // FILE: filename.ext
  // AUTHOR: Dan Eckert (deckert@troyergroup.com)
  // DESCRIPTION: short purpose, 2 short sentences max (history belongs in git/changelog, not here)
  // DATE: YYYY-MM-DD @ HH:MM (EST)
  // VERSION: x.y
  // =====================
  ```
  (Existing headers are longer than this; trim only when you are already rewriting the header.)
- Dependencies: when a script or code file uses third-party packages, add a `NOTE: Dependencies detected: [dep1, dep2]` line to its header, and mention any new dependency in your response. Prefer public JS libraries that install automatically; do not add anything heavy without telling me. Note the existing `xlsx` (SheetJS) advisory (prototype pollution/ReDoS) is accepted because it only opens local files Dan already has.
- Write OS-agnostic, idempotent code (use `path`, no hardcoded separators; safe to re-run). The app code stays OS-agnostic (Windows dev, Linux prod). The installer is Ubuntu-specific by design and is the one exception; it must still be idempotent.
- Lighter-weight alternative first: if a request is resource-heavy, tell me the cheaper option before doing it. Do not trigger that for inherently large tasks. H10 has its own gate.
- Git: small, descriptive commits; never `git add -A` blindly. My working tree has an unrelated modified `frontend/package-lock.json` that is not part of this work - leave it unstaged unless I say otherwise. Do not push unless I ask. `node_modules/`, build output, `backend/project.config.json`, certificates, keys and credentials stay out of git.
- Secrets: no passwords, tokens or keys in the repo, in logs, in test output or in your replies to me. The installer prints a generated login once to the terminal only.
- Docs: git log is the detailed record. This task authorizes exactly one new markdown file, `deploy/DEPLOY.md`, plus a short "Production deployment" section in `README.md` that points to it. Do not create other README/markdown files unless asked. At the end of each task give me a one-or-two sentence pointer entry (date, what, how verified) that I can paste into `i3-qc-app-changelog.md` in the Claude project.
- Do not reproduce the OneDrive pitfalls: node_modules lives in a OneDrive-synced folder, which has caused flaky partial installs (jsPDF optional deps are stubbed in `vite.config.ts` for exactly this reason). If an install misbehaves, diagnose rather than deleting and reinstalling blindly.
- Never touch my real server. No SSH, scp, or installs on any remote machine. Test only on a throwaway Ubuntu 24.04 (Section 10) and give me the exact commands to run on the real server.

## 10. Test environment for Ubuntu validation

You run on my Windows machine. Validate on a throwaway Ubuntu 24.04 with real systemd, in this order of preference: a WSL2 distro `Ubuntu-24.04` with systemd enabled (`[boot] systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown`), or a Multipass/Hyper-V VM. A Docker container without systemd is not enough. (The "not WSL" rule in Section 4 is about running the dev servers on Windows; it does not apply to this throwaway test box.) Work in the Linux filesystem (for example `~/i3-qc-test`), not under `/mnt/c`, to avoid permission, CRLF and speed problems. If no suitable environment exists, finish Phases 1 and 2, then stop and hand me the exact commands for the real server instead of improvising.

## 11. Decisions (ask me once, in a single message, each with your default)

- D1. Server name or IP users will browse to, and TLS. Default: self-signed certificate for that name now; later `--tls provided` with an internal-CA certificate. Self-signed means browsers warn until the certificate is trusted on each PC, and HSTS is deliberately off in that mode.
- D2. Access control. Default: nginx basic auth plus `--allow-cidr` for the office network. Ask whether to create one account per person (then the audit log names people; with one shared account it cannot). Do not build SSO now; mention Microsoft 365 / Entra ID sign-in (for example via oauth2-proxy) as the proper follow-up if I want it.
- D3. Where the project folders live on the server. This is the real operational question: the app reads ArcGIS projects straight from disk, and my team's projects live on Windows machines and OneDrive. Present the options (a SMB share mounted with `cifs-utils` and `uid/gid` mapped to `i3qc`; rsync from design workstations; manual copy) with the cheapest option that works, and document the chosen one in `DEPLOY.md`. Do not build sync tooling in this task.
- D4. Node major. Default 24; fall back to 22 only if the baselines differ.
- D5. Who may push to workbooks. Default: any authenticated user, audited, with the kill switch available.

## 12. How I want you to work

Phase 0 - orient (do this now, then stop). Read `README.md`, `backend/src/server.js`, `backend/src/config.js`, `backend/src/browse.js`, `frontend/src/App.tsx`, `deploy/install-i3-qc.sh`. Run `git status`, `git log --oneline -8`, and the Section 4 baseline on Windows so we both know the start is green. Then send me one message with: baseline results; anything stale or broken; the places where the repo disagrees with the installer's assumptions (Section 7); a short plan for H1-H11; and the D1-D5 questions with your defaults. Wait for my reply. (This is a deliberate exception to "one focused question": the decisions are independent and each has a default.)

Phase 1 - hardening (H1-H11). Small commits. Show real evidence (command output or counts), not just "it works".

Phase 2 - installer fit (Section 7), then write `deploy/DEPLOY.md`: prerequisites, install, upgrade, rollback, status, uninstall, trusting the self-signed certificate or installing an internal-CA one, adding or rotating basic-auth users, mounting a project share, backups (only `/etc/i3-qc` and `/var/lib/i3-qc` need backing up; project data is backed up by whatever already protects it), reading logs and the audit log, and a troubleshooting table of the failures you actually saw.

Phase 3 - validate on the throwaway Ubuntu 24.04. Show output for each:
- V1 clean install from the repo; service active; survives a reboot.
- V2 second run changes nothing: no new release, no restart, nginx untouched, login unchanged.
- V3 upgrade with a trivial change; `rollback`; pruning with `--keep-releases 2`.
- V4 a deliberately broken release is rejected by the smoke test and the current release is untouched; a failure that only appears under production settings triggers automatic rollback.
- V5 security: no credentials -> 401; `/api/healthz` open; spoofed `X-Remote-User` ignored; traversal attempts from H3 -> 403; `sudo -u i3qc touch /opt/i3-qc/x` fails; the backend is reachable only on loopback (`ss -ltnp`); report `systemd-analyze security i3-qc`.
- V6 baselines through nginx on the sample project (copied under the projects root): Snapping 4, Direction 27, ROC Length 28, Terminal Calc 2, Setback 44, zero console errors, zero CSP violations.
- V7 workbook push on a throwaway copy: Section 5 byte-level checks, an audit log line, two simultaneous pushes serialized, kill switch flips the behavior.
- V8 `kill -9` of the node process restarts within seconds; `systemctl stop` exits gracefully; the H10 capacity report.
- V9 `uninstall --yes` then a fresh install works again; the projects root is never touched.

Phase 4 - handoff. Finish with: what changed (files), decisions taken, evidence for V1-V9, anything that could NOT be tested here (for example a real NodeSource install, ufw, IPv6-less hosts, the real server), dependency notes, the exact commands I run on the real server (copy repo, `sudo ./deploy/install-i3-qc.sh --server-name ... --allow-cidr ...`, where the one-time login is printed), anything I must do on my machine, and the changelog pointer line.

## 13. Your first task

Phase 0 only. Do not change any files in Phase 0.
