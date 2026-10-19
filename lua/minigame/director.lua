-------------------------------------------------------------------------------
-- director.lua — the game director ("state machine") of the minigame.
--
-- ATTACHED TO: the root Client Container Control, named "SmashGarden".
--
-- Why the director lives on the root control and NOT in a Global Script:
-- a Global Script has `script.object == nil` and no way to reach into the
-- UI hierarchy. The director needs to find/spawn/destroy controls, so it
-- hangs off the root and uses game.FindClientUIRoot + FindChild + GetChild.
-- Everything else in the minigame talks to the director via script:Invoke.
--
-- PATTERN TOUR (search for these keywords while reverse-engineering):
--   [STATE MACHINE]   round state + EnableUpdate gating
--   [COUNTDOWN]       3..2..1..GO driven by OnUpdate real-time (exercise 2)
--   [PAUSE]           OnLevelUpdate-driven timer + PauseLevelTime (exercise 3)
--   [GOLDEN TARGET]   second template, self-reported multiplier (exercise 4)
--   [TIMER COLOR]     imageColor tween when time runs low (exercise 5)
--   [SERVER TUNING]   golden rate changed live from a node graph (exercise 6)
--   [I18N]            GetLanguageType-aware formatting (exercise 7)
--   [SIGNAL IN/OUT]   RegisterServerSignalHandler / game.ServerSignal
--   [CUSTOM VAR]      high score persisted via Custom Variables
--   [POOLING]         Instantiate/destroy targets + score popups
--   [CLEANUP]         OnDestroy kills every tween it created
-------------------------------------------------------------------------------

---@class StartRound          -- typed signal params for LuaLS (match signal name!)
---@field [1] integer         -- [1] optional round-duration override in seconds

-- Script Variables defined in this script's mapping (Script Mapping menu).
-- Read in OnInit, NOT at top level: the mapping is guaranteed loaded by
-- OnInit, whereas top-level code runs before any lifecycle guarantee.
local ROUND_DURATION = 30
local TARGET_TEMPLATE_INDEX = nil
local GOLDEN_TEMPLATE_INDEX = nil
local POPUP_TEMPLATE_INDEX = nil
local HIT_SFX_ID, MISS_SFX_ID, ROUND_END_SFX_ID = 0, 0, 0
-- 1 = the F key starts a round (test play / no node graph yet). Set to 0
-- in a production stage so only the server's StartRound signal can start
-- rounds — the key listener then declines everything.
local ALLOW_MANUAL_START = 1

-- `ui` is declared HERE, before any function that closes over it — in Lua,
-- a local declared AFTER a function body would not be captured; references
-- would silently resolve to a global (nil) and crash at call time.
local ui = {}        -- { root, playArea, timerBar, scoreText, comboText, ... }
local bestScore = 0

-- Shared-code pattern: helpers.lua is attached to the same root control;
-- resolve its Script instance and always check .alive before Invoke.
local function helpers()
    local root = game.FindClientUIRoot("SmashGarden")
    local h = root and root:GetScriptByPath("minigame/helpers")
    if h and h.alive then return h end
    return nil
end

-- Panel scripts resolved LAZILY, not cached in OnStart: we can't control
-- the order in which sibling controls' OnStart run, but by the time we
-- Invoke on a panel it's certainly initialized. Re-resolve every call —
-- GetScriptByPath is cheap and the .alive check keeps us honest.
local function panelScript(controlName, scriptPath)
    local root = ui.root or game.FindClientUIRoot("SmashGarden")
    if not root then return nil end
    local control = root:GetChild(controlName)
    local s = control and control:GetScriptByPath(scriptPath)
    if s and s.alive then return s end
    return nil
end

local function resultsPanel() return panelScript("Results", "minigame/results_panel") end
local function pauseMenu()    return panelScript("PauseMenu", "minigame/pause_menu") end

-- Where the "BestScore" Custom Variable component lives. See
-- Enum.CustomVariableEntityType for the valid entity types and adjust to
-- wherever you placed the Custom Variable component in the editor.
local HIGHSCORE_ENTITY = Enum.CustomVariableEntityType.Player
local HIGHSCORE_VAR = "BestScore"

local State = { IDLE = 1, COUNTDOWN = 2, PLAYING = 3 }
local STATE_NAMES = { [State.IDLE] = "IDLE", [State.COUNTDOWN] = "COUNTDOWN",
                      [State.PLAYING] = "PLAYING" }
local state = State.IDLE

-- Round state
local score, combo, bestCombo, hits, misses = 0, 0, 0, 0, 0
local timeLeft = 0
local roundDuration = ROUND_DURATION
local countdownLeft = 0
local nextSpawnIn = 0
local goldenRate = 0.12          -- chance a spawn is golden; server-tunable
local paused = false
local timerPulsed = false        -- low-time color flash fired this round?
local slotOccupied = {}          -- [slotIndex] = true while a target lives there
local liveTargets = {}           -- [controlId] = { control, slot, expiresAt }
-- Tween registry: a SET (tween -> true), not an array, so finished tweens
-- can prune themselves in their own OnComplete — the registry never grows
-- unbounded across a long session. OnDestroy kills whatever remains.
local activeTweens = {}          -- every live Tween we created
local function addTween(t)
    activeTweens[t] = true
    return t
end
local function trackTween(t, onComplete)
    activeTweens[t] = true
    return t:SetOnComplete(function()
        activeTweens[t] = nil -- self-prune: this tween is done
        if onComplete then onComplete() end
    end)
end
local playingAudio = {}          -- audio instance ids, so we can StopAudio cleanly

-- Colors for the timer bar (exercise 5). Color.FromRGB is documented on the
-- Color global; ColorValues are immutable value objects.
local COLOR_TIMER_OK = Color.FromRGB(76, 175, 80)
local COLOR_TIMER_LOW = Color.FromRGB(244, 67, 54)
local COLOR_GOLD_POPUP = Color.FromRGB(255, 204, 0)

-- Combo text font sizes: base value and the "pop" value the change-tween
-- overshoots to. Named because both are written in three places below.
local COMBO_FONT_BASE, COMBO_FONT_POP = 26, 36
local comboPopTween = nil -- current pop tween; killed before retriggering

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Find a child or fail loudly. printerr is your best friend in test play.
local function mustFind(parent, name)
    local c = parent:GetChild(name)
    if not c then
        printerr("[SmashGarden] missing control: " .. name ..
                 " (parent=" .. tostring(parent and parent.name) .. ")")
    end
    return c
end

local function playSfx(id)
    if id > 0 then
        local audioId = game.PlayAudio2D(id)
        playingAudio[audioId] = true
        return audioId
    end
    return nil
end

-------------------------------------------------------------------------------
-- Localized text (never hardcode strings; game.GetText falls back to the
-- source language when a translation is missing).
-------------------------------------------------------------------------------
local function fmtScore(n)   return string.format(game.GetText("minigame.score"), n) end
local function fmtCombo(c)   return string.format(game.GetText("minigame.combo"), c) end

-- [I18N] Exercise 7: some languages read better with different separators.
-- game.GetLanguageType() returns an EnumItem.LanguageType — branch on it
-- for formatting quirks, but keep ALL visible strings in Text Mapping.
local function comboSeparator()
    local lang = game.GetLanguageType()
    if lang == Enum.LanguageType.Japanese then return "／" end
    return " · "
end

-------------------------------------------------------------------------------
-- UI refresh
-------------------------------------------------------------------------------
local function refreshHud()
    if ui.scoreText then ui.scoreText.text = fmtScore(score) end
    if ui.comboText then
        local h = helpers()
        local mult = h and h:Invoke("GetMultiplier", combo) or 1
        ui.comboText.text = fmtCombo(combo) .. comboSeparator() .. "x" .. mult

        -- Combo text pops when it changes (tweenable field!). Kill the
        -- previous pop FIRST: tweened fields are LOCKED while a Tween plays,
        -- so an overlapping pop would warn and fight over fontSize. After a
        -- kill the field is free again — snap it to base before re-popping.
        if comboPopTween then
            comboPopTween:Kill(false)
            comboPopTween = nil
            if ui.comboText.alive then ui.comboText.fontSize = COMBO_FONT_BASE end
        end
        comboPopTween = trackTween(
            game.Tween(ui.comboText, { fontSize = COMBO_FONT_POP }, 0.15),
            function()
                -- Track the return tween in the SAME reference: it holds
                -- the fontSize lock, and an untracked leftover would fight
                -- the next pop over the locked field.
                if ui.comboText and ui.comboText.alive then
                    comboPopTween = addTween(
                        game.Tween(ui.comboText, { fontSize = COMBO_FONT_BASE }, 0.15):Play())
                else
                    comboPopTween = nil
                end
            end):Play()
    end
end

-------------------------------------------------------------------------------
-- Score popups: spawn a floating "+20" at a position, tween it up, destroy it.
-- This is the instantiate -> animate -> destroy pattern in miniature.
-------------------------------------------------------------------------------
local function spawnPopup(x, y, text, color)
    if not POPUP_TEMPLATE_INDEX then return end
    local popup = game.InstantiateClientUIControl(POPUP_TEMPLATE_INDEX, ui.playArea)
    popup.text = text
    popup:SetAnchoredPosition(x, y)
    popup:SetAsLastSibling() -- higher sibling index renders on top
    if color then popup.fontColor = color end
    -- trackTween: prunes itself from the registry on completion, and the
    -- callback destroys the popup — nothing accumulates.
    trackTween(game.Tween(popup, { anchoredPositionY = y + 80, fontSize = 48 }, 0.6)
        :SetEase(Enum.EaseType.OutCubic), function()
            game.DestroyClientUIControl(popup) -- popups are disposable
        end):Play()
end

-------------------------------------------------------------------------------
-- Targets: spawn into a free slot, pop in; director owns their lifetime.
-------------------------------------------------------------------------------
local MAX_ACTIVE = 3

local function anyFreeSlot()
    local free = {}
    for i = 1, #ui.slots do
        if not slotOccupied[i] then free[#free + 1] = i end
    end
    if #free == 0 then return nil end
    return free[math.random(#free)]
end

local function spawnTarget()
    -- [GOLDEN TARGET] (exercise 4) roll the dice: golden targets use their
    -- own template (prettier art) with a higher PointsMultiplier script var.
    local isGolden = GOLDEN_TEMPLATE_INDEX ~= nil and math.random() < goldenRate
    local templateIndex = isGolden and GOLDEN_TEMPLATE_INDEX or TARGET_TEMPLATE_INDEX
    if not templateIndex then
        printerr("[SmashGarden] TargetTemplateIndex script variable not set!")
        return
    end
    local slot = anyFreeSlot()
    if not slot then return end

    local control = game.InstantiateClientUIControl(templateIndex, ui.slots[slot])
    control:SetAnchoredPosition(0, 0)
    control:SetLocalScale(0, 0, 1) -- start invisible, pop in
    slotOccupied[slot] = true

    -- Pop-in bounce. EaseLab (linked from the Tween docs) visualizes eases.
    -- Golden targets pop bigger to telegraph their value. The tween is
    -- STORED in the live entry: if the target gets clicked or expires while
    -- still popping in, we must kill it before tweening scale again
    -- (tweened fields are LOCKED while a Tween plays).
    local popScale = isGolden and 1.25 or 1
    local popTween = game.Tween(control,
        { localScaleX = popScale, localScaleY = popScale }, 0.18)
        :SetEase(Enum.EaseType.OutBack)
    addTween(popTween:Play())

    -- Golden targets are greedier: shorter lifetime.
    local baseLifetime = math.max(0.6, 1.6 - (1 - timeLeft / roundDuration) * 0.9)
    local lifetime = isGolden and baseLifetime * 0.55 or baseLifetime
    liveTargets[control.id] = { control = control, slot = slot,
                                expiresAt = timeLeft - lifetime,
                                golden = isGolden, popTween = popTween }
    -- NOTE: expiresAt counts DOWN with timeLeft; see OnLevelUpdate.
end

-- despawn: pop out and destroy. Safe to call twice — the live-list removal
-- below is the idempotence guard (a despawned id can't be found again).
local function despawnTarget(id)
    local t = liveTargets[id]
    if not t or not t.control or not t.control.alive then return end
    liveTargets[id] = nil
    slotOccupied[t.slot] = nil

    -- Kill the pop-in tween first (force-complete so the target despawns
    -- from full size, not from mid-pop): a second tween on the same scale
    -- fields would hit the tween lock. The pop-in has no OnComplete, so
    -- force-completing is side-effect free.
    if t.popTween then
        t.popTween:Kill(true)
        t.popTween = nil
    end

    local c = t.control
    c.raycastTarget = false -- stop it eating clicks while it shrinks
    trackTween(game.Tween(c, { localScaleX = 0, localScaleY = 0 }, 0.12)
        :SetEase(Enum.EaseType.InBack), function()
            game.DestroyClientUIControl(c)
        end):Play()
end

local function expireTargets()
    for id, t in pairs(liveTargets) do
        if timeLeft <= t.expiresAt then
            despawnTarget(id)
            -- A target escaping resets the combo: rewards speed.
            combo = 0
            refreshHud()
        end
    end
end

-------------------------------------------------------------------------------
-- Round lifecycle
-------------------------------------------------------------------------------
local function showResults()
    playSfx(ROUND_END_SFX_ID)

    -- Persist high score via Custom Variables (server-side state!).
    if score > bestScore then
        bestScore = score
        -- Writing goes through the server: see README "Custom Variables"
        -- section — the node graph owns the variable, we report to it.
        local sig = game.ServerSignal("SubmitHighScore")
        sig:AddInt(score)
        sig:SendSignal()
    end

    local results = resultsPanel()
    if results then
        -- Results panel knows how to animate itself in; we just hand it data.
        results:Invoke("Show", score, hits, misses, bestCombo, bestScore)
    end

    -- Report the round to node graphs (rewards, unlocks, analytics...).
    -- [SERVER-DRIVEN] (exercise 6): the node graph listens for this to
    -- unlock the next stage — see README "Node graph wiring".
    local sig = game.ServerSignal("RoundComplete")
    sig:AddInt(score)
    sig:AddInt(hits)
    sig:AddInt(misses)
    sig:AddInt(bestCombo)
    sig:SendSignal()
end

-- [COUNTDOWN] (exercise 2) 3..2..1..GO, then the round. Runs on OnUpdate
-- (real time) — NOT OnLevelUpdate — so the countdown ignores level-time
-- pausing; a paused game can't have a half-paused countdown.
local function beginCountdown()
    state = State.COUNTDOWN
    countdownLeft = 3.2
    ui.playArea:SetActive(true)
    ui.hud:SetActive(true)
    if ui.countdownText then ui.countdownText:SetActive(true) end
    script:EnableUpdate(true)
end

local function tickCountdown(dt)
    local previous = math.ceil(countdownLeft)
    countdownLeft = countdownLeft - dt
    local current = math.ceil(countdownLeft)
    local cd = ui.countdownText -- may be nil (mustFind already logged it)

    local text
    if countdownLeft > 1 then
        text = string.format(game.GetText("minigame.countdown"), current)
    elseif countdownLeft > 0 then
        text = game.GetText("minigame.go")
    else
        if cd then cd:SetActive(false) end
        state = State.PLAYING
        timeLeft = roundDuration
        nextSpawnIn = 0.4
        print(string.format("[SmashGarden] round started (%.0fs)", timeLeft))
        return
    end

    if cd and text and current ~= previous then
        cd.text = text
        -- Punch the number in: big -> normal. Two chained tweens.
        cd:SetLocalScale(1.6, 1.6, 1)
        addTween(game.Tween(cd, { localScaleX = 1, localScaleY = 1 }, 0.25)
            :SetEase(Enum.EaseType.OutBack)
            :Play())
    end
end

local function startRound(durationOverride)
    if state ~= State.IDLE then return end

    score, combo, bestCombo, hits, misses = 0, 0, 0, 0, 0
    -- Clamp the server-provided duration: a bad node graph payload must
    -- not be able to produce a zero/negative round (division by zero in
    -- the timer bar and spawn ramp below).
    roundDuration = math.max(5, math.min(300,
        tonumber(durationOverride) or ROUND_DURATION))
    slotOccupied, liveTargets = {}, {}
    paused = false
    timerPulsed = false

    -- The tween registry grows by ~2 entries per target and never shrinks;
    -- reset it at the round boundary (NOT kill — leftover pop/despawn
    -- tweens from the previous round self-complete and self-destroy).
    activeTweens = {}
    -- The combo pop is the exception: the registry forgot it, so kill it
    -- explicitly or the first refreshHud of the new round hits its lock.
    if comboPopTween then
        comboPopTween:Kill(false)
        comboPopTween = nil
    end

    -- Restore the timer bar's calm color for the new round (direct set:
    -- no tween is running on it between rounds, so the field isn't locked).
    if ui.timerBar then
        ui.timerBar.imageColor = COLOR_TIMER_OK
    end

    local results = resultsPanel()
    if results then results:Invoke("Hide") end
    local pause = pauseMenu()
    if pause then pause:Invoke("ForceClose") end
    beginCountdown()
    refreshHud()
end

local function endRound()
    -- Normalize pause first: AbortRound from the server can end a round
    -- while paused, and leaving level time frozen would break the next
    -- stage. One owner (this function) guarantees the unfreeze.
    if paused then
        paused = false
        game.PauseLevelTime(false)
        if pauseMenu() then pauseMenu():Invoke("ForceClose") end
    end
    state = State.IDLE
    script:EnableUpdate(false) -- idle: OnUpdate/OnLevelUpdate stop being called

    for id in pairs(liveTargets) do despawnTarget(id) end
    ui.hud:SetActive(false)
    ui.playArea:SetActive(false) -- back to the IDLE baseline (no stray clicks)
    if ui.countdownText then ui.countdownText:SetActive(false) end
    playSfx(ROUND_END_SFX_ID)
    showResults()
end

-- [PAUSE] (exercise 3) game.PauseLevelTime halts LEVEL time: OnLevelUpdate
-- stops firing entirely while paused. The round clock lives in
-- OnLevelUpdate, so pausing freezes it for free — no `if paused` guards
-- in the timer. (Single-player stages only; see PauseLevelTime docs.)
local function setPaused(p)
    if state ~= State.PLAYING then return end -- pause only exists mid-round
    paused = p
    game.PauseLevelTime(p)
    if pauseMenu() then pauseMenu():Invoke(p and "Show" or "Hide") end
    print("[SmashGarden] " .. (p and "paused" or "resumed"))
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function OnInit()
    -- Script Variables are guaranteed readable here (mapping is loaded
    -- before the lifecycle starts). Values validate early, fail LOUDLY,
    -- and once — instead of silently misbehaving on every spawn.
    ROUND_DURATION = tonumber(script:GetParam("RoundDuration")) or 30
    TARGET_TEMPLATE_INDEX = script:GetParam("TargetTemplateIndex")
    GOLDEN_TEMPLATE_INDEX = script:GetParam("GoldenTemplateIndex")
    POPUP_TEMPLATE_INDEX = script:GetParam("PopupTemplateIndex")
    HIT_SFX_ID = tonumber(script:GetParam("HitSfxId")) or 0
    MISS_SFX_ID = tonumber(script:GetParam("MissSfxId")) or 0
    ROUND_END_SFX_ID = tonumber(script:GetParam("RoundEndSfxId")) or 0
    ALLOW_MANUAL_START = tonumber(script:GetParam("AllowManualStart")) or 1
    roundDuration = ROUND_DURATION

    if not TARGET_TEMPLATE_INDEX then
        printerr("[SmashGarden] TargetTemplateIndex script variable not set — spawns will fail!")
    end
    print("[SmashGarden] OnInit — round=" .. tostring(ROUND_DURATION) .. "s")
end

function OnStart()
    -- UI controls only exist from OnStart on. Rebuild ALL cached refs here;
    -- after any loading screen OnStart runs again on the recreated controls.
    local root = game.FindClientUIRoot("SmashGarden")
    if not root then
        printerr("[SmashGarden] root control 'SmashGarden' not found")
        return
    end

    ui.root = root
    ui.playArea = mustFind(root, "PlayArea")
    ui.hud = mustFind(root, "Hud")
    ui.timerBar = mustFind(ui.hud, "TimerBar")
    ui.scoreText = mustFind(ui.hud, "ScoreText")
    ui.comboText = mustFind(ui.hud, "ComboText")
    ui.countdownText = mustFind(root, "CountdownText")
    ui.slots = {}
    for i = 1, 9 do
        ui.slots[i] = mustFind(ui.playArea, "Slot" .. i)
    end

    -- NOTE: no eager panel-script caching here on purpose. Sibling OnStart
    -- order is unspecified; panelScript() resolves lazily at each call site.

    -- Miss detection: clicking empty space in the play area breaks the combo.
    -- Targets sit ABOVE this area and raycast first, so their clicks don't
    -- fall through here (see README "Raycast order" note).
    ui.playArea:AddCursorEventListener(Enum.CursorEventType.CursorClick, function(_)
        if state == State.PLAYING and combo > 0 then
            combo = 0
            misses = misses + 1 -- empty clicks count as misses in the stats
            playSfx(MISS_SFX_ID)
            refreshHud()
        end
    end)

    -- [SIGNAL IN] Server -> client. Remember: ~100ms minimum latency, and
    -- params arrive as an indexable table matching the Server Signal Explorer.
    script:RegisterServerSignalHandler("StartRound", function(_, params)
        startRound(params and params[1])
    end)
    script:RegisterServerSignalHandler("AbortRound", function()
        if state == State.PLAYING then endRound() end
    end)
    -- [SERVER TUNING] (exercise 6) a node graph timer can crank difficulty
    -- mid-stage: params[1] = golden rate as a 0-100 integer.
    script:RegisterServerSignalHandler("SetGoldenRate", function(_, params)
        if params and params[1] then
            goldenRate = math.min(100, math.max(0, params[1])) / 100
            print(string.format("[SmashGarden] golden rate -> %d%%", goldenRate * 100))
        end
    end)

    -- [CUSTOM VAR] Seed + watch the high score.
    bestScore = tonumber(game.GetGlobalCustomVariableValue(HIGHSCORE_ENTITY, HIGHSCORE_VAR)) or 0
    script:RegisterCustomVariableChangedHandler(HIGHSCORE_ENTITY, HIGHSCORE_VAR, function(_, varName)
        bestScore = tonumber(game.GetGlobalCustomVariableValue(HIGHSCORE_ENTITY, varName)) or bestScore
        if ui.scoreText then ui.scoreText.text = fmtScore(score) end
    end)

    ui.hud:SetActive(false)
    ui.playArea:SetActive(false)
    if ui.countdownText then ui.countdownText:SetActive(false) end

    -- Test-play + keyboard convenience: F starts a round with no node graph,
    -- ESC toggles pause. Key listeners on the ROOT control — it's active in
    -- every state (IDLE, countdown, playing, results), which is exactly the
    -- "always listening" scope we want. Callbacks return a boolean: true =
    -- event handled (stops the chain), false = let others have it.
    ui.root:AddKeyEventListener(Enum.KeyEventType.KeyboardInteractKeyUp, function()
        if ALLOW_MANUAL_START ~= 1 then return false end -- server-only start
        if state == State.IDLE then
            startRound()
            return true
        end
        return false
    end)
    ui.root:AddKeyEventListener(Enum.KeyEventType.KeyboardOpenShortcutWheelKeyUp, function()
        if state == State.PLAYING then
            setPaused(not paused)
            return true
        end
        return false
    end)
    -- Controller parity: same pause toggle on the menu-back button.
    ui.root:AddKeyEventListener(Enum.KeyEventType.ControllerMenuBackKeyUp, function()
        if state == State.PLAYING then
            setPaused(not paused)
            return true
        end
        return false
    end)

    print("[SmashGarden] ready. Press F (or send the StartRound signal).")
end

-- [TIME] The whole game clock. deltaTime makes it frame-rate independent.
-- Countdown ticks on REAL time (OnUpdate)...
function OnUpdate(deltaTime)
    if state == State.COUNTDOWN then
        tickCountdown(deltaTime)
    end
end

-- ...while the round ticks on LEVEL time (OnLevelUpdate), which
-- game.PauseLevelTime can suspend. That split IS the pause feature.
function OnLevelUpdate(deltaTime)
    if state ~= State.PLAYING or paused then return end

    timeLeft = timeLeft - deltaTime
    if timeLeft <= 0 then
        timeLeft = 0
        endRound()
        return
    end

    -- Timer bar: set fillAmount directly per frame. It's [Tweenable], but a
    -- tween would fight per-frame writes — tweened fields are LOCKED while
    -- a Tween plays. Use tweens for one-shot flourishes (see color pulse),
    -- direct sets for continuous, value-driven updates like this.
    if ui.timerBar then
        ui.timerBar:SetFillHorizontal(Enum.ImageFillHorizontalType.LeftToRight,
                                      timeLeft / roundDuration)
    end

    -- [TIMER COLOR] (exercise 5) under 25%: flash the bar red once. One-shot
    -- tweens are fine here — the color is a flourish, not the driving value.
    -- The local flag prevents re-triggering every frame (and tween-lock
    -- errors on an already-tweened field).
    if ui.timerBar and timeLeft < roundDuration * 0.25 and not timerPulsed then
        timerPulsed = true
        addTween(game.Tween(ui.timerBar, { imageColor = COLOR_TIMER_LOW }, 0.3)
            :SetEase(Enum.EaseType.InOutSine)
            :Play())
    end

    -- Spawn pressure ramps up as the round drains.
    nextSpawnIn = nextSpawnIn - deltaTime
    if nextSpawnIn <= 0 then
        local aliveCount = 0
        for _ in pairs(liveTargets) do aliveCount = aliveCount + 1 end
        if aliveCount < MAX_ACTIVE then spawnTarget() end
        local progress = 1 - timeLeft / roundDuration
        nextSpawnIn = math.max(0.25, 0.9 - progress * 0.6)
    end

    expireTargets()
end

-------------------------------------------------------------------------------
-- Entry points for other scripts (called via script:Invoke).
-------------------------------------------------------------------------------

-- target.lua reports the kill via OnTargetClicked with ITS MULTIPLIER
-- (from its PointsMultiplier script var) — the golden rule lives with the
-- target template, not in this file. We combine it with the combo-based
-- base and clamp both: trust, but verify — clients lie.
--
-- NOTE: there is NO tween here on purpose. The target owns its death
-- animation (target.lua onClick); tweening scale from BOTH sides would
-- fight over locked fields. We own bookkeeping + juice, they own looks.
function OnTargetClicked(controlId, multiplier)
    if state ~= State.PLAYING or paused then return end
    local t = liveTargets[controlId]
    if not t then return end -- already claimed (double-click race)

    liveTargets[controlId] = nil
    slotOccupied[t.slot] = nil
    -- The target is about to squish (target.lua animates AFTER reporting,
    -- so our kill lands before its tween locks the scale fields). Force-
    -- complete the pop-in: the squish should start from full size.
    if t.popTween then
        t.popTween:Kill(true)
        t.popTween = nil
    end

    local slotControl = ui.slots[t.slot]
    local x, y = slotControl:GetAnchoredPosition()

    hits = hits + 1
    combo = combo + 1
    bestCombo = math.max(bestCombo, combo)

    local h = helpers()
    local base = h and h:Invoke("PointsFor", combo) or 10
    local mult = math.min(5, math.max(1, tonumber(multiplier) or 1))
    local points = base * mult
    score = score + points

    playSfx(HIT_SFX_ID)
    -- Golden hits pop in gold: the `golden` flag the spawn stored is the
    -- same truth the template's PointsMultiplier encodes — use it for juice.
    spawnPopup(x, y, "+" .. points, t.golden and COLOR_GOLD_POPUP or nil)
    refreshHud()
end

function OnReplayRequested()
    if state == State.IDLE then startRound() end
end

-- Pause menu buttons call this (it's on the director, so pause state stays
-- in ONE place instead of being duplicated across scripts).
function OnResumeRequested()
    if paused then setPaused(false) end
end

-- Called by pause_menu's "Quit" button: end the round without results.
function OnQuitRequested()
    if paused then setPaused(false) end
    if state == State.PLAYING then endRound() end
end

function GetState()
    return STATE_NAMES[state] or "UNKNOWN"
end

-- Debug support for debug_hud.lua: one formatted line of live state.
-- Keeping the readout ON the director means the HUD never pokes at the
-- director's internals — same rule as everything else: one owner per
-- piece of state, everyone else asks nicely via Invoke.
function GetDebugLine()
    local n = 0
    for _ in pairs(liveTargets) do n = n + 1 end
    return string.format("%s score=%d combo=%d best=%d hits=%d miss=%d gold=%d%% targets=%d",
        STATE_NAMES[state] or "?", score, combo, bestCombo, hits, misses,
        math.floor(goldenRate * 100 + 0.5), n)
end

-------------------------------------------------------------------------------
-- Teardown. Controls die on loading screens; so must our tweens and audio,
-- or they play on destroyed objects or leak into the next stage.
-------------------------------------------------------------------------------
function OnDestroy()
    for t in pairs(activeTweens) do
        t:Kill(false) -- false = don't force-complete, just stop
    end
    activeTweens = {}
    for audioId in pairs(playingAudio) do
        if game.IsAudioAlive(audioId) then game.StopAudio(audioId) end
    end
    playingAudio = {}
    if paused then game.PauseLevelTime(false) end -- never leave time frozen
    print("[SmashGarden] destroyed — cleaned up tweens and audio")
end
