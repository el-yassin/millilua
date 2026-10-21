-------------------------------------------------------------------------------
-- helpers.lua — the shared pure-function library of Smash Garden.
--
-- ATTACHED TO: the root container "SmashGarden" (alongside director.lua,
-- wallet.lua, game_flow.lua and level_data.lua).
--
-- MiliLua has no require-style module loader in the documented API. The
-- supported way to share code between script instances is: attach a script
-- to a control, reach it via GetScriptByPath and call its global functions
-- with script:Invoke. This file is that shared library.
--
-- RULES:
--   * PURE. No state, no UI references, no engine calls. Every function is
--     deterministic input -> output, which makes the whole economy testable.
--   * EVERY caller checks helpers.alive before Invoke (see director/wallet).
--   * ONE RETURN VALUE per function. Cross-script Invoke return marshalling
--     for multiple values is not part of the documented API; keep it to one.
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Text with embedded English fallbacks.
--
-- game.GetText returns the KEY ITSELF when a stage has no Text Mapping entry
-- for it. That makes a zero-setup stage readable: every visible string has a
-- built-in English default here, and a mapped/localized value (when the stage
-- provides one) always wins. One function, so the fallback table exists once.
--
-- Text(key [, a [, b [, c]]]) — string.format is applied only when at least
-- one argument is passed; callers always pass the full argument set their
-- format string needs.
-------------------------------------------------------------------------------

local TEXT = {
    -- HUD / round
    ["minigame.score"]       = "Score: %d",
    ["minigame.combo"]       = "Combo: %d",
    ["minigame.best"]        = "Best: %d",
    ["minigame.final_score"] = "Final Score: %d",
    ["minigame.stats"]       = "Hits: %d  Misses: %d  Best Combo: %d",
    ["minigame.countdown"]   = "%d",
    ["minigame.go"]          = "GO!",
    ["minigame.fever"]       = "FEVER!",
    ["minigame.bomb"]        = "-15",
    ["minigame.time_bonus"]  = "+3s",
    ["minigame.hud_level"]   = "Level %d — Target %d",
    ["minigame.coins"]       = "Coins: %d",
    -- title / menus
    ["minigame.title"]       = "SMASH GARDEN",
    ["minigame.subtitle"]    = "Whack your way to a perfect harvest!",
    ["minigame.press_start"] = "Press Start",
    ["minigame.play"]        = "Play",
    ["minigame.shop"]        = "Garden Shop",
    ["minigame.stats_title"] = "Garden Records",
    ["minigame.back"]        = "Back",
    -- level select
    ["minigame.level_select"] = "Choose a Patch",
    ["minigame.level_locked"] = "Locked",
    ["minigame.level.name.1"]  = "First Sprouts",
    ["minigame.level.name.2"]  = "Golden Hour",
    ["minigame.level.name.3"]  = "Silver Lining",
    ["minigame.level.name.4"]  = "Weedy Business",
    ["minigame.level.name.5"]  = "Time Thief",
    ["minigame.level.name.6"]  = "Pressure Pot",
    ["minigame.level.name.7"]  = "Combo Garden",
    ["minigame.level.name.8"]  = "Bomb Squad",
    ["minigame.level.name.9"]  = "Golden Rush",
    ["minigame.level.name.10"] = "Marathon Patch",
    ["minigame.level.name.11"] = "Perfect Patch",
    ["minigame.level.name.12"] = "Grand Harvest",
    -- shop
    ["minigame.shop.time_name"]  = "Longer Rounds",
    ["minigame.shop.time_desc"]  = "+2s per round",
    ["minigame.shop.gold_name"]  = "Golden Touch",
    ["minigame.shop.gold_desc"]  = "+1 golden target value",
    ["minigame.shop.combo_name"] = "Combo Master",
    ["minigame.shop.combo_desc"] = "Fever starts 1 combo earlier",
    ["minigame.shop.tier"]       = "Lv %d/%d",
    ["minigame.shop.max"]        = "MAX",
    ["minigame.shop.price"]      = "%d",
    -- stats
    ["minigame.stats.cleared"] = "Patches cleared: %d/%d",
    ["minigame.stats.rounds"]  = "Rounds played: %d",
    ["minigame.stats.smashes"] = "Total smashes: %d",
    ["minigame.stats.best"]    = "Best score: %d",
    -- results
    ["minigame.results_title"] = "Harvest Report",
    ["minigame.complete"]      = "Patch cleared!",
    ["minigame.failed"]        = "Target missed — try again!",
    ["minigame.coins_earned"]  = "+%d coins",
    ["minigame.new_best"]      = "NEW BEST!",
    ["minigame.next"]          = "Next",
    ["minigame.replay"]        = "Replay",
    ["minigame.menu"]          = "Menu",
    -- pause
    ["minigame.paused"]        = "Paused",
    ["minigame.pause.resume"]  = "Resume",
    ["minigame.pause.restart"] = "Restart",
    ["minigame.pause.quit"]    = "Quit",
}

function Text(key, a, b, c)
    local s = game.GetText(key)
    if s == key then s = TEXT[key] or key end -- unmapped: fall back to English
    if a == nil then return s end
    return string.format(s, a, b or 0, c or 0)
end

-- Combo tier: +1 per 5 combo, capped at x5.
function GetMultiplier(combo)
    return math.min(5, 1 + math.floor((tonumber(combo) or 0) / 5))
end

-- Base points for the next hit at this combo (before target kind / fever).
function PointsFor(combo)
    return 10 * GetMultiplier(combo)
end

-- "Longer Rounds" shop upgrade: +2s per tier, clamped to sane round bounds.
function AdjustedDuration(base, tier)
    local d = (tonumber(base) or 30) + 2 * (tonumber(tier) or 0)
    return math.max(5, math.min(300, d))
end

-- "Golden Touch" shop upgrade: +1 to the golden target multiplier per tier.
-- The templates report 5; the cap keeps a corrupted payload harmless.
function GoldenMultiplier(base, tier)
    local m = (tonumber(base) or 5) + (tonumber(tier) or 0)
    return math.max(1, math.min(10, m))
end

-- "Combo Master" shop upgrade: fever starts 1 combo earlier per tier.
function FeverThreshold(base, tier)
    local t = (tonumber(base) or 10) - (tonumber(tier) or 0)
    return math.max(4, t)
end

-- 0..3 stars for a score against a level's three thresholds.
function StarsFor(score, target, silver, gold)
    score = tonumber(score) or 0
    if score >= (tonumber(gold) or math.huge) then return 3 end
    if score >= (tonumber(silver) or math.huge) then return 2 end
    if score >= (tonumber(target) or math.huge) then return 1 end
    return 0
end

-- Coins paid for a run: every 20 points is a coin, plus a star bonus.
function CoinsFor(score, stars)
    local s = math.max(0, math.min(3, tonumber(stars) or 0))
    return math.floor(math.max(0, tonumber(score) or 0) / 20) + 5 * s
end

-- "★★☆" — glyphs, not language: no Text Mapping entry needed.
function FormatStars(stars)
    local s = math.max(0, math.min(3, tonumber(stars) or 0))
    return string.rep("★", s) .. string.rep("☆", 3 - s)
end
