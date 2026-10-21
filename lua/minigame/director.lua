-------------------------------------------------------------------------------
-- director.lua — the in-round game director (state machine + scoring).
--
-- ATTACHED TO: the root Client Container Control, named "SmashGarden".
--
-- Why the director lives on the root control and NOT in a Global Script:
-- a Global Script has `script.object == nil` and no way to reach into the
-- UI hierarchy. Everything else in the game talks to it via script:Invoke.
--
-- The director owns exactly one thing: A RUN. Menus, screens, coins and
-- progression belong to game_flow.lua / wallet.lua. The director is told
-- "run level N", reports facts when it ends, and keeps no opinions about
-- what happens next.
--
-- PATTERN TOUR:
--   [STATE MACHINE]  IDLE -> COUNTDOWN -> PLAYING -> IDLE (EnableUpdate gating)
--   [COUNTDOWN]      real-time 3..2..1..GO on OnUpdate (ignores level pause)
--   [ROUND CLOCK]    OnLevelUpdate + PauseLevelTime (pause freezes the clock)
--   [TARGET KINDS]   5 templates, one script, different `Kind` script vars
--   [FEVER]          combo threshold -> double points + screen flash + sfx
--   [SERVER SIGNALS] RoundComplete / SubmitHighScore are sent by wallet.lua
--   [CLEANUP]        OnDestroy kills every tween/audio it created
-------------------------------------------------------------------------------

-- Script Variables (read in OnInit; mapping is guaranteed loaded by then).
local TEMPLATE = { [1] = nil, [2] = nil, [3] = nil, [4] = nil, [5] = nil }
local POPUP_TEMPLATE_INDEX = nil
local HIT_SFX_ID, MISS_SFX_ID, BOMB_SFX_ID = 0, 0, 0
local TIME_SFX_ID, ROUND_END_SFX_ID, FEVER_SFX_ID = 0, 0, 0

-- Target kind codes. Kept in sync with level_data.lua and target.lua.
local KIND_NORMAL, KIND_SILVER, KIND_GOLDEN, KIND_BOMB, KIND_TIME = 1, 2, 3, 4, 5

-- Scoring constants (design data, safe to tune).
local BOMB_PENALTY = 15
local TIME_BONUS_SECONDS = 3
local FEVER_BASE_THRESHOLD = 10
local FEVER_POINTS_MULTIPLIER = 2

local State = { IDLE = 1, COUNTDOWN = 2, PLAYING = 3 }
local STATE_NAMES = { [State.IDLE] = "IDLE", [State.COUNTDOWN] = "COUNTDOWN",
                      [State.PLAYING] = "PLAYING" }
local state = State.IDLE

-- `ui` is declared before every function that closes over it (Lua lexical
-- scoping: a local declared later would resolve to a global nil at runtime).
local ui = {}
local activeTweens = {}   -- self-pruning registry
local playingAudio = {}

local currentLevel = 1
local config = nil        -- level definition fetched from level_data.lua
local roundDuration = 30
local feverThreshold = FEVER_BASE_THRESHOLD
local goldTier = 0

local score, combo, bestCombo, hits, misses, bombs, timeBonuses = 0, 0, 0, 0, 0, 0, 0
local fever = false
local timeLeft = 0
local countdownLeft = 0
local nextSpawnIn = 0
local paused = false
local slotOccupied = {}
local liveTargets = {}
local kindOverride = 0    -- debug: force the next spawns to one kind (0 = off)

local COLOR_GOLD_POPUP = Color.FromRGB(255, 204, 0)
local COLOR_BOMB_POPUP = Color.FromRGB(244, 67, 54)
local COLOR_TIME_POPUP = Color.FromRGB(80, 200, 255)

-------------------------------------------------------------------------------
-- Cross-script lookups (always lazy + alive-checked)
-------------------------------------------------------------------------------

local function rootControl()
    return ui.root or game.FindClientUIRoot("SmashGarden")
end

-- Resolves a control owned by ANOTHER script: the editor-authored child of the
-- root with the expected name (the layout is built in the MiliLua editor).
local function panelControl(controlName)
    local root = rootControl()
    return root and root:GetChild(controlName)
end

local function rootScript(path)
    local root = rootControl()
    local s = root and root:GetScriptByPath(path)
    if s and s.alive then return s end
    return nil
end

local function panelScript(controlName, path)
    local c = panelControl(controlName)
    local s = c and c:GetScriptByPath(path)
    if s and s.alive then return s end
    return nil
end

local function levelData()  return rootScript("minigame/level_data") end
local function wallet()     return rootScript("minigame/wallet") end
local function flow()       return rootScript("minigame/game_flow") end
local function hud()        return ui.hud and ui.hud:GetScriptByPath("minigame/hud") end
local function resultsPanel() return panelScript("Results", "minigame/results_panel") end
local function pauseMenu()    return panelScript("PauseMenu", "minigame/pause_menu") end

-- Localized text with the embedded English fallback (see helpers.Text).
local function txt(key, a, b, c)
    local h = rootScript("minigame/helpers")
    return h and h:Invoke("Text", key, a, b, c) or key
end

-------------------------------------------------------------------------------
-- Small utilities
-------------------------------------------------------------------------------

local function mustFind(parent, name)
    if not parent then return nil end
    local c = parent:GetChild(name)
    if not c then
        printerr("[director] missing control: " .. name ..
                 " (parent=" .. tostring(parent.name) .. ")")
    end
    return c
end

local function addTween(t)
    activeTweens[t] = true
    return t
end
local function trackTween(t, onComplete)
    activeTweens[t] = true
    return t:SetOnComplete(function()
        activeTweens[t] = nil
        if onComplete then onComplete() end
    end)
end

local function playSfx(id)
    if id and id > 0 then
        local audioId = game.PlayAudio2D(id)
        playingAudio[audioId] = true
        return audioId
    end
    return nil
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function refreshHudScore()
    local h = hud()
    if h then h:Invoke("SetScore", score) end
end

local function refreshHudCombo()
    local h = hud()
    if not h then return end
    local hp = rootScript("minigame/helpers")
    local mult = hp and hp:Invoke("GetMultiplier", combo) or 1
    h:Invoke("SetCombo", combo, mult, fever)
end

local function refreshHudAll()
    refreshHudScore()
    refreshHudCombo()
end

-------------------------------------------------------------------------------
-- Score popups
-------------------------------------------------------------------------------

local function spawnPopup(x, y, text, color)
    if not POPUP_TEMPLATE_INDEX then return end
    local popup = game.InstantiateClientUIControl(POPUP_TEMPLATE_INDEX, ui.playArea)
    popup.text = text
    popup:SetAnchoredPosition(x, y)
    popup:SetAsLastSibling()
    if color then popup.fontColor = color end
    trackTween(game.Tween(popup, { anchoredPositionY = y + 80, fontSize = 48 }, 0.6)
        :SetEase(Enum.EaseType.OutCubic), function()
            if popup.alive then game.DestroyClientUIControl(popup) end
        end):Play()
end

-------------------------------------------------------------------------------
-- Level configuration
-------------------------------------------------------------------------------

local function fetchConfig(levelId)
    local ld = levelData()
    if not ld then
        printerr("[director] level_data script is missing — cannot start a level")
        return nil
    end
    local c = {
        duration   = ld:Invoke("GetDuration", levelId),
        target     = ld:Invoke("GetTarget", levelId),
        silver     = ld:Invoke("GetSilver", levelId),
        gold       = ld:Invoke("GetGold", levelId),
        spawnStart = ld:Invoke("GetSpawnStart", levelId),
        spawnMin   = ld:Invoke("GetSpawnMin", levelId),
        maxActive  = ld:Invoke("GetMaxActive", levelId),
        weights    = {},
    }
    for code = 1, 5 do
        c.weights[code] = ld:Invoke("GetWeight", levelId, code)
    end
    return c
end

-------------------------------------------------------------------------------
-- Targets
-------------------------------------------------------------------------------

local function anyFreeSlot()
    local free = {}
    for i = 1, #ui.slots do
        if not slotOccupied[i] then free[#free + 1] = i end
    end
    if #free == 0 then return nil end
    return free[math.random(#free)]
end

local function pickKind()
    if kindOverride ~= 0 then return kindOverride end
    local roll = math.random(1, 100)
    local acc = 0
    for code = 1, 5 do
        acc = acc + (config.weights[code] or 0)
        if roll <= acc then return code end
    end
    return KIND_NORMAL
end

local function lifetimeFor(kind)
    local progress = 1 - (timeLeft / roundDuration)
    local base = math.max(0.6, 1.6 - progress * 0.9)
    if kind == KIND_GOLDEN then return base * 0.55 end
    if kind == KIND_BOMB then return base * 1.35 end
    if kind == KIND_TIME then return base * 1.10 end
    return base
end

local function spawnTarget(forcedKind)
    local kind = forcedKind or pickKind()
    local templateIndex = TEMPLATE[kind]
    if not templateIndex then
        printerr("[director] missing TargetTemplate script variable for kind " .. tostring(kind))
        return nil
    end
    local slot = anyFreeSlot()
    if not slot then return nil end

    local control = game.InstantiateClientUIControl(templateIndex, ui.slots[slot])
    control:SetAnchoredPosition(0, 0)
    control:SetLocalScale(0, 0, 1)
    slotOccupied[slot] = true

    local popScale = (kind == KIND_GOLDEN) and 1.25 or 1
    local popTween = game.Tween(control,
        { localScaleX = popScale, localScaleY = popScale }, 0.18)
        :SetEase(Enum.EaseType.OutBack)
    addTween(popTween:Play())

    liveTargets[control.id] = {
        control = control,
        slot = slot,
        kind = kind,
        expiresAt = timeLeft - lifetimeFor(kind),
        popTween = popTween,
    }
    return control
end

local function despawnTarget(id)
    local t = liveTargets[id]
    if not t or not t.control or not t.control.alive then return end
    liveTargets[id] = nil
    slotOccupied[t.slot] = nil

    -- Kill the pop-in first (force-complete: despawn from full size).
    if t.popTween then
        t.popTween:Kill(true)
        t.popTween = nil
    end

    local c = t.control
    c.raycastTarget = false
    trackTween(game.Tween(c, { localScaleX = 0, localScaleY = 0 }, 0.12)
        :SetEase(Enum.EaseType.InBack), function()
            if c.alive then game.DestroyClientUIControl(c) end
        end):Play()
end

local function resetCombo()
    combo = 0
    if fever then
        fever = false
    end
end

local function expireTargets()
    for id, t in pairs(liveTargets) do
        if timeLeft <= t.expiresAt then
            despawnTarget(id)
            -- An escaped target breaks the combo and counts as a miss.
            resetCombo()
            misses = misses + 1
            refreshHudAll()
        end
    end
end

-------------------------------------------------------------------------------
-- Round lifecycle
-------------------------------------------------------------------------------

local function beginCountdown()
    state = State.COUNTDOWN
    countdownLeft = 3.2
    ui.playArea:SetVisible(false) -- no clicking through the countdown
    ui.hud:SetVisible(true)
    if ui.countdownText then ui.countdownText:SetVisible(true) end
    script:EnableUpdate(true)
end

local function tickCountdown(dt)
    local previous = math.ceil(countdownLeft)
    countdownLeft = countdownLeft - dt
    local current = math.ceil(countdownLeft)
    local cd = ui.countdownText

    local text
    if countdownLeft > 1 then
        text = txt("minigame.countdown", current)
    elseif countdownLeft > 0 then
        text = txt("minigame.go")
    else
        if cd then cd:SetVisible(false) end
        state = State.PLAYING
        ui.playArea:SetVisible(true)
        timeLeft = roundDuration
        nextSpawnIn = 0.35
        print(string.format("[director] level %d started (%.0fs)", currentLevel, timeLeft))
        return
    end

    if cd and text and current ~= previous then
        cd.text = text
        cd:SetLocalScale(1.6, 1.6, 1)
        addTween(game.Tween(cd, { localScaleX = 1, localScaleY = 1 }, 0.25)
            :SetEase(Enum.EaseType.OutBack):Play())
    end
end

local function stopRound(report)
    if paused then
        paused = false
        game.PauseLevelTime(false)
        if pauseMenu() then pauseMenu():Invoke("ForceClose") end
        local f = flow()
        if f then f:Invoke("OnPauseChanged", false) end
    end
    state = State.IDLE
    script:EnableUpdate(false)

    for id in pairs(liveTargets) do despawnTarget(id) end
    ui.hud:SetVisible(false)
    ui.playArea:SetVisible(false)
    if ui.countdownText then ui.countdownText:SetVisible(false) end
    playSfx(ROUND_END_SFX_ID)

    if report then
        local hp = rootScript("minigame/helpers")
        local stars = hp and hp:Invoke("StarsFor", score,
            config.target, config.silver, config.gold) or 0
        local f = flow()
        if f then
            f:Invoke("OnRoundFinished", currentLevel, score, hits, misses, bestCombo, stars)
        end
    end
end

local function startLevel(levelId)
    if state ~= State.IDLE then return false end

    currentLevel = clamp(tonumber(levelId) or 1, 1, 99)
    config = fetchConfig(currentLevel)
    if not config then return false end

    -- Shop upgrades are read once per round: menus cannot open mid-round.
    local w = wallet()
    local timeTier = w and w:Invoke("GetUpgrade", "time") or 0
    goldTier = w and w:Invoke("GetUpgrade", "gold") or 0
    local comboTier = w and w:Invoke("GetUpgrade", "combo") or 0

    local hp = rootScript("minigame/helpers")
    roundDuration = hp and hp:Invoke("AdjustedDuration", config.duration, timeTier) or config.duration
    feverThreshold = hp and hp:Invoke("FeverThreshold", FEVER_BASE_THRESHOLD, comboTier)
                     or FEVER_BASE_THRESHOLD

    score, combo, bestCombo, hits, misses, bombs, timeBonuses = 0, 0, 0, 0, 0, 0, 0
    fever = false
    paused = false
    kindOverride = 0
    slotOccupied, liveTargets = {}, {}
    activeTweens = {}

    local h = hud()
    if h then h:Invoke("Reset", currentLevel, config.target) end

    local results = resultsPanel()
    if results then results:Invoke("Hide") end
    local pause = pauseMenu()
    if pause then pause:Invoke("ForceClose") end

    beginCountdown()
    print(string.format("[director] StartLevel %d (duration=%.0fs, target=%d)",
        currentLevel, roundDuration, config.target))
    return true
end

-------------------------------------------------------------------------------
-- Pause
-------------------------------------------------------------------------------

local function setPaused(p)
    if state ~= State.PLAYING then return end
    if paused == p then return end
    paused = p
    game.PauseLevelTime(p)
    if pauseMenu() then pauseMenu():Invoke(p and "Show" or "Hide") end
    local f = flow()
    if f then f:Invoke("OnPauseChanged", p) end
    print("[director] " .. (p and "paused" or "resumed"))
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function OnInit()
    TEMPLATE[KIND_NORMAL] = script:GetParam("TemplateNormal")
    TEMPLATE[KIND_SILVER] = script:GetParam("TemplateSilver")
    TEMPLATE[KIND_GOLDEN] = script:GetParam("TemplateGolden")
    TEMPLATE[KIND_BOMB]   = script:GetParam("TemplateBomb")
    TEMPLATE[KIND_TIME]   = script:GetParam("TemplateTime")
    POPUP_TEMPLATE_INDEX = script:GetParam("PopupTemplateIndex")

    HIT_SFX_ID = tonumber(script:GetParam("HitSfxId")) or 0
    MISS_SFX_ID = tonumber(script:GetParam("MissSfxId")) or 0
    BOMB_SFX_ID = tonumber(script:GetParam("BombSfxId")) or 0
    TIME_SFX_ID = tonumber(script:GetParam("TimeSfxId")) or 0
    ROUND_END_SFX_ID = tonumber(script:GetParam("RoundEndSfxId")) or 0
    FEVER_SFX_ID = tonumber(script:GetParam("FeverSfxId")) or 0

    if not TEMPLATE[KIND_NORMAL] then
        printerr("[director] TemplateNormal script variable not set — spawns will fail!")
    end
end

function OnStart()
    local root = game.FindClientUIRoot("SmashGarden")
    if not root then
        printerr("[director] root control 'SmashGarden' not found")
        return
    end
    ui.root = root
    ui.game = mustFind(root, "Game")
    ui.playArea = mustFind(ui.game, "PlayArea")
    ui.hud = mustFind(ui.game, "Hud")
    ui.countdownText = mustFind(ui.game, "CountdownText")
    ui.slots = {}
    for i = 1, 9 do
        ui.slots[i] = mustFind(ui.playArea, "Slot" .. i)
    end

    -- Clicking empty space is a miss: breaks the combo, breaks fever.
    ui.playArea:AddCursorEventListener(Enum.CursorEventType.CursorClick, function(_)
        if state == State.PLAYING and not paused then
            resetCombo()
            misses = misses + 1
            playSfx(MISS_SFX_ID)
            refreshHudAll()
        end
    end)

    -- Pause key: only OPENS the pause menu. Closing belongs to game_flow (so
    -- a paused game has exactly one handler for Tab/back and no double toggle).
    ui.root:AddKeyEventListener(Enum.KeyEventType.KeyboardOpenShortcutWheelKeyUp, function()
        if state == State.PLAYING and not paused then
            setPaused(true)
            return true
        end
        return false
    end)
    ui.root:AddKeyEventListener(Enum.KeyEventType.ControllerMenuBackKeyUp, function()
        if state == State.PLAYING and not paused then
            setPaused(true)
            return true
        end
        return false
    end)

    -- Start hidden; game_flow shows the Game screen when a level starts.
    ui.hud:SetVisible(false)
    ui.playArea:SetVisible(false)
    if ui.countdownText then ui.countdownText:SetVisible(false) end
    print("[director] ready")
end

-- Countdown uses REAL time (no half-paused countdowns).
function OnUpdate(dt)
    if state == State.COUNTDOWN then
        tickCountdown(dt)
    end
end

-- The round clock uses LEVEL time: PauseLevelTime suspends OnLevelUpdate,
-- which freezes the clock, spawning and expiry for free.
function OnLevelUpdate(dt)
    if state ~= State.PLAYING or paused then return end

    timeLeft = timeLeft - dt
    if timeLeft <= 0 then
        timeLeft = 0
        stopRound(true)
        return
    end

    local h = hud()
    if h then h:Invoke("SetTimer", timeLeft / roundDuration) end

    nextSpawnIn = nextSpawnIn - dt
    if nextSpawnIn <= 0 then
        local aliveCount = 0
        for _ in pairs(liveTargets) do aliveCount = aliveCount + 1 end
        if aliveCount < config.maxActive then spawnTarget() end
        local progress = 1 - timeLeft / roundDuration
        nextSpawnIn = math.max(config.spawnMin,
            config.spawnStart - progress * (config.spawnStart - config.spawnMin))
    end

    expireTargets()
end

-------------------------------------------------------------------------------
-- Invokable API (called by target.lua, game_flow.lua, debug_hud.lua)
-------------------------------------------------------------------------------

-- target.lua reports (controlId, kind, multiplier). All scoring POLICY —
-- combo, fever, upgrades, penalties — lives here.
function OnTargetClicked(controlId, kind, multiplier)
    if state ~= State.PLAYING or paused then return end
    local t = liveTargets[controlId]
    if not t then return end -- already claimed (double-click race)

    liveTargets[controlId] = nil
    slotOccupied[t.slot] = nil
    if t.popTween then
        t.popTween:Kill(true)
        t.popTween = nil
    end

    local slotControl = ui.slots[t.slot]
    local x, y = slotControl:GetAnchoredPosition()

    -- BOMB: no points, breaks combo/fever, costs score. Never below zero.
    if kind == KIND_BOMB then
        score = math.max(0, score - BOMB_PENALTY)
        bombs = bombs + 1
        resetCombo()
        playSfx(BOMB_SFX_ID)
        spawnPopup(x, y, txt("minigame.bomb"), COLOR_BOMB_POPUP)
        refreshHudAll()
        return
    end

    -- TIME: adds seconds, capped at the round's starting duration.
    if kind == KIND_TIME then
        timeBonuses = timeBonuses + 1
        timeLeft = math.min(roundDuration, timeLeft + TIME_BONUS_SECONDS)
        playSfx(TIME_SFX_ID)
        spawnPopup(x, y, txt("minigame.time_bonus"), COLOR_TIME_POPUP)
        return
    end

    -- Scoring kinds: normal (1), silver (2), golden (3).
    hits = hits + 1
    combo = combo + 1
    bestCombo = math.max(bestCombo, combo)

    -- Fever turns on the moment the combo reaches the (upgradeable) threshold
    -- and lasts until the combo breaks.
    local feverStarted = false
    if not fever and combo >= feverThreshold then
        fever = true
        feverStarted = true
    end

    local hp = rootScript("minigame/helpers")
    local base = hp and hp:Invoke("PointsFor", combo) or 10
    local mult = clamp(tonumber(multiplier) or 1, 1, 10)
    if kind == KIND_GOLDEN then
        mult = hp and hp:Invoke("GoldenMultiplier", mult, goldTier) or mult
    end
    local points = base * mult * (fever and FEVER_POINTS_MULTIPLIER or 1)
    score = score + points

    playSfx(feverStarted and FEVER_SFX_ID or HIT_SFX_ID)
    if feverStarted then
        local h = hud()
        if h then h:Invoke("FeverFlash") end
    end
    spawnPopup(x, y, "+" .. points,
        kind == KIND_GOLDEN and COLOR_GOLD_POPUP or nil)
    refreshHudAll()
end

-- Start a specific level (game_flow / server signal). Returns true on start.
function StartLevel(levelId)
    return startLevel(levelId)
end

-- Stop the current run WITHOUT showing results (quit/restart). game_flow
-- decides where the player goes next.
function AbortLevel()
    if state ~= State.IDLE then stopRound(false) end
end

-- Pause menu "Resume" button (wired by game_flow).
function OnResumeRequested()
    if paused then setPaused(false) end
end

function GetState()
    return STATE_NAMES[state] or "UNKNOWN"
end

function GetLevel()
    return currentLevel
end

function GetRoundDuration()
    return roundDuration
end

-- Debug/testing helper: force every spawn to one kind until cleared (0).
-- Used by the automated tests and handy for previewing target art in-editor.
function OverrideKind(kindCode)
    local k = tonumber(kindCode) or 0
    kindOverride = (k >= 1 and k <= 5) and k or 0
end

-- Debug/testing helper: spawn immediately if a slot is free.
function DebugSpawn()
    if state == State.PLAYING and not paused then
        spawnTarget()
    end
end

function GetDebugLine()
    local n = 0
    for _ in pairs(liveTargets) do n = n + 1 end
    return string.format(
        "lvl=%d %s score=%d combo=%d best=%d hits=%d miss=%d bomb=%d time+=%d fever=%s targets=%d",
        currentLevel, STATE_NAMES[state] or "?", score, combo, bestCombo,
        hits, misses, bombs, timeBonuses, tostring(fever), n)
end

-------------------------------------------------------------------------------
-- Teardown
-------------------------------------------------------------------------------

function OnDestroy()
    for t in pairs(activeTweens) do t:Kill(false) end
    activeTweens = {}
    for audioId in pairs(playingAudio) do
        if game.IsAudioAlive(audioId) then game.StopAudio(audioId) end
    end
    playingAudio = {}
    if paused then game.PauseLevelTime(false) end
    print("[director] destroyed — cleaned up tweens and audio")
end
