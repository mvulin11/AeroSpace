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
- [ ] Create GitHub fork, add as `origin`, keep upstream remote as `upstream`
- [ ] Self-signed codesign certificate (needed only to run the fork as AeroSpace.app;
      see `dev-docs/development.md` §2)
- [ ] Figure out debug-vs-release socket coexistence so the fork can be tested
      without killing the daily-driver Homebrew install

## Phase 1 — `window-closed` event (~30 lines, do first)

- [ ] Branch: `feat/window-closed-event`

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

- [ ] Branch: `feat/count-based-layout-policy`

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
