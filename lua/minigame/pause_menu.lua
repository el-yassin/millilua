-------------------------------------------------------------------------------
-- pause_menu.lua — the pause overlay (exercise 3).
--
-- ATTACHED TO: the "PauseMenu" Container Control (sibling of PlayArea/Hud/
-- Results under the root). The director invokes Show/Hide/ForceClose.
-- ALL pause STATE lives in the director — this script is pure presentation.
-- One owner per piece of state!
--
-- WHY THE PAUSE KEY ISN'T HERE: the toggle lives on the always-active root
-- control in director.lua; this panel only draws and offers buttons.
--
-- VISIBILITY vs ACTIVE: same rule as results_panel — this panel stays
-- ACTIVE for the whole stage and hides with SetVisible(false), so its
-- OnStart has always run by the time Show is first invoked, and its key
-- listeners stay registered.
--
-- PATTERN TOUR:
--   [SCREENS]       dim overlay + centered menu, fade/pop in
--   [CONTROLLER]    focus moves to Resume on show
--   [KEY EVENTS]    confirm + back listeners, boolean = consumed
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

local function director()
    local root = game.FindClientUIRoot("SmashGarden")
    local d = root and root:GetScriptByPath("minigame/director")
    if d and d.alive then return d end
    return nil
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

    -- Controller users: focus lands on Resume, so the menu is operable
    -- without ever touching a stick to "find" a button.
    if game.GetDevice() == Enum.Device.Gamepad then
        game.SetControllerFocus(ui.resumeButton)
    end
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
-- AbortRound from the server): no animation, just gone, state forgotten.
function ForceClose()
    Hide()
end

local function resume()
    if not shown then return false end
    local d = director()
    if d then d:Invoke("OnResumeRequested") end
    return true
end

local function quit()
    if not shown then return false end
    local d = director()
    if d then d:Invoke("OnQuitRequested") end
    return true
end

function OnStart()
    ui.panel = script.object
    ui.overlay = ui.panel:GetChild("Overlay")     -- full-screen dim image
    ui.menu = ui.panel:GetChild("MenuBox")        -- centered container
    ui.resumeButton = ui.menu:GetChild("ResumeButton")
    ui.quitButton = ui.menu:GetChild("QuitButton")

    -- Register BOTH keyboard and controller variants on each button —
    -- the controller-parity pattern. The boolean return matters: true =
    -- handled (stops the chain), false = let other listeners try.
    ui.resumeButton:AddKeyEventListener(Enum.KeyEventType.KeyboardInteractKeyUp, resume)
    ui.resumeButton:AddKeyEventListener(Enum.KeyEventType.ControllerJumpKeyUp, resume)
    ui.quitButton:AddKeyEventListener(Enum.KeyEventType.KeyboardDropKeyUp, quit)
    ui.quitButton:AddKeyEventListener(Enum.KeyEventType.ControllerInteractKeyUp, quit)

    -- The overlay itself isn't a button, but the pause key should still
    -- resume when focus isn't on a specific button: listen on the panel too.
    ui.panel:AddKeyEventListener(Enum.KeyEventType.KeyboardOpenShortcutWheelKeyUp, resume)
    ui.panel:AddKeyEventListener(Enum.KeyEventType.ControllerMenuBackKeyUp, resume)

    Hide() -- always start hidden; director owns Show
end

function OnDestroy()
    killTweens()
    shown = false
end
