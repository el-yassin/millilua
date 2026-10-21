# Smash Garden

A complete, playable whack-a-mole game for **MiliLua v7.1** (Miliastra client
UI scripts). Twelve levels, five target kinds, a shop, medals, persistence
via Custom Variables, and a server-signal contract for node graphs — no
server required to play it locally.

**Play it end to end:** title → Play → level select → whack targets →
results → next level / shop / stats. Pause with Tab, buy upgrades in the
shop, watch persistence survive a session through Custom Variables.

**Test it:** `lua5.4 test/run_test.lua` — 314 assertions covering boot, all
menus, a full round, every target kind, fever, pause/restart/quit, results,
shop purchase/denial/cap, stats, server signals, and teardown.

Every visible string comes through Text Mapping, every control reference
resolves through `GetChild`, and shared code crosses script boundaries only
via `GetScriptByPath` + `Invoke` — the three rules the whole project is
built on (see [Architecture](#architecture)).

---

## How to play

| Input (keyboard) | Action |
| --- | --- |
| `W` / `S` (or `A` / `D`) | Move focus between buttons (4-column grid on level select) |
| `F` | Confirm the focused button |
| `Tab` | Back / open-pause / resume-pause |
| Mouse | Click anything |
| Gamepad | Native controller navigation; **Confirm** / **Cancel** nav events mirror F / Tab |

### Scoring

```
points = PointsFor(combo) × kindMultiplier × (fever ? 2 : 1)

PointsFor(combo)       = 10 × min(5, 1 + floor(combo / 5))   -- x1 → x5
kindMultiplier         = template value, clamped 1..10        -- golden: 5 + shop tier
fever                  = combo ≥ threshold (10 − combo tier, min 4); survives
                         until the combo breaks
```

Hitting **nothing** (empty ground), letting a target **escape**, or hitting a
**bomb** resets the combo and ends fever.

| Kind | Code | Value | Notes |
| --- | --- | --- | --- |
| Normal | 1 | 1× | The baseline pest |
| Silver | 2 | 2× | |
| Golden | 3 | 5× (+1 per Golden Touch tier, cap 10) | Short life (0.55×), pops bigger |
| Bomb | 4 | **−15 points** | Breaks combo and fever; long life (1.35×) |
| Time | 5 | **+3 s** on the clock | Capped at the round duration; keeps combo |

### Medals, coins, progression

* Stars: **3** ≥ gold threshold · **2** ≥ silver threshold · **1** ≥ target
  (0 = failed, next level stays locked).
* Coins earned: `floor(score / 20) + 5 × stars`.
* Clearing a level (≥ 1 star) unlocks the next one; results' **Next** starts
  it, **Replay** reruns it, **Menu** exits.
* Best score per level is tracked for the star readout; the aggregate best
  (`BestScore` Custom Variable) persists — see
  [tradeoffs](#known-tradeoffs).

### Shop

| Upgrade | Tiers | Cost per tier | Effect |
| --- | --- | --- | --- |
| Longer Rounds (`time`) | 3 | 60 / 150 / 320 | Round duration +2 s per tier |
| Golden Touch (`gold`) | 3 | 80 / 180 / 400 | Golden multiplier +1 per tier (5 → 8) |
| Combo Master (`combo`) | 3 | 70 / 160 / 350 | Fever starts 1 combo earlier per tier (10 → 7) |

Purchases are **local-first**: the wallet mutates immediately, echoes the
whole wallet to the server (`SubmitWallet`), and any server-confirmed Custom
Variable change overwrites the local state — server wins.

### Levels

12 levels, all content in `lua/minigame/level_data.lua`. Weights are
percentages over kinds `{normal, silver, golden, bomb, time}` and must sum
to 100. Level 1 is deliberately all-normal (tutorial patch + deterministic
tests).

| # | Name key | Dur | Target / Silver / Gold | Spawn start→min | Max active | Weights |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `minigame.level.name.1` | 30 | 80 / 150 / 240 | 1.00→0.55 | 3 | 100,0,0,0,0 |
| 2 | `minigame.level.name.2` | 30 | 120 / 220 / 340 | 0.95→0.50 | 3 | 82,0,18,0,0 |
| 3 | `minigame.level.name.3` | 32 | 160 / 300 / 450 | 0.90→0.50 | 3 | 70,20,10,0,0 |
| 4 | `minigame.level.name.4` | 32 | 180 / 330 / 500 | 0.90→0.45 | 3 | 65,15,12,8,0 |
| 5 | `minigame.level.name.5` | 28 | 170 / 320 / 480 | 0.90→0.45 | 3 | 58,15,12,5,10 |
| 6 | `minigame.level.name.6` | 30 | 220 / 400 / 600 | 0.75→0.35 | 4 | 60,18,12,10,0 |
| 7 | `minigame.level.name.7` | 35 | 260 / 480 / 720 | 0.85→0.40 | 4 | 55,20,15,5,5 |
| 8 | `minigame.level.name.8` | 32 | 240 / 430 / 650 | 0.75→0.35 | 4 | 50,18,12,20,0 |
| 9 | `minigame.level.name.9` | 30 | 280 / 520 / 800 | 0.70→0.32 | 4 | 40,18,30,7,5 |
| 10 | `minigame.level.name.10` | 45 | 350 / 650 / 950 | 0.80→0.35 | 5 | 55,18,15,7,5 |
| 11 | `minigame.level.name.11` | 25 | 260 / 450 / 650 | 0.65→0.30 | 5 | 45,20,20,10,5 |
| 12 | `minigame.level.name.12` | 40 | 420 / 780 / 1150 | 0.60→0.28 | 5 | 40,20,25,10,5 |

---

## Architecture

```
lua/minigame/
├── helpers.lua       pure functions: scoring, stars, coins, upgrades   (shared lib)
├── level_data.lua    12 levels of pure data + accessors               (content)
├── wallet.lua        offline-first economy + Custom Variable sync     (persistence)
├── director.lua      one round: countdown, spawning, hits, pause state (gameplay)
├── game_flow.lua     screen router + ALL button/keyboard/pause input   (UI shell)
├── hud.lua           push-model HUD view (score/combo/timer/fever)     (view)
├── target.lua        one target: kind, points multiplier, click guard  (template)
├── results_panel.lua results screen view — flow pushes primitives in   (view)
├── pause_menu.lua    pause overlay view — director drives Show/Hide    (view)
└── debug_hud.lua     throttled readout of flow + director + wallet     (dev tool)
```

**One owner per piece of state**, enforced throughout:

| State | Owner |
| --- | --- |
| Screen shown, focused button, every button action | `game_flow.lua` |
| Round phase, score, combo, fever, timer, live targets | `director.lua` |
| Coins, unlock, bests, purchases, persistence | `wallet.lua` |
| Level numbers | `level_data.lua` |
| What is drawn on a panel | that panel's script (views only) |

### The three rules

1. **Text Mapping** — no visible string literal ever appears in Lua;
   everything goes through `game.GetText(key)` (or `string.format` on one of
   its results). Star glyphs `★☆` are non-linguistic and exempt.
2. **`GetChild` only** — controls are referenced by child name from a parent
   the script owns (`root:GetChild("Shop"):GetChild("TimeButton")`), never
   by a hard-coded path string.
3. **`GetScriptByPath` + `Invoke` for sharing** — MiliLua sandboxes each
   script environment; there are no globals across scripts and no module
   loader. Cross-script lookups are lazy and `.alive`-checked on every use:

   ```lua
   local function wallet()
       local root = game.FindClientUIRoot("SmashGarden")
       local s = root and root:GetScriptByPath("minigame/wallet")
       if s and s.alive then return s end
       return nil
   end
   ```

   `Invoke` returns **one value** — every cross-script function in this
   project returns a single primitive (number/string/boolean). Multi-value
   returns are not part of the documented API.

### Visible vs. active (the #1 engine trap)

Every screen, overlay and template is **active for the whole stage** and
hidden with `SetVisible(false)`. A control that starts inactive may never
run its `OnStart` (refs would be nil on first use) and `SetActive(false)`
also kills key listeners and lifecycle callbacks — so it is never used for
hiding. Toggling a template's `SetActive(false)` is how objects are
recycled after they pop.

### Tween discipline

A tweened field is **locked** while it plays. Anything that writes a locked
field directly must `:Kill()` the tween first (see `killComboPop` in
`hud.lua`, the results slide-in, the pause fade). Self-pruning registries
track per-field tweens so a retrigger can't overlap and `OnDestroy` can
sweep everything.

### Input model

* **One key owner outside rounds:** `game_flow.lua` registers `W/A/S/D`,
  `F`, and `Tab` on the root control, plus controller `Confirm`/`Cancel`
  nav events. Each screen has an ordered focus group; keyboard and gamepad
  share one focus index (nav `Focus` events keep them in sync).
* **The director only listens for `Tab` while a round is PLAYING** (opens
  pause); its listener returns "not handled" while paused so the flow's
  listener closes it. During the 3-second countdown Tab is a no-op by design.
* **0.25 s activation debounce** in `game_flow.runAction` makes the double
  activation that a gamepad confirm can produce (nav `Confirm` + simulated
  cursor click in one frame) structurally impossible. Target clicks are not
  debounced — that guard lives only in the flow.

---

## Editor setup

### Control tree

Root is a Client Container Control named **`SmashGarden`**. All controls
stay active; visibility is driven by the scripts.

```
SmashGarden (Container)
│   scripts: helpers, level_data, wallet, director, game_flow
│
├── TitleScreen (Container)
│   ├── TitleText, SubtitleText (TextWindow)
│   └── StartButton (CursorEventArea) └── Label
├── MainMenu (Container)
│   ├── TitleText, CoinsText
│   └── PlayButton, ShopButton, StatsButton  └── Label each
├── LevelSelect (Container)
│   ├── HeaderText
│   ├── Level1 … Level12 (Container) ── NameText, StarsText
│   └── BackButton └── Label
├── Shop (Container)
│   ├── HeaderText, CoinsText
│   ├── TimeButton, GoldButton, ComboButton (Container)
│   │     └── NameText, DescText, TierText, PriceText
│   └── BackButton └── Label
├── Stats (Container)
│   ├── HeaderText, StatsBody (TextWindow, multi-line)
│   └── BackButton └── Label
├── Game (Container)
│   ├── PlayArea (CursorEventArea)
│   │     └── Slot1 … Slot9 (Containers — spawn anchors)
│   ├── Hud (Container)  script: hud
│   │     ├── TimerBar (Image, fill LeftToRight)
│   │     ├── ScoreText, ComboText, LevelText
│   │     └── FeverFlash (Image, full-screen white)
│   └── CountdownText
├── Results (Container)  script: results_panel
│   ├── TitleText, VerdictText, MedalText, FinalScoreText
│   ├── StatsText, CoinsText, NewBestText, BestText
│   └── NextButton, ReplayButton, MenuButton  └── Label each
├── PauseMenu (Container)  script: pause_menu
│   ├── Overlay (Image, full-screen dim)
│   └── MenuBox (Container)
│         ├── TitleText
│         └── ResumeButton, RestartButton, QuitButton  └── Label each
└── DebugText (TextWindow)  script: debug_hud   (Enabled = 0 to ship)
```

Panels (`Results`, `PauseMenu`) must be attached **before** `director` in
start order is *not* required — all cross-script lookups are lazy — but
attaching them anywhere works, as the test boot order proves.

### Template Client Controls

The director's template indices (script vars on **`SmashGarden`**) point at
these Templates:

| Index | Name | Script | Script vars |
| --- | --- | --- | --- |
| 1 | `TargetN` | `minigame/target` | `Kind = 1`, `PointsMultiplier = 1` |
| 2 | `TargetS` | `minigame/target` | `Kind = 2`, `PointsMultiplier = 2` |
| 3 | `TargetG` | `minigame/target` | `Kind = 3`, `PointsMultiplier = 5` |
| 4 | `TargetB` | `minigame/target` | `Kind = 4`, `PointsMultiplier = 1` |
| 5 | `TargetT` | `minigame/target` | `Kind = 5`, `PointsMultiplier = 1` |
| 6 | `Popup` | *(none — text-only float-up popup)* | — |

### Script variables

| On control | Variable | Meaning |
| --- | --- | --- |
| `SmashGarden` (director) | `TemplateNormal` / `TemplateSilver` / `TemplateGolden` / `TemplateBomb` / `TemplateTime` | Template indices (1–5 above) |
| `SmashGarden` (director) | `PopupTemplateIndex` | 6 |
| `SmashGarden` (director) | `HitSfxId`, `MissSfxId`, `BombSfxId`, `TimeSfxId`, `RoundEndSfxId`, `FeverSfxId` | Audio ids (0 = silent) |
| `SmashGarden` (game_flow) | `ClickSfxId` | Menu click audio id (0 = silent) |
| target templates | `Kind`, `PointsMultiplier` | Reported to the director on each hit |
| `DebugText` (debug_hud) | `Enabled` | `1` = show live state, `0` = zero-cost silence |

### Text Mapping keys

Every key the game reads (add each to the stage's Text Mapping):

```
minigame.score            minigame.combo             minigame.best
minigame.final_score      minigame.stats             minigame.countdown
minigame.go               minigame.fever             minigame.bomb
minigame.time_bonus       minigame.hud_level         minigame.coins
minigame.title            minigame.subtitle          minigame.press_start
minigame.play             minigame.shop              minigame.stats_title
minigame.back             minigame.level_select      minigame.level_locked
minigame.level.name.1 … minigame.level.name.12
minigame.shop.time_name   minigame.shop.time_desc
minigame.shop.gold_name   minigame.shop.gold_desc
minigame.shop.combo_name  minigame.shop.combo_desc
minigame.shop.tier        minigame.shop.max          minigame.shop.price
minigame.stats.cleared    minigame.stats.rounds
minigame.stats.smashes    minigame.stats.best
minigame.results_title    minigame.complete          minigame.failed
minigame.coins_earned     minigame.new_best
minigame.next             minigame.replay            minigame.menu
minigame.paused           minigame.pause.resume      minigame.pause.restart
minigame.pause.quit
```

Format args (in `string.format` order):

| Key | Args |
| --- | --- |
| `score`, `combo`, `best`, `final_score`, `stats` (×3), `coins`, `countdown` | `%d` … |
| `hud_level` | level, target |
| `stats.cleared` | cleared, total |
| `coins_earned` | coins |
| `shop.tier` | tier, max |

The exact English values live in `test/harness.lua`'s `TEXTS` table and are
asserted against, so that table doubles as the reference for missing keys.

---

## Server integration

Client-only scripts; the bridge is **Server Signals** (index-matched
parameters, ~100 ms) and **Custom Variables**.

### Signals sent by the client (`game.ServerSignal(name)` → `AddInt`… → `SendSignal`)

| Signal | Params | When |
| --- | --- | --- |
| `RoundComplete` | `[1]` level `[2]` score `[3]` stars `[4]` coins `[5]` hits | A round ended (not on abort/quit) |
| `SubmitHighScore` | `[1]` best score | Round ended **and** a new all-time best |
| `Purchase` | `[1]` item code (1 time / 2 gold / 3 combo) `[2]` new tier | A purchase succeeded |
| `SubmitWallet` | `[1]` coins `[2]` unlocked `[3]` best `[4]` plays `[5]` smashes `[6]` time tier `[7]` gold tier `[8]` combo tier | After any wallet mutation (full snapshot) |

### Signals accepted by the client (`script:RegisterServerSignalHandler`)

| Signal | Params | Effect |
| --- | --- | --- |
| `StartLevel` | `[1]` level id | Starts that level if the director is idle — **bypasses level locks** (server is authoritative) |
| `AbortRound` | — | Aborts the current round with no results screen, returns to the menu |

Handler signature: `function(signalName, signalParams)`.

### Custom Variables (server-managed, read on boot, echoed on change)

| Variable | Meaning |
| --- | --- |
| `SmashCoins` | Coin balance |
| `SmashUnlocked` | Highest unlocked level (1 = only level 1) |
| `BestScore` | All-time best score |
| `SmashPlays` | Finished rounds |
| `SmashSmashes` | Total targets hit |
| `SmashUpgTime` / `SmashUpgGold` / `SmashUpgCombo` | Shop tiers (0–3) |

Each is watched with `script:RegisterCustomVariableChangedHandler(Player,
varName, …)` — **when the server confirms a value, it overwrites local
state** (server wins). A node graph that validates `Purchase` /
`RoundComplete` and writes these variables gets full authority; without one
the game is entirely playable offline.

---

## Testing

```bash
cd mililua-minigame
lua5.4 test/run_test.lua          # deterministic run
SEED=1234 lua5.4 test/run_test.lua  # vary target spawn randomness
```

* `test/harness.lua` — a fake MiliLua runtime: control tree with active/
  visible chains, per-instance script environments, `Invoke`, tween engine
  **with field locking** (overlapping tweens are recorded as failures),
  localization table, custom variables, server signals, nav/key/cursor
  events. It tests the *game*, modeling only the documented engine surface.
* `test/run_test.lua` — P0…P13: boot → title → menus → shop inspection →
  level select → level 1 (countdown, scoring, combo, fever, all five target
  kinds, escapes) → pause/restart/quit → a complete round with exact score,
  coin and signal assertions → results navigation → server abort → shop
  purchase/denial/cap + upgrade effects → stats → persistence echo →
  server-driven start → replay → teardown.
* Deterministic hooks on the director: `Invoke("OverrideKind", kind)` and
  `Invoke("DebugSpawn")` — also handy in-editor for previewing target art.

The harness models the engine; enum spellings, `SetVisible` semantics,
signal param order and template indices are verified against the v7.1 docs
but still deserve one real in-editor smoke test when the stage is built.

## Known tradeoffs

* **Per-level bests are session-only.** Custom Variables are scalars;
  twelve more editor variables is a steep setup cost, so only the aggregate
  `BestScore` persists. The level-select star readouts use session memory —
  they are rebuilt from `BestScore` for level 1 semantics only within the
  session. A node graph can persist them if you want.
* **Rounds aborted via Quit/Restart/AbortRound pay nothing and record
  nothing** — only completed rounds reach `RoundComplete`.
* Debug HUD ships with `Enabled` as a script variable so you can ship the
  script but not the behavior (no `EnableUpdate`, no text writes when 0).

## Docs

* MiliLua Lua docs (searchable): <https://interverse.github.io/miliastra-lua-docs/>
* Per-class API: <https://haminpants.github.io/miliastra-lua-api/>
* Simulator API reference: <https://seelnon.github.io/Miliastra_LuaAPI/>
* VS Code extension (script paths, snippets): <https://github.com/jverif/mililua>
