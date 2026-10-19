-------------------------------------------------------------------------------
-- target.lua — one whackable target ("mole").
--
-- ATTACHED TO: the Target control TEMPLATE (the one the director spawns via
-- game.InstantiateClientUIControl). Every spawned instance runs its own copy
-- of this script — that's the mental model: template = class, instance = object.
--
-- [GOLDEN TARGET] (exercise 4) The SAME script is mapped onto BOTH templates
-- (normal + golden). The golden template's mapping just sets
-- PointsMultiplier=5. The rule lives with the template, not in the director:
-- adding a third variant (silver? explosive?) = duplicate the template,
-- change two script vars, done. Zero Lua changes.
--
-- PATTERN TOUR:
--   [SELF-CONTAINED]   the target manages its own click reaction + scoring
--   [SCRIPT VARS]      per-template behavior via GetParam (PointsMultiplier)
--   [EVENT]            AddCursorEventListener with a CursorEventData payload
--   [TWEEN CHAIN]      squish on click -> director is told to clean up
--   [ALIVE CHECK]      script.alive guard before every cross-script Invoke
-------------------------------------------------------------------------------

-- Per-template tuning from the Script Mapping menu. Read in OnInit, not at
-- top level: the mapping is only guaranteed loaded by then.
local POINTS_MULTIPLIER = 1

-- Tiny debounce: a fast double-click shouldn't double-score. The director
-- removes the target from its live list on the first hit, but the squish
-- tween below takes a moment, and clicks during it are still delivered.
local hit = false

local function getDirector()
    -- The director hangs off the root container, which every control can
    -- reach by name regardless of depth in the hierarchy.
    local root = game.FindClientUIRoot("SmashGarden")
    if not root then return nil end
    local dir = root:GetScriptByPath("minigame/director")
    if dir and dir.alive then return dir end
    return nil
end

local function onClick(_eventData)
    if hit then return end
    hit = true

    local self_ = script.object
    if not self_ or not self_.alive then return end

    -- Stop eating clicks immediately: the corpse below shrinks for ~0.18s
    -- and shouldn't swallow the next click aimed at a fresh target.
    self_.raycastTarget = false

    -- Report the kill BEFORE animating: the director drops us from its
    -- live list immediately (a second click can't double-score, the
    -- round-end sweep can't despawn us twice) and kills our pop-in tween
    -- if it's still running — otherwise the squish below would tween the
    -- same LOCKED scale fields. We report our MULTIPLIER, not points:
    -- our worth is template data, the combo-based value is policy.
    local dir = getDirector()
    if not dir then
        printerr("[target] no live director to report hit to")
        return
    end
    dir:Invoke("OnTargetClicked", self_.id, POINTS_MULTIPLIER)

    -- Squish: X flattens, Y stretches, then we shrink away.
    -- WE own this animation — the director deliberately does NOT tween our
    -- scale when we report the hit (two tweens on one field = tween-lock
    -- conflict; fields are locked while a Tween plays).
    local seq = game.TweenSequence()
    seq:Append(game.Tween(self_, { localScaleX = 1.4, localScaleY = 0.4 }, 0.06))
    local shrink = game.Tween(self_, { localScaleX = 0, localScaleY = 0 }, 0.12)
    shrink:SetOnComplete(function()
        -- script.alive guards against the round ending mid-squish: the
        -- director sweeps leftover targets wholesale and may have already
        -- destroyed this control (and thus this script instance).
        if script.alive and self_.alive then
            game.DestroyClientUIControl(self_)
        end
    end)
    seq:Append(shrink)
    seq:Play()
end

function OnInit()
    POINTS_MULTIPLIER = tonumber(script:GetParam("PointsMultiplier")) or 1
end

function OnStart()
    -- CursorEventArea is a separate component type: the spawned control must
    -- HAVE one (add it in the editor template) or cursor events never fire.
    local area = script.object
    if not area then return end
    area:AddCursorEventListener(Enum.CursorEventType.CursorClick, onClick)
end

function OnDestroy()
    -- The control is being destroyed (teleport, round end, director cleanup).
    -- Listeners die with the control; the `hit` flag dies with the script
    -- instance. The squish TweenSequence in onClick is intentionally NOT
    -- killed: it completes in 0.18s (its OnComplete checks script.alive so
    -- it won't double-destroy). Killing mid-squish would freeze the corpse
    -- at half-squish.
end
