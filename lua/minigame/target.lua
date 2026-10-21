-------------------------------------------------------------------------------
-- target.lua — one whackable target.
--
-- ATTACHED TO: every Target control TEMPLATE (normal / silver / golden /
-- bomb / time — five templates, same script, different script vars).
-- Every spawned instance runs its own copy of this script: template = class,
-- instance = object.
--
-- SCRIPT VARIABLES (set per template in the Script Mapping menu):
--   Kind             1 normal, 2 silver, 3 golden, 4 bomb, 5 time
--   PointsMultiplier base point multiplier reported to the director
--                     (normal 1, silver 2, golden 5; ignored by bomb/time)
--
-- RESPONSIBILITIES: react to a click ONCE, tell the director what kind it
-- was, then play its own squish-and-die animation. The director owns all
-- scoring policy (combo, fever, upgrades, penalties); the template only
-- reports facts. The target also owns its death animation: the director
-- never tweens a target's scale after the hit is reported (two tweens on
-- one field would fight over the engine's field lock).
-------------------------------------------------------------------------------

local KIND = 1
local POINTS_MULTIPLIER = 1

-- One-shot guard: the director drops us from its live list on the first
-- report, but the squish animation takes a moment and clicks during it are
-- still delivered to this control.
local hit = false

local function getDirector()
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
    -- and must not swallow the next click aimed at a fresh target.
    self_.raycastTarget = false

    -- Report BEFORE animating (see header). Kind + multiplier travel up;
    -- the director adds combo/fever/upgrade policy.
    local dir = getDirector()
    if not dir then
        printerr("[target] no live director to report hit to")
        return
    end
    dir:Invoke("OnTargetClicked", self_.id, KIND, POINTS_MULTIPLIER)

    -- Squish: X flattens, Y stretches, then we shrink away. WE own this
    -- animation — the director deliberately does not tween us after the hit.
    local seq = game.TweenSequence()
    seq:Append(game.Tween(self_, { localScaleX = 1.4, localScaleY = 0.4 }, 0.06))
    local shrink = game.Tween(self_, { localScaleX = 0, localScaleY = 0 }, 0.12)
    shrink:SetOnComplete(function()
        -- script.alive guards a round ending mid-squish: the director sweeps
        -- leftover targets wholesale and may have destroyed this control.
        if script.alive and self_.alive then
            game.DestroyClientUIControl(self_)
        end
    end)
    seq:Append(shrink)
    seq:Play()
end

function OnInit()
    KIND = tonumber(script:GetParam("Kind")) or 1
    POINTS_MULTIPLIER = tonumber(script:GetParam("PointsMultiplier")) or 1
end

function OnStart()
    -- The template root must have a CursorEventArea component or cursor
    -- events never fire.
    local area = script.object
    if not area then return end
    area:AddCursorEventListener(Enum.CursorEventType.CursorClick, onClick)
end

function OnDestroy()
    -- Listeners and the `hit` flag die with the script instance. The squish
    -- sequence is intentionally not killed: it completes in 0.18s and its
    -- OnComplete is script.alive-guarded.
end
