-------------------------------------------------------------------------------
-- harness.lua — a fake MiliLua runtime for testing the minigame headlessly.
--
-- It emulates the documented engine surface the minigame uses:
--   * Client control tree (GetChild, SetActive/SetVisible, listeners, ids)
--   * Script instances (env-per-instance, OnInit/OnStart/OnDestroy, Invoke,
--     GetParam, EnableUpdate, signal + custom-var handlers)
--   * Tween engine WITH FIELD LOCKING (a tweened field is locked while the
--     tween plays; overlapping tweens on it are reported as errors) and
--     TweenSequence chaining
--   * game.* globals: UI root lookup, instantiate/destroy, audio, server
--     signals, custom variables, PauseLevelTime, GetText, focus, device
--
-- The point of the locks/error recorder: if the game code re-triggers a
-- tween on a locked field, forgets to kill something, or hits a missing
-- localization key / missing control, the test FAILS. This is a behavior
-- test for the game code, not for the engine.
--
-- NOT emulated on purpose: rendering, tween easing curves (end values are
-- applied at completion), real timing/latency.
-------------------------------------------------------------------------------

local M = {}

-------------------------------------------------------------------------------
-- Error / log recording
-------------------------------------------------------------------------------

M.errors = {}  -- every printerr call AND every engine-contract violation

function M.err(msg)
    table.insert(M.errors, msg)
end

M.verbose = false
local logs = {}

function M.log(msg)
    table.insert(logs, tostring(msg))
    if M.verbose then print("[log] " .. msg) end
end

function M.logs()
    return logs
end

-------------------------------------------------------------------------------
-- Global-ish engine state
-------------------------------------------------------------------------------

M.sentSignals = {}     -- { { name=..., params={...} } } in send order
M.customVars = {}      -- ["Player/BestScore"] = value
M.customVarHandlers = {} -- ["Player/BestScore"] = { fn, ... }
M.serverHandlers = {}  -- ["StartRound"] = { {inst=..., fn=...}, ... }
M.levelPaused = false
M.pauseLog = {}        -- every PauseLevelTime argument in order
M.device = "Keyboard"  -- Enum.Device value
M.language = "English" -- Enum.LanguageType value
M.focus = nil          -- last SetControllerFocus target
M.templates = {}       -- [index] = { name=..., scriptPath=..., params=..., props=... }
M.scripts = {}         -- every attached script instance, in attach order
M.instantiated = 0     -- InstantiateClientUIControl call count
M.destroyed = 0        -- DestroyClientUIControl call count
M.audioCounter = 0
M.audioAlive = {}      -- [audioId] = clipId
M.audioStopped = 0
M.roots = {}           -- [name] = control

-------------------------------------------------------------------------------
-- Localization table. GetText on a missing key is an ERROR: the game must
-- never hardcode a string that isn't mapped.
-------------------------------------------------------------------------------

local TEXTS = {
    -- core / HUD
    ["minigame.score"]       = "Score: %d",
    ["minigame.combo"]       = "Combo: %d",
    ["minigame.best"]        = "Best: %d",
    ["minigame.final_score"] = "Final Score: %d",
    ["minigame.stats"]       = "Hits: %d  Misses: %d  Best Combo: %d",
    ["minigame.countdown"]   = "%d",
    ["minigame.go"]          = "GO!",
    ["minigame.fever"]       = "FEVER!",
    ["minigame.bomb"]        = "-15",
    ["minigame.time_bonus"]  = "+3s",
    ["minigame.hud_level"]   = "Level %d — Target %d",
    ["minigame.coins"]       = "Coins: %d",
    -- title screen
    ["minigame.title"]       = "SMASH GARDEN",
    ["minigame.subtitle"]    = "Whack your way to a perfect harvest!",
    ["minigame.press_start"] = "Press Start",
    -- main menu
    ["minigame.play"]        = "Play",
    ["minigame.shop"]        = "Garden Shop",
    ["minigame.stats_title"] = "Garden Records",
    ["minigame.back"]        = "Back",
    -- level select
    ["minigame.level_select"]  = "Choose a Patch",
    ["minigame.level_locked"]  = "Locked",
    ["minigame.level.name.1"]  = "First Sprouts",
    ["minigame.level.name.2"]  = "Golden Hour",
    ["minigame.level.name.3"]  = "Silver Lining",
    ["minigame.level.name.4"]  = "Weedy Business",
    ["minigame.level.name.5"]  = "Time Thief",
    ["minigame.level.name.6"]  = "Pressure Pot",
    ["minigame.level.name.7"]  = "Combo Garden",
    ["minigame.level.name.8"]  = "Bomb Squad",
    ["minigame.level.name.9"]  = "Golden Rush",
    ["minigame.level.name.10"] = "Marathon Patch",
    ["minigame.level.name.11"] = "Perfect Patch",
    ["minigame.level.name.12"] = "Grand Harvest",
    -- shop
    ["minigame.shop.time_name"]  = "Longer Rounds",
    ["minigame.shop.time_desc"]  = "+2s per round",
    ["minigame.shop.gold_name"]  = "Golden Touch",
    ["minigame.shop.gold_desc"]  = "+1 golden target value",
    ["minigame.shop.combo_name"] = "Combo Master",
    ["minigame.shop.combo_desc"] = "Fever starts 1 combo earlier",
    ["minigame.shop.tier"]       = "Lv %d/%d",
    ["minigame.shop.max"]        = "MAX",
    ["minigame.shop.price"]      = "%d",
    -- stats
    ["minigame.stats.cleared"] = "Patches cleared: %d/%d",
    ["minigame.stats.rounds"]  = "Rounds played: %d",
    ["minigame.stats.smashes"] = "Total smashes: %d",
    ["minigame.stats.best"]    = "Best score: %d",
    -- results
    ["minigame.results_title"] = "Harvest Report",
    ["minigame.complete"]      = "Patch cleared!",
    ["minigame.failed"]        = "Target missed — try again!",
    ["minigame.coins_earned"]  = "+%d coins",
    ["minigame.new_best"]      = "NEW BEST!",
    ["minigame.next"]          = "Next",
    ["minigame.replay"]        = "Replay",
    ["minigame.menu"]          = "Menu",
    -- pause
    ["minigame.paused"]        = "Paused",
    ["minigame.pause.resume"]  = "Resume",
    ["minigame.pause.restart"] = "Restart",
    ["minigame.pause.quit"]    = "Quit",
}

-------------------------------------------------------------------------------
-- Enum / Color fakes (values are plain strings/tables; identity-comparable)
-------------------------------------------------------------------------------

M.Enum = {
    CursorEventType = { CursorClick = "CursorClick" },
    KeyEventType = {
        KeyboardInteractKeyUp = "KeyboardInteractKeyUp",
        KeyboardDropKeyUp = "KeyboardDropKeyUp",
        KeyboardOpenShortcutWheelKeyUp = "KeyboardOpenShortcutWheelKeyUp",
        KeyboardMoveForwardKeyUp = "KeyboardMoveForwardKeyUp",
        KeyboardMoveBackwardKeyUp = "KeyboardMoveBackwardKeyUp",
        KeyboardMoveLeftKeyUp = "KeyboardMoveLeftKeyUp",
        KeyboardMoveRightKeyUp = "KeyboardMoveRightKeyUp",
        ControllerJumpKeyUp = "ControllerJumpKeyUp",
        ControllerInteractKeyUp = "ControllerInteractKeyUp",
        ControllerMenuBackKeyUp = "ControllerMenuBackKeyUp",
    },
    ControllerNavigationEventType = {
        Confirm = "Confirm", Cancel = "Cancel",
        Focus = "Focus", LostFocus = "LostFocus",
        Enter = "Enter", Exit = "Exit", Direction = "Direction",
    },
    EaseType = { OutBack = "OutBack", InBack = "InBack",
                 OutCubic = "OutCubic", InOutSine = "InOutSine" },
    Device = { Keyboard = "Keyboard", Gamepad = "Gamepad" },
    LanguageType = { English = "English", Japanese = "Japanese" },
    ImageFillHorizontalType = { LeftToRight = "LeftToRight" },
    CustomVariableEntityType = { Player = "Player" },
}

M.Color = {
    FromRGB = function(r, g, b) return { r = r, g = g, b = b, a = 255 } end,
    FromRGBA = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end,
}

-------------------------------------------------------------------------------
-- Tween engine with field locks
-------------------------------------------------------------------------------

local playing = {}          -- currently-playing tweens
local lockedFields = {}     -- ["<controlId>.<field>"] = tween
local Tween = {}
Tween.__index = Tween

local function lockKey(target, field)
    return tostring(target.id) .. "." .. field
end

local function newTween(target, props, duration)
    return setmetatable({
        target = target, props = props, duration = duration,
        state = "Initial", elapsed = 0, ease = nil, onComplete = nil,
    }, Tween)
end

function Tween:SetEase(e)
    self.ease = e
    return self
end

function Tween:SetOnComplete(fn)
    -- Engine contract from the docs: callbacks only in the Initial state.
    if self.state ~= "Initial" then
        M.err("SetOnComplete called on a " .. self.state .. " tween")
    end
    self.onComplete = fn
    return self
end

function Tween:Play()
    if self.state == "Playing" then
        M.err("Play called on an already-playing tween")
        return self
    end
    for field in pairs(self.props) do
        local key = lockKey(self.target, field)
        if lockedFields[key] then
            M.err("TWEEN FIELD LOCK VIOLATION: " .. self.target.name ..
                  "." .. field .. " already tweened by another tween")
        end
        lockedFields[key] = self
    end
    self.state = "Playing"
    table.insert(playing, self)
    return self
end

function Tween:finish(completed)
    self.state = completed and "Complete" or "Killed"
    for field in pairs(self.props) do
        local key = lockKey(self.target, field)
        if lockedFields[key] == self then lockedFields[key] = nil end
    end
    if completed then
        for field, value in pairs(self.props) do
            self.target[field] = value
        end
        if self.onComplete then self.onComplete() end
    end
end

function Tween:Kill(force)
    if self.state ~= "Playing" then return end
    self:finish(force == true)
end

function M.tickTweens(dt)
    -- Snapshot: OnComplete callbacks may create/kill other tweens.
    local snapshot = {}
    for i, t in ipairs(playing) do snapshot[i] = t end
    for _, t in ipairs(snapshot) do
        if t.state == "Playing" then
            t.elapsed = t.elapsed + dt
            if t.elapsed >= t.duration then t:finish(true) end
        end
    end
    local keep = {}
    for _, t in ipairs(playing) do
        if t.state == "Playing" then keep[#keep + 1] = t end
    end
    playing = keep
end

function M.liveTweenCount()
    return #playing
end

-- TweenSequence: chains its tweens by wiring the previous one's OnComplete.
local Seq = {}
Seq.__index = Seq

function M.newTweenSequence()
    return setmetatable({ tweens = {} }, Seq)
end

function Seq:Append(t)
    table.insert(self.tweens, t)
    return self
end

function Seq:Play()
    local i = 0
    local function playNext()
        i = i + 1
        local t = self.tweens[i]
        if not t then return end
        -- Preserve any callback the game set at Append time, then chain:
        -- overwriting it would silently drop e.g. a destroy-on-complete.
        local user = t.onComplete
        t.onComplete = function()
            if user then user() end
            playNext()
        end
        t:Play()
    end
    playNext()
end

-------------------------------------------------------------------------------
-- Client controls
-------------------------------------------------------------------------------

local Control = {}
Control.__index = Control

local nextControlId = 0

function M.newControl(name, parent)
    nextControlId = nextControlId + 1
    local c = setmetatable({
        name = name,
        id = nextControlId,
        parent = parent,
        children = {},
        childByName = {},
        active = true,
        visible = true,
        alive = true,
        raycastTarget = true,
        -- common animatable fields the game writes:
        text = "",
        fontSize = 20,
        fontColor = nil,
        imageColor = nil,
        fillAmount = 1,
        anchoredPositionX = 0,
        anchoredPositionY = 0,
        anchorMinX = 0.5, anchorMinY = 0.5,
        anchorMaxX = 0.5, anchorMaxY = 0.5,
        localScaleX = 1, localScaleY = 1, localScaleZ = 1,
        scripts = {},      -- [scriptPath] = script instance
        cursorListeners = {}, -- [eventType] = { fn, ... }
        keyListeners = {},    -- [keyType] = { fn, ... }
        navListeners = {},    -- [navEventType] = { fn, ... }
    }, Control)
    if parent then
        table.insert(parent.children, c)
        parent.childByName[name] = c
    end
    return c
end

function Control:GetChild(name)
    return self.childByName[name]
end

function Control:GetScriptByPath(path)
    return self.scripts[path]
end

function Control:SetActive(v) self.active = v and true or false end
function Control:SetVisible(v) self.visible = v and true or false end
function Control:SetAnchoredPosition(x, y)
    self.anchoredPositionX, self.anchoredPositionY = x, y
end
function Control:GetAnchoredPosition()
    return self.anchoredPositionX, self.anchoredPositionY
end
function Control:SetLocalScale(x, y, z)
    self.localScaleX, self.localScaleY, self.localScaleZ = x, y, z
end
function Control:SetAnchorMin(x, y) self.anchorMinX, self.anchorMinY = x, y end
function Control:SetAnchorMax(x, y) self.anchorMaxX, self.anchorMaxY = x, y end
function Control:SetFillHorizontal(_, amount) self.fillAmount = amount end

function Control:SetAsLastSibling()
    local sibs = self.parent.children
    for i, c in ipairs(sibs) do
        if c == self then table.remove(sibs, i); break end
    end
    table.insert(sibs, self)
end

function Control:AddCursorEventListener(eventType, fn)
    local list = self.cursorListeners[eventType]
    if not list then list = {}; self.cursorListeners[eventType] = list end
    table.insert(list, fn)
end

function Control:AddKeyEventListener(keyType, fn)
    local list = self.keyListeners[keyType]
    if not list then list = {}; self.keyListeners[keyType] = list end
    table.insert(list, fn)
end

function Control:AddNavigationEventListener(eventType, fn)
    local list = self.navListeners[eventType]
    if not list then list = {}; self.navListeners[eventType] = list end
    table.insert(list, fn)
end

-- Is the control in a state where the engine would deliver events?
local function chainActive(c)
    while c do
        if not c.active then return false end
        c = c.parent
    end
    return true
end
M.chainActive = chainActive

-- A click needs the whole ancestor CHAIN visible, not just the control:
-- a hidden screen swallows clicks on its buttons.
local function chainVisible(c)
    while c do
        if not c.visible then return false end
        c = c.parent
    end
    return true
end
M.chainVisible = chainVisible

local function detach(c)
    if c.parent then
        for i, ch in ipairs(c.parent.children) do
            if ch == c then table.remove(c.parent.children, i); break end
        end
        c.parent.childByName[c.name] = nil
        c.parent = nil
    end
end
M.detach = detach

-------------------------------------------------------------------------------
-- Script instances (env per instance — template = class, instance = object)
-------------------------------------------------------------------------------

local ScriptMt = {}

function ScriptMt:GetParam(name)
    return self.params[name]
end

function ScriptMt:EnableUpdate(v)
    self.updateEnabled = v and true or false
end

function ScriptMt:RegisterServerSignalHandler(name, fn)
    local list = M.serverHandlers[name]
    if not list then list = {}; M.serverHandlers[name] = list end
    table.insert(list, { inst = self, fn = fn })
end

function ScriptMt:RegisterCustomVariableChangedHandler(entity, name, fn)
    local key = entity .. "/" .. name
    local list = M.customVarHandlers[key]
    if not list then list = {}; M.customVarHandlers[key] = list end
    table.insert(list, { inst = self, fn = fn })
end

function ScriptMt:Invoke(name, ...)
    local fn = self.env[name]
    if type(fn) ~= "function" then
        M.err("Invoke on missing function: " .. name .. " (" .. self.path .. ")")
        return nil
    end
    return fn(...)
end
ScriptMt.__index = ScriptMt

-- Load a script file as its own instance attached to a control.
function M.attachScript(control, relPath, params)
    local f = assert(io.open(M.luaDir .. "/" .. relPath .. ".lua", "r"))
    local src = f:read("a")
    f:close()

    local inst = setmetatable({
        path = relPath,
        object = control,
        alive = true,
        updateEnabled = false,
        params = params or {},
        env = nil,
    }, ScriptMt)

    local env = setmetatable({ script = inst }, { __index = M.shared })
    inst.env = env

    local chunk, loadErr = load(src, "@" .. relPath, "t", env)
    if not chunk then error("compile " .. relPath .. ": " .. loadErr) end
    chunk()

    control.scripts[relPath] = inst
    table.insert(M.scripts, inst)
    return inst
end

function M.startScript(inst)
    if inst.env.OnInit then inst.env.OnInit() end
    if inst.env.OnStart then inst.env.OnStart() end
end

local function destroyScriptsOf(c)
    for _, inst in pairs(c.scripts) do
        if inst.alive then
            inst.alive = false
            if inst.env.OnDestroy then inst.env.OnDestroy() end
        end
    end
end

-------------------------------------------------------------------------------
-- Shared environment handed to every script chunk
-------------------------------------------------------------------------------

M.shared = {
    ipairs = ipairs, pairs = pairs, next = next,
    tonumber = tonumber, tostring = tostring, type = type,
    math = math, string = string, table = table, os = os,
    print = function(...) M.log(table.concat({ ... }, " ")) end,
    printerr = function(...) M.err("printerr: " .. table.concat({ ... }, " ")) end,
    Enum = M.Enum,
    Color = M.Color,
}

M.shared.game = {
    FindClientUIRoot = function(name)
        return M.roots[name]
    end,

    InstantiateClientUIControl = function(index, parent)
        local t = M.templates[index]
        if not t then
            M.err("InstantiateClientUIControl: no template #" .. tostring(index))
            return nil
        end
        if not parent or not parent.alive then
            M.err("InstantiateClientUIControl: dead/nil parent for " .. t.name)
            return nil
        end
        local c = M.newControl(t.name, parent)
        for k, v in pairs(t.props or {}) do c[k] = v end
        if t.scriptPath then
            local inst = M.attachScript(c, t.scriptPath, t.params)
            M.startScript(inst)
        end
        M.instantiated = M.instantiated + 1
        return c
    end,

    DestroyClientUIControl = function(c)
        if not c.alive then
            M.err("DestroyClientUIControl called twice on " .. tostring(c.name))
            return
        end
        c.alive = false
        M.destroyed = M.destroyed + 1
        destroyScriptsOf(c)
        detach(c)
    end,

    Tween = newTween,
    TweenSequence = M.newTweenSequence,

    PlayAudio2D = function(clipId)
        M.audioCounter = M.audioCounter + 1
        M.audioAlive[M.audioCounter] = clipId
        return M.audioCounter
    end,
    IsAudioAlive = function(audioId) return M.audioAlive[audioId] ~= nil end,
    StopAudio = function(audioId)
        if M.audioAlive[audioId] then
            M.audioAlive[audioId] = nil
            M.audioStopped = M.audioStopped + 1
        end
    end,

    ServerSignal = function(name)
        local sig = { name = name, params = {} }
        function sig:AddInt(v) table.insert(self.params, v); return self end
        function sig:AddString(v) table.insert(self.params, v); return self end
        function sig:AddIntList(v) table.insert(self.params, v); return self end
        function sig:SendSignal()
            table.insert(M.sentSignals, { name = self.name, params = self.params })
        end
        return sig
    end,

    GetGlobalCustomVariableValue = function(entity, name)
        return M.customVars[entity .. "/" .. name]
    end,

    PauseLevelTime = function(p)
        M.levelPaused = p and true or false
        table.insert(M.pauseLog, M.levelPaused)
    end,

    GetText = function(key)
        local t = TEXTS[key]
        if not t then
            M.err("GetText: unmapped key " .. tostring(key))
            return key
        end
        return t
    end,

    GetLanguageType = function() return M.language end,
    GetDevice = function() return M.device end,
    SetControllerFocus = function(c) M.focus = c end,
}

-------------------------------------------------------------------------------
-- Templates & scene building
-------------------------------------------------------------------------------

function M.registerTemplate(index, t)
    M.templates[index] = t
end

function M.buildRoot(name)
    local root = M.newControl(name, nil)
    M.roots[name] = root
    return root
end

-------------------------------------------------------------------------------
-- Driving the runtime
-------------------------------------------------------------------------------

function M.dispatchUpdate(name, dt)
    for _, inst in ipairs(M.scripts) do
        if inst.alive and inst.updateEnabled and inst.env[name] then
            inst.env[name](dt)
        end
    end
end

function M.frame(dt)
    dt = dt or (1 / 30)
    M.tickTweens(dt)
    -- OnLevelUpdate stops firing entirely while level time is paused.
    if not M.levelPaused then M.dispatchUpdate("OnLevelUpdate", dt) end
    M.dispatchUpdate("OnUpdate", dt)
end

function M.run(seconds, dt)
    dt = dt or (1 / 30)
    local steps = math.floor(seconds / dt)
    for _ = 1, steps do M.frame(dt) end
end

function M.fireKey(control, keyType)
    if not control or not control.alive or not chainActive(control) then
        return false
    end
    for _, fn in ipairs(control.keyListeners[keyType] or {}) do
        if fn() then return true end
    end
    return false
end

function M.fireNav(control, navType)
    if not control or not control.alive or not chainActive(control) then
        return false
    end
    for _, fn in ipairs(control.navListeners[navType] or {}) do
        fn() -- nav callbacks return nil by API contract; nothing to chain on
    end
    return true
end

function M.fireClick(control)
    if not control or not control.alive or not chainActive(control)
       or not chainVisible(control) then
        return false
    end
    for _, fn in ipairs(control.cursorListeners[M.Enum.CursorEventType.CursorClick] or {}) do
        fn({})
    end
    return true
end

function M.sendSignal(name, params)
    local list = M.serverHandlers[name]
    if not list or #list == 0 then
        M.err("sendSignal: no handler registered for " .. name)
        return
    end
    for _, entry in ipairs(list) do
        entry.fn(nil, params)
    end
end

function M.setCustomVar(entity, name, value)
    M.customVars[entity .. "/" .. name] = value
    for _, entry in ipairs(M.customVarHandlers[entity .. "/" .. name] or {}) do
        entry.fn(nil, name)
    end
end

-- Teardown: recursively destroy the tree like a loading screen would.
function M.destroyTree(c)
    if not c.alive then return end
    -- NOT `ipairs(table.unpack(c.children))`: ipairs only receives the
    -- FIRST unpacked value, so that silently iterates zero or one times.
    for i = 1, #c.children do
        local child = c.children[i]
        if child then M.destroyTree(child) end
    end
    c.alive = false
    destroyScriptsOf(c)
end

return M
