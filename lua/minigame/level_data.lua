-------------------------------------------------------------------------------
-- level_data.lua — the game's content tables (pure data + tiny accessors).
--
-- ATTACHED TO: the root container "SmashGarden".
--
-- Everything that defines HOW a level plays lives here: duration, medal
-- thresholds, spawn pressure, how many targets may coexist, and the spawn
-- weights of the five target kinds. Tuning the game = editing numbers in
-- this file; not one line of game logic needs to change.
--
-- TARGET KINDS (codes are passed to target.lua as the `Kind` script var and
-- reported back to the director on every hit):
--   1 normal   — 1x value, standard lifetime
--   2 silver   — 2x value
--   3 golden   — 5x value (+ shop tier), short lifetime, pops bigger
--   4 bomb     — breaks the combo and costs points; longer lifetime
--   5 time     — +3 seconds on the clock
--
-- WEIGHTS are integer percentages and MUST sum to 100 per level. A kind
-- with weight 0 never spawns. Level 1 is all-normal on purpose: it is the
-- tutorial patch, and it makes automated tests deterministic.
-------------------------------------------------------------------------------

local LEVELS = {
    -- id, duration, target/silver/gold, spawnStart, spawnMin, maxActive, weights {normal, silver, golden, bomb, time}
    { duration = 30, target =  80, silver = 150, gold = 240, spawnStart = 1.00, spawnMin = 0.55, maxActive = 3, weights = { 100, 0,  0,  0, 0 } },
    { duration = 30, target = 120, silver = 220, gold = 340, spawnStart = 0.95, spawnMin = 0.50, maxActive = 3, weights = {  82, 0, 18,  0, 0 } },
    { duration = 32, target = 160, silver = 300, gold = 450, spawnStart = 0.90, spawnMin = 0.50, maxActive = 3, weights = {  70, 20, 10,  0, 0 } },
    { duration = 32, target = 180, silver = 330, gold = 500, spawnStart = 0.90, spawnMin = 0.45, maxActive = 3, weights = {  65, 15, 12,  8, 0 } },
    { duration = 28, target = 170, silver = 320, gold = 480, spawnStart = 0.90, spawnMin = 0.45, maxActive = 3, weights = {  58, 15, 12,  5, 10 } },
    { duration = 30, target = 220, silver = 400, gold = 600, spawnStart = 0.75, spawnMin = 0.35, maxActive = 4, weights = {  60, 18, 12, 10, 0 } },
    { duration = 35, target = 260, silver = 480, gold = 720, spawnStart = 0.85, spawnMin = 0.40, maxActive = 4, weights = {  55, 20, 15,  5, 5 } },
    { duration = 32, target = 240, silver = 430, gold = 650, spawnStart = 0.75, spawnMin = 0.35, maxActive = 4, weights = {  50, 18, 12, 20, 0 } },
    { duration = 30, target = 280, silver = 520, gold = 800, spawnStart = 0.70, spawnMin = 0.32, maxActive = 4, weights = {  40, 18, 30,  7, 5 } },
    { duration = 45, target = 350, silver = 650, gold = 950, spawnStart = 0.80, spawnMin = 0.35, maxActive = 5, weights = {  55, 18, 15,  7, 5 } },
    { duration = 25, target = 260, silver = 450, gold = 650, spawnStart = 0.65, spawnMin = 0.30, maxActive = 5, weights = {  45, 20, 20, 10, 5 } },
    { duration = 40, target = 420, silver = 780, gold = 1150, spawnStart = 0.60, spawnMin = 0.28, maxActive = 5, weights = { 40, 20, 25, 10, 5 } },
}

local DEFAULT = {
    duration = 30, target = 80, silver = 150, gold = 240,
    spawnStart = 1.0, spawnMin = 0.55, maxActive = 3,
    weights = { 100, 0, 0, 0, 0 },
}

local function level(id)
    id = tonumber(id) or 1
    return LEVELS[id] or DEFAULT
end

-- All accessors take a level id and return a primitive (string/number), which
-- is the safest thing to marshal across script:Invoke.

function GetLevelCount()
    return #LEVELS
end

function GetDuration(id)   return level(id).duration end
function GetTarget(id)     return level(id).target end
function GetSilver(id)     return level(id).silver end
function GetGold(id)       return level(id).gold end
function GetSpawnStart(id) return level(id).spawnStart end
function GetSpawnMin(id)   return level(id).spawnMin end
function GetMaxActive(id)  return level(id).maxActive end

-- kindCode: 1 normal, 2 silver, 3 golden, 4 bomb, 5 time
function GetWeight(id, kindCode)
    return level(id).weights[tonumber(kindCode) or 0] or 0
end

-- Human-readable level name key for Text Mapping (all 12 exist; see README).
function GetNameKey(id)
    return string.format("minigame.level.name.%d", tonumber(id) or 1)
end
