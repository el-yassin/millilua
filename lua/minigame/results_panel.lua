-------------------------------------------------------------------------------
-- results_panel.lua — the end-of-round screen.
--
-- ATTACHED TO: the "Results" Container Control (sibling of PlayArea/Hud
-- under the root). The director calls Invoke("Show", ...) / Invoke("Hide").
--
-- VISIBILITY vs ACTIVE (important!): this panel stays ACTIVE for the whole
-- stage and hides with SetVisible(false) (+ parking offscreen). A control
-- that starts INACTIVE may never run its OnStart — meaning this script's
-- ui refs would be nil the first time Show is invoked. Keep script-bearing
-- controls active; use SetVisible for hiding. (SetActive(false) also stops
-- event listeners and lifecycle functions — we want neither.)
--
-- PATTERN TOUR:
--   [SCREENS]     show/hide with tweened slide-in (SetVisible, not SetActive)
--   [KEY INPUT]   keyboard + controller confirm listeners returning a boolean
--   [FOCUS]       game.SetControllerFocus so a gamepad can press the button
--   [TWEEN]       panel slide-in — a single killable Tween (TweenSequence
--                  has no documented Kill, so keep a Tween reference instead)
--   [LOCALIZATION]every string via game.GetText
-------------------------------------------------------------------------------

local ui = {}
local shown = false
-- Slide-in tween kept as a reference so Hide can kill it: a live tween
-- LOCKS the fields it animates (anchors here), and Hide wants to park the
-- panel by writing those same fields directly.
local slideTween = nil

local function fmt(k, ...) return string.format(game.GetText("minigame." .. k), ...) end

local function hide()
    shown = false
    if not ui.panel then return end
    if slideTween then
        slideTween:Kill(false)
        slideTween = nil
    end
    ui.panel:SetVisible(false)
    -- Park it offscreen-right so the slide-in has somewhere to come from.
    ui.panel:SetAnchorMin(1.2, 0.5)
    ui.panel:SetAnchorMax(1.2, 0.5)
end

function Show(score, hits, misses, bestCombo, bestScore)
    if not ui.panel or shown then return end
    shown = true

    ui.panel:SetVisible(true)
    ui.scoreText.text  = fmt("final_score", score)
    ui.statsText.text  = fmt("stats", hits, misses, bestCombo)
    ui.bestText.text   = fmt("best", bestScore)

    -- Slide in from the right (single tween; self-clears the reference
    -- when it finishes so Hide won't try to kill a dead one).
    if slideTween then slideTween:Kill(false) end
    slideTween = game.Tween(ui.panel, { anchorMinX = 0.5, anchorMaxX = 0.5 }, 0.35)
        :SetEase(Enum.EaseType.OutCubic)
        :SetOnComplete(function() slideTween = nil end)
    slideTween:Play()

    -- Controller users need focus on a button to interact at all.
    if game.GetDevice() == Enum.Device.Gamepad then
        game.SetControllerFocus(ui.replayButton)
    end
    print("[results] shown, score=" .. tostring(score))
end

function Hide()
    hide()
end

function OnStart()
    ui.panel        = script.object
    ui.scoreText    = ui.panel:GetChild("FinalScoreText")
    ui.statsText    = ui.panel:GetChild("StatsText")
    ui.bestText     = ui.panel:GetChild("BestText")
    ui.replayButton = ui.panel:GetChild("ReplayButton")

    local function replay()
        if not shown then return false end
        hide() -- the director restarts the round, which shows HUD again
        local root = game.FindClientUIRoot("SmashGarden")
        local dir = root and root:GetScriptByPath("minigame/director")
        if dir and dir.alive then
            dir:Invoke("OnReplayRequested")
        end
        return true -- consumed: stops other listeners in the chain
    end

    -- Key listeners live on the button control. The boolean return matters:
    -- true = handled (stops the event reaching other listeners of the same
    -- type), false = let the chain continue. Register BOTH keyboard and
    -- controller variants — this is the controller-parity pattern.
    ui.replayButton:AddKeyEventListener(Enum.KeyEventType.KeyboardInteractKeyUp, replay)
    ui.replayButton:AddKeyEventListener(Enum.KeyEventType.ControllerJumpKeyUp, replay)

    hide() -- start hidden + parked offscreen
end

function OnDisable()
    -- Fires when the whole UI group is torn down (loading screen, stage
    -- end). Reset internal state so a fresh OnStart starts clean.
    shown = false
    slideTween = nil
end
