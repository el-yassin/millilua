-------------------------------------------------------------------------------
-- debug_hud.lua — a live state readout for test play.
--
-- ATTACHED TO: a "DebugText" TextWindow (child of the ROOT, anchored
-- top-left — menus too, not just the game screen). Every owner stays the
-- single owner of its state; this script only ASKS for formatted lines via
-- script:Invoke.
--
-- GATING: its own `Enabled` script variable. Set Enabled=0 (or remove the
-- script from the control) in a production stage. With Enabled=0 the
-- script stays completely silent: no EnableUpdate, no text writes — a
-- debug overlay that costs zero frames when shipped.
--
-- PATTERN TOUR:
--   [POLLING]      state lives in OTHER scripts; read via Invoke, never
--                  by reaching into their locals (you can't — sandboxed)
--   [THROTTLE]     OnUpdate runs every frame; accumulate deltaTime and
--                  only refresh a few times per second
--   [SCRIPT VARS]  feature flags via GetParam (ship debug code without
--                  shipping debug behavior)
-------------------------------------------------------------------------------

local UPDATE_INTERVAL = 0.25 -- seconds between refreshes (4 Hz)

local ui = {}
local enabled = false
local accumulator = 0

local function rootScript(path)
    local root = game.FindClientUIRoot("SmashGarden")
    local s = root and root:GetScriptByPath(path)
    if s and s.alive then return s end
    return nil
end

function OnInit()
    enabled = tonumber(script:GetParam("Enabled")) == 1
end

function OnStart()
    ui.text = script.object
    if ui.text then
        ui.text:SetVisible(enabled) -- never shown when disabled
    end
    -- No update loop at all when disabled: zero cost in production.
    script:EnableUpdate(enabled)
end

function OnUpdate(deltaTime)
    accumulator = accumulator + deltaTime
    if accumulator < UPDATE_INTERVAL then return end
    accumulator = 0

    if not ui.text or not ui.text.alive then return end
    local d = rootScript("minigame/director")
    local f = rootScript("minigame/game_flow")
    local w = rootScript("minigame/wallet")
    ui.text.text = table.concat({
        f and f:Invoke("GetDebugLine") or "(no flow)",
        d and d:Invoke("GetDebugLine") or "(no director)",
        w and w:Invoke("GetDebugLine") or "(no wallet)",
    }, " | ")
end
