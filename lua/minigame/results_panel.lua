-------------------------------------------------------------------------------
-- results_panel.lua — the end-of-round scoreboard (a pure VIEW).
--
-- ATTACHED TO: the "Results" Container Control (child of the root, drawn over
-- the Game screen).
--
-- game_flow owns navigation and calls Invoke("Show", ...) / Invoke("Hide").
-- This script owns nothing but its own text and slide-in animation. The three
-- buttons (Next / Replay / Menu) are wired by game_flow like every other
-- button in the game — one input owner for the whole UI.
--
-- VISIBILITY vs ACTIVE (important everywhere in this project): this panel
-- stays ACTIVE for the whole stage and hides with SetVisible(false) + parking
-- offscreen. A control that starts INACTIVE may never run its OnStart, so the
-- script's ui refs would be nil the first time Show is invoked.
--
-- PATTERN TOUR:
--   [VIEW ONLY]   no game state, no callbacks — flow pushes primitives in
--   [SCREENS]     SetVisible (never SetActive) + a tweened slide-in
--   [TWEEN LOCKS] slide tween is killable AND killed before we write anchors
--   [LOCALIZATION]every visible string via game.GetText
-------------------------------------------------------------------------------

local ui = {}
local shown = false
-- Slide-in tween kept as a reference so Hide can kill it: a live tween LOCKS
-- the fields it animates (anchors here), and Hide wants to park the panel by
-- writing those same fields directly.
local slideTween = nil

local COLOR_NEW_BEST = Color.FromRGB(255, 204, 0)
local COLOR_COINS = Color.FromRGB(255, 214, 0)

local function helpers()
    local root = game.FindClientUIRoot("SmashGarden")
    local h = root and root:GetScriptByPath("minigame/helpers")
    if h and h.alive then return h end
    return nil
end

-- Localized text with the embedded English fallback (see helpers.Text).
local function txt(key, a, b, c)
    local h = helpers()
    return h and h:Invoke("Text", key, a, b, c) or key
end

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

-- All primitives, one parameter each — the safest thing to marshal across
-- script:Invoke. Order matches game_flow's call site.
function Show(level, score, hits, misses, bestCombo, coins, newBest, stars, best, completed)
    if not ui.panel then return end
    shown = true

    local h = helpers()
    local starText = h and h:Invoke("FormatStars", stars) or ""

    ui.titleText.text  = txt("minigame.results_title")
    ui.verdictText.text = txt(completed and "minigame.complete" or "minigame.failed")
    ui.medalText.text  = starText
    ui.scoreText.text  = txt("minigame.final_score", score)
    ui.statsText.text  = txt("minigame.stats", hits, misses, bestCombo)
    ui.coinsText.text  = txt("minigame.coins_earned", coins)
    ui.bestText.text   = txt("minigame.best", best)
    ui.newBestText:SetVisible(newBest and true or false)
    ui.newBestText.text = txt("minigame.new_best")
    ui.newBestText.fontColor = COLOR_NEW_BEST

    if slideTween then slideTween:Kill(false) end
    ui.panel:SetVisible(true)
    slideTween = game.Tween(ui.panel, { anchorMinX = 0.5, anchorMaxX = 0.5 }, 0.35)
        :SetEase(Enum.EaseType.OutCubic)
        :SetOnComplete(function() slideTween = nil end)
    slideTween:Play()

    print(string.format("[results] shown: level=%d score=%d stars=%d coins=%d newBest=%s",
        tonumber(level) or 0, tonumber(score) or 0, tonumber(stars) or 0,
        tonumber(coins) or 0, tostring(newBest)))
end

function Hide()
    hide()
end

function IsShown()
    return shown
end

function OnStart()
    ui.panel = script.object
    ui.titleText   = ui.panel:GetChild("TitleText")
    ui.verdictText = ui.panel:GetChild("VerdictText")
    ui.medalText   = ui.panel:GetChild("MedalText")
    ui.scoreText   = ui.panel:GetChild("FinalScoreText")
    ui.statsText   = ui.panel:GetChild("StatsText")
    ui.coinsText   = ui.panel:GetChild("CoinsText")
    ui.bestText    = ui.panel:GetChild("BestText")
    ui.newBestText = ui.panel:GetChild("NewBestText")

    if ui.coinsText then ui.coinsText.fontColor = COLOR_COINS end
    hide() -- start hidden + parked offscreen
end

function OnDisable()
    -- Fires when the whole UI group is torn down (loading screen, stage
    -- end). Reset internal state so a fresh OnStart starts clean.
    shown = false
    slideTween = nil
end
