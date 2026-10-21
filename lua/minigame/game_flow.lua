-------------------------------------------------------------------------------
-- game_flow.lua — screens, navigation, input and the round hand-off.
--
-- ATTACHED TO: the root Client Container Control "SmashGarden" (alongside
-- director.lua, wallet.lua, helpers.lua and level_data.lua).
--
-- THE ONE-OWNER RULE, applied to input: every button in the game (menus,
-- results, pause overlay) is wired HERE and nowhere else. Keyboard = W/A/S/D
-- to move focus, F to confirm, Tab to go back / resume. Gamepad = native
-- controller navigation + the root-level Confirm / Cancel navigation events.
-- The director only ever listens for the pause key while a round is live.
--
-- Screen model (all screens are ACTIVE for the whole stage; SetVisible only):
--   title -> menu -> select -> game -> results
--                  -> shop                 \-> pause -> (resume|restart|quit)
--                  -> stats
--
-- PATTERN TOUR:
--   [SCREEN ROUTER]    one table, one goTo(), one visibility owner
--   [FOCUS GROUP]      per-screen ordered buttons, keyboard + controller
--   [DEBOUNCE]         a confirm key press can fire BOTH the nav Confirm
--                      event and a simulated CursorClick — one 0.25s
--                      cooldown makes double-activation impossible
--   [SERVER SIGNALS]   StartLevel / AbortRound accepted from node graphs
--   [OPTIMISTIC ECONOMY] wallet mutations are local-first, server-reconciled
-------------------------------------------------------------------------------

local CLICK_SFX_ID = 0

-- How many times per button a click can be swallowed by the debounce.
-- 0.25s is long enough to eat a duplicate event and short enough to feel
-- instant to a human.
local ACTION_COOLDOWN = 0.25

local ui = {}
local groups = {}      -- screen name -> ordered list of button controls
local gridCols = {}    -- screens laid out as grids (level select)
local actions = {}     -- control.id -> action function
local playingAudio = {} -- click-sfx audio ids for OnDestroy cleanup
local screen = "title"
local focusIndex = 1
local cooldown = 0
local lastLevel = 1
local lastStars = 0

local MENU_SCREENS = {
    title = "TitleScreen",
    menu = "MainMenu",
    select = "LevelSelect",
    shop = "Shop",
    stats = "Stats",
}

-------------------------------------------------------------------------------
-- Cross-script lookups (lazy + alive-checked, never cached across frames)
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

local function director()    return rootScript("minigame/director") end
local function wallet()      return rootScript("minigame/wallet") end
local function helpers()     return rootScript("minigame/helpers") end
local function levelData()   return rootScript("minigame/level_data") end
local function resultsPanel() return panelScript("Results", "minigame/results_panel") end
local function pauseMenu()    return panelScript("PauseMenu", "minigame/pause_menu") end

local function directorState()
    local d = director()
    if not d then return "UNKNOWN" end
    return d:Invoke("GetState")
end

local function levelCount()
    local ld = levelData()
    return (ld and ld:Invoke("GetLevelCount")) or 1
end

local function playSfx(id)
    if id and id > 0 then
        local audioId = game.PlayAudio2D(id)
        playingAudio[audioId] = true
    end
end

-------------------------------------------------------------------------------
-- Focus group machinery
-------------------------------------------------------------------------------

local function setFocus(i)
    local g = groups[screen]
    if not g or #g == 0 then return end
    focusIndex = math.max(1, math.min(#g, i))
    -- Visual feedback via a plain field write (direct, never tweened: a
    -- focused button must never fight a lock).
    for j, btn in ipairs(g) do
        if btn.alive then
            local s = (j == focusIndex) and 1.06 or 1
            btn:SetLocalScale(s, s, 1)
        end
    end
    local btn = g[focusIndex]
    if btn then game.SetControllerFocus(btn) end
end

-- Called by navigation Focus events so the keyboard index and the gamepad
-- cursor never disagree about which button is "focused".
local function syncFocus(control)
    local g = groups[screen]
    if not g then return end
    for j, btn in ipairs(g) do
        if btn.id == control.id then
            setFocus(j)
            return
        end
    end
end

local function runAction(action)
    if not action then return end
    if cooldown > 0 then return end -- debounce (see header)
    cooldown = ACTION_COOLDOWN
    playSfx(CLICK_SFX_ID)
    action()
end

-- The single button wiring helper: cursor click (mouse/touch/gamepad
-- cursor) + controller navigation focus tracking.
local function bind(control, action)
    if not control then return end
    actions[control.id] = action
    control:AddCursorEventListener(Enum.CursorEventType.CursorClick, function()
        runAction(action)
    end)
    control:AddNavigationEventListener(Enum.ControllerNavigationEventType.Focus, function()
        syncFocus(control)
    end)
end

-- Localized text with the embedded English fallback (see helpers.Text).
local function txt(key, a, b, c)
    local h = helpers()
    return h and h:Invoke("Text", key, a, b, c) or key
end

local function label(control, key)
    local l = control and control:GetChild("Label")
    if l then l.text = txt(key) end
end

local function setText(parent, name, key)
    local c = parent and parent:GetChild(name)
    if c then c.text = txt(key) end
end

-------------------------------------------------------------------------------
-- Screen routing — the ONLY place SetVisible on a screen container happens
-------------------------------------------------------------------------------

local function goTo(name)
    screen = name

    for screenName, controlName in pairs(MENU_SCREENS) do
        local c = ui[controlName]
        if c then c:SetVisible(screenName == name) end
    end

    -- Game stays up behind results/pause for context; hidden everywhere else.
    if ui.game then
        ui.game:SetVisible(name == "game" or name == "results" or name == "pause")
    end
    if name ~= "results" then
        local r = resultsPanel()
        if r then r:Invoke("Hide") end
    end
    if name ~= "pause" then
        local p = pauseMenu()
        if p then p:Invoke("ForceClose") end
    end

    if name == "select" then refreshLevelSelect()
    elseif name == "shop" then refreshShop()
    elseif name == "stats" then refreshStats()
    elseif name == "menu" then refreshCoins()
    end

    focusIndex = 1
    setFocus(1)
end

-------------------------------------------------------------------------------
-- Screen refreshers (every one re-reads wallet — single source of truth)
-------------------------------------------------------------------------------

function refreshCoins()
    local w = wallet()
    local c = w and w:Invoke("GetCoins") or 0
    local t = ui.mainCoins or (ui.MainMenu and ui.MainMenu:GetChild("CoinsText"))
    if t then t.text = txt("minigame.coins", c) end
end

function refreshShop()
    local w = wallet()
    if not w then return end
    local coins = w:Invoke("GetCoins")
    local maxTier = w:Invoke("GetTierMax")
    local t = ui.shopCoins
    if t then t.text = txt("minigame.coins", coins) end

    local COLOR_BUY = Color.FromRGB(76, 175, 80)
    local COLOR_POOR = Color.FromRGB(244, 67, 54)
    local COLOR_MAX = Color.FromRGB(160, 160, 160)

    for _, item in ipairs(ui.shopItems) do
        local tier = w:Invoke("GetUpgrade", item.id)
        local cost = w:Invoke("GetCost", item.id)
        setText(item.button, "NameText", "minigame.shop." .. item.id .. "_name")
        setText(item.button, "DescText", "minigame.shop." .. item.id .. "_desc")
        if item.tierText then
            item.tierText.text = txt("minigame.shop.tier", tier, maxTier)
        end
        if item.priceText then
            if cost <= 0 then
                item.priceText.text = txt("minigame.shop.max")
                item.priceText.fontColor = COLOR_MAX
            else
                item.priceText.text = txt("minigame.shop.price", cost)
                item.priceText.fontColor = coins >= cost and COLOR_BUY or COLOR_POOR
            end
        end
    end
end

function refreshStats()
    local w = wallet()
    if not w or not ui.statsBody then return end
    local count = levelCount()
    local cleared = math.max(0, math.min(count, w:Invoke("GetUnlocked") - 1))
    ui.statsBody.text = table.concat({
        txt("minigame.stats.cleared", cleared, count),
        txt("minigame.stats.rounds", w:Invoke("GetPlays")),
        txt("minigame.stats.smashes", w:Invoke("GetSmashes")),
        txt("minigame.stats.best", w:Invoke("GetBest")),
        txt("minigame.coins", w:Invoke("GetCoins")),
    }, "\n")
end

function refreshLevelSelect()
    local w = wallet()
    local ld = levelData()
    local hp = helpers()
    if not w or not ld or not hp then return end
    local unlocked = w:Invoke("GetUnlocked")

    for i = 1, #ui.levelButtons do
        local btn = ui.levelButtons[i]
        local nameText = btn:GetChild("NameText")
        local starsText = btn:GetChild("StarsText")
        if nameText then
            nameText.text = txt(ld:Invoke("GetNameKey", i))
        end
        if starsText then
            if i > unlocked then
                starsText.text = txt("minigame.level_locked")
            else
                local best = w:Invoke("GetBestForLevel", i)
                if best > 0 then
                    local stars = hp:Invoke("StarsFor", best,
                        ld:Invoke("GetTarget", i), ld:Invoke("GetSilver", i), ld:Invoke("GetGold", i))
                    starsText.text = hp:Invoke("FormatStars", stars)
                else
                    starsText.text = "" -- unlocked, never played
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

local function startLevel(levelId, allowLocked)
    -- The director's IDLE state is the only real guard: restart/quit paths
    -- abort a round (which routes the flow through "game") before starting.
    if directorState() ~= "IDLE" then return false end

    local count = levelCount()
    levelId = math.max(1, math.min(count, tonumber(levelId) or 1))

    if not allowLocked then
        local w = wallet()
        if w and levelId > w:Invoke("GetUnlocked") then
            print("[flow] level " .. levelId .. " is locked")
            return false
        end
    end

    lastLevel = levelId
    goTo("game")
    local d = director()
    if not d then
        printerr("[flow] director missing — cannot start level")
        return false
    end
    return d:Invoke("StartLevel", levelId)
end

local function nextLevel()
    local count = levelCount()
    if lastStars >= 1 and lastLevel < count then
        startLevel(lastLevel + 1)
    else
        startLevel(lastLevel)
    end
end

local function restartLevel()
    local d = director()
    if d then d:Invoke("AbortLevel") end -- no results; state IDLE again
    startLevel(lastLevel)
end

local function quitToMenu()
    local d = director()
    if d then d:Invoke("AbortLevel") end
    goTo("menu")
end

local function buy(id)
    local w = wallet()
    if not w then return end
    local result = w:Invoke("Purchase", id)
    if result ~= "ok" then
        print("[flow] purchase denied (" .. tostring(result) .. ")")
    end
    refreshShop()
end

-------------------------------------------------------------------------------
-- Keyboard navigation (W/A/S/D move keys + F confirm + Tab back)
-------------------------------------------------------------------------------

local function moveVertical(delta)
    local g = groups[screen]
    if not g then return false end
    local step = gridCols[screen] or 1
    setFocus(focusIndex + delta * step)
    return true
end

local function moveHorizontal(delta)
    local g = groups[screen]
    if not g then return false end
    setFocus(focusIndex + delta)
    return true
end

local function confirmFocus()
    local g = groups[screen]
    if not g or not g[focusIndex] then return false end
    runAction(actions[g[focusIndex].id])
    return true
end

-- Tab during a round is the DIRECTOR's (it pauses). Tab on "game" without
-- pause must return false so both listeners can coexist on one key.
local function onBack()
    if screen == "pause" then
        local d = director()
        if d then d:Invoke("OnResumeRequested") end
        return true
    end
    if screen == "select" or screen == "shop" or screen == "stats" or screen == "results" then
        goTo("menu")
        return true
    end
    if screen == "menu" then
        goTo("title")
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function mustFind(parent, name)
    if not parent then return nil end
    local c = parent:GetChild(name)
    if not c then printerr("[flow] missing control: " .. name) end
    return c
end

function OnInit()
    CLICK_SFX_ID = tonumber(script:GetParam("ClickSfxId")) or 0
end

function OnStart()
    local root = game.FindClientUIRoot("SmashGarden")
    if not root then
        printerr("[flow] root control 'SmashGarden' not found")
        return
    end
    ui.root = root
    ui.TitleScreen = mustFind(root, "TitleScreen")
    ui.MainMenu = mustFind(root, "MainMenu")
    ui.LevelSelect = mustFind(root, "LevelSelect")
    ui.Shop = mustFind(root, "Shop")
    ui.Stats = mustFind(root, "Stats")
    ui.game = mustFind(root, "Game")

    -------------------------------------------------------------------
    -- Title
    -------------------------------------------------------------------
    local startButton = mustFind(ui.TitleScreen, "StartButton")
    setText(ui.TitleScreen, "TitleText", "minigame.title")
    setText(ui.TitleScreen, "SubtitleText", "minigame.subtitle")
    label(startButton, "minigame.press_start")
    bind(startButton, function() goTo("menu") end)

    -------------------------------------------------------------------
    -- Main menu
    -------------------------------------------------------------------
    setText(ui.MainMenu, "TitleText", "minigame.title")
    ui.mainCoins = mustFind(ui.MainMenu, "CoinsText")
    local playButton = mustFind(ui.MainMenu, "PlayButton")
    local shopButton = mustFind(ui.MainMenu, "ShopButton")
    local statsButton = mustFind(ui.MainMenu, "StatsButton")
    label(playButton, "minigame.play")
    label(shopButton, "minigame.shop")
    label(statsButton, "minigame.stats_title")
    bind(playButton, function() goTo("select") end)
    bind(shopButton, function() goTo("shop") end)
    bind(statsButton, function() goTo("stats") end)

    -------------------------------------------------------------------
    -- Level select (12 buttons, 4 columns) + Back
    -------------------------------------------------------------------
    setText(ui.LevelSelect, "HeaderText", "minigame.level_select")
    ui.levelButtons = {}
    for i = 1, 12 do
        local btn = mustFind(ui.LevelSelect, "Level" .. i)
        ui.levelButtons[i] = btn
        local levelId = i
        bind(btn, function() startLevel(levelId) end)
    end
    local selectBack = mustFind(ui.LevelSelect, "BackButton")
    label(selectBack, "minigame.back")
    bind(selectBack, function() goTo("menu") end)

    -------------------------------------------------------------------
    -- Shop
    -------------------------------------------------------------------
    setText(ui.Shop, "HeaderText", "minigame.shop")
    ui.shopCoins = mustFind(ui.Shop, "CoinsText")
    local SHOP_BUTTON_NAMES = { time = "TimeButton", gold = "GoldButton", combo = "ComboButton" }
    ui.shopItems = {}
    for _, item in ipairs({ { id = "time" }, { id = "gold" }, { id = "combo" } }) do
        local button = mustFind(ui.Shop, SHOP_BUTTON_NAMES[item.id])
        item.button = button
        item.tierText = button and button:GetChild("TierText")
        item.priceText = button and button:GetChild("PriceText")
        ui.shopItems[#ui.shopItems + 1] = item
        local id = item.id
        bind(button, function() buy(id) end)
    end
    local shopBack = mustFind(ui.Shop, "BackButton")
    label(shopBack, "minigame.back")
    bind(shopBack, function() goTo("menu") end)

    -------------------------------------------------------------------
    -- Stats
    -------------------------------------------------------------------
    setText(ui.Stats, "HeaderText", "minigame.stats_title")
    ui.statsBody = mustFind(ui.Stats, "StatsBody")
    local statsBack = mustFind(ui.Stats, "BackButton")
    label(statsBack, "minigame.back")
    bind(statsBack, function() goTo("menu") end)

    -------------------------------------------------------------------
    -- Results (buttons live on the panel; results_panel.lua draws only)
    -------------------------------------------------------------------
    local results = mustFind(root, "Results")
    local nextButton = mustFind(results, "NextButton")
    local replayButton = mustFind(results, "ReplayButton")
    local menuButton = mustFind(results, "MenuButton")
    label(nextButton, "minigame.next")
    label(replayButton, "minigame.replay")
    label(menuButton, "minigame.menu")
    bind(nextButton, nextLevel)
    bind(replayButton, function() startLevel(lastLevel) end)
    bind(menuButton, function() goTo("menu") end)

    -------------------------------------------------------------------
    -- Pause menu (buttons inside MenuBox; pause_menu.lua draws only)
    -------------------------------------------------------------------
    local pause = mustFind(root, "PauseMenu")
    local pauseBox = mustFind(pause, "MenuBox")
    setText(pauseBox, "TitleText", "minigame.paused")
    local resumeButton = mustFind(pauseBox, "ResumeButton")
    local restartButton = mustFind(pauseBox, "RestartButton")
    local quitButton = mustFind(pauseBox, "QuitButton")
    label(resumeButton, "minigame.pause.resume")
    label(restartButton, "minigame.pause.restart")
    label(quitButton, "minigame.pause.quit")
    bind(resumeButton, function()
        local d = director()
        if d then d:Invoke("OnResumeRequested") end
    end)
    bind(restartButton, restartLevel)
    bind(quitButton, quitToMenu)

    -------------------------------------------------------------------
    -- Focus groups (order matters: keyboard walks this list)
    -------------------------------------------------------------------
    groups.title = { startButton }
    groups.menu = { playButton, shopButton, statsButton }
    groups.select = {}
    for i = 1, 12 do groups.select[#groups.select + 1] = ui.levelButtons[i] end
    groups.select[#groups.select + 1] = selectBack
    gridCols.select = 4
    groups.shop = { ui.shopItems[1].button, ui.shopItems[2].button,
                    ui.shopItems[3].button, shopBack }
    groups.stats = { statsBack }
    groups.results = { nextButton, replayButton, menuButton }
    groups.pause = { resumeButton, restartButton, quitButton }

    -------------------------------------------------------------------
    -- Input (this script is the game's ONLY key owner outside rounds)
    -------------------------------------------------------------------
    root:AddKeyEventListener(Enum.KeyEventType.KeyboardMoveForwardKeyUp, function()
        return moveVertical(-1)
    end)
    root:AddKeyEventListener(Enum.KeyEventType.KeyboardMoveBackwardKeyUp, function()
        return moveVertical(1)
    end)
    root:AddKeyEventListener(Enum.KeyEventType.KeyboardMoveLeftKeyUp, function()
        return moveHorizontal(-1)
    end)
    root:AddKeyEventListener(Enum.KeyEventType.KeyboardMoveRightKeyUp, function()
        return moveHorizontal(1)
    end)
    root:AddKeyEventListener(Enum.KeyEventType.KeyboardInteractKeyUp, function()
        return confirmFocus()
    end)
    root:AddKeyEventListener(Enum.KeyEventType.KeyboardOpenShortcutWheelKeyUp, function()
        return onBack()
    end)
    -- Gamepad: controller navigation Confirm / Cancel (native cursor moves
    -- between CursorEventArea controls; Focus events keep our index synced).
    root:AddNavigationEventListener(Enum.ControllerNavigationEventType.Confirm, function()
        return confirmFocus()
    end)
    root:AddNavigationEventListener(Enum.ControllerNavigationEventType.Cancel, function()
        return onBack()
    end)

    -------------------------------------------------------------------
    -- Server signals (a node graph can start or abort rounds remotely)
    -------------------------------------------------------------------
    script:RegisterServerSignalHandler("StartLevel", function(_, params)
        if directorState() == "IDLE" then
            startLevel(params and params[1] or 1, true) -- server bypasses locks
        end
    end)
    script:RegisterServerSignalHandler("AbortRound", function()
        local d = director()
        if d then d:Invoke("AbortLevel") end
        goTo("menu")
    end)

    script:EnableUpdate(true) -- action debounce clock only (see OnUpdate)
    goTo("title")             -- boots hidden menus; title is the entry screen
    print("[flow] ready — starting at the title screen")
end

-- Action debounce clock. EnableUpdate makes OnUpdate fire every frame; the
-- body is a subtraction and a compare, so the per-frame cost is nil.
function OnUpdate(dt)
    if cooldown > 0 then
        cooldown = math.max(0, cooldown - dt)
    end
end

-------------------------------------------------------------------------------
-- Invokable API (called by director.lua and debug_hud.lua)
-------------------------------------------------------------------------------

-- director.lua: round is over, here are the facts. We own what happens next.
function OnRoundFinished(level, score, hits, misses, bestCombo, stars)
    lastLevel = level
    lastStars = stars

    local w = wallet()
    if not w then
        printerr("[flow] wallet missing — round results discarded")
        goTo("menu")
        return
    end
    w:Invoke("RecordRound", level, score, stars, hits)
    local coins = w:Invoke("GetLastCoins")
    local newBest = w:Invoke("WasNewBest")
    local best = w:Invoke("GetBest")

    goTo("results")
    local r = resultsPanel()
    if r then
        r:Invoke("Show", level, score, hits, misses, bestCombo,
                 coins, newBest, stars, best, stars >= 1)
    end
end

-- director.lua: pause opened/closed — this only changes which focus group
-- is active; the director owns the overlay visibility itself.
function OnPauseChanged(paused)
    if paused then
        screen = "pause"
        focusIndex = 1
        setFocus(1)
    elseif screen == "pause" then
        screen = "game"
    end
end

function GetScreenName()
    return screen
end

function GetDebugLine()
    return "screen=" .. screen .. " last=" .. lastLevel .. "/" .. lastStars
end

function OnDestroy()
    cooldown = 0
    for audioId in pairs(playingAudio) do
        if game.IsAudioAlive(audioId) then game.StopAudio(audioId) end
    end
    playingAudio = {}
end
