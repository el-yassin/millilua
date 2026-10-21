-------------------------------------------------------------------------------
-- pause_menu.lua — the pause overlay (a pure VIEW).
--
-- ATTACHED TO: the "PauseMenu" Container Control (child of the root, drawn
-- over the Game screen). The director invokes Show/Hide/ForceClose.
--
-- ALL pause STATE lives in the director, and ALL input (Resume/Restart/Quit,
-- Tab to resume, gamepad back) lives in game_flow.lua — like every other
-- screen. This script only draws: dim overlay + centered menu.
--
-- VISIBILITY vs ACTIVE: same rule as results_panel — this panel stays ACTIVE
-- for the whole stage and hides with SetVisible(false), so its OnStart has
-- always run by the time Show is first invoked.
--
-- PATTERN TOUR:
--   [SCREENS]       dim overlay + centered menu, fade/pop in
--   [INVOKABLE API] Show/Hide/ForceClose called cross-script
--   [TWEEN SET]     self-pruning registry, killed on Hide + OnDestroy
-------------------------------------------------------------------------------

local ui = {}
local shown = false

-- Tween registry as a SET with self-pruning onComplete — entries remove
-- themselves when done, so nothing accumulates. Hide() and OnDestroy()
-- kill whatever is still in flight. (Declared BEFORE first use — in Lua,
-- a `local` referenced earlier in the chunk would silently become a global.)
local tweens = {}
local function trackTween(t, onComplete)
    tweens[t] = true
    return t:SetOnComplete(function()
        tweens[t] = nil
        if onComplete then onComplete() end
    end)
end
local function killTweens()
    for t in pairs(tweens) do t:Kill(false) end
    tweens = {}
end

function IsShown()
    return shown
end

function Show()
    if shown or not ui.panel then return end
    shown = true
    killTweens() -- a previous Show/Hide cycle may have left tweens mid-flight
    ui.panel:SetVisible(true)

    -- Fade in: tween the overlay image's alpha (imageColor is [Tweenable],
    -- and Color.FromRGBA builds the target value).
    ui.overlay.imageColor = Color.FromRGBA(0, 0, 0, 0)
    trackTween(game.Tween(ui.overlay,
        { imageColor = Color.FromRGBA(0, 0, 0, 160) }, 0.15)):Play()

    -- Menu pops in with a little overshoot.
    ui.menu:SetLocalScale(0.8, 0.8, 1)
    trackTween(game.Tween(ui.menu,
        { localScaleX = 1, localScaleY = 1 }, 0.2)
        :SetEase(Enum.EaseType.OutBack)):Play()
end

function Hide()
    -- Unconditional + idempotent on purpose: OnStart calls this while the
    -- panel is still visible-but-`shown=false`, and a guarded version would
    -- silently leave the overlay up at boot.
    shown = false
    killTweens() -- never let a half-played fade write to a hidden panel
    if ui.panel then ui.panel:SetVisible(false) end
end

-- Director calls this when a round ends while somehow still paused (e.g.
-- the server aborting the round): no animation, just gone, state forgotten.
function ForceClose()
    Hide()
end

function OnStart()
    ui.panel = script.object
    ui.overlay = ui.panel:GetChild("Overlay")     -- full-screen dim image
    ui.menu = ui.panel:GetChild("MenuBox")        -- centered container

    -- Buttons (ResumeButton / RestartButton / QuitButton) are wired by
    -- game_flow.lua — this view script never registers input listeners.
    Hide() -- always start hidden; director owns Show
end

function OnDestroy()
    killTweens()
    shown = false
end
