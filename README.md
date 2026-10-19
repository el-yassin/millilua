# Smash Garden — a reverse-engineerable MiliLua minigame

A complete whack-a-mole minigame for **Miliastra Wonderland** (MiliLua 7.1),
written to be read and taken apart. Every file is annotated with the
*pattern* it demonstrates.

**The game:** a 30-second round, 9 slots, up to 3 targets alive at once —
12% of them **golden** (5× points, half the lifetime). Click targets for
points, combo builds a multiplier (x1→x5), targets that escape or empty
clicks reset the combo. Pre-round countdown, a pause menu, a results screen
with replay, server-persisted high score, and difficulty tunable live from
the node graph.

## Files

| File | Attached to | Role |
|---|---|---|
| `lua/minigame/director.lua` | root container `SmashGarden` | Game state machine (IDLE→COUNTDOWN→PLAYING), round timer, spawning, scoring, server signals, pause toggle |
| `lua/minigame/helpers.lua` | root container `SmashGarden` | Shared pure functions ("stdlib"), called via `script:Invoke` |
| `lua/minigame/target.lua` | Target **templates** (normal + golden) | Self-managing target: click → reports its multiplier → owns its own death animation |
| `lua/minigame/results_panel.lua` | `Results` container | End screen: slide-in, keyboard + controller replay button |
| `lua/minigame/pause_menu.lua` | `PauseMenu` container | Pause overlay: dim + pop-in, resume/quit buttons (presentation only) |
| `lua/minigame/debug_hud.lua` | `DebugText` TextWindow (optional) | Live state readout for test play; `Enabled=0` = zero-cost when shipped |

Next step after this README: **`TUTORIAL.md`** — turning the demo into an
actual playable game (stage, server wiring, progression, content, QA).

## Patterns index (start here when reverse-engineering)

| Pattern | Where |
|---|---|
| Lifecycle order & when UI exists | `director.OnStart` header comment |
| Script Variables from editor mapping | `director` top: `script:GetParam` |
| Per-template behavior via script vars | `target.lua` `PointsMultiplier` (golden target) |
| State machine across lifecycle fns | `director` `State` table + `state` |
| OnUpdate (real time) vs OnLevelUpdate (level time) | `director` countdown vs round clock |
| EnableUpdate gating (no frames burned when idle) | `beginCountdown` / `endRound` |
| Pause via `game.PauseLevelTime` | `director.setPaused` `[PAUSE]` |
| Server → client signals (~100ms latency) | `director.OnStart` `[SIGNAL IN]` |
| Client → server signals | `showResults`, `SetGoldenRate` handler |
| Server-tunable gameplay values | `goldenRate` + `SetGoldenRate` |
| Custom Variables (server-persisted high score) | `director.OnStart` `[CUSTOM VAR]` |
| Instantiation + destroy (targets, popups) | `spawnTarget`, `spawnPopup` |
| Tween lifecycle + self-pruning set registry + kill-on-destroy | `director.trackTween`, `pause_menu` tweens, `OnDestroy` |
| Kill-before-retrigger (tweened fields lock while playing) | `director` combo pop, `results_panel` slide-in |
| TweenSequence chaining | `target.onClick` |
| Tweenable color values (`Color.FromRGB/RGBA`) | timer color pulse, pause overlay fade |
| Image fill (proper timer bar) | `timerBar:SetFillHorizontal` in `OnLevelUpdate` |
| Cursor events (`CursorEventData`) | `target.OnStart`, `director.OnStart` (miss detection) |
| Key events (boolean = consumed) | `results_panel`, `pause_menu`, `director` (F/ESC) |
| Controller focus + device detection | `results_panel.Show`, `pause_menu.Show` |
| Cross-script calls with `script.alive` guard | `helpers()`, `getDirector()`, `pause_menu.director()` |
| SetActive vs SetVisible | panels hide via `SetVisible` (their scripts must stay alive!); script-less HUD/playArea use `SetActive` |
| Sibling index = z-order | `spawnPopup` (`SetAsLastSibling`) |
| Localization via `game.GetText` + `GetLanguageType` | all `fmt*` + `comboSeparator` |
| Teardown discipline | `director.OnDestroy` (incl. unfreezing level time), `pause_menu.OnDestroy` |

## Editor setup (what to build in the stage editor)

### Control hierarchy

```
SmashGarden            (root ContainerControl — Interface Layout)
├─ PlayArea            (ContainerControl, covers the play field)
│  ├─ Slot1 .. Slot9   (ContainerControls, 3x3 grid — pure positions)
│  └─ (targets + popups get instantiated here at runtime)
├─ Hud                 (ContainerControl)
│  ├─ TimerBar         (Image, Horizontal fill — NOT resized; fillAmount driven)
│  ├─ ScoreText        (TextWindow)
│  ├─ ComboText        (TextWindow)
│  └─ DebugText        (TextWindow, optional — debug_hud.lua lives here)
├─ CountdownText       (TextWindow)
├─ Results             (ContainerControl — starts ACTIVE, hidden by script via SetVisible)
│  ├─ FinalScoreText   (TextWindow)
│  ├─ StatsText        (TextWindow)
│  ├─ BestText         (TextWindow)
│  └─ ReplayButton     (ContainerControl with a CursorEventArea)
└─ PauseMenu           (ContainerControl — starts ACTIVE, hidden by script via SetVisible)
   ├─ Overlay          (Image, full-screen, imageColor alpha 0→160 tweened)
   └─ MenuBox          (ContainerControl, centered)
      ├─ ResumeButton  (ContainerControl with a CursorEventArea)
      └─ QuitButton    (ContainerControl with a CursorEventArea)
```

### Templates & script mappings

1. **Target templates** — two controls (image + `CursorEventArea` component)
   registered as **Client Control Templates**:
   - **Normal** → map `target.lua`, script var `PointsMultiplier=1`
   - **Golden** → map `target.lua`, script var `PointsMultiplier=5`
     (same script, different mapping values — that's the whole golden feature)
   Note both template indices.
2. **Popup template** — a small TextWindow also registered as a template.
   No script needed; the director drives it.
3. Map scripts onto the root `SmashGarden` container:
   - `director.lua` with Script Variables:
     `RoundDuration=30`, `TargetTemplateIndex=<normal>`,
     `GoldenTemplateIndex=<golden>`, `PopupTemplateIndex=<popup>`,
     `HitSfxId`, `MissSfxId`, `RoundEndSfxId` (audio clip IDs),
     `AllowManualStart=1` (set to `0` in a production stage so only the
     server's `StartRound` signal can begin rounds).
   - `helpers.lua` (no variables).
4. Map `results_panel.lua` onto `Results`, `pause_menu.lua` onto `PauseMenu`.
   Both panels must start **active** (scripts hidden via `SetVisible(false)`,
   never `SetActive(false)` — an inactive control's script gets no lifecycle
   functions, so its first `Show` would run against uninitialized refs).
5. *(Optional, recommended for development)* Map `debug_hud.lua` onto
   `DebugText` with Script Variable `Enabled=1`. The script stays active
   but hidden when disabled (`Enabled=0`), and skips its update loop
   entirely — zero cost when shipped.
6. **TimerBar** must be an Image control with fill type Horizontal
   (the director calls `SetFillHorizontal`; it never resizes the control).
7. **Text Mapping** entries (Script Text Variables):

   | ID | Source (en) |
   |---|---|
   | `minigame.score` | `Score: %d` |
   | `minigame.combo` | `Combo: %d` |
   | `minigame.best` | `Best: %d` |
   | `minigame.final_score` | `Final Score: %d` |
   | `minigame.stats` | `Hits: %d  Misses: %d  Best Combo: %d` |
   | `minigame.countdown` | `%d` |
   | `minigame.go` | `GO!` |

   **Localization pass (exercise 7):** add a second language column for every
   entry (e.g. `minigame.go` → `スタート!`), then set the client language in
   test play and confirm `game.GetText` switches. The code-side rule this
   demonstrates: **no visible string is ever assembled in Lua** — only
   format-specifiers live in code. The one language *behavior* branch is
   `comboSeparator()` in the director (cosmetic only).
8. **Custom Variable component** on the Player entity with an integer
   `BestScore` (this is the `HIGHSCORE_ENTITY`/`HIGHSCORE_VAR` pair at the
   top of `director.lua` — adjust the enum if you put it elsewhere).

### Node graph wiring (server side)

| Signal | Direction | Node | Payload |
|---|---|---|---|
| `StartRound` | server → Lua | *Send Client Scripted Signal* | `[1] int` = duration override (optional) |
| `AbortRound` | server → Lua | *Send Client Scripted Signal* | none |
| `SetGoldenRate` | server → Lua | *Send Client Scripted Signal* | `[1] int` = percent 0–100 |
| `RoundComplete` | Lua → server | signal-receiving node (see Server Signal Explorer) | `int score, int hits, int misses, int bestCombo` |
| `SubmitHighScore` | Lua → server | signal-receiving node → Set Custom Variable | `int score` |

> Order matters: signal params are read **by index** on both sides, matching
> the Server Signal Explorer order exactly.

**Putting the server-driven parts together (exercise 6):** a stage-flow
graph where (a) an entry trigger sends `StartRound`, (b) a Stage Timer node
sends `SetGoldenRate(40)` halfway through the stage (difficulty spike from
the server!), and (c) a receiving node on `RoundComplete` checks the score
param against a threshold and unlocks the next stage. The client never
decides progression — it reports, the server judges. That's the intended
Miliastra architecture.

### Testing without any node graph

Test Play → in-game keys registered on the root control:

| Key | Action |
|---|---|
| **F** (`KeyboardInteractKeyUp`) | Start a round from IDLE (only when `AllowManualStart=1`) |
| **Tab** (`KeyboardOpenShortcutWheelKeyUp`) | Toggle pause while PLAYING |
| **Controller menu-back** | Same pause toggle (controller parity) |

The signal handlers are also wired, so once the node graph exists, both
paths work.

### Debugging tools

- **`debug_hud.lua`** — attach it to a TextWindow (`Enabled=1`) for a
  live state/score/combo readout refreshed 4× per second. It reads the
  director via `Invoke` (`GetDebugLine`) — the pattern to copy when you
  want to display state you don't own. Set `Enabled=0` to ship it inert.
- `game.PrintClientUITree()` — dump the whole control hierarchy (call it in
  `OnStart` while exploring).
- `print` / `printerr` — log output in test play.
- [seelnon's simulator](https://seelnon.github.io/Miliastra_LuaAPI/) — try
  snippets in a browser.
- [EaseLab](https://interverse.github.io/easelab/) — visualize ease types.

## Gotchas this example deliberately shows (or dodges)

1. **Controls die on loading screens.** Everything cached in `ui` is
   re-resolved in `OnStart`, never at top level.
2. **No shared global namespace.** Each script instance is sandboxed; cross-script
   access = `GetScriptByPath` + `script:Invoke` + `.alive` check. There is no
   documented `require`; `helpers.lua` shows the verified alternative.
3. **Tweened fields are locked while a Tween plays.** That's why the timer bar
   is set directly per-frame instead of tweened.
4. **Tween callbacks can only be set in the Initial state** — set ease,
   loops, and callbacks *before* `Play()`.
5. **The ~100ms server latency** makes server signals useless for
   frame-accurate things; all round timing here is client-side, the server
   only starts/ends and receives results.
6. **Raycast order:** targets instantiated into `PlayArea` sit above its
   cursor area, so a click on a target does *not* reach the "miss" listener.
   Set `raycastTarget = false` on dying targets (`despawnTarget`) so their
   shrinking corpse can't eat the next click.
7. **`script.object` is nil** for the Global Script and Modules — another
   reason the director lives on the root control.

## The exercises — now implemented in code

The original 7 progressive exercises are **built in**; here's where each one
lives and what to study in it:

1. **Read `target.lua` first.** ~70 lines showing the whole
   template→instance→click→report loop.
2. **Countdown (3…2…1…GO)** — `director.beginCountdown`/`tickCountdown`.
   Study: the countdown runs on `OnUpdate` (real time) while the round runs
   on `OnLevelUpdate` (level time) — the split isn't cosmetic, it's what
   makes pausing clean. Also: scale-punch tween per number, and the
   "only update text when the integer changes" guard.
3. **Pause menu** — `pause_menu.lua` + `director.setPaused`. Study: pause
   state lives in ONE place (the director); the panel is presentation only.
   The key listener is on the root control, because an inactive script gets
   no events — a listener on the paused panel could never un-pause it.
   Also: `game.PauseLevelTime` is single-player-only, and `OnDestroy`
   unfreezes time so a teleport mid-pause can't leave the next stage frozen.
4. **Golden targets** — `target.lua` + `spawnTarget`. Study: the same
   script mapped onto two templates with different `PointsMultiplier`
   values. Behavior = template + data, not branching code. The director
   clamps the self-reported multiplier against the combo base (trust, but
   verify — clients lie). Scoring policy stays central; only data travels.
5. **Timer bar** — `OnLevelUpdate`'s timer block. Study: the proper fill
   API (`SetFillHorizontal` + `fillAmount`) instead of resizing, the
   "continuous value = direct set, flourish = tween" rule, and the
   low-time color flash with its per-round one-shot guard.
6. **Server-driven events** — `SetGoldenRate` handler + the node-graph
   recipe in *Node graph wiring*. Study: the client tunes gameplay from
   the server, and `RoundComplete` is the hook the server uses to judge
   and unlock. Progression never lives client-side.
7. **Localization** — `comboSeparator()` + the Text Mapping table above.
   Study: strings never get assembled in Lua; only `%d`-style format
   specifiers live in code, and even the language branch is cosmetic.

## Ideas for extending it further

- **Wave mode:** server sends `StartRound` with decreasing durations —
  a difficulty curve defined entirely in the node graph.
- ** Fever mode:** 10-hit combo → double points + a fullscreen flash
  (`ClientUIFullscreenAnimationControl` is in the API for exactly this).
- **Scroller leaderboard:** `ClientUIGridScrollerControl` fed by a
  server signal with a list param (`AddIntList`/`AddStringList`).
- **Second minigame reusing `helpers.lua`** — proof the shared-code
  pattern pays for itself.

## Testing (headless, no game client needed)

`test/harness.lua` is a fake MiliLua runtime: control tree, per-instance
script environments, a tween engine **with real field-locking semantics**,
server signals, custom variables, audio, and localization lookups (an
unmapped key is an error). `test/run_test.lua` drives the real scripts
through a full match — F to start, countdown, hits, debounce, miss, combo
ramp to x2, golden 5x, pause/resume with frozen clock, low-time flash,
round end + signals + results, replay, `AbortRound` mid-countdown and
mid-pause (level time must unfreeze), signal-started round, teardown.

```sh
lua5.4 test/run_test.lua   # 153 assertions; any tween-lock violation,
                           # missing control, unmapped string, or
                           # double-destroy fails the run
```

The suite has caught real bugs during development: pop-in tweens fighting
despawn tweens over locked scale fields, an untracked combo "shrink back"
tween, a pause overlay that never hid at boot, and PlayArea staying active
after a round.

## References

- Searchable API: https://interverse.github.io/miliastra-lua-docs/
- Per-class docs: https://haminpants.github.io/miliastra-lua-api/
- API definitions (VS Code ext): https://github.com/jverif/mililua
- Simulator + examples: https://seelnon.github.io/Miliastra_LuaAPI/
- Community wiki: https://wiki.miliastra.dev/
