-------------------------------------------------------------------------------
-- debug_hud.lua — a live state readout for test play.
--
-- ATTACHED TO: a "DebugText" TextWindow (recommended: child of Hud,
-- anchored top-left). The director stays the single owner of all state;
-- this script only ASKS for a formatted line via script:Invoke.
--
-- GATING: its own `Enabled` script variable. Set Enabled=0 (or remove the
-- script from the control) in a production stage. With Enabled=0 the
-- script stays completely silent: no EnableUpdate, no text writes — a
-- debug overlay that costs zero frames when shipped.
--
-- PATTERN TOUR:
--   [POLLING]      state lives in ANOTHER script; read via Invoke, never
--                  by reaching into its locals (you can't — sandboxed)
--   [THROTTLE]     OnUpdate runs every frame; accumulate deltaTime and
--                  only refresh a few times per second
--   [SCRIPT VARS]  feature flags via GetParam (this is how you ship
--                  debug code without shipping debug behavior)
-------------------------------------------------------------------------------

local UPDATE_INTERVAL = 0.25 -- seconds between refreshes (4 Hz)

local ui = {}
local enabled = false
local accumulator = 0

local function director()
    local root = game.FindClientUIRoot("SmashGarden")
    local d = root and root:GetScriptByPath("minigame/director")
    if d and d.alive then return d end
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

    local d = director()
    if ui.text and ui.text.alive then
        ui.text.text = d and d:Invoke("GetDebugLine") or "(no director)"
    end
end
