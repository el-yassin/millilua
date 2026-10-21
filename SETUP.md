# SETUP.md — building Smash Garden in the MiliLua editor

The Lua in `lua/minigame/` is the whole game **logic**. It does not — and cannot —
create its own UI. MiliLua has no API to attach a script to a control at runtime,
to register Text Mapping keys, or to write Custom Variables from the client, so
the stage has to be assembled in the editor once. This file is that assembly,
in order, top to bottom. Budget roughly 30 minutes the first time.

Do the steps in order. Each one only depends on the ones above it.

---

## Before you start

- Open the MiliLua editor on your stage.
- Have the folder `lua/minigame/` where the editor expects external Lua files
  (the Script Mapping dialog reads paths *relative to* `external_lua_file`, so
  a file at `lua/minigame/game_flow.lua` is referenced as `minigame/game_flow`).
- Keep the game in **test play** while you build. Every script prints a clear
  `printerr` naming the control or key it could not find, so the log is your
  checklist validator.

---

## Step 1 — The root container

1. Open **Interface Layout**.
2. Add a root-level **Client Container Control**.
3. Rename it exactly **`SmashGarden`** (case-sensitive; `game.FindClientUIRoot`
   matches this string).

> Every other control in this document is a child of `SmashGarden`, and every
> script looks its controls up by name with `GetChild`, so **names are the
> contract**. A typo shows up as a `printerr`, never as a silent failure.

---

## Step 2 — Attach the root scripts

Open the **Script Mapping** panel for `SmashGarden` and attach these five files.
Order does not matter.

| Script path              | Role |
|--------------------------|------|
| `minigame/helpers`       | pure scoring / star / coin / upgrade math, and `Text` |
| `minigame/level_data`    | the 12 level definitions |
| `minigame/wallet`        | coins, unlocks, upgrades, server sync |
| `minigame/director`      | one round: spawning, scoring, fever, pause |
| `minigame/game_flow`     | screen router + **all** input & focus |

`game_flow` is the single owner of keyboard/controller/cursor input outside a
round; `director` only listens for the pause key while a round is playing.

---

## Step 3 — Build the control tree

Create these controls as **children of `SmashGarden`**. Exact names and types.
Leaf controls carry no children of their own unless listed.

```
SmashGarden                     (Client Container Control)
├── TitleScreen                 (Container)
│   ├── TitleText               (Text Window)
│   ├── SubtitleText            (Text Window)
│   └── StartButton             (Cursor Event Area)
│       └── Label               (Text Window)
├── MainMenu                    (Container)
│   ├── TitleText               (Text Window)
│   ├── CoinsText               (Text Window)
│   ├── PlayButton              (Cursor Event Area)
│   │   └── Label               (Text Window)
│   ├── ShopButton              (Cursor Event Area)
│   │   └── Label               (Text Window)
│   └── StatsButton             (Cursor Event Area)
│       └── Label               (Text Window)
├── LevelSelect                 (Container)
│   ├── HeaderText              (Text Window)
│   ├── Level1 … Level12        (Cursor Event Area ×12)
│   │   ├── NameText            (Text Window)
│   │   └── StarsText           (Text Window)
│   └── BackButton              (Cursor Event Area)
│       └── Label               (Text Window)
├── Shop                        (Container)
│   ├── HeaderText              (Text Window)
│   ├── CoinsText               (Text Window)
│   ├── TimeButton              (Cursor Event Area)
│   │   ├── NameText   DescText   TierText   PriceText   (Text Window ×4)
│   ├── GoldButton              (Cursor Event Area)
│   │   ├── NameText   DescText   TierText   PriceText   (Text Window ×4)
│   ├── ComboButton             (Cursor Event Area)
│   │   ├── NameText   DescText   TierText   PriceText   (Text Window ×4)
│   └── BackButton              (Cursor Event Area)
│       └── Label               (Text Window)
├── Stats                       (Container)
│   ├── HeaderText              (Text Window)
│   ├── StatsBody               (Text Window)
│   └── BackButton              (Cursor Event Area)
│       └── Label               (Text Window)
├── Game                        (Container)
│   ├── PlayArea                (Cursor Event Area)
│   │   └── Slot1 … Slot9       (Container ×9 — 3×3 grid)
│   ├── Hud                     (Container)          ← see Step 4
│   │   ├── ScoreText           (Text Window)
│   │   ├── ComboText           (Text Window)
│   │   ├── LevelText           (Text Window)
│   │   ├── TimerBar            (Image)              ← see Step 4
│   │   └── FeverFlash          (Image)
│   └── CountdownText           (Text Window)
├── Results                     (Container)          ← see Step 5
│   ├── TitleText               (Text Window)
│   ├── VerdictText             (Text Window)
│   ├── MedalText               (Text Window)
│   ├── FinalScoreText          (Text Window)
│   ├── StatsText               (Text Window)
│   ├── CoinsText               (Text Window)
│   ├── BestText                (Text Window)
│   ├── NewBestText             (Text Window)
│   ├── NextButton              (Cursor Event Area) → Label
│   ├── ReplayButton            (Cursor Event Area) → Label
│   └── MenuButton              (Cursor Event Area) → Label
├── PauseMenu                   (Container)          ← see Step 5
│   ├── Overlay                 (Image)
│   └── MenuBox                 (Container)
│       ├── TitleText           (Text Window)
│       ├── ResumeButton        (Cursor Event Area) → Label
│       ├── RestartButton       (Cursor Event Area) → Label
│       └── QuitButton          (Cursor Event Area) → Label
└── DebugText                   (Text Window)        ← optional, see Step 6
```

Notes that matter:

- **Buttons are Cursor Event Areas with a child named `Label`.** `game_flow`
  writes the button text into `Label`; the click handler is registered on the
  Cursor Event Area itself.
- **`PlayArea` is a Cursor Event Area**, not a container, because `director`
  listens for clicks there to detect **misses** (a click that hits no target).
- **Nine slots**, named `Slot1`…`Slot9`, laid out 3×3. Targets are instantiated
  into a random free slot.
- Park `Results` and `PauseMenu` offscreen (they also `SetVisible(false)`
  themselves on start). Never `SetActive(false)` a control that carries a
  script — that stops its lifecycle callbacks.

---

## Step 4 — Attach the view scripts

These three scripts are attached to the control they draw, not to the root:

| Script attached to | Script path              | Role |
|--------------------|--------------------------|------|
| `Hud`              | `minigame/hud`           | score / combo / level text, timer bar, fever flash |
| `Results`          | `minigame/results_panel` | results panel drawing + slide-in |
| `PauseMenu`        | `minigame/pause_menu`    | pause overlay |

`hud` uses `script.object` (the `Hud` control) and looks up `ScoreText`,
`ComboText`, `LevelText`, `TimerBar`, `FeverFlash` underneath it.

- **`TimerBar` must be an Image.** The script writes `TimerBar.imageColor` and
  calls `TimerBar:SetFillHorizontal(LeftToRight, fraction)`, so it needs an
  image/fill component.
- **`FeverFlash` must be an Image**, and should sit above everything else in
  `Hud` (last sibling). The script sets `imageColor` on it for the flash and
  sets `raycastTarget = false` so it never eats target clicks.

If you also want the optional debug overlay, attach `minigame/debug_hud` to
`DebugText` (see Step 6).

---

## Step 5 — Target templates (this is what makes targets spawnable)

Each spawnable target is a **Client Control Template**. `director` instantiates
one by template index, so you need five templates, each a Cursor Event Area with
`minigame/target` attached.

1. Build a control: a **Cursor Event Area** with the visual you want for one
   target kind (an Image child, etc.). Keep the Cursor Event Area itself named
   whatever you like.
2. Open its **Script Mapping** and attach `minigame/target`.
3. On that script, set its Script Variables:
   - `Kind` — `1` normal, `2` silver, `3` golden, `4` bomb, `5` time
   - `PointsMultiplier` — `1` normal, `2` silver, `5` golden (ignored by bomb/time)
4. Save it as a **Client Control Template** and note its index.
5. Repeat for all five kinds.

Then create **one more** template for the score popup: a plain **Text Window**
(named e.g. `PopupTemplate`), no script. Note its index.

---

## Step 6 — Script Variables on `SmashGarden`

Open the Script Mapping for `SmashGarden` and set these. All are optional —
missing ones fall back to safe defaults — but the template indices are required
or no targets will spawn.

**On the `director` script:**

| Variable              | Meaning | Example |
|-----------------------|---------|---------|
| `TemplateNormal`      | template index of the normal target | `1` |
| `TemplateSilver`      | template index of the silver target | `2` |
| `TemplateGolden`      | template index of the golden target | `3` |
| `TemplateBomb`        | template index of the bomb | `4` |
| `TemplateTime`        | template index of the time bonus | `5` |
| `PopupTemplateIndex`  | template index of the score popup Text Window | `6` |
| `HitSfxId`, `MissSfxId`, `BombSfxId`, `TimeSfxId`, `FeverSfxId`, `RoundEndSfxId` | audio clip ids (0 = silent) | `0` |

**On the `game_flow` script:**

| Variable      | Meaning | Example |
|---------------|---------|---------|
| `ClickSfxId`  | audio clip id for UI clicks (0 = silent) | `0` |

**On the `debug_hud` script (only if you attached it):**

| Variable  | Meaning | Example |
|-----------|---------|---------|
| `Enabled` | `1` shows the debug line, `0` hides it | `0` |

---

## Step 7 — Text Mapping (optional — the game speaks English without it)

Every visible string is looked up through `game.GetText`, and `helpers.Text`
detects an unmapped key (`GetText` returns the ID itself) and substitutes a
built-in English default. So **you can skip this step and the game still reads
correctly**. Add entries only to localize or to reword.

Create Script Text Variables with these IDs (the English default is the value
the game ships with):

| Text Mapping ID | Default |
|---|---|
| `minigame.title` | SMASH GARDEN |
| `minigame.subtitle` | Whack your way to a perfect harvest! |
| `minigame.press_start` | Press Start |
| `minigame.play` | Play |
| `minigame.shop` | Garden Shop |
| `minigame.stats_title` | Garden Records |
| `minigame.back` | Back |
| `minigame.level_select` | Choose a Patch |
| `minigame.level_locked` | Locked |
| `minigame.level.name.1` … `.12` | level names |
| `minigame.score` | Score: %d |
| `minigame.combo` | Combo: %d |
| `minigame.best` | Best: %d |
| `minigame.final_score` | Final Score: %d |
| `minigame.stats` | Hits: %d  Misses: %d  Best Combo: %d |
| `minigame.hud_level` | Level %d — Target %d |
| `minigame.countdown` | %d |
| `minigame.go` | GO! |
| `minigame.fever` | FEVER! |
| `minigame.bomb` | -15 |
| `minigame.time_bonus` | +3s |
| `minigame.coins` | Coins: %d |
| `minigame.shop.time_name` / `_desc` | Longer Rounds / +2s per round |
| `minigame.shop.gold_name` / `_desc` | Golden Touch / +1 golden target value |
| `minigame.shop.combo_name` / `_desc` | Combo Master / Fever starts 1 combo earlier |
| `minigame.shop.tier` | Lv %d/%d |
| `minigame.shop.max` | MAX |
| `minigame.shop.price` | %d |
| `minigame.stats.cleared` | Patches cleared: %d/%d |
| `minigame.stats.rounds` | Rounds played: %d |
| `minigame.stats.smashes` | Total smashes: %d |
| `minigame.stats.best` | Best score: %d |
| `minigame.results_title` | Harvest Report |
| `minigame.complete` | Patch cleared! |
| `minigame.failed` | Target missed — try again! |
| `minigame.coins_earned` | +%d coins |
| `minigame.new_best` | NEW BEST! |
| `minigame.next` / `minigame.replay` / `minigame.menu` | Next / Replay / Menu |
| `minigame.paused` | Paused |
| `minigame.pause.resume` / `.restart` / `.quit` | Resume / Restart / Quit |

---

## Step 8 — Custom Variables (persistence)

The client **cannot write** Custom Variables, so `wallet` reads them at boot and
mirrors its state out as Server Signals. Create these as Custom Variables on the
player (or stage) entity, then wire the writes in a Server Node Graph:

| Variable | Meaning |
|---|---|
| `SmashCoins` | coin balance |
| `SmashUnlocked` | highest unlocked level (1–12) |
| `BestScore` | best score |
| `SmashPlays` | rounds played |
| `SmashSmashes` | total hits |
| `SmashUpgTime` | time upgrade tier (0–3) |
| `SmashUpgGold` | golden upgrade tier (0–3) |
| `SmashUpgCombo` | fever upgrade tier (0–3) |

Signals the client sends that the graph should handle:

| Signal | Params | When |
|---|---|---|
| `RoundComplete` | score, stars, hits, coins, level | a round ends |
| `SubmitHighScore` | score | new personal best |
| `Purchase` | itemId, newTier | an upgrade is bought |
| `SubmitWallet` | coins, unlocked, best, plays, smashes, upgTime, upgGold, upgCombo | wallet changed |

Signals the client listens for (send these from the graph):

| Signal | Params | Effect |
|---|---|---|
| `StartLevel` | levelId | starts that level, bypassing unlock locks |
| `AbortRound` | — | aborts the current round |

If you skip this step entirely, everything still works — coins and unlocks just
live for the session only.

---

## Step 9 — First smoke test

1. Start **test play** from the editor.
2. Expected: the title screen appears, `StartButton` is focused.
3. Press **F** (or controller Confirm, or click) → main menu.
4. **Play** → level select. **Tab** walks back / pauses.
5. Pick level 1 → a 3-2-1 countdown → targets start popping in the 3×3 grid.
6. Click a target → score and combo update; miss → combo breaks; a bomb costs
   15 points; a time target adds 3s.
7. Let the round end → results panel slides in with stars and coin earnings.

If something is blank or missing, check the console: the scripts `printerr` the
exact control name or template index they could not find, e.g.
`[flow] missing control: PlayButton`. Fix the name in the tree and re-test.

### Fast debug loop

- On the `director` script you can call (from the script console / a test
  harness): `OverrideKind(code)` to force the next spawns to one kind, and
  `DebugSpawn()` to force an immediate spawn.
- Run `game.PrintClientUITree()` at any time to dump the live control hierarchy
  and compare it against the tree in Step 3.
- `director` also exposes `OverrideKind` / `DebugSpawn` unconditionally, so they
  are safe to leave in a shipped stage; they only act when called.

---

## What the editor still can't automate

For the record — these have **no runtime API** in MiliLua v7.1, which is why
this file exists:

- Attaching a script to a control (`Script` only has `GetParam`, `Invoke`,
  `EnableUpdate`, …).
- Registering Text Mapping keys or Custom Variables from the client.
- Creating root-level containers, or creating controls without a template.

Controls *can* be created at runtime with
`game.InstantiateClientUIControl(templateIndex, parent)` and *renamed*
(`control.name` is Read/Write) — but a created control has no scripts of its
own and cannot be given any, so runtime-built UI can only ever be inert
decoration. Every interactive control is built here, by hand, once.

---

## Verification

The Lua is test-covered by a pure-Lua fake runtime:

```sh
lua5.4 test/run_test.lua          # 314 assertions across P0–P13
SEED=7 lua5.4 test/run_test.lua   # any seed; all deterministic
```

The harness models the engine, not the real client, so the first in-editor run
may still need a spot-check of enums, `SetVisible` timing, or signal ordering —
but the logic, scoring, economy, and screen routing are verified independently
of the editor.
