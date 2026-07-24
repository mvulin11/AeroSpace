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

- [x] Branch: `feat/dead-pid-gc` — implemented, LIVE-VALIDATED, and DEPLOYED
      2026-07-24 in v0.21.3-fork.8. Both investigation gaps confirmed and fixed:
      kill(pid,0) liveness probe (with EPERM=alive; 3 unit tests) added to the
      dead-app sweep, and the dead app's windows are GC'd in the sweep itself —
      which runs BEFORE the per-app enumeration that #1615 stalls — instead of
      after it. Live: SIGKILL'd TextEdit's window left the tree in 0.4s with
      exactly one window-closed event, under a 30-call concurrent CLI hammer,
      across 3 kill cycles, log clean.
      CRASH LESSON (first attempt died in live validation): GC'ing the windows
      from an unstructured non-cancellable MainActor task interleaved with a
      light session's layout pass at a suspension point — layoutRecursive dies
      (getWeight) when the tree mutates under it. ALL tree mutations must happen
      inside the single active session task, serialized by the cancel-on-new-
      session discipline; "non-cancellable so it always runs" was precisely the
      bug. The GC loop is now synchronous (no awaits) inside the sweep, placed
      before destroy() so a cancellation between the two can't strand windows
      (destroy removes the app from allAppsMap, ending the sweep's reach).
      prune-ghost-windows.sh: KEEP RUNNING for now — retire after its logs show
      zero real prunes for a few days (and check whether the YouTube-PWA ghost
      recurs; if it does, it's not dead-PID and needs its own root-cause).
      Retirement requires the lockstep sync-mini + ~/.aerospace.toml updates.

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

- [x] Branch: `feat/window-frame-format-token` — implemented, LIVE-VALIDATED, and
      DEPLOYED 2026-07-24 in v0.21.3-fork.8. Five new tokens: %{window-x/y/width/
      height} (Numbers, rounded) and %{window-frame} (X11 geometry WxH+X+Y).
      Frame is PREFETCHED like the title (AX is async, format expansion is sync)
      and only when the format references a geometry token; nil frame (window
      died mid-query) renders NULL-WINDOW-FRAME. Live: tiled frames matched the
      real splits, and hidden-workspace windows correctly reported their
      park-corner coordinates (1727,1085 bottom-right) — geometry is AX truth,
      not tile-slot fiction. Docs updated in aerospace-list-windows.adoc.
      2 new FormatTests; EchoCommand/TestCommand golden strings updated.

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

- [x] Branch: `feat/ax-isolation` — implemented, LIVE-VALIDATED, and DEPLOYED
      2026-07-24 in v0.21.3-fork.9.
      Root cause confirmed: runInLoop awaits a continuation that only resumes when
      the app's dedicated AX thread executes the action; a wedged app blocks its
      thread inside a single AX call for up to the 6s messaging timeout PER CALL,
      the refresh task group awaits ALL apps, and cooperative cancellation can't
      run while the thread is blocked — so every session stalls behind the slowest
      app and cancel-restart churn means they may never complete.
      Fix (two layers):
      1. TIMEOUT-WITH-ABANDON: runInLoop gains a deadline (`ax-app-timeout-ms`,
         default 2000, 0 = stock); a watchdog races the run-loop action for a
         one-shot continuation claim. On timeout the await is abandoned (throws
         AxTimeoutError, distinct from CancellationError so callers degrade
         instead of aborting); the closure still finishes on the AX thread later
         and its side effects apply. Degradation per call site: refresh
         enumeration → last-known window ids (session completes, no false GC);
         withWindow/getFocusedWindow/getAxWindowsCount → existing nil paths
         (updateFocusCache(nil) keeps previous focus).
      2. QUARANTINE: without it every session re-paid the full deadline on the
         wedged app (~2s/session forever). After a timeout the app is quarantined
         for 5s — all its AX calls short-circuit to fallbacks instantly; the
         refresh enumeration doubles as the re-probe and a success ends the
         quarantine.
      Live validation (SIGSTOP'd TextEdit as the wedge): new windows tiled at
      exact no-wedge baseline parity (2.2s vs 2.3s, launch-dominated), and
      workspace move round-trips ran at 0.43-0.49s while the app was hard-wedged
      — one unresponsive app degrades ONLY itself, self-heals on recovery
      (verified: window title/frame readable again post-SIGCONT).
      3 unit tests (RunLoopTimeoutTest): timeout-under-wedge fires on deadline,
      abandoned action's late resume is swallowed (no double-resume crash),
      nil timeout = stock blocking.
      Known wedge-era nuance (harmless, self-healing): abandoned enumerations
      eventually run against the still-stopped process, read nils, and can drop
      the app's internal AxWindow entries + AX subscriptions; the tree windows
      survive (last-known ids) and the first post-recovery probe re-registers
      and re-subscribes everything.
      Validation footnote: TextEdit's window in the close test was its Open
      dialog (no AX close button) — `close` no-ops on it by design; not a bug.

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

- [x] Branch: `feat/persist-workspace-assignments` — implemented, unit-tested, and
      LIVE-VALIDATED 2026-07-24 on the debug build: 14 windows scattered across
      workspaces 1-5, SIGINT + relaunch → every window returned to its exact
      workspace AND tree position (side-by-side pairs and the 7-window split tree
      survived; focused workspace restored). State file appeared within the 500ms
      debounce of the moves, bootTime matched sysctl. Release server's in-memory
      assignments were untouched by the whole exercise.
      DEPLOYED 2026-07-24 as v0.21.3-fork.6 (the deploy itself was the last
      scattering restart — no release state file existed yet; layout re-scattered
      by CLI from a pre-deploy capture, and the new server immediately began
      writing workspace-state-bobko.aerospace.json). Layout daemon survived the
      swap in fork mode. From now on WM restarts/hot-swaps restore themselves.
      fork.7 follow-up (same day): the fork.6 self-restore test brought every
      window back but left FOCUS on workspace 1 (startup focuses the first
      workspace before the seed is restored). Now the focused workspace name is
      persisted too (optional field — fork.6 files still decode) and re-focused
      inside the restore path under an isStartup guard, so lock-unlock restores
      keep leaving focus to native tracking. Verified live: fork.6→fork.7
      hot-swap self-restored all 14 windows AND focus with zero intervention —
      the acceptance criterion end-to-end.
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

## macOS-native tabs (user-reported 2026-07-24, deployed in v0.21.3-fork.10)

- [x] Branch: `feat/native-tabs` — Ghostty cmd+T "treats a tab like a new window and
      sorts it as such". Native tabs are real AXWindows; upstream tracks only the
      ACTIVE tab (verified with a programmatic NSWindow-tabbing probe app), so the
      damage happens in TRANSITIONS: the previously active tab's window leaves the AX
      list and is GC'd while the new active tab arrives as a "new" window that binds
      via the MRU heuristic — tile hops + count-blip reshapes.
      Fix (two cooperating mechanisms):
      1. Ordered-out shelving in normalizeLayoutReason (4th state alongside
         fullscreen/minimized/hidden-app): not-onscreen per CGWindowList while none
         of the other three apply => background native tab; shelved like minimized,
         restored when ordered back in. Fullscreen precedence must stay FIRST
         (fullscreen windows live on their own Space and also read not-onscreen);
         detection skipped while screen is locked. VERIFIED SAFE: every corner-parked
         hidden-workspace window reads onscreen=true; background tab reads false.
         Config: exclude-background-tabs (default true).
      2. Vacated-position memory (closedTilingPositionMemory.swift): GC'd or shelved
         tiling windows record (pid, parent, index, weight) for 5s; the next new
         window of that app on that workspace reclaims the exact spot AND size
         instead of MRU insertion. Also gives cmd+W→new-window position inheritance.
      Live-validated with a scripted tab lifecycle (create/switch/switch/close/exit)
      against the debug server: exactly one probe window in the tree at every phase,
      same position throughout, all 13 other windows in identical order, log clean.
      5 unit tests (BackgroundTabTest): shelve+restore round-trip to exact index,
      nil-info no-op, memory match/expiry/consume, workspace scoping, index clamp.
      Limitation: switching back to a tab idle >5s falls back to MRU-adjacent
      placement (memory TTL) for apps whose background tabs leave the AX list;
      apps whose tabs persist in AX restore exactly via the shelf path.

## Close/minimize reflow latency (user-reported 2026-07-24, awaiting live validation)

- [~] Branch: `perf/reflow-latency` — "closing or minimizing an app takes a couple
      seconds before the rest of the windows adjust".
      MEASURED with a 200Hz CGWindowList probe (`optionOnScreenOnly`, ground truth of
      what reaches the screen, independent of AeroSpace's own reporting):
        * healthy baseline: close 67ms, app-quit 65ms, minimize 187ms after the
          ~680ms macOS genie animation. All fine — the complaint is NOT the steady state.
        * ONE wedged app (SIGSTOP'd Calculator) parked on an INVISIBLE workspace, with
          no window on the visible monitor: close #1 2055ms, close #3 1607ms.
      Root cause: `refresh()` calls `MacApp.refreshAllAndGetAliveWindowIds`, whose task
      group awaits EVERY app before `layoutWorkspaces()` (the thing that actually moves
      windows) can run. Phase 5's per-app deadline stops a wedged app from breaking the
      session, but the session still pays the full `ax-app-timeout-ms` (2000) to *discover*
      it is wedged — once per quarantine expiry — and that discovery gates the reflow of
      every other app's windows. Confirmed by dose-response on the live release build
      (reload-config applies the knob without a restart): 2000 -> 2054ms, 500 -> 543ms,
      200 -> 59ms. The reflow latency IS the deadline, near-exactly.
      Fix: give the enumeration probe its own, impatient deadline
      (`ax-refresh-timeout-ms`, default 250) and leave deliberate AX work (setFrame,
      focus, close) on the patient `ax-app-timeout-ms`. Justified because this call site's
      failure mode is already designed to be benign — last known window ids, quarantine,
      self-heal on the next probe — so it can afford to give up early, whereas a deliberate
      operation cannot. Stock mode (`ax-app-timeout-ms = 0`) still disables both deadlines.
      Immediate quarantine on the first refresh timeout is LOAD-BEARING, not incidental:
      it is what makes the subsequent `normalizeLayoutReason` short-circuit that app's
      per-window probes instead of then paying the 2000ms deadline on each of them
      (without it the change makes things *worse*: 250ms + 2000ms).
      Quarantine backoff 5s -> 1.5s: a re-probe now costs 250ms instead of 2000ms, so a
      wedged app stalls at most one session per window by 250ms (~17% of a busy stream vs
      40% before), and an app that was merely slow for one probe regains new-window
      detection in <=1.5s instead of being denied it for 5s.
      2 unit tests (ConfigTest): key parsing, and the sync semantics incl. 0 = fall back
      to the app deadline and stock mode disabling both.
      409 tests green. NOT yet live-validated, NOT deployed — daily driver still fork.10.
      VALIDATE BEFORE DEPLOY: (1) wedged-bystander close should drop ~2055ms -> ~300ms;
      (2) healthy close/minimize unchanged (~65ms / ~190ms); (3) REGRESSION WATCH —
      new-window detection for an app whose enumeration lands in the 250ms..2000ms band
      now waits for the next probe (<=1.5s) where it used to succeed inline. If that bites
      on real app launches (Xcode, Electron), raise the default to ~400-500ms (still 4x
      better) rather than reverting.

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

## Deployed state (2026-07-24)

- MacBook: fork v0.21.3-fork.10 live (ALL phases 1-6 + centering v4 + native tabs);
  fork.8/9/10 hot-swaps all self-restored via Phase 6 (window map + focus
  identical, zero manual steps);
  `persist-workspace-assignments` on by default — restarts self-restore;
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
