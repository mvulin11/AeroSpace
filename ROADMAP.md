# AeroSpace Fork Roadmap

Personal fork plan for making the `~/.config/aerospace/` shell-workaround layer native.
Owner: Matthew. Started 2026-07-23. Upstream: `nikitabobko/AeroSpace` (cloned at `d56e163`, v0.21.3-Beta era).

**Goal**: every quirk currently papered over by `layout-daemon.sh` / `enforce-three-pane.sh` /
`prune-ghost-windows.sh` / `nudge-vm-width.sh` gets fixed inside the server, where the window
tree lives and timing races don't exist. Delete scripts as their reason for existing disappears.

**Strategy**: one branch per fix on top of upstream `main`, kept rebase-friendly.
Generic fixes get PRed upstream (less fork to maintain forever); opinionated ones stay ours.
Homebrew AeroSpace stays the daily driver until a fix is validated on the debug build.

---

## Status legend
`[ ]` not started · `[~]` in progress · `[x]` done · `[u]` upstreamed/merged upstream

## Phase 0 — Infrastructure (done)

- [x] Clone upstream to `~/dev/aerospace`, verify local build
  - Builds with `PATH="/opt/homebrew/bin:$PATH" ./build-debug.sh`
  - Requires Homebrew bash 5 (installed 2026-07-23). System bash 3.2 fails with a
    misleading error that `| tail` masks — always check the exit code.
- [x] Create GitHub fork (`mvulin11/AeroSpace`), add as `origin`, keep upstream remote as `upstream`
- [x] Self-signed codesign certificate `aerospace-codesign-certificate` — created via
      CLI 2026-07-23 (openssl + `security import` with legacy PKCS12 algos +
      `security add-trusted-cert -p codeSign`; key material was in the session
      scratchpad and is disposable — losing it just means re-creating the cert and
      re-granting Accessibility once)
- [x] DEPLOYED 2026-07-23: fork v0.21.3-fork.1 is the daily driver.
      Homebrew cask uninstalled; app at /Applications/AeroSpace.app, CLI at
      /opt/homebrew/bin/aerospace. Upstream PR for Phase 1:
      https://github.com/nikitabobko/AeroSpace/pull/2199
      Build recipe (full build-release.sh needs Ruby 3.x for man pages — skipped):
        ./generate.sh --build-version 0.21.3-fork.N --codesign-identity aerospace-codesign-certificate --generate-git-hash
        swift build -c release --arch arm64 --product aerospace
        (cd xcode && xcodebuild clean build -scheme AeroSpace -destination "generic/platform=macOS" -configuration Release -derivedDataPath .xcode-build)
        codesign -f -s aerospace-codesign-certificate .build/release/aerospace
        git checkout .   # reset generated files
      KEEP the '-fork' version suffix: layout-daemon.sh's fork-mode probe greps for it.
- [x] Debug-vs-release coexistence — SOLVED UPSTREAM by design: debug builds use app id
      `bobko.aerospace.debug` with their own socket, and on startup send `enable off` to
      the release server (re-enable on quit). Swap procedure that works:
      `.debug/AeroSpaceApp --config-path ~/dev/aerospace/test-config.toml` (test config =
      real config minus after-startup-command/start-at-login, plus fork options).
      GOTCHA: only SIGINT is intercepted for the re-enable — after SIGTERM you must run
      `aerospace enable on` manually (candidate fork fix: intercept SIGTERM too).
      The release server keeps its in-memory workspace assignments while disabled, so
      windows return to their workspaces after swap-back; the layout daemon survives too.

## Phase 1 — `window-closed` event (~30 lines, do first)

- [x] Branch: `feat/window-closed-event` — implemented and LIVE-VALIDATED 2026-07-23.
      Verified on the debug server: `close --window-id` emits the event with full payload
      (windowId/workspace/appBundleId/appName); SIGKILL of an app (TextEdit) emitted
      window-closed for each of its windows within ~3s via the dead-app GC path; real-world
      popup churn (Gemini/UserNotificationCenter transients) produced balanced
      detected/closed pairs.
      Design note: screen lock GCs all windows into the closed-windows cache and now emits
      window-closed for each; cache *restore* now broadcasts a matching window-detected
      (upstream deliberately skips on-window-detected callbacks on restore; the event
      broadcast keeps subscriber bookkeeping balanced across lock/unlock).
      Next: PR upstream.

**Problem**: no window-closed callback (upstream #445 — AX destroy notifications are
unreliable). The entire `layout-daemon.sh` close-detection path infers closes from
`focus-changed` events, with `enforce-three-pane.sh`'s count-guard turning the noise
into cheap exits.

**Fix**: the server already garbage-collects closed windows reliably. Broadcast an event
at that point:
- Emit in `MacWindow.garbageCollect` — `Sources/AppBundle/tree/MacWindow.swift:79`
- New case in `ServerEventType` — `Sources/Common/cmdArgs/impl/SubscribeCmdArgs.swift:56`
- New `ServerEvent` payload (window-id, app-bundle-id, workspace) + wire through
  `broadcastEvent` (`Sources/AppBundle/subscriptions.swift`)

**Acceptance**: `aerospace subscribe window-closed` fires exactly once per real close,
including app quits and dead-PID cleanup. No event for windows moved between workspaces.

**Upstream PR candidate: YES** — closes a long-open feature request.

## Phase 2 — Native count-based layouts (the big win)

- [x] Branch: `feat/count-based-layouts` — implemented and LIVE-VALIDATED 2026-07-23 as
      `enable-count-based-layouts` config option; runs as the last step of
      normalizeContainers on the settled tree. 8 unit tests
      (CountBasedLayoutTest) cover all shapes, idempotency/weight preservation,
      floating exclusion, 5+ untouched, and the option being off by default.
      Live: 4 windows showed the 2x2 signature (all parents v_tiles), closing one
      instantly reshaped to primary+stack (1 h_tiles + 2 v_tiles parents), and the
      14-window workspace stayed untouched. The 3-window shape accepts the stack on
      either side (matches the script's permissive signature check) so `move`
      commands aren't snapped back.
      Known nuance: in the heavy refresh session normalization runs BEFORE window GC,
      so a kill-path close reshapes on the NEXT refresh event, not the same one
      (close-command path reshapes immediately). In practice event churn makes this
      invisible; if it ever matters, add a normalize pass after GC in refresh().
      Next: flip the flag in the real config at deploy time (Phase D).

**Problem**: `enforce-three-pane.sh` rebuilds the focused workspace by tiling-window count
from *outside* the server: flatten + `join-with` on a possibly half-settled tree, then a
verify-shape-and-retry loop (nested `v_tiles` signature: 2→0, 3→2, 4→4), plus the
daemon's debounce/coalescing machinery to avoid forking bash on every event.

**Fix**: a config-driven layout policy applied during normalization in
`Sources/AppBundle/layout/refresh.swift`, running atomically on the settled tree:
- 1 window → full screen (current default, untouched)
- 2 → side by side `[A | B]`
- 3 → half + two quarters `[A | (B over C)]`
- 4 → 2×2 quarters `[(A over B) | (C over D)]`
- 5+ → untouched (no opinion above 4)
- Tiling windows only — floating windows excluded from the count
- Config knob (e.g. `count-based-layout = true`) so the fork behaves stock when off

**Acceptance**: opening/closing/moving windows lands the correct shape instantly with no
retry loop; manual `cmd-ctrl-shift-r` re-assert becomes redundant.

**Deletes**: `enforce-three-pane.sh` + most of `layout-daemon.sh` (see lockstep warnings).
**Upstream PR candidate: unlikely** — opinionated; keep in fork.

## Phase 3 — Server-side ghost-window GC

- [ ] Branch: `feat/dead-pid-gc`

**Problem**: windows whose owning app PID is dead linger in the tree ("ghost windows");
`prune-ghost-windows.sh` polls `list-windows` + `ps` on a 15s debounce to close them.

**Fix**: during the existing per-refresh GC (`Sources/AppBundle/layout/refresh.swift:130`),
validate the app PID is alive; remove and GC windows of dead apps. Also covers the
title-less YouTube-PWA ghost case if it turns out to be dead-PID; if not, keep that one
narrow rule in the script until root-caused.

**Investigation (2026-07-23, code-read only — needs runtime confirmation)**: upstream
DOES already GC dead apps (`refreshAllAndGetAliveWindowIds` sweeps `nsApp.isTerminated`
-> `app.destroy()`), and refresh() GCs windows absent from aliveWindowIds. Two candidate
gaps explain surviving ghosts:
1. `destroy()` (MacApp.swift) removes the app from allAppsMap and stops its AX thread
   but does NOT GC its MacWindows — that's deferred to the refresh loop's alive-check,
   and the whole refresh session is CANCELLABLE (`scheduleCancellableCompleteRefreshSession`
   cancels the in-flight task on every new event). Event storms or a #1615 stall can
   starve the GC pass indefinitely.
2. `NSRunningApplication.isTerminated` can be stale for hard-crashed processes, while a
   `kill(pid, 0) == ESRCH` check (equivalent to the prune script's `ps` sweep) is truth.
Fix sketch: GC the app's windows inside destroy() itself (which also makes Phase 1's
window-closed event fire for them), plus a cheap kill(pid,0) liveness check in the
dead-app sweep. Confirm with DAEMON_LOG evidence or a repro before coding.

**Acceptance**: kill -9 an app → its windows vanish from the tree within one refresh,
`window-closed` events fire (Phase 1), no `flatten-workspace-tree` cleanup needed.

**Deletes**: `prune-ghost-windows.sh` (or shrinks it to the YouTube-PWA special case).
**Upstream PR candidate: maybe** — bug-fix flavored.

## Phase 4 — Window geometry in the CLI

- [ ] Branch: `feat/window-frame-format-token`

**Problem**: the CLI exposes no window geometry, so layout drift (Xcode restoring frames,
a busy app swallowing a setFrame) is undetectable. Workaround is a blind `balance-sizes`
on every workspace entry — which also destroys manual resize tweaks.

**Fix**: add `%{window-x}/%{window-y}/%{window-width}/%{window-height}` (or a single
`%{window-frame}`) format token to `list-windows`. Then drift can be *detected* and the
rebalance made conditional — or, better, add a server-side "re-assert frames on workspace
enter if diverged" option so no client polling is needed at all.

**Acceptance**: `list-windows --format '%{window-frame}'` matches actual AX frames;
manual resizes survive workspace round-trips unless real drift occurred.

**Deletes**: `spawn_rebalance` in `layout-daemon.sh`.
**Upstream PR candidate: YES** (the format token half).

## Phase 5 — The hard one: busy-app AX stall (#1615)

- [ ] Branch: `feat/ax-isolation` (attempt only after Phases 1–4 are live)

**Problem**: one wedged/busy app's AX thread stalls window detection for ALL apps
(upstream #1615, open). Symptom: windows suddenly take seconds to tile until the heavy
offender (Godot-class, stuck Electron) is restarted.

**Fix direction**: timeout/isolation around per-app AX calls so one unresponsive app
degrades only itself. Needs real architecture study of the AX thread model
(`Sources/AppBundle/util/AxSubscription.swift` and the app-attachment path) before
committing to a design. This is the highest-value *performance* fix and the riskiest.

**Upstream PR candidate: YES if it works** — it's their most-wanted class of fix.

## Visual polish — round one (2026-07-23, deployed in v0.21.3-fork.3)

- [x] JankyBorders: focused-window highlight (round, 6px, macOS blue 0xff007aff,
      inactive invisible). Brew tap refused to build (demands Xcode 27), so it's
      built from source at `~/dev/JankyBorders` (plain `make`), binary at
      `/opt/homebrew/bin/borders`, config `~/.config/borders/bordersrc`, run by
      LaunchAgent `~/Library/LaunchAgents/com.matthewvulin.borders.plist`
      (RunAtLoad + KeepAlive). Update: git pull + make + cp +
      `launchctl kickstart -k gui/$UID/com.matthewvulin.borders`.
- [x] Gaps: inner/outer 8px in the shared config (flows to the mini too — no borders
      there yet; build JankyBorders on the mini if wanted).
- [x] Branch `feat/center-non-resizable` — `center-non-resizable-windows` (default on):
      windows that CLAMP setAxFrame's size get re-positioned centered in their tile.
      v1 used an AXIsAttributeSettable probe and FAILED live: System Settings is
      vertically resizable (size settable) but clamps width — AX has no per-axis
      resizability. v2 observes clamping via one size readback after layout, cached
      per window (conforming windows pay one readback ever). LIVE-VALIDATED: System
      Settings at exact tile center x=502 = 8+(1712-723)/2.
      v2 REGRESSION (user-reported 2026-07-24, fixed in fork.4): the two-step
      "place top-left, then re-center after readback" ran on EVERY layout pass, so
      clamping windows visibly hopped left and back constantly. v3 caches the last
      clamped size (knownClampedAxSize) and places known-clamping windows at the
      centered position directly; re-positions only when the observed size moves
      the centering target. Steady state = one setAxFrame at the correct spot.
      v3 REGRESSION (user screenshot 2026-07-24, fixed in fork.5): Chrome applies
      resizes ASYNCHRONOUSLY, so a readback can catch the pre-resize size; v3
      classified clamping on a single observation and never self-healed -> a Chrome
      window got pinned to a phantom 381pt clamped size and was "centered" a third
      off-screen forever (y=387 instead of 46; size was correct). v4: clamping needs
      3 consecutive identical clamp observations (real fixed sizes repeat, races
      don't); until confirmed the window lays out stock; a clamping window observed
      conforming resets to unknown. LESSON: never permanently trust a single AX
      observation - confirm, and always leave a self-heal path.
- Later rounds: SketchyBar workspace indicator driven by fork events (window-closed
  makes per-workspace app icons accurate); empty-workspace window routing; #386
  cursor-fling skip; resize mode bindings.
- PROCESS NOTE: the build recipe ends with `git checkout .` — it discards ANY
  uncommitted edits, not just generated files. Commit everything before building.

## Phase 6 — Persist workspace assignments across restarts (high value)

- [~] Branch: `feat/persist-workspace-assignments` — implemented + unit-tested
      2026-07-24; NEEDS LIVE VALIDATION on the debug build (restart cycle).
      Design: reuses the lock-screen FrozenWorld machinery instead of a parallel
      windowId→workspace map. Write side: after every successful refresh session a
      debounced (500ms) snapshot of the full frozen world (tree shape + weights +
      floating + visible workspaces) is JSON-dumped to
      `~/Library/Application Support/AeroSpace/workspace-state-<appId>.json`
      (appId suffix keeps debug/release servers from clobbering each other; write
      skipped when bytes unchanged; sync flush in beforeTermination). Restore side:
      at startup the file is seeded into closedWindowsCache, so the EXISTING
      restoreClosedWindowsCacheIfNeeded path rebinds each window as it's detected —
      partial detection, orphan force-tiling, and monitor visible-workspace restore
      all come for free, and layout-changing commands invalidate the seed the same
      way they invalidate the lock-screen cache. kern.boottime is stamped in the
      file and checked with ±120s tolerance (CGWindowIDs recycle across reboots).
      Config knob `persist-workspace-assignments`, default ON.
      Known behavior notes: (1) restored windows skip on-window-detected callbacks
      (same as lock-unlock; the frozen tree already encodes float/workspace so
      routing rules are redundant for them) and broadcast window-detected instead;
      (2) macOS-minimized windows aren't in the frozen world (global container,
      same gap as upstream's lock cache); (3) SIGTERM isn't intercepted (Phase 0
      gotcha), so a SIGTERM kill relies on the 500ms debounced write, not the flush.

**Problem (root-caused 2026-07-24)**: upstream has NO workspace persistence (grep:
only a UI pref uses UserDefaults). On startup every window binds to its monitor's
active workspace, so any server restart (hot-swap deploys included) heaps all
windows onto one workspace. Side effect chain observed live: 12 windows in one
v-stack → ~88pt tiles → Chrome clamps at its ~375pt min height → (with pre-v4
classification) Chrome got pinned as "clamping" and mis-centered later.

**Fix sketch**: debounced dump of windowId → (workspace, floating?) to a state file
on every tree change; on startup, restore assignments for window ids that still
exist before falling back to monitor-position binding. CGWindowIDs are stable while
apps run, so this covers WM restarts/crashes (not machine reboots).

**Acceptance**: hot-swap deploy → every window returns to its workspace.

## Backlog / watch list

- [ ] Windows App (`com.microsoft.rdc.macos`) aspect-ratio clamp: `nudge-vm-width.sh`
      (AXZoomWindow renegotiation) works; a native per-app "renegotiate frame" action is
      possible but lowest priority. Keep the script.
- [ ] Upstream #386: `move-mouse window-lazy-center` can fling cursor to the hidden-window
      parking corner on floating-only workspaces. Watch; fixable in fork if it bites.
- [ ] Upstream discussion #2151: focus-follows-mouse can focus a floating window behind a
      tiled one. Watch.
- [ ] Track upstream releases (currently on Homebrew 0.21.1-Beta; upstream at 0.21.3-Beta)
      and rebase fork branches after each.

## Deployed state (2026-07-23)

- MacBook: fork v0.21.3-fork.1 live; `enable-count-based-layouts = true` in config;
  layout-daemon in FORK MODE (subscribes focused-workspace-changed + window-detected +
  window-closed; no focus-changed, no enforce-three-pane.sh, no auto-rebalance —
  manual resizes now survive; cmd-ctrl-b re-evens on demand).
- Mac mini: stock Homebrew 0.21.1-Beta; synced daemon auto-detected legacy mode
  (verified: subscribes focus-changed + enforce flow). Mini config generated with
  fork-only lines stripped.
- enforce-three-pane.sh: no longer invoked by the MacBook daemon but MUST stay in the
  repo — the mini still uses it and the sync scp's it by name; cmd-ctrl-shift-r also
  still points at it (harmless double-enforce on the fork).
- prune-ghost-windows.sh: still active on both machines until Phase 3.

## Lockstep warnings (do NOT skip when deleting scripts)

1. `sync-mini-aerospace.sh` anchors on **exact line text** in `~/.aerospace.toml`
   (the `com.microsoft.rdc.macos` block) and scp's scripts **by exact filename**
   (`enforce-three-pane.sh`). Retiring or renaming anything requires updating the Mac
   mini sync in the same change — it fails silently otherwise.
2. `~/.aerospace.toml` `after-startup-command` starts the daemon and force-prunes ghosts;
   both lines go away only when Phases 1–3 are all deployed.
3. The Mac mini presumably runs the Homebrew build — it needs the fork deployed too
   before its config can drop the scripts, or the sync must maintain two variants.

## Deploy checklist (per validated fix)

1. `PATH="/opt/homebrew/bin:$PATH" ./build-debug.sh` + run test suite (`swift test`)
2. Validate behavior against the debug build (daily driver untouched)
3. Build release, codesign (self-signed cert), install as AeroSpace.app
4. Update `~/.aerospace.toml` + delete/shrink the now-redundant script **and** update
   `sync-mini-aerospace.sh` in the same commit to the config repo
5. Rebase remaining fork branches on the new state
