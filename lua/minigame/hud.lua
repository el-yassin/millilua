-------------------------------------------------------------------------------
-- hud.lua — the in-round heads-up display.
--
-- ATTACHED TO: the "Hud" ContainerControl (child of Game).
--
-- The director owns every piece of game state and pushes values here; this
-- script owns presentation only (text, colors, pops, the fever flash). Same
-- rule as everywhere else in this project: one owner per piece of state,
-- everyone else asks nicely.
--
-- It also has an invokable API — the director calls SetScore/SetCombo/
-- SetTimer/Reset/FeverFlash, never touches HUD controls directly.
--
-- PATTERN TOUR:
--   [PUSH MODEL]   state owner pushes; view never polls game logic
--   [TWEEN SET]    self-pruning registry; OnDestroy kills the rest
--   [TWEEN LOCKS]  kill a field's tween before writing the field directly
--   [THROTTLE]     the timer bar is written per frame — direct set, no tween
-------------------------------------------------------------------------------

local ui = {}
local tweens = {}
local function addTween(t)
    tweens[t] = true
    return t
end
local function killTweens()
    for t in pairs(tweens) do t:Kill(false) end
    tweens = {}
end

-- Font sizes and palette declared BEFORE killComboPop so the function
-- captures locals — a local declared after a function body would leave the
-- reference resolving to a global (nil) at call time.
local COMBO_FONT_BASE, COMBO_FONT_POP = 26, 36
local COLOR_OK = Color.FromRGB(76, 175, 80)
local COLOR_LOW = Color.FromRGB(244, 67, 54)
local COLOR_FEVER = Color.FromRGB(255, 152, 0)
local COLOR_FLASH = Color.FromRGBA(255, 190, 40, 0)

-- The combo pop lives in its own reference (not the registry) so flashes and
-- timer pulses can't abort it — and vice versa.
local comboPopTween = nil
local function killComboPop()
    if comboPopTween then
        comboPopTween:Kill(false)
        comboPopTween = nil
    end
    if ui.comboText and ui.comboText.alive then
        ui.comboText.fontSize = COMBO_FONT_BASE
    end
end

local lowPulsed = false

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

-- [I18N] Same cosmetic language branch used by the old demo: Japanese reads
-- better with a full-width separator. Strings still live in Text Mapping.
local function comboSeparator()
    if game.GetLanguageType() == Enum.LanguageType.Japanese then return "／" end
    return " · "
end

local function fmtScore(n) return txt("minigame.score", n) end
local function fmtCombo(c) return txt("minigame.combo", c) end

function Reset(levelId, target)
    killTweens()
    killComboPop()
    lowPulsed = false

    if ui.timerBar then
        ui.timerBar.imageColor = COLOR_OK
        ui.timerBar:SetFillHorizontal(Enum.ImageFillHorizontalType.LeftToRight, 1)
    end
    if ui.scoreText then ui.scoreText.text = fmtScore(0) end
    if ui.comboText then
        ui.comboText.text = fmtCombo(0) .. comboSeparator() .. "x1"
        ui.comboText.fontSize = COMBO_FONT_BASE
        ui.comboText.fontColor = Color.FromRGB(255, 255, 255)
    end
    if ui.levelText then
        ui.levelText.text = txt("minigame.hud_level",
                                tonumber(levelId) or 1, tonumber(target) or 0)
    end
    if ui.feverFlash then
        ui.feverFlash.imageColor = COLOR_FLASH
        ui.feverFlash:SetVisible(true)
    end
end

function SetScore(n)
    if ui.scoreText then ui.scoreText.text = fmtScore(n) end
end

function SetCombo(combo, mult, fever)
    if not ui.comboText then return end
    local suffix = fever and ("  " .. txt("minigame.fever")) or ""
    ui.comboText.text = fmtCombo(combo) .. comboSeparator() .. "x" .. mult .. suffix
    ui.comboText.fontColor = fever and COLOR_FEVER or Color.FromRGB(255, 255, 255)

    -- Kill the previous pop first: a tweened field is locked while playing,
    -- and overlapping pops would fight over fontSize. The pop is kept OUT of
    -- the generic registry so a fever flash never aborts it mid-flight.
    killComboPop()
    comboPopTween = game.Tween(ui.comboText, { fontSize = COMBO_FONT_POP }, 0.12)
        :SetOnComplete(function()
            if ui.comboText and ui.comboText.alive then
                comboPopTween = game.Tween(ui.comboText,
                    { fontSize = COMBO_FONT_BASE }, 0.14)
                    :SetOnComplete(function() comboPopTween = nil end)
                    :Play()
            else
                comboPopTween = nil
            end
        end)
        :Play()
end

function SetTimer(fraction)
    if not ui.timerBar then return end
    -- Continuous, value-driven update: direct write every frame. A tween
    -- here would lock the field and fight the next frame's write.
    ui.timerBar:SetFillHorizontal(Enum.ImageFillHorizontalType.LeftToRight,
                                  math.max(0, math.min(1, fraction)))

    if fraction < 0.25 and not lowPulsed then
        lowPulsed = true
        -- But the one-shot color pulse IS a tween (a flourish, not the value).
        addTween(game.Tween(ui.timerBar, { imageColor = COLOR_LOW }, 0.3)
            :SetEase(Enum.EaseType.InOutSine):Play())
    end
end

function FeverFlash()
    if not ui.feverFlash then return end
    killTweens() -- never stack two flashes on a locked imageColor
    lowPulsed = lowPulsed or false
    if ui.timerBar then
        -- killTweens may have aborted the low-time pulse mid-flight; the
        -- color is a plain field again, so re-assert the current state.
        ui.timerBar.imageColor = lowPulsed and COLOR_LOW or COLOR_OK
    end
    ui.feverFlash.imageColor = COLOR_FLASH
    addTween(game.Tween(ui.feverFlash, { imageColor = Color.FromRGBA(255, 190, 40, 140) }, 0.08)
        :SetOnComplete(function()
            if ui.feverFlash and ui.feverFlash.alive then
                addTween(game.Tween(ui.feverFlash,
                    { imageColor = Color.FromRGBA(255, 190, 40, 0) }, 0.3):Play())
            end
        end):Play())
end

function OnStart()
    ui.panel = script.object
    ui.timerBar = ui.panel and ui.panel:GetChild("TimerBar")
    ui.scoreText = ui.panel and ui.panel:GetChild("ScoreText")
    ui.comboText = ui.panel and ui.panel:GetChild("ComboText")
    ui.levelText = ui.panel and ui.panel:GetChild("LevelText")
    ui.feverFlash = ui.panel and ui.panel:GetChild("FeverFlash")
    if ui.feverFlash then
        ui.feverFlash.imageColor = COLOR_FLASH
        ui.feverFlash.raycastTarget = false -- never steal target clicks
    end
end

function OnDestroy()
    killTweens()
    killComboPop() -- Kill(false) on a finished tween is a no-op
end
