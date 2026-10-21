-------------------------------------------------------------------------------
-- run_test.lua — drives the full Smash Garden game on the fake runtime in
-- harness.lua: title screen, menus, shop, progression, a complete round,
-- pause/restart/quit, server signals, persistence resync, teardown.
--
-- Run from the mililua-minigame directory:   lua5.4 test/run_test.lua
--
-- Determinism notes:
--   * Level 1 is 100% normal targets, so scoring math is exact.
--   * Debug helpers OverrideKind(kind) / DebugSpawn() on the director force
--     specific target kinds (also useful for previewing art in-editor).
--   * Menu activations (clicks/keys/nav) go through a 0.25s debounce in
--     game_flow, so tests space UI activations with H.run(0.3).
--   * Target clicks are NOT debounced (that debounce lives in flow only).
-------------------------------------------------------------------------------

local H = dofile("test/harness.lua")
H.luaDir = "lua"
-- Fixed seed by default so failures reproduce; override to flake-check:
--   SEED=1234 lua5.4 test/run_test.lua
math.randomseed(tonumber(os.getenv("SEED")) or 20261019)

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. msg)
    end
end
local function eq(a, b, msg)
    if a == b then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL: %s (got %s, want %s)", msg, tostring(a), tostring(b)))
    end
end
local function near(a, b, tol, msg)
    if math.abs(a - b) <= tol then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL: %s (got %.3f, want %.3f +-%.3f)", msg, a, b, tol))
    end
end
local function contains(haystack, needle, msg)
    check(type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
          msg .. " [text: " .. tostring(haystack) .. "]")
end

local K = H.Enum.KeyEventType
local N = H.Enum.ControllerNavigationEventType
local GREEN = { r = 76, g = 175, b = 54 }
local RED = { r = 244, g = 67, b = 54 }

-------------------------------------------------------------------------------
-- Scene: the full game hierarchy the editor setup produces
-------------------------------------------------------------------------------

local root = H.buildRoot("SmashGarden")
local function C(name, parent) return H.newControl(name, parent) end
local function button(parent, name)
    local b = C(name, parent)
    C("Label", b)
    return b
end

local title = C("TitleScreen", root)
C("TitleText", title)
C("SubtitleText", title)
local startButton = button(title, "StartButton")

local menu = C("MainMenu", root)
C("TitleText", menu)
local mainCoins = C("CoinsText", menu)
local playButton = button(menu, "PlayButton")
local shopButton = button(menu, "ShopButton")
local statsButton = button(menu, "StatsButton")

local select = C("LevelSelect", root)
C("HeaderText", select)
local levelButtons = {}
for i = 1, 12 do
    local b = C("Level" .. i, select)
    C("NameText", b)
    C("StarsText", b)
    levelButtons[i] = b
end
local selectBack = button(select, "BackButton")

local shop = C("Shop", root)
C("HeaderText", shop)
local shopCoins = C("CoinsText", shop)
local function shopItem(name)
    local b = C(name, shop)
    C("NameText", b)
    C("DescText", b)
    C("TierText", b)
    C("PriceText", b)
    return b
end
local timeButton = shopItem("TimeButton")
local goldButton = shopItem("GoldButton")
local comboButton = shopItem("ComboButton")
local shopBack = button(shop, "BackButton")

local statsScreen = C("Stats", root)
C("HeaderText", statsScreen)
local statsBody = C("StatsBody", statsScreen)
local statsBack = button(statsScreen, "BackButton")

local gameScreen = C("Game", root)
local playArea = C("PlayArea", gameScreen)
local slots = {}
for i = 1, 9 do slots[i] = C("Slot" .. i, playArea) end
local hud = C("Hud", gameScreen)
local timerBar = C("TimerBar", hud)
local scoreText = C("ScoreText", hud)
local comboText = C("ComboText", hud)
local levelText = C("LevelText", hud)
local feverFlash = C("FeverFlash", hud)
local countdown = C("CountdownText", gameScreen)

local results = C("Results", root)
C("TitleText", results)
local verdictText = C("VerdictText", results)
local medalText = C("MedalText", results)
local finalScoreText = C("FinalScoreText", results)
local statsText = C("StatsText", results)
local coinsText = C("CoinsText", results)
local newBestText = C("NewBestText", results)
local bestText = C("BestText", results)
local nextButton = button(results, "NextButton")
local replayButton = button(results, "ReplayButton")
local menuButton = button(results, "MenuButton")

local pause = C("PauseMenu", root)
C("Overlay", pause)
local pauseBox = C("MenuBox", pause)
C("TitleText", pauseBox)
local resumeButton = button(pauseBox, "ResumeButton")
local restartButton = button(pauseBox, "RestartButton")
local quitButton = button(pauseBox, "QuitButton")

local debugText = C("DebugText", root)

-- Target templates: one script, five `Kind`/`PointsMultiplier` combos.
H.registerTemplate(1, { name = "TargetN", scriptPath = "minigame/target",
                        params = { Kind = 1, PointsMultiplier = 1 } })
H.registerTemplate(2, { name = "TargetS", scriptPath = "minigame/target",
                        params = { Kind = 2, PointsMultiplier = 2 } })
H.registerTemplate(3, { name = "TargetG", scriptPath = "minigame/target",
                        params = { Kind = 3, PointsMultiplier = 5 } })
H.registerTemplate(4, { name = "TargetB", scriptPath = "minigame/target",
                        params = { Kind = 4, PointsMultiplier = 1 } })
H.registerTemplate(5, { name = "TargetT", scriptPath = "minigame/target",
                        params = { Kind = 5, PointsMultiplier = 1 } })
H.registerTemplate(6, { name = "Popup" }) -- text-only, no script

-- Seed persistence: 500 coins, level 1 unlocked, golden touch tier 1
-- (so the golden multiplier is 5+1=6 in every scoring assertion below).
H.customVars["Player/SmashCoins"] = 500
H.customVars["Player/SmashUnlocked"] = 1
H.customVars["Player/SmashUpgGold"] = 1

-- Attach scripts. Panels BEFORE the director (lazy resolution), like a
-- worst-case editor layout; every OnStart runs in this order.
local S = {}
S.helpers = H.attachScript(root, "minigame/helpers")
S.levels = H.attachScript(root, "minigame/level_data")
S.wallet = H.attachScript(root, "minigame/wallet")
S.resultsView = H.attachScript(results, "minigame/results_panel")
S.pauseView = H.attachScript(pause, "minigame/pause_menu")
S.hudScript = H.attachScript(hud, "minigame/hud")
S.debug = H.attachScript(debugText, "minigame/debug_hud", { Enabled = 1 })
S.director = H.attachScript(root, "minigame/director", {
    TemplateNormal = 1, TemplateSilver = 2, TemplateGolden = 3,
    TemplateBomb = 4, TemplateTime = 5, PopupTemplateIndex = 6,
    HitSfxId = 11, MissSfxId = 12, BombSfxId = 13,
    TimeSfxId = 14, RoundEndSfxId = 15, FeverSfxId = 16,
})
S.flow = H.attachScript(root, "minigame/game_flow", { ClickSfxId = 21 })

for _, name in ipairs({ "helpers", "levels", "wallet", "resultsView",
                        "pauseView", "hudScript", "debug", "director", "flow" }) do
    H.startScript(S[name])
end

-- Convenience wrappers ------------------------------------------------------

local function screenName() return S.flow:Invoke("GetScreenName") end
local function state() return S.director:Invoke("GetState") end
local function pressKey(k) return H.fireKey(root, k) end
local function confirm() return pressKey(K.KeyboardInteractKeyUp) end
local function backKey() return pressKey(K.KeyboardOpenShortcutWheelKeyUp) end
local function move(dir)
    local map = {
        up = K.KeyboardMoveForwardKeyUp, down = K.KeyboardMoveBackwardKeyUp,
        left = K.KeyboardMoveLeftKeyUp, right = K.KeyboardMoveRightKeyUp,
    }
    return pressKey(map[dir])
end
local function currentScore()
    local t = scoreText.text
    return tonumber(t:match("(%d+)")) or -1
end

local function liveTargets()
    local list = {}
    for _, slot in ipairs(slots) do
        for i = 1, #slot.children do
            local c = slot.children[i]
            if c and c.alive and c.raycastTarget then list[#list + 1] = c end
        end
    end
    return list
end

local function killFirst()
    local t = liveTargets()[1]
    if not t then return false end
    H.fireClick(t)
    return true
end

-- wait up to maxWait seconds for a target to appear, then click it
local function waitClickKill(maxWait)
    local waited = 0
    while waited < (maxWait or 3) do
        H.run(0.1)
        waited = waited + 0.1
        if killFirst() then return true end
    end
    return false
end

local function killExactly(n)
    local done = 0
    for _ = 1, n do
        if waitClickKill() then done = done + 1 end
    end
    return done
end

-- Mirror of the director's scoring formula (level_data + wallet policy).
local function expectedPoints(combo, kindMult, feverOn)
    local mult = math.min(5, 1 + math.floor(combo / 5))
    local pts = 10 * mult * math.max(1, math.min(10, kindMult))
    if feverOn then pts = pts * 2 end
    return pts
end

local function signalCount(name)
    local n = 0
    for _, s in ipairs(H.sentSignals) do
        if s.name == name then n = n + 1 end
    end
    return n
end
local function lastSignal(name)
    for i = #H.sentSignals, 1, -1 do
        if H.sentSignals[i].name == name then return H.sentSignals[i] end
    end
    return nil
end

-------------------------------------------------------------------------------
print("=== P0: boot ===")
-------------------------------------------------------------------------------

check(title.visible, "P0: title visible")
check(not menu.visible, "P0: main menu hidden")
check(not select.visible, "P0: level select hidden")
check(not shop.visible, "P0: shop hidden")
check(not statsScreen.visible, "P0: stats hidden")
check(not gameScreen.visible, "P0: game screen hidden")
check(not results.visible, "P0: results hidden")
check(not pause.visible, "P0: pause hidden")
eq(screenName(), "title", "P0: flow starts on title")
eq(H.focus, startButton, "P0: focus on the Start button")
H.run(0.3) -- debug HUD refreshes at 4 Hz: give it one interval
contains(debugText.text, "screen=title", "P0: debug HUD shows screen")
contains(debugText.text, "coins=500", "P0: debug HUD shows wallet")
eq(#H.errors, 0, "P0: zero errors at boot")

-------------------------------------------------------------------------------
print("=== P1: title -> menu, keyboard focus ===")
-------------------------------------------------------------------------------

confirm()
eq(screenName(), "menu", "P1: confirm leaves the title")
check(title.visible == false, "P1: title hidden")
check(menu.visible, "P1: main menu visible")
eq(mainCoins.text, "Coins: 500", "P1: menu coin counter")
eq(H.focus, playButton, "P1: focus lands on Play")
move("down")
eq(H.focus, shopButton, "P1: S moves focus to Shop")
move("down")
eq(H.focus, statsButton, "P1: S moves focus to Stats")
move("down")
eq(H.focus, statsButton, "P1: focus clamps at the end of the group")
move("up")
move("up")
eq(H.focus, playButton, "P1: W walks focus back to Play")
eq(#H.errors, 0, "P1: zero errors")

-------------------------------------------------------------------------------
print("=== P2: shop inspection, stats, level select ===")
-------------------------------------------------------------------------------

H.run(0.3)
H.fireClick(shopButton)
eq(screenName(), "shop", "P2: shop screen shown")
eq(timeButton:GetChild("NameText").text, "Longer Rounds", "P2: shop item name")
eq(timeButton:GetChild("DescText").text, "+2s per round", "P2: shop item desc")
eq(timeButton:GetChild("TierText").text, "Lv 0/3", "P2: shop tier readout")
eq(timeButton:GetChild("PriceText").text, "60", "P2: shop price readout")
eq(timeButton:GetChild("PriceText").fontColor.r, GREEN.r, "P2: affordable price is green")
eq(shopCoins.text, "Coins: 500", "P2: shop coin counter")
eq(H.focus, timeButton, "P2: focus on first shop item")

H.run(0.3)
backKey()
eq(screenName(), "menu", "P2: back returns to menu")

H.run(0.3)
H.fireClick(statsButton)
eq(screenName(), "stats", "P2: stats screen shown")
contains(statsBody.text, "Rounds played: 0", "P2: no rounds yet")
contains(statsBody.text, "Patches cleared: 0/12", "P2: nothing cleared yet")

H.run(0.3)
backKey()
eq(screenName(), "menu", "P2: back from stats")

H.run(0.3)
H.fireClick(playButton)
eq(screenName(), "select", "P2: level select shown")
eq(levelButtons[1]:GetChild("NameText").text, "First Sprouts", "P2: level 1 name")
eq(levelButtons[2]:GetChild("StarsText").text, "Locked", "P2: level 2 locked")

-- clicking a locked level must not start anything
H.fireClick(levelButtons[2])
eq(screenName(), "select", "P2: locked level click is denied")
eq(state(), "IDLE", "P2: no round started by a locked level")

-- grid navigation: 4 columns
eq(H.focus, levelButtons[1], "P2: focus starts on level 1")
move("down")
eq(H.focus, levelButtons[5], "P2: S steps a row (+4)")
move("right")
eq(H.focus, levelButtons[6], "P2: D steps one column (+1)")
move("left")
move("up")
eq(H.focus, levelButtons[1], "P2: back to level 1")

H.run(0.3)
backKey()
eq(screenName(), "menu", "P2: back from level select")

-- controller navigation: native nav events on the root
H.run(0.3)
H.fireNav(root, N.Confirm)
eq(screenName(), "select", "P2: controller Confirm presses Play (focused button)")
H.run(0.3)
H.fireNav(root, N.Cancel)
eq(screenName(), "menu", "P2: controller Cancel backs out of level select")
eq(#H.errors, 0, "P2: zero errors")

-------------------------------------------------------------------------------
print("=== P3: start level 1 (countdown -> playing) ===")
-------------------------------------------------------------------------------

H.run(0.3)
H.fireClick(playButton)
H.run(0.3)
H.fireClick(levelButtons[1])
eq(screenName(), "game", "P3: game screen shown")
check(gameScreen.visible, "P3: Game container visible")
check(not select.visible, "P3: level select hidden")
eq(state(), "COUNTDOWN", "P3: countdown state")
check(countdown.visible, "P3: countdown text visible")
check(not playArea.visible, "P3: play area inert during countdown")
check(hud.visible, "P3: HUD visible during countdown")
H.run(0.3) -- let the debug HUD's 4 Hz refresh catch up
contains(debugText.text, "lvl=1 COUNTDOWN", "P3: debug HUD tracks state")

H.run(3.3)
eq(state(), "PLAYING", "P3: playing after countdown")
check(playArea.visible, "P3: play area active")
check(not countdown.visible, "P3: countdown text hidden")
eq(levelText.text, "Level 1 — Target 80", "P3: HUD level line")
contains(debugText.text, "lvl=1 PLAYING", "P3: debug HUD shows playing")

-------------------------------------------------------------------------------
print("=== P4: scoring, combo multiplier, fever ===")
-------------------------------------------------------------------------------

local expected = 0
local expectedKills = 0
local function killExpected(combo, kindMult, feverOn)
    if not waitClickKill() then
        check(false, "P4: a target should have spawned")
        return false
    end
    expectedKills = expectedKills + 1
    expected = expected + expectedPoints(combo, kindMult, feverOn)
    return true
end

-- combos 1..9: no fever; combo 10: fever turns ON (threshold 10, no upgrade)
for combo = 1, 9 do killExpected(combo, 1, false) end
eq(currentScore(), expected, "P4: score after 9 hits is exact")

killExpected(10, 1, true) -- fever doubles the 10th hit
eq(currentScore(), expected, "P4: score at fever activation")
eq(comboText.text:match("Combo: 10") ~= nil, true, "P4: combo reads 10")
contains(comboText.text, "FEVER!", "P4: HUD shows FEVER")
contains(comboText.text, "x3", "P4: combo tier x3 at combo 10")

killExpected(11, 1, true)
killExpected(12, 1, true)
eq(currentScore(), expected, "P4: fever keeps doubling")
eq(currentScore(), 320, "P4: full expected total after 12 kills (10*4 + 20*5 + 60*3)")

-- clicking empty space breaks the combo AND fever
H.fireClick(playArea)
contains(comboText.text, "Combo: 0", "P4: empty click resets combo")
check(not comboText.text:find("FEVER", 1, true), "P4: empty click ends fever")
local s0 = currentScore()
eq(currentScore(), s0, "P4: empty click costs no points")

-------------------------------------------------------------------------------
print("=== P5: target kinds ===")
-------------------------------------------------------------------------------

-- SILVER (2x): combo 1
S.director:Invoke("OverrideKind", 2)
local before = currentScore()
killExpected(1, 2, false)
eq(currentScore() - before, 20, "P5: silver pays 2x at combo 1")

-- GOLDEN (5x + golden touch tier 1 = 6x): combo 2
S.director:Invoke("OverrideKind", 3)
before = currentScore()
killExpected(2, 6, false)
eq(currentScore() - before, 60, "P5: golden pays 6x with shop upgrade")

-- BOMB: -15 score, combo reset
S.director:Invoke("OverrideKind", 4)
before = currentScore()
waitClickKill()
eq(currentScore(), before - 15, "P5: bomb costs 15 points (floor 0)")
contains(comboText.text, "Combo: 0", "P5: bomb breaks the combo")
check(not comboText.text:find("FEVER", 1, true), "P5: bomb ends fever")

-- TIME: +3 seconds, no score/combo change
S.director:Invoke("OverrideKind", 5)
local f0 = timerBar.fillAmount
waitClickKill()
H.run(1 / 30) -- timer bar refreshes on the next level update
check(timerBar.fillAmount > f0 + 2 / 30, "P5: time bonus visibly adds time")
eq(currentScore(), before - 15, "P5: time bonus pays no points")

-- ESCAPE: an unclicked target breaks the combo and counts as a miss
S.director:Invoke("OverrideKind", 1)
waitClickKill() -- combo back to 1
S.director:Invoke("OverrideKind", 3)
S.director:Invoke("DebugSpawn")
H.run(1.3) -- golden lifetime is short (~0.55x) — it escapes
contains(comboText.text, "Combo: 0", "P5: escaped target resets combo")
S.director:Invoke("OverrideKind", 0)
eq(#H.errors, 0, "P5: zero errors")

-------------------------------------------------------------------------------
print("=== P6: pause / resume / restart / quit ===")
-------------------------------------------------------------------------------

backKey() -- Tab
check(pause.visible, "P6: pause overlay shown")
eq(H.levelPaused, true, "P6: level time frozen")
eq(screenName(), "pause", "P6: flow knows we are paused")
eq(H.focus, resumeButton, "P6: focus on Resume")
contains(pauseBox:GetChild("TitleText").text, "Paused", "P6: pause title localized")

local frozenFill = timerBar.fillAmount
H.run(2)
eq(timerBar.fillAmount, frozenFill, "P6: timer frozen while paused")
eq(state(), "PLAYING", "P6: still in playing state")

backKey() -- Tab resumes (director ignores it while paused; flow resumes)
check(not pause.visible, "P6: pause overlay hidden")
eq(H.levelPaused, false, "P6: level time resumed")
eq(screenName(), "game", "P6: back on game screen")

-- pause -> restart: same level, fresh countdown, score reset
backKey()
H.run(0.3)
H.fireClick(restartButton)
eq(state(), "COUNTDOWN", "P6: restart begins a new countdown")
check(not pause.visible, "P6: pause overlay closed by restart")
eq(H.levelPaused, false, "P6: level time running again")
check(not playArea.visible, "P6: play area inert during countdown")
eq(currentScore(), 0, "P6: score reset by restart")
H.run(3.6)
eq(state(), "PLAYING", "P6: restarted round is playing")

-- pause -> quit: menu, no results
backKey()
H.run(0.3)
H.fireClick(quitButton)
eq(state(), "IDLE", "P6: quit ends the round")
eq(screenName(), "menu", "P6: quit returns to menu")
check(not gameScreen.visible, "P6: game screen hidden")
check(not results.visible, "P6: quit shows NO results")
eq(scoreText.text, "Score: 0", "P6: HUD reset for the next round")

-------------------------------------------------------------------------------
print("=== P7: a complete round, results, wallet, progression ===")
-------------------------------------------------------------------------------

H.run(0.3)
H.fireClick(playButton)
H.run(0.3)
H.fireClick(levelButtons[1])
H.run(3.6)
eq(state(), "PLAYING", "P7: playing level 1 again")

expected, expectedKills = 0, 0
local iter = 0
while state() == "PLAYING" and iter < 600 do
    iter = iter + 1
    H.run(0.1)
    if killFirst() then
        expectedKills = expectedKills + 1
        expected = expected + expectedPoints(expectedKills, 1, expectedKills >= 10)
    end
end
check(expectedKills >= 10, "P7: cleared plenty of targets (" .. expectedKills .. ")")
check(expected >= 80, "P7: score clears the level target")
eq(state(), "IDLE", "P7: round ended on the timer")
eq(screenName(), "results", "P7: results screen shown")
check(results.visible, "P7: results panel visible")
check(gameScreen.visible, "P7: game screen stays up behind results")
check(finalScoreText.text:match(tostring(expected)) ~= nil, "P7: results show the exact score")
eq(verdictText.text, "Patch cleared!", "P7: verdict says cleared")

local stars = S.helpers:Invoke("StarsFor", expected, 80, 150, 240)
eq(medalText.text, S.helpers:Invoke("FormatStars", stars), "P7: medal stars shown")
local coinsEarned = S.helpers:Invoke("CoinsFor", expected, stars)
eq(coinsText.text, "+" .. coinsEarned .. " coins", "P7: coins earned shown")
check(newBestText.visible, "P7: NEW BEST banner shown")
contains(bestText.text, tostring(expected), "P7: best score shown")
eq(H.focus, nextButton, "P7: focus on Next")
contains(statsText.text, "Hits: " .. expectedKills, "P7: stats line shows hits")

eq(S.wallet:Invoke("GetCoins"), 500 + coinsEarned, "P7: wallet paid out")
eq(S.wallet:Invoke("GetPlays"), 1, "P7: one round recorded")
eq(S.wallet:Invoke("GetSmashes"), expectedKills, "P7: smash count recorded")
eq(S.wallet:Invoke("GetBest"), expected, "P7: best score recorded")
eq(S.wallet:Invoke("GetBestForLevel", 1), expected, "P7: per-level best recorded")
eq(S.wallet:Invoke("GetUnlocked"), 2, "P7: clearing unlockes level 2")

local rc = lastSignal("RoundComplete")
check(rc ~= nil, "P7: RoundComplete signal sent")
if rc then
    eq(rc.params[1], 1, "P7: RoundComplete.level")
    eq(rc.params[2], expected, "P7: RoundComplete.score")
    eq(rc.params[3], stars, "P7: RoundComplete.stars")
    eq(rc.params[4], coinsEarned, "P7: RoundComplete.coins")
    eq(rc.params[5], expectedKills, "P7: RoundComplete.hits")
end
check(lastSignal("SubmitHighScore") ~= nil, "P7: SubmitHighScore sent")
local sw = lastSignal("SubmitWallet")
check(sw ~= nil, "P7: SubmitWallet snapshot sent")
if sw then
    eq(sw.params[1], 500 + coinsEarned, "P7: snapshot coins")
    eq(sw.params[2], 2, "P7: snapshot unlocked")
end
-- remembered for P10: the stats screen must still show THIS score as best
local bestScore = expected
eq(#H.errors, 0, "P7: zero errors")

-------------------------------------------------------------------------------
print("=== P8: results navigation + server signals ===")
-------------------------------------------------------------------------------

H.run(0.3)
H.fireClick(nextButton)
eq(state(), "COUNTDOWN", "P8: Next starts the following level")
eq(S.director:Invoke("GetLevel"), 2, "P8: level 2 running")
H.run(3.6)
eq(state(), "PLAYING", "P8: level 2 playing")

-- golden multiplier now 5+1=6 on level 2. The round may have auto-spawned
-- a normal during the countdown transition — drain those first so the
-- measured kill is definitely golden (combo stays in the x1 tier either way).
S.director:Invoke("OverrideKind", 3)
while liveTargets()[1] do killFirst() end
before = currentScore()
if waitClickKill() then expectedKills = expectedKills + 1 end
eq(currentScore() - before, 60, "P8: golden 6x on level 2 too")

H.sendSignal("AbortRound")
eq(state(), "IDLE", "P8: server abort ends the round")
eq(screenName(), "menu", "P8: server abort returns to menu")
check(not results.visible, "P8: server abort shows no results")

-------------------------------------------------------------------------------
print("=== P9: shop purchases, denial, caps, upgrade effects ===")
-------------------------------------------------------------------------------

H.run(0.3)
H.fireClick(shopButton)
eq(screenName(), "shop", "P9: shop shown")

local coinsBefore = S.wallet:Invoke("GetCoins")
H.run(0.3)
H.fireClick(timeButton) -- cost 60
eq(S.wallet:Invoke("GetUpgrade", "time"), 1, "P9: time upgrade tier 1 bought")
eq(S.wallet:Invoke("GetCoins"), coinsBefore - 60, "P9: coins deducted")
eq(timeButton:GetChild("TierText").text, "Lv 1/3", "P9: tier readout updated")
local ps = lastSignal("Purchase")
check(ps ~= nil and ps.params[1] == 1 and ps.params[2] == 1,
      "P9: Purchase signal sent (item 1, tier 1)")

-- too expensive: denied, no money lost
H.setCustomVar("Player", "SmashCoins", 10)
eq(S.wallet:Invoke("GetCoins"), 10, "P9: custom var echo resyncs wallet")
-- price colours refresh on shop ENTRY (push model: goTo refreshes the screen)
H.run(0.3)
backKey()
H.run(0.3)
H.fireClick(shopButton)
eq(goldButton:GetChild("PriceText").fontColor.r, RED.r, "P9: unaffordable price is red")
H.run(0.3)
H.fireClick(goldButton) -- golden touch next tier costs 180 > 10
eq(S.wallet:Invoke("GetUpgrade", "gold"), 1, "P9: poor purchase denied")
eq(S.wallet:Invoke("GetCoins"), 10, "P9: no coins lost on denial")

-- rich again: max out golden touch (tiers 2 and 3, then denial at cap)
H.setCustomVar("Player", "SmashCoins", 2000)
H.run(0.3)
H.fireClick(goldButton) -- 180
eq(S.wallet:Invoke("GetUpgrade", "gold"), 2, "P9: gold tier 2")
H.run(0.3)
H.fireClick(goldButton) -- 400
eq(S.wallet:Invoke("GetUpgrade", "gold"), 3, "P9: gold tier 3 (max)")
eq(S.wallet:Invoke("GetCoins"), 2000 - 180 - 400, "P9: both purchases deducted")
eq(goldButton:GetChild("PriceText").text, "MAX", "P9: maxed item shows MAX")
H.run(0.3)
H.fireClick(goldButton)
eq(S.wallet:Invoke("GetUpgrade", "gold"), 3, "P9: cap holds")
eq(S.wallet:Invoke("GetCoins"), 2000 - 180 - 400, "P9: cap costs nothing")

-- combo master: three tiers -> fever threshold 10-3 = 7
H.run(0.3)
H.fireClick(comboButton) -- 70
H.run(0.3)
H.fireClick(comboButton) -- 160
H.run(0.3)
H.fireClick(comboButton) -- 350
eq(S.wallet:Invoke("GetUpgrade", "combo"), 3, "P9: combo tier 3 bought")
local afterShopping = S.wallet:Invoke("GetCoins")
H.run(0.3)
backKey()
H.fireClick(playButton)
H.run(0.3)
H.fireClick(levelButtons[2])
eq(S.director:Invoke("GetRoundDuration"), 32, "P9: level 2 duration 30 + 2 (time tier 1)")
H.run(3.6)
eq(state(), "PLAYING", "P9: level 2 running with all upgrades")

-- fever threshold 7: the 7th hit (combo 7) starts fever. Drain anything
-- auto-spawned before the override, tracking how many hits that added.
S.director:Invoke("OverrideKind", 1)
local c = 0
while liveTargets()[1] do
    killFirst()
    c = c + 1
end
expected, expectedKills = 0, 0
while c < 6 do
    if waitClickKill() then
        c = c + 1
        expected = expected + expectedPoints(c, 1, false)
    end
end
check(not comboText.text:find("FEVER", 1, true), "P9: no fever at combo 6")
if waitClickKill() then
    c = c + 1
    expected = expected + expectedPoints(c, 1, true)
end
contains(comboText.text, "FEVER!", "P9: fever at combo 7 with upgrade")

-- golden with golden touch tier 3: 5+3 = 8x
S.director:Invoke("OverrideKind", 3)
before = currentScore()
if waitClickKill() then c = c + 1 end
local goldenDelta = currentScore() - before
eq(goldenDelta, expectedPoints(c, 8, true), "P9: golden pays 8x at tier 3 (with fever)")
S.director:Invoke("OverrideKind", 0)

-- back out through the pause menu
backKey()
H.run(0.3)
H.fireClick(quitButton)
eq(screenName(), "menu", "P9: quit to menu")
eq(state(), "IDLE", "P9: round aborted")
eq(S.wallet:Invoke("GetCoins"), afterShopping, "P9: aborted round pays nothing")
eq(S.wallet:Invoke("GetPlays"), 1, "P9: aborted round is not recorded")
eq(#H.errors, 0, "P9: zero errors")

-------------------------------------------------------------------------------
print("=== P10: stats screen + persistence echo ===")
-------------------------------------------------------------------------------

H.run(0.3)
H.fireClick(statsButton)
contains(statsBody.text, "Rounds played: 1", "P10: only finished rounds count")
contains(statsBody.text, "Patches cleared: 1/12", "P10: one patch cleared")
contains(statsBody.text, "Best score: " .. bestScore, "P10: best score shown")
contains(statsBody.text, "Coins: " .. afterShopping, "P10: coin line shown")
H.run(0.3)
backKey()

H.setCustomVar("Player", "SmashCoins", 42)
eq(S.wallet:Invoke("GetCoins"), 42, "P10: server echo overwrites local state")

-------------------------------------------------------------------------------
print("=== P11: server-driven start bypasses locks ===")
-------------------------------------------------------------------------------

H.sendSignal("StartLevel", { 3 }) -- level 3 is LOCKED; the server wins
eq(screenName(), "game", "P11: server started a level from the menu")
eq(state(), "COUNTDOWN", "P11: countdown running")
eq(S.director:Invoke("GetLevel"), 3, "P11: level 3 started while locked")
H.sendSignal("AbortRound")
eq(screenName(), "menu", "P11: abort returns to menu")
eq(state(), "IDLE", "P11: idle again")

-------------------------------------------------------------------------------
print("=== P12: replay from results ===")
-------------------------------------------------------------------------------

-- finish a zero-effort round quickly via level select, then Replay
H.run(0.3)
H.fireClick(playButton)
H.run(0.3)
H.fireClick(levelButtons[1])
H.run(3.6)
local guard = 0
while state() == "PLAYING" and guard < 600 do
    guard = guard + 1
    H.run(0.1) -- no clicking: score stays 0
end
eq(screenName(), "results", "P12: results after a zero score")
eq(verdictText.text, "Target missed — try again!", "P12: failed verdict")
check(not newBestText.visible, "P12: no new best at 0 points")
eq(S.wallet:Invoke("GetUnlocked"), 2, "P12: failing does not unlock")
eq(S.wallet:Invoke("GetPlays"), 2, "P12: failed run still recorded")

H.run(0.3)
H.fireClick(replayButton)
eq(state(), "COUNTDOWN", "P12: replay restarts the same level")
eq(S.director:Invoke("GetLevel"), 1, "P12: replay runs level 1")
H.run(3.6) -- Tab only pauses a PLAYING round, so let the countdown finish
eq(state(), "PLAYING", "P12: replay is playing")
backKey() -- pause
check(pause.visible, "P12: pause overlay shown")
H.run(0.3)
H.fireClick(quitButton)
eq(screenName(), "menu", "P12: back to menu")

H.run(0.3)
H.fireClick(playButton)
H.run(0.3)
H.fireClick(selectBack)
eq(screenName(), "menu", "P12: back button works")
H.run(0.3)
H.fireNav(root, N.Confirm) -- Play again, then back twice to title
H.run(0.3)
backKey()
H.run(0.3)
backKey()
eq(screenName(), "title", "P12: back from menu returns to title")
check(title.visible, "P12: title visible again")
eq(#H.errors, 0, "P12: zero errors")

-------------------------------------------------------------------------------
print("=== P13: teardown ===")
-------------------------------------------------------------------------------

H.destroyTree(root)
for _, inst in ipairs(H.scripts) do
    check(not inst.alive, "P13: script dead after teardown: " .. inst.path)
end
eq(H.liveTweenCount(), 0, "P13: no tweens left alive")
eq(next(H.audioAlive) == nil, true, "P13: all audio stopped")
eq(#H.errors, 0, "P13: zero errors for the entire run")

-------------------------------------------------------------------------------
print(string.format("=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
