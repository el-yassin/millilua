-------------------------------------------------------------------------------
-- helpers.lua — the "shared library" of the minigame.
--
-- ATTACHED TO: the root container "SmashGarden" (alongside director.lua).
--
-- PATTERN TOUR:
--   [SHARED CODE]   MiliLua has Module-type scripts, but the reference does
--                   not document a require-style loader. The VERIFIED way to
--                   share code between script instances is: attach a script
--                   to a control, then reach it via GetScriptByPath and call
--                   its global functions with script:Invoke. That's what
--                   this file is — a poor man's stdlib.
--   [PURE FUNCS]    no state, no UI refs: safe to call from anywhere.
--   [ALIVE CHECK]   every caller checks helpers.alive before Invoke.
-------------------------------------------------------------------------------

-- Combo multiplier: +1 per 5 combo, capped at x5.
function GetMultiplier(combo)
    return math.min(5, 1 + math.floor(combo / 5))
end

function PointsFor(combo)
    return 10 * GetMultiplier(combo)
end
