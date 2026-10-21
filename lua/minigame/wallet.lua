-------------------------------------------------------------------------------
-- wallet.lua — coins, shop upgrades, progression and all persistence.
--
-- ATTACHED TO: the root container "SmashGarden".
--
-- This is the game's economy owner. It reads the Player Custom Variables on
-- start, keeps an in-memory copy (so the UI is instant and the game is fully
-- playable in test play with no node graph), and reports every mutation to
-- the server via signals. When a node graph echoes a change back through the
-- Custom Variable component, the changed handler resyncs the local copy —
-- the server's value always wins.
--
-- OFFLINE-FIRST PATTERN (important):
--   * test play / single-player: local state is the source of truth for the
--     session; signals go nowhere.
--   * production: the node graph validates purchases and round rewards and
--     writes the Custom Variables; values survive reconnects.
--   Never trust the client for *rewards* — see README → server contract.
--
-- SIGNALS OUT (all fire-and-forget, index-matched; see README):
--   RoundComplete [1]level [2]score [3]stars [4]coins [5]hits
--   SubmitHighScore [1]best
--   Purchase [1]itemCode [2]newTier
--   SubmitWallet [1]coins [2]unlocked [3]best [4]plays [5]smashes
--                [6]upgTime [7]upgGold [8]upgCombo
-------------------------------------------------------------------------------

local Player = Enum.CustomVariableEntityType.Player
local V = {
    coins = "SmashCoins",
    unlocked = "SmashUnlocked",
    best = "BestScore",
    plays = "SmashPlays",
    smashes = "SmashSmashes",
    upgTime = "SmashUpgTime",
    upgGold = "SmashUpgGold",
    upgCombo = "SmashUpgCombo",
}

-- Upgrade catalogue. Keep ids/costs aligned with the README shop table and
-- with the script variables on the Shop screen's script mapping.
local UPGRADES = {
    time  = { code = 1, costs = { 60, 150, 320 } },
    gold  = { code = 2, costs = { 80, 180, 400 } },
    combo = { code = 3, costs = { 70, 160, 350 } },
}
local MAX_TIER = 3

local state = {
    coins = 0,
    unlocked = 1,
    best = 0,
    plays = 0,
    smashes = 0,
    tiers = { time = 0, gold = 0, combo = 0 },
}

-- Per-level best scores are session-only (Custom Variables are scalars and
-- twelve more editor variables is a steep setup cost). Aggregate best and
-- unlock progress DO persist; with a node graph you can also persist these.
local bestByLevel = {}
local lastCoins, lastNewBest = 0, false

local function helpers()
    local root = game.FindClientUIRoot("SmashGarden")
    local h = root and root:GetScriptByPath("minigame/helpers")
    if h and h.alive then return h end
    return nil
end

local function num(name, fallback)
    local v = tonumber(game.GetGlobalCustomVariableValue(Player, name))
    if v == nil then return fallback end
    return v
end

local function readAll()
    state.coins = num(V.coins, 0)
    state.unlocked = math.max(1, num(V.unlocked, 1))
    state.best = num(V.best, 0)
    state.plays = num(V.plays, 0)
    state.smashes = num(V.smashes, 0)
    state.tiers.time = math.max(0, math.min(MAX_TIER, num(V.upgTime, 0)))
    state.tiers.gold = math.max(0, math.min(MAX_TIER, num(V.upgGold, 0)))
    state.tiers.combo = math.max(0, math.min(MAX_TIER, num(V.upgCombo, 0)))
end

local function snapshot()
    local sig = game.ServerSignal("SubmitWallet")
    sig:AddInt(state.coins)
    sig:AddInt(state.unlocked)
    sig:AddInt(state.best)
    sig:AddInt(state.plays)
    sig:AddInt(state.smashes)
    sig:AddInt(state.tiers.time)
    sig:AddInt(state.tiers.gold)
    sig:AddInt(state.tiers.combo)
    sig:SendSignal()
end

local function watch(varName, apply)
    script:RegisterCustomVariableChangedHandler(Player, varName, function(_, name)
        -- Server echo wins: only overwrite when a value actually exists.
        if name ~= varName then return end
        local v = tonumber(game.GetGlobalCustomVariableValue(Player, varName))
        if v ~= nil then apply(v) end
    end)
end

function OnInit()
    -- Nothing to read here yet: Custom Variables are readable in OnStart,
    -- and keeping engine reads out of OnInit makes lifecycle failures obvious.
end

function OnStart()
    readAll()

    watch(V.coins, function(v) state.coins = math.max(0, v) end)
    watch(V.unlocked, function(v) state.unlocked = math.max(1, v) end)
    watch(V.best, function(v) state.best = math.max(0, v) end)
    watch(V.plays, function(v) state.plays = math.max(0, v) end)
    watch(V.smashes, function(v) state.smashes = math.max(0, v) end)
    watch(V.upgTime, function(v) state.tiers.time = math.max(0, math.min(MAX_TIER, v)) end)
    watch(V.upgGold, function(v) state.tiers.gold = math.max(0, math.min(MAX_TIER, v)) end)
    watch(V.upgCombo, function(v) state.tiers.combo = math.max(0, math.min(MAX_TIER, v)) end)

    -- Announce a coherent snapshot so a server graph can seed itself.
    snapshot()
    print(string.format("[wallet] coins=%d unlocked=%d best=%d", state.coins, state.unlocked, state.best))
end

-------------------------------------------------------------------------------
-- Read API (single primitive return values — safe across script:Invoke)
-------------------------------------------------------------------------------

function GetCoins()    return state.coins end
function GetUnlocked() return state.unlocked end
function GetBest()     return state.best end
function GetPlays()    return state.plays end
function GetSmashes()  return state.smashes end
function GetTierMax()  return MAX_TIER end

function GetUpgrade(id)
    return state.tiers[id] or 0
end

-- Next price for an upgrade, or 0 when it is maxed.
function GetCost(id)
    local def = UPGRADES[id]
    if not def then return 0 end
    local tier = state.tiers[id] or 0
    return def.costs[tier + 1] or 0
end

function GetBestForLevel(levelId)
    return bestByLevel[tonumber(levelId) or 0] or 0
end

function GetLastCoins() return lastCoins end
function WasNewBest()   return lastNewBest end

function GetDebugLine()
    return string.format("coins=%d unlocked=%d best=%d plays=%d smashes=%d t=%d g=%d c=%d",
        state.coins, state.unlocked, state.best, state.plays, state.smashes,
        state.tiers.time, state.tiers.gold, state.tiers.combo)
end

-------------------------------------------------------------------------------
-- Write API
-------------------------------------------------------------------------------

-- Returns exactly one of "ok", "max", "poor" (one return value, by design).
function Purchase(id)
    local def = UPGRADES[id]
    if not def then
        printerr("[wallet] unknown upgrade id: " .. tostring(id))
        return "poor"
    end
    local tier = state.tiers[id] or 0
    if tier >= MAX_TIER then return "max" end
    local cost = def.costs[tier + 1] or 0
    if state.coins < cost then return "poor" end

    state.coins = state.coins - cost
    state.tiers[id] = tier + 1

    local sig = game.ServerSignal("Purchase")
    sig:AddInt(def.code)
    sig:AddInt(tier + 1)
    sig:SendSignal()
    snapshot()
    print(string.format("[wallet] bought %s tier %d for %d", id, tier + 1, cost))
    return "ok"
end

local function levelCount()
    local root = game.FindClientUIRoot("SmashGarden")
    local ld = root and root:GetScriptByPath("minigame/level_data")
    if ld and ld.alive then return ld:Invoke("GetLevelCount") end
    return 1
end

-- Called once per finished round by game_flow. Applies rewards locally,
-- fires the analytics/economy signals, and remembers the last pay-out for
-- the results panel (getters above — no multiple return values).
function RecordRound(levelId, score, stars, hits)
    levelId = tonumber(levelId) or 1
    score = tonumber(score) or 0
    stars = tonumber(stars) or 0
    hits = tonumber(hits) or 0

    local h = helpers()
    lastCoins = (h and h:Invoke("CoinsFor", score, stars)) or 0
    lastNewBest = score > state.best

    state.coins = state.coins + lastCoins
    state.plays = state.plays + 1
    state.smashes = state.smashes + hits
    if lastNewBest then state.best = score end
    if score > (bestByLevel[levelId] or 0) then bestByLevel[levelId] = score end

    -- Clearing a patch unlocks the next one. Only a *new* clear extends the
    -- unlock frontier; replaying early levels never jumps the queue.
    if stars >= 1 and levelId + 1 > state.unlocked then
        state.unlocked = math.min(levelCount(), levelId + 1)
    end

    local complete = game.ServerSignal("RoundComplete")
    complete:AddInt(levelId)
    complete:AddInt(score)
    complete:AddInt(stars)
    complete:AddInt(lastCoins)
    complete:AddInt(hits)
    complete:SendSignal()

    if lastNewBest then
        local best = game.ServerSignal("SubmitHighScore")
        best:AddInt(state.best)
        best:SendSignal()
    end
    snapshot()
end
