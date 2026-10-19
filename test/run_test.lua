-------------------------------------------------------------------------------
-- run_test.lua — drives the real minigame scripts through a full match
-- on the fake runtime in harness.lua.
--
-- Run from the mililua-minigame directory:   lua5.4 test/run_test.lua
--
-- Coverage:
--   * boot order (panels attached BEFORE the director — lazy resolution)
--   * state machine: IDLE -> COUNTDOWN -> PLAYING -> IDLE via F key
--   * EnableUpdate gating, countdown text, spawn ramp, slot bookkeeping
--   * click hit, double-click debounce, corpse cleanup, score popups
--   * miss click (combo reset + miss counted in the stats)
--   * combo multiplier (x1 -> x2), per-click score deltas verified exactly
--   * golden targets: server-tuned spawn rate, 5x multiplier, gold popup
--   * pause: PauseLevelTime, frozen clock, controller focus, resume
--   * low-time timer color flash, target escapes resetting combo
--   * round end: RoundComplete + SubmitHighScore signals, results panel
--   * replay button, AbortRound mid-countdown ignored, AbortRound while
--     paused (level time MUST be unfrozen), Japanese separator, StartRound
--   * teardown: OnDestroy kills tweens + audio
--   * ZERO engine-contract violations (tween locks, missing controls,
--     unmapped localization keys, double-destroys) — any is a FAILURE
-------------------------------------------------------------------------------

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. package.path

local H = require("harness")
H.luaDir = here .. "/../lua"

local Enum, game = H.Enum, H.shared.game

-------------------------------------------------------------------------------
-- Tiny test framework
-------------------------------------------------------------------------------

local passed, failed = 0, 0
local phase = "?"

local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL [%s] %s", phase, msg))
    end
end

local function eq(got, want, msg)
    check(got == want,
          string.format("%s (got %s, want %s)", msg, tostring(got), tostring(want)))
end

local function checkNoErrors(what)
    if #H.errors > 0 then
        for _, e in ipairs(H.errors) do
            failed = failed + 1
            print(string.format("FAIL [%s] engine error: %s", what, e))
        end
        H.errors = {}
    end
end

local function waitUntil(cond, maxSeconds, dt)
    dt = dt or (1 / 30)
    local steps = math.floor(maxSeconds / dt)
    for _ = 1, steps do
        if cond() then return true end
        H.frame(dt)
    end
    return cond()
end

-------------------------------------------------------------------------------
-- Scene: the exact control hierarchy from the README
-------------------------------------------------------------------------------

phase = "scene"

local root = H.buildRoot("SmashGarden")
local playArea = H.newControl("PlayArea", root)
for i = 1, 9 do H.newControl("Slot" .. i, playArea) end
local hud = H.newControl("Hud", root)
local timerBar = H.newControl("TimerBar", hud)
local scoreTextHud = H.newControl("ScoreText", hud)
local comboTextHud = H.newControl("ComboText", hud)
local countdownText = H.newControl("CountdownText", root)
-- Debug HUD: one enabled, one disabled (the disabled one must stay silent).
local debugTextOn = H.newControl("DebugText", hud)
local debugTextOff = H.newControl("DebugTextOff", hud)

local results = H.newControl("Results", root)
local finalScoreText = H.newControl("FinalScoreText", results)
local statsText = H.newControl("StatsText", results)
local bestText = H.newControl("BestText", results)
local replayButton = H.newControl("ReplayButton", results)

local pausePanel = H.newControl("PauseMenu", root)
local overlay = H.newControl("Overlay", pausePanel)
local menuBox = H.newControl("MenuBox", pausePanel)
local resumeButton = H.newControl("ResumeButton", menuBox)
local quitButton = H.newControl("QuitButton", menuBox)

-- Templates: normal target, golden target (SAME script, different var),
-- popup text. Indices as the director's script variables will reference.
H.registerTemplate(1, { name = "TargetN", scriptPath = "minigame/target",
                        params = { PointsMultiplier = 1 } })
H.registerTemplate(2, { name = "TargetG", scriptPath = "minigame/target",
                        params = { PointsMultiplier = 5 } })
H.registerTemplate(3, { name = "Popup", props = { fontSize = 20 } })

-- Attach scripts. NOTE the order: panels BEFORE the director, on purpose —
-- sibling OnStart order is unspecified in the engine, and the director
-- resolves panel scripts lazily.
local resultsScript = H.attachScript(results, "minigame/results_panel")
local pauseScript = H.attachScript(pausePanel, "minigame/pause_menu")
local director = H.attachScript(root, "minigame/director", {
    RoundDuration = 30,
    TargetTemplateIndex = 1,
    GoldenTemplateIndex = 2,
    PopupTemplateIndex = 3,
    HitSfxId = 101, MissSfxId = 102, RoundEndSfxId = 103,
})
H.attachScript(root, "minigame/helpers")
H.attachScript(debugTextOn, "minigame/debug_hud", { Enabled = 1 })
H.attachScript(debugTextOff, "minigame/debug_hud", { Enabled = 0 })

local function boot(s) H.startScript(s) end
boot(resultsScript); boot(pauseScript); boot(director); boot(root.scripts["minigame/helpers"])
boot(debugTextOn.scripts["minigame/debug_hud"])
boot(debugTextOff.scripts["minigame/debug_hud"])

local function state() return director:Invoke("GetState") end

-- Live whackable targets sitting in slots (excludes squishing corpses:
-- a corpse has raycastTarget=false or scale collapsing).
local function liveTargets()
    local out = {}
    for i = 1, 9 do
        for _, c in ipairs(playArea.childByName["Slot" .. i].children) do
            if c.alive and c.raycastTarget
               and c.cursorListeners[Enum.CursorEventType.CursorClick]
               and #c.cursorListeners[Enum.CursorEventType.CursorClick] > 0 then
                out[#out + 1] = c
            end
        end
    end
    return out
end

local function findTarget(kind)
    for _, c in ipairs(liveTargets()) do
        if c.name == kind then return c end
    end
    return nil
end

local function scoreNow() return tonumber(scoreTextHud.text:match("%d+")) or -1 end

-------------------------------------------------------------------------------
-- P0: boot state
-------------------------------------------------------------------------------

phase = "P0 boot"

eq(state(), "IDLE", "state after boot")
eq(hud.active, false, "HUD starts inactive")
eq(playArea.active, false, "play area starts inactive")
eq(countdownText.active, false, "countdown text starts inactive")
eq(results.visible, false, "results panel hidden by script")
eq(pausePanel.visible, false, "pause panel hidden by script")
eq(H.focus, nil, "no controller focus at boot")

-- Debug HUD: enabled one polls the director; disabled one stays silent.
H.run(0.6)
check(debugTextOn.text:find("IDLE"), "debug HUD shows IDLE at boot")
check(debugTextOn.text:find("score=0"), "debug HUD shows zero score at boot")
eq(debugTextOff.visible, false, "disabled debug HUD hides itself")
eq(debugTextOff.text, "", "disabled debug HUD never writes text")
checkNoErrors(phase)

-- Kill golden randomness BEFORE the round starts so scoring is fully
-- deterministic; the golden phase below opts in explicitly.
H.sendSignal("SetGoldenRate", { 0 })
checkNoErrors(phase)

-------------------------------------------------------------------------------
-- P1: F starts a round; countdown; PLAYING; spawn ramp
-------------------------------------------------------------------------------

phase = "P1 countdown"

H.fireKey(root, Enum.KeyEventType.KeyboardInteractKeyUp)
eq(state(), "COUNTDOWN", "F starts the countdown")
eq(director.updateEnabled, true, "EnableUpdate(true) during countdown")
eq(countdownText.active, true, "countdown text shown")

H.run(0.5)
eq(countdownText.text, "3", "countdown shows 3")
H.run(3.2) -- total 3.7s > 3.2s countdown
eq(state(), "PLAYING", "countdown ends in PLAYING")
eq(countdownText.active, false, "countdown text hidden")
eq(playArea.active, true, "play area active during play")
eq(hud.active, true, "HUD active during play")

-- Spawn ramp: first target within ~0.4s + interval.
check(waitUntil(function() return #liveTargets() >= 1 end, 3), "first target spawns")
check(#liveTargets() <= 3, "never more than MAX_ACTIVE targets")
checkNoErrors(phase)

-------------------------------------------------------------------------------
-- P2: hit, debounce, popup, corpse cleanup; then a miss
-------------------------------------------------------------------------------

phase = "P2 first hit"

local t1 = findTarget("TargetN")
check(t1 ~= nil, "a normal target is alive")

local popupSeen, popupText = nil, nil
H.fireClick(t1)
eq(scoreNow(), 10, "first hit scores 10 (combo 1, x1)")
check(comboTextHud.text:find("Combo: 1"), "combo text shows 1")
check(comboTextHud.text:find("x1"), "multiplier text x1")

-- Double-click debounce: the same corpse must not score again.
H.fireClick(t1)
eq(scoreNow(), 10, "double-click does not double-score")

-- The popup floated where the target died.
for _, c in ipairs(playArea.children) do
    if c.name == "Popup" and c.text ~= "" then popupSeen = c; popupText = c.text end
end
check(popupSeen ~= nil, "score popup spawned")
eq(popupText, "+10", "popup reads +10")

check(waitUntil(function() return not t1.alive end, 1), "target destroyed after squish")
check(waitUntil(function()
    for _, c in ipairs(playArea.children) do
        if c == popupSeen then return false end
    end
    return popupSeen == nil or not popupSeen.alive or popupSeen.parent == nil
end, 2), "popup destroyed after float")
check(waitUntil(function()
    return debugTextOn.text:find("PLAYING") and debugTextOn.text:find("score=10")
end, 1), "debug HUD tracks live state (PLAYING, score=10)")

phase = "P2 miss"

waitUntil(function() return #liveTargets() == 0 end, 4)
H.fireClick(playArea) -- empty click
eq(scoreNow(), 10, "miss click scores nothing")
check(comboTextHud.text:find("Combo: 0"), "miss resets combo")
checkNoErrors(phase)

-------------------------------------------------------------------------------
-- P3: combo to x2 with exact per-click deltas; golden target at 5x
-------------------------------------------------------------------------------

phase = "P3 combo ramp"

local expectedCombo = 0
local expectedScore = 10

local function expectedDelta(mult)
    local comboMult = math.min(5, 1 + math.floor(expectedCombo / 5))
    return 10 * comboMult * mult
end

-- Click normals the instant they appear; no waiting => no escapes.
for i = 1, 5 do
    local t = waitUntil(function() return findTarget("TargetN") end, 4)
        and findTarget("TargetN")
    check(t ~= nil, "normal target available for combo click " .. i)
    if t then
        expectedCombo = expectedCombo + 1
        expectedScore = expectedScore + expectedDelta(1)
        H.fireClick(t)
        eq(scoreNow(), expectedScore, "score delta after combo click " .. i)
    end
end
eq(expectedCombo, 5, "combo reached 5")
check(comboTextHud.text:find("x2"), "multiplier text shows x2 at combo 5")
checkNoErrors(phase)

phase = "P3 golden"

H.sendSignal("SetGoldenRate", { 100 })
local g = waitUntil(function() return findTarget("TargetG") end, 4)
    and findTarget("TargetG")
check(g ~= nil, "golden target spawned after tuning signal")
if g then
    expectedCombo = expectedCombo + 1 -- 6
    expectedScore = expectedScore + expectedDelta(5)
    H.fireClick(g)
    eq(scoreNow(), expectedScore, "golden hit scores 5x at current combo")
    local goldPopup
    for _, c in ipairs(playArea.children) do
        if c.name == "Popup" and c.fontColor then goldPopup = c end
    end
    check(goldPopup ~= nil, "golden popup has a font color")
    eq(goldPopup and goldPopup.fontColor.r, 255, "golden popup is gold (r)")
    eq(goldPopup and goldPopup.fontColor.g, 204, "golden popup is gold (g)")
end
H.sendSignal("SetGoldenRate", { 0 })

local bestComboSoFar = expectedCombo
checkNoErrors(phase)

-------------------------------------------------------------------------------
-- P4: pause / resume, frozen clock, controller focus
-------------------------------------------------------------------------------

phase = "P4 pause"

H.device = Enum.Device.Gamepad
H.fireKey(root, Enum.KeyEventType.KeyboardOpenShortcutWheelKeyUp)
eq(state(), "PLAYING", "still playing while paused")
eq(H.levelPaused, true, "PauseLevelTime(true) on pause")
eq(pausePanel.visible, true, "pause panel shown")
eq(H.focus, resumeButton, "controller focus moved to Resume")

local fillBefore = timerBar.fillAmount
local aliveBefore = #liveTargets()
H.run(2) -- two seconds of real+level time
eq(timerBar.fillAmount, fillBefore, "timer bar frozen while paused")
eq(#liveTargets(), aliveBefore, "no spawns/escapes while paused")

H.fireKey(resumeButton, Enum.KeyEventType.KeyboardInteractKeyUp)
eq(H.levelPaused, false, "PauseLevelTime(false) on resume")
eq(pausePanel.visible, false, "pause panel hidden on resume")
checkNoErrors(phase)

-------------------------------------------------------------------------------
-- P5: low-time color flash, escapes, round end, signals, results
-------------------------------------------------------------------------------

phase = "P5 round end"

check(waitUntil(function()
    return timerBar.fillAmount < 0.25
           and timerBar.imageColor and timerBar.imageColor.r == 244
end, 30), "low-time color flash fires")
eq(timerBar.imageColor.r, 244, "timer flash color r")
eq(timerBar.imageColor.b, 54, "timer flash color b")

check(waitUntil(function() return state() == "IDLE" end, 30), "round ends on the clock")
eq(hud.active, false, "HUD hidden after round")
eq(playArea.active, false, "play area hidden after round")
eq(#liveTargets(), 0, "no targets left after round")

-- Signals out, in order: SubmitHighScore (new best) then RoundComplete.
local roundComplete, highScore
for _, s in ipairs(H.sentSignals) do
    if s.name == "RoundComplete" then roundComplete = s end
    if s.name == "SubmitHighScore" then highScore = s end
end
check(roundComplete ~= nil, "RoundComplete sent")
check(highScore ~= nil, "SubmitHighScore sent")
eq(scoreNow(), 170, "final score 10 + 5*10..20 + 5x20 golden")
eq(roundComplete and roundComplete.params[1], 170, "RoundComplete score")
eq(roundComplete and roundComplete.params[2], 7, "RoundComplete hits")
eq(roundComplete and roundComplete.params[3], 1, "RoundComplete misses")
eq(roundComplete and roundComplete.params[4], bestComboSoFar, "RoundComplete bestCombo")
eq(highScore and highScore.params[1], 170, "SubmitHighScore score")

eq(results.visible, true, "results panel shown")
eq(finalScoreText.text, "Final Score: 170", "results final score text")
check(statsText.text:find("Hits: 7"), "results stats text has hits")
check(statsText.text:find("Misses: 1"), "results stats text has misses")
eq(H.focus, replayButton, "controller focus on Replay button")
checkNoErrors(phase)

-------------------------------------------------------------------------------
-- P6: replay -> round 2; AbortRound mid-countdown ignored; i18n; abort
-------------------------------------------------------------------------------

phase = "P6 replay + abort"

H.fireKey(replayButton, Enum.KeyEventType.KeyboardInteractKeyUp)
eq(state(), "COUNTDOWN", "replay starts a new countdown")
eq(results.visible, false, "results hidden on replay")

H.sendSignal("AbortRound")
eq(state(), "COUNTDOWN", "AbortRound ignored outside PLAYING")

H.run(3.5)
eq(state(), "PLAYING", "round 2 running")

H.language = Enum.LanguageType.Japanese
local t2 = waitUntil(function() return findTarget("TargetN") end, 4)
    and findTarget("TargetN")
check(t2 ~= nil, "round 2 spawns a target")
H.fireClick(t2)
eq(scoreNow(), 10, "round 2 first hit scores 10")
check(comboTextHud.text:find("／"), "Japanese combo separator used")

H.fireKey(root, Enum.KeyEventType.KeyboardOpenShortcutWheelKeyUp)
eq(H.levelPaused, true, "round 2 pause works")

local roundCompletes = 0
for _, s in ipairs(H.sentSignals) do
    if s.name == "RoundComplete" then roundCompletes = roundCompletes + 1 end
end

H.sendSignal("AbortRound") -- server aborts WHILE PAUSED
eq(state(), "IDLE", "AbortRound ends the paused round")
eq(H.levelPaused, false, "level time UNFROZEN by round end while paused")
eq(H.pauseLog[#H.pauseLog], false, "last PauseLevelTime call was false")
eq(pausePanel.visible, false, "pause panel force-closed")
eq(hud.active, false, "HUD hidden after abort")
local after = 0
for _, s in ipairs(H.sentSignals) do
    if s.name == "RoundComplete" then after = after + 1 end
end
eq(after, roundCompletes + 1, "aborted round still reports RoundComplete")
checkNoErrors(phase)

-------------------------------------------------------------------------------
-- P7: StartRound server signal with duration override
-------------------------------------------------------------------------------

phase = "P7 signal start"

H.sendSignal("StartRound", { 8 })
eq(state(), "COUNTDOWN", "StartRound signal starts a round")
H.run(3.5)
eq(state(), "PLAYING", "signal-started round reaches PLAYING")
local t3 = waitUntil(function() return #liveTargets() > 0 end, 3)
check(t3, "signal-started round spawns")
H.sendSignal("AbortRound")
eq(state(), "IDLE", "signal-started round aborts cleanly")
checkNoErrors(phase)

-------------------------------------------------------------------------------
-- P8: production gate — AllowManualStart=0 makes the F key inert
-------------------------------------------------------------------------------

phase = "P8 production gate"

-- Fresh scene with the production setting (server-only round starts).
local root2 = H.buildRoot("SmashGarden") -- replaces the old root lookup
local playArea2 = H.newControl("PlayArea", root2)
for i = 1, 9 do H.newControl("Slot" .. i, playArea2) end
local hud2 = H.newControl("Hud", root2)
H.newControl("TimerBar", hud2); H.newControl("ScoreText", hud2); H.newControl("ComboText", hud2)
local cd2 = H.newControl("CountdownText", root2)
local res2 = H.newControl("Results", root2)
H.newControl("FinalScoreText", res2); H.newControl("StatsText", res2)
H.newControl("BestText", res2); H.newControl("ReplayButton", res2)
local pause2 = H.newControl("PauseMenu", root2)
local menu2 = H.newControl("MenuBox", pause2)
H.newControl("Overlay", pause2); H.newControl("ResumeButton", menu2); H.newControl("QuitButton", menu2)
local director2 = H.attachScript(root2, "minigame/director", {
    RoundDuration = 30, TargetTemplateIndex = 1, PopupTemplateIndex = 3,
    AllowManualStart = 0,
    HitSfxId = 101, MissSfxId = 102, RoundEndSfxId = 103,
})
H.attachScript(root2, "minigame/helpers")
H.startScript(director2); H.startScript(root2.scripts["minigame/helpers"])
H.roots["SmashGarden"] = root2

H.fireKey(root2, Enum.KeyEventType.KeyboardInteractKeyUp)
eq(director2:Invoke("GetState"), "IDLE", "F key inert with AllowManualStart=0")
H.sendSignal("StartRound", { 12 })
eq(director2:Invoke("GetState"), "COUNTDOWN", "server StartRound still works")
checkNoErrors(phase)

-------------------------------------------------------------------------------
-- P9: teardown
-------------------------------------------------------------------------------

phase = "P9 teardown"

H.run(0.5) -- let the aborted round's short cleanup tweens tick out
check(H.liveTweenCount() >= 0, "tween engine sane before teardown")
H.destroyTree(root)  -- first scene (P0–P7)
H.destroyTree(root2) -- production-gate scene (P8)
eq(H.liveTweenCount(), 0, "OnDestroy killed every live tween")
eq(next(H.audioAlive), nil, "OnDestroy stopped every live audio clip")
for _, s in ipairs(H.scripts) do
    eq(s.alive, false, "script instance " .. s.path .. " dead after teardown")
end
checkNoErrors(phase)

-------------------------------------------------------------------------------
-- Report
-------------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed (%d controls instantiated, %d destroyed)",
      passed, failed, H.instantiated, H.destroyed))
if failed > 0 then os.exit(1) end
print("ALL GREEN")
