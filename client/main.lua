local scaleState = {}
local remoteAimState = {}
local lastApplied = {}
local appliedGroundOffsets = {}
local uiOpen = false
local previewScale = nil
local ownSavedScale = Config.Scale.Default
local damageByHash = nil
local lastShotAt = 0
local lastNativeDamageAt = 0
local suppressDamageObservationUntil = 0
local observedPed = 0
local observedHealth = nil
local observedArmor = nil

local function scaleDefaults()
    local default = tonumber(Config.Scale.Default) or 1.0
    local minScale = tonumber(Config.Scale.Min) or 0.87
    local maxScale = tonumber(Config.Scale.Max) or 1.10
    if minScale > maxScale then
        minScale, maxScale = maxScale, minScale
    end
    return default, minScale, maxScale
end

local function clampScale(scale)
    local default, minScale, maxScale = scaleDefaults()
    local value = tonumber(scale) or default
    if value < minScale then value = minScale end
    if value > maxScale then value = maxScale end
    return math.floor((value * 100.0) + 0.5) / 100.0
end

local function isDefaultScale(scale)
    local default = scaleDefaults()
    return math.abs((tonumber(scale) or default) - default) < 0.001
end

-- ---------------------------------------------------------------------------
-- v45 forward declarations.
--
-- Lua binds a free name at COMPILE time. `local function f` at line 980 is not
-- in scope for a function body written at line 470 -- that body resolves `f`
-- as a GLOBAL, which is nil. v40-v44 had exactly that bug: applyMatrixScale
-- guarded on `shortTacklePhysicsActive and shortTacklePhysicsActive()`, the
-- name was nil, and the `and` silently swallowed it, so the tackle isolation
-- branch never ran once. Declaring the locals up front binds them correctly.
-- ---------------------------------------------------------------------------
local shortTacklePhysicsActive
local isPedDowned

-- ---------------------------------------------------------------------------
-- v45 downed / last-stand detection.
--
-- Medical resources (qbx_medical, sc-ambulance, qb-ambulancejob) do NOT leave
-- a downed player's ped dead. They call NetworkResurrectLocalPlayer and set a
-- non-zero health so the ped can play a bleed-out animation, which means
-- IsEntityDead() is FALSE for the whole last-stand window and often for the
-- fully-dead window too.
--
-- Config.Scale.DisableWhenDead relied on IsEntityDead alone, so the scaler
-- kept ground-anchoring a prone body and the hitbox guard kept treating a
-- bleeding-out player as a live target -- letting a downed player be finished
-- off and skipping the EMS revive window entirely.
--
-- This only READS state other resources already publish. It modifies nothing
-- outside this resource.
-- ---------------------------------------------------------------------------
local function stateFlagSet(bag, flags)
    if not bag then return false end
    -- One pcall around the whole read, not one per flag: statebag indexing can
    -- throw for a player that has just disconnected.
    local ok, hit = pcall(function()
        for _, flag in ipairs(flags or {}) do
            if bag[flag] then return true end
        end
        return false
    end)
    return ok and hit or false
end

-- Statebag reads are comparatively expensive and isPedDowned runs per ped per
-- frame from shouldScalePed. Cache ONLY the statebag half; the native checks
-- (IsEntityDead / IsPedFatallyInjured / health) are cheap and stay live so the
-- safety-critical "do not finish off a downed player" gate is never stale.
local downedStateCache = {}
local DOWNED_STATE_TTL_MS = 120

local function downedByStatebag(serverId)
    local now = GetGameTimer()
    local entry = downedStateCache[serverId]
    if entry and (now - entry.at) <= DOWNED_STATE_TTL_MS then
        return entry.value
    end

    local compat = Config.Compat or {}
    local value
    if serverId == GetPlayerServerId(PlayerId()) then
        value = stateFlagSet(LocalPlayer and LocalPlayer.state, compat.LocalStateFlags)
    else
        local ok, bag = pcall(function() return Player(serverId).state end)
        value = ok and stateFlagSet(bag, compat.PlayerStateFlags) or false
    end

    downedStateCache[serverId] = { at = now, value = value }
    return value
end

isPedDowned = function(ped, serverId)
    local compat = Config.Compat or {}

    if ped ~= 0 and DoesEntityExist(ped) then
        if IsEntityDead(ped) then return true end

        if compat.UseIsPedFatallyInjured ~= false then
            local ok, injured = pcall(IsPedFatallyInjured, ped)
            if ok and injured then return true end
        end

        local threshold = tonumber(compat.DownedHealthThreshold) or 1
        local health = GetEntityHealth(ped)
        if health and health <= threshold then return true end
    end

    if serverId then return downedByStatebag(serverId) end
    return false
end

local function notify(message)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, false)
end

RegisterNetEvent('crimson-pedscale:client:notify', function(message, kind)
    local prefix = Config.Notifications.Prefix or 'Crimson Ped Scale'
    notify(('%s: %s'):format(prefix, message))

    if Config.Notifications.UseChat then
        local color = kind == 'error' and { 220, 65, 65 } or { 190, 32, 48 }
        TriggerEvent('chat:addMessage', {
            color = color,
            args = { prefix, message }
        })
    end
end)

local function ownServerId()
    return GetPlayerServerId(PlayerId())
end

local function effectiveScale(serverId)
    if uiOpen and previewScale and serverId == ownServerId() then
        return previewScale
    end
    return scaleState[serverId] or Config.Scale.Default
end

local function normalizeVector(vec)
    local length = math.sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
    if length <= 0.0001 then return vec end
    return vector3(vec.x / length, vec.y / length, vec.z / length)
end

local groundZCache = {}

-- v19: Keep matrix scaling active during vaults/climbs, but stop forcing the
-- entity root onto our ground ray while GTA is performing a vertical traversal.
-- Ground anchoring during these tasks fights the native animation/collision and
-- causes the visible stair/vault stutter.
local traversalState = {}

local function isVerticalTraversal(ped, serverId)
    local now = GetGameTimer()
    local ground = Config.Scale.Grounding or {}
    local holdMs = tonumber(ground.TraversalReleaseDelayMs) or 260

    local active = IsPedClimbing(ped)
        or IsPedVaulting(ped)
        or IsPedJumping(ped)
        or IsPedFalling(ped)
        or IsPedRagdoll(ped)
        or IsPedGettingUp(ped)
        -- v31 tackle/physics fix: tackle scripts can put a ped into a real
        -- airborne physics state before GTA reports IsPedJumping/Falling.
        -- Release root-Z control immediately whenever the entity is airborne
        -- so the tackle leap/ragdoll is driven by native GTA physics.
        or IsEntityInAir(ped)

    if active then
        if serverId then traversalState[serverId] = now + holdMs end
        return true
    end

    if serverId and (traversalState[serverId] or 0) > now then
        return true
    end

    return false
end

local function isWalkableGroundNormal(normal, minNormalZ)
    if not normal then return false end
    return (normal.z or 0.0) >= minNormalZ
end

local function groundRay(ped, x, y, top, bottom, flags, minNormalZ, rootZ, minBelowRoot)
    local ray = StartShapeTestRay(x, y, top, x, y, bottom, flags, ped, 0)
    local _, hit, hitPos, surfaceNormal = GetShapeTestResult(ray)
    if hit == 1 and hitPos and isWalkableGroundNormal(surfaceNormal, minNormalZ) then
        -- v27: A valid floor must be BELOW the ped's entity/root origin.
        -- The old ray began 2m above the root, so MLO ceilings/doorway geometry
        -- could be returned as a "walkable" horizontal surface before the real
        -- floor. The doorway diagnostic caught exactly that: ped Z ~43.28 while
        -- the alleged ground jumped to 44.74/45.28. Reject such impossible hits.
        if rootZ and hitPos.z > (rootZ - (minBelowRoot or 0.35)) then
            return nil
        end
        return hitPos.z
    end
    return nil
end

-- v45 ground-ray cache.
--
-- desiredRootZ called getGroundZUnderPed every frame for every scaled ped in
-- render range, and each call issues up to FOUR StartShapeTestRay probes. With
-- a handful of scaled players in view that is dozens of synchronous probes per
-- frame, every frame, with no reuse.
--
-- Cache the result per ped and only re-probe when the ped has moved
-- horizontally by more than a few centimetres or the entry has aged out. A
-- stationary ped reuses its floor height; a moving one re-probes promptly.
local groundRayCache = {}
local GROUND_CACHE_TTL_MS = 90
local GROUND_CACHE_MAX_MOVE = 0.10

local function cachedGroundZ(ped, position, probeFn)
    local now = GetGameTimer()
    local entry = groundRayCache[ped]

    if entry and (now - entry.at) <= GROUND_CACHE_TTL_MS then
        local dx = position.x - entry.x
        local dy = position.y - entry.y
        if ((dx * dx) + (dy * dy)) <= (GROUND_CACHE_MAX_MOVE * GROUND_CACHE_MAX_MOVE)
            and math.abs(position.z - entry.rootZ) <= 0.75 then
            return entry.groundZ
        end
    end

    local value = probeFn(ped, position)
    groundRayCache[ped] = {
        at = now, x = position.x, y = position.y, rootZ = position.z, groundZ = value
    }
    return value
end

local function probeGroundZUnderPed(ped, position)
    local ground = Config.Scale.Grounding or {}
    -- v21 doorway fix: doors, frames and threshold props are OBJECT collisions.
    -- When OBJECT and WORLD are tested together, Pillbox-style doors can win the
    -- ray for a frame and then lose it on the next frame. That makes the scaled
    -- root oscillate vertically and the gameplay camera rapidly zoom in/out.
    -- Always prefer real map/world collision first. Only fall back to objects
    -- when there genuinely is no world floor beneath the ped.
    local x = position.x
    local y = position.y
    -- v27 doorway root fix: search DOWN from just above the ped root instead
    -- of from 2m overhead. A freemode ped root sits roughly 1m above the soles,
    -- so there is no reason for a floor query to begin near ceiling/upper-MLO
    -- geometry. This prevents horizontal ceiling/doorway pieces from winning
    -- the ray before the actual floor beneath the player.
    local top = position.z + (tonumber(ground.RaycastRootHeadroom) or 0.18)
    local bottom = position.z - (tonumber(ground.RaycastBelow) or 3.0)
    local minNormalZ = tonumber(ground.MinWalkableSurfaceNormalZ) or 0.65
    local minBelowRoot = tonumber(ground.MinGroundBelowRoot) or 0.35

    -- 1 = world/map geometry. This ignores animated door props entirely.
    local worldZ = groundRay(ped, x, y, top, bottom, 1, minNormalZ, position.z, minBelowRoot)
    if worldZ ~= nil then
        return worldZ
    end

    local longBelow = tonumber(ground.FallbackRaycastBelow) or 6.0
    local longBottom = position.z - longBelow
    worldZ = groundRay(ped, x, y, top, longBottom, 1, minNormalZ, position.z, minBelowRoot)
    if worldZ ~= nil then
        return worldZ
    end

    -- 16 = object. Some custom/MLO floors can be object collision rather than
    -- world collision, so retain support for them, but ONLY if the hit surface
    -- points upward like a floor. Vertical doors/walls are rejected.
    local objectZ = groundRay(ped, x, y, top, bottom, 16, minNormalZ, position.z, minBelowRoot)
    if objectZ ~= nil then
        return objectZ
    end

    objectZ = groundRay(ped, x, y, top, longBottom, 16, minNormalZ, position.z, minBelowRoot)
    if objectZ ~= nil then
        return objectZ
    end

    local found, gz = GetGroundZFor_3dCoord(position.x, position.y, position.z, false)
    if found then return gz end

    return nil
end

-- Cached entry point. probeGroundZUnderPed is passed by value, so this never
-- forward-references a local.
local function getGroundZUnderPed(ped, position)
    return cachedGroundZ(ped, position, probeGroundZUnderPed)
end

-- Drop cache entries for peds that no longer exist. Ped handles are recycled,
-- so this is a size guard rather than a correctness one (TTL covers staleness).
local function pruneGroundRayCache()
    for ped in pairs(groundRayCache) do
        if not DoesEntityExist(ped) then groundRayCache[ped] = nil end
    end
end

CreateThread(function()
    while true do
        Wait(15000)
        pruneGroundRayCache()
    end
end)

local function desiredRootZ(ped, scale, position, serverId)
    local ground = Config.Scale.Grounding or {}
    local groundZ = getGroundZUnderPed(ped, position)
    if groundZ == nil then
        local cached = serverId and groundZCache[serverId]
        groundZ = cached or (position.z - (tonumber(ground.BaseRootHeight) or 1.0))
    elseif serverId then
        groundZCache[serverId] = groundZ
    end

    -- This is the important change in v7. Matrix scaling scales the visual ped
    -- around the entity origin, while GTA keeps its normal collision/root logic.
    -- Therefore an offset relative to last frame will always fight the engine.
    -- Anchor the entity root directly to the WORLD ground instead:
    --      rootZ = groundZ + scaled native root height + tiny sole clearance
    -- This is the same grounding principle used by the current open-source
    -- Nass ped scaler fix for floating/clipping.
    local baseRootHeight = tonumber(ground.BaseRootHeight) or 1.0
    local clearance = tonumber(ground.SoleClearance) or 0.04

    -- Keep the short-ped grounding from v7 untouched. Taller peds need a tiny
    -- downward calibration because the freemode visual soles do not scale
    -- perfectly 1:1 with the entity/root height. Blend it from 0 at 1.00 to
    -- TallMaxScaleCorrection at Config.Scale.Max so there is no hard jump.
    local tallCorrection = 0.0
    if scale > 1.0 then
        local maxScale = tonumber(Config.Scale.Max) or 1.10
        local range = math.max(0.001, maxScale - 1.0)
        local t = math.min(1.0, math.max(0.0, (scale - 1.0) / range))
        tallCorrection = (tonumber(ground.TallMaxScaleCorrection) or -0.025) * t
    end

    -- v12: .87 was still hovering for BOTH the owner and remote observers.
    -- Apply one shared short-scale calibration so every client anchors the
    -- same ped at the same apparent sole height. This blends from zero at
    -- 1.00 to ShortMaxScaleCorrection at the configured minimum scale.
    local shortCorrection = 0.0
    if scale < 1.0 then
        local minScale = tonumber(Config.Scale.Min) or 0.87
        local range = math.max(0.001, 1.0 - minScale)
        local t = math.min(1.0, math.max(0.0, (1.0 - scale) / range))
        shortCorrection = (tonumber(ground.ShortMaxScaleCorrection) or -0.025) * t
    end

    -- Kept for config compatibility, but defaults to zero in v12 so the local
    -- player does not get a second short-scale correction on top of the global
    -- one.
    local localShortCorrection = 0.0
    if serverId == ownServerId() and scale < 1.0 then
        local minScale = tonumber(Config.Scale.Min) or 0.87
        local range = math.max(0.001, 1.0 - minScale)
        local t = math.min(1.0, math.max(0.0, (1.0 - scale) / range))
        localShortCorrection = (tonumber(ground.LocalShortMaxCorrection) or 0.0) * t
    end

    -- Same local-vs-remote visual mismatch can happen on the tall end. Keep
    -- the global 1.10 grounding that already works for observers and lower
    -- only the owner's local render a tiny amount.
    local localTallCorrection = 0.0
    if serverId == ownServerId() and scale > 1.0 then
        local maxScale = tonumber(Config.Scale.Max) or 1.10
        local range = math.max(0.001, maxScale - 1.0)
        local t = math.min(1.0, math.max(0.0, (scale - 1.0) / range))
        localTallCorrection = (tonumber(ground.LocalTallMaxCorrection) or -0.012) * t
    end

    return groundZ + (baseRootHeight * scale) + clearance + tallCorrection + shortCorrection + localShortCorrection + localTallCorrection
end

-- v45: setScaledLegIk was an empty stub, so legIkDisabled was never populated
-- and its restore path in removeScale was unreachable. Both removed. The
-- absolute ground anchor already gives GTA a stable root to solve leg IK
-- against, which is why no IK toggling is needed.

local function setScaledMatrixAtZ(ped, scale, forward, right, up, position, z)
    SetEntityMatrix(
        ped,
        forward.x * scale, forward.y * scale, forward.z * scale,
        right.x * scale, right.y * scale, right.z * scale,
        up.x * scale, up.y * scale, up.z * scale,
        position.x, position.y, z
    )
end

local function applyMatrixScale(ped, scale, serverId)
    local forward, right, up, position = GetEntityMatrix(ped)
    if not forward or not right or not up or not position then return end

    forward = normalizeVector(forward)
    right = normalizeVector(right)
    up = normalizeVector(up)

    local ground = Config.Scale.Grounding or {}
    local cached = serverId and appliedGroundOffsets[serverId] or nil
    local appliedZ

    -- v28: remote peds need their own VISUAL ground anchor too. v25 stopped
    -- all remote Z correction to avoid doorway pops, but that left observers
    -- rendering a scaled skeleton around the native 1.00 root. The result was
    -- bent knees while idle and feet clipping through the floor while walking.
    --
    -- v27 fixed the real doorway bug in the ray itself (false floor hits ABOVE
    -- the ped root), so it is now safe to ground remote renders again. This is
    -- client-side SetEntityMatrix positioning only; it does not take network
    -- ownership or write the remote player's authoritative entity coordinates.
    if serverId ~= ownServerId() then
        -- v33 remote ledge handoff fix:
        -- Remote clients normally render a scaled ped at a visually corrected
        -- root Z that is different from the raw network/native root Z. The old
        -- traversal branch switched straight from correctedZ -> position.z the
        -- instant a remote ped became airborne. On a ledge drop that looked like
        -- a small teleport to observers even though the owner saw a normal fall.
        --
        -- For NON-ragdoll vertical traversal, capture the visual offset that was
        -- already being used on the last grounded frame and carry that SAME
        -- offset while following the networked Z. This preserves the native fall
        -- motion without a one-frame change of reference frame. After landing,
        -- ease back to the normal remote ground anchor.
        --
        -- Ragdolls/get-up states intentionally keep the v31/v32 raw-Z behavior;
        -- adding a standing visual offset to a horizontal ragdoll is what caused
        -- the earlier floating tackle bug.
        local ragdollPhysics = IsPedRagdoll(ped) or IsPedGettingUp(ped)
        local traversal = isVerticalTraversal(ped, serverId)

        if ragdollPhysics then
            appliedZ = position.z
            if cached then
                cached.remoteTraversalOffset = nil
                cached.remoteRegrounding = nil
            end
        elseif traversal then
            local offset
            if cached and cached.ped == ped and cached.remoteTraversalOffset ~= nil then
                offset = cached.remoteTraversalOffset
            elseif cached and cached.ped == ped and cached.rootZ then
                offset = cached.rootZ - position.z
                -- A visual scale correction should only be a small fraction of
                -- a metre. Clamp defensive outliers so a stale cache can never
                -- create a large remote displacement.
                local maxOffset = tonumber(ground.RemoteTraversalMaxOffset) or 0.22
                if offset > maxOffset then offset = maxOffset end
                if offset < -maxOffset then offset = -maxOffset end
            else
                offset = 0.0
            end

            appliedZ = position.z + offset
            if cached then
                cached.remoteTraversalOffset = offset
                cached.remoteRegrounding = true
            end
        else
            local targetZ = desiredRootZ(ped, scale, position, serverId)

            -- If we just came out of a ledge/jump/fall traversal, do not snap
            -- from the carried airborne visual offset straight to targetZ.
            -- Ease only this landing handoff; ordinary remote standing/walking
            -- continues to use the exact v28 grounding behavior.
            if cached and cached.ped == ped and cached.remoteRegrounding and cached.rootZ then
                local diff = targetZ - cached.rootZ
                local absDiff = math.abs(diff)
                local shortLanding = scale <= (tonumber(ground.ShortLandingScaleThreshold) or 0.92)
                local fallContinueThreshold = tonumber(ground.RemoteLandingContinueFallThreshold) or 0.18

                -- v39: a remote client can stop reporting IsEntityInAir/Falling
                -- one or two packets before the scaled visual ped has actually
                -- reached the landing surface. Treating that packet as a normal
                -- landing caused the very slow 1.5 cm/frame "hover down" seen on
                -- short (.87-ish) peds after bushes/ledges.
                --
                -- If the target floor is still meaningfully BELOW our rendered
                -- Z, keep using a fall-rate catch-up instead of the tiny landing
                -- correction. Once we are close to the floor, switch to a short
                -- critically-fast settle. There is never a hard Z snap.
                if diff < -fallContinueThreshold then
                    local dt = GetFrameTime()
                    if not dt or dt <= 0.0 or dt > 0.10 then dt = 1.0 / 60.0 end
                    local fallSpeed = shortLanding
                        and (tonumber(ground.ShortRemoteLandingCatchupSpeed) or 5.25)
                        or (tonumber(ground.RemoteLandingCatchupSpeed) or 4.50)
                    local minStep = tonumber(ground.RemoteLandingCatchupMinStep) or 0.018
                    local step = math.max(minStep, fallSpeed * dt)
                    appliedZ = math.max(targetZ, cached.rootZ - step)
                else
                    local alpha = shortLanding
                        and (tonumber(ground.ShortRemoteLandingSmoothing) or 0.62)
                        or (tonumber(ground.RemoteLandingSmoothing) or 0.28)
                    local maxStep = shortLanding
                        and (tonumber(ground.ShortRemoteLandingMaxCorrectionPerFrame) or 0.050)
                        or (tonumber(ground.RemoteLandingMaxCorrectionPerFrame) or 0.025)
                    local step = diff * alpha
                    if step > maxStep then step = maxStep end
                    if step < -maxStep then step = -maxStep end
                    appliedZ = cached.rootZ + step
                end

                local snapTolerance = shortLanding
                    and (tonumber(ground.ShortRemoteLandingSnapTolerance) or 0.012)
                    or (tonumber(ground.RemoteLandingSnapTolerance) or 0.006)
                if absDiff <= snapTolerance then
                    appliedZ = targetZ
                    cached.remoteTraversalOffset = nil
                    cached.remoteRegrounding = nil
                end
            else
                appliedZ = targetZ
            end
        end

        -- v38: stairs are still blended, but with a slightly longer response
        -- than v37. v37 caught up so aggressively that individual stair treads
        -- were still visible as tiny vertical jolts. This filter only runs on
        -- normal grounded movement and only across roughly one stair of delta,
        -- so it cannot accumulate the large floating/sinking error v36 caused.
        if not ragdollPhysics and not traversal and cached and cached.ped == ped and cached.rootZ then
            local diff = appliedZ - cached.rootZ
            local maxTerrainDelta = tonumber(ground.RemoteStairSmoothMaxDelta) or 0.28
            if math.abs(diff) > 0.001 and math.abs(diff) <= maxTerrainDelta then
                local dt = GetFrameTime()
                if not dt or dt <= 0.0 or dt > 0.10 then dt = 1.0 / 60.0 end
                local tau = diff >= 0.0 and (tonumber(ground.RemoteStairUpTimeConstant) or 0.050)
                    or (tonumber(ground.RemoteStairDownTimeConstant) or 0.055)
                local alpha = 1.0 - math.exp(-dt / math.max(tau, 0.001))
                local step = diff * alpha
                local maxSpeed = diff >= 0.0 and (tonumber(ground.RemoteStairMaxUpSpeed) or 4.0)
                    or (tonumber(ground.RemoteStairMaxDownSpeed) or 3.8)
                local maxStep = maxSpeed * dt
                if step > maxStep then step = maxStep end
                if step < -maxStep then step = -maxStep end
                appliedZ = cached.rootZ + step
            end
        end

        -- v38: do NOT rely only on IsEntityInAir/IsPedFalling for remote ledges.
        -- FiveM can deliver the observer a packet where the remote ped is already
        -- at the lower Z before those natives ever report a traversal state. In
        -- v37 that packet bypassed the fall smoother and produced the exact
        -- top-of-ledge -> bottom-of-ledge snap the observer was seeing.
        --
        -- Any substantial downward visual step (larger than a normal stair
        -- tread), or a detected traversal, is therefore treated as a ledge/fall
        -- packet and limited by metres-per-second. Small grounded stair changes
        -- stay in the stair filter above, so they cannot build vertical lag.
        if not ragdollPhysics and cached and cached.ped == ped and cached.rootZ then
            local down = appliedZ - cached.rootZ
            local minDrop = tonumber(ground.RemoteLedgeSmoothMinDrop) or 0.015
            local triggerDrop = tonumber(ground.RemoteLedgeTriggerDrop) or 0.24
            local maxDrop = tonumber(ground.RemoteLedgeSmoothMaxDrop) or 3.00
            local shouldSmoothFall = traversal or down <= -triggerDrop
            if shouldSmoothFall and down <= -minDrop and down >= -maxDrop then
                local dt = GetFrameTime()
                if not dt or dt <= 0.0 or dt > 0.10 then dt = 1.0 / 60.0 end
                local maxFallSpeed = tonumber(ground.RemoteLedgeVisualFallSpeed) or 3.6
                local maxStep = math.max(tonumber(ground.RemoteLedgeMinStepPerFrame) or 0.010, maxFallSpeed * dt)
                appliedZ = math.max(appliedZ, cached.rootZ - maxStep)
            end
        end

        setScaledMatrixAtZ(ped, scale, forward, right, up, position, appliedZ)

        -- v41 remote aim-pose sync:
        -- A scaled remote ped can visually keep a stale upper-body/weapon IK
        -- pose even though the owning player is aiming at the correct target.
        -- SetEntityMatrix changes the root transform after GTA has already
        -- evaluated the streamed animation pose for that frame. Force one
        -- animation/IK refresh only while that remote player is actively
        -- free-aiming or shooting, and explicitly keep arm/torso IK enabled.
        -- This changes presentation only; it does not create an aim task,
        -- rotate the ped, alter bullets, or touch hit/damage logic.
        local remotePlayer = GetPlayerFromServerId(serverId)
        if remotePlayer ~= -1 and (IsPlayerFreeAiming(remotePlayer) or IsPedShooting(ped)) then
            SetPedCanArmIk(ped, true)
            SetPedCanTorsoIk(ped, true)
            SetPedCanHeadIk(ped, true)
            ForcePedAiAndAnimationUpdate(ped, false, false)
        end

        if serverId then
            appliedGroundOffsets[serverId] = {
                ped = ped,
                rootZ = appliedZ,
                remoteTraversalOffset = cached and cached.remoteTraversalOffset or nil,
                remoteRegrounding = cached and cached.remoteRegrounding or nil
            }
        end
        return
    end

    -- No `and shortTacklePhysicsActive` nil-guard here on purpose: that guard is
    -- exactly what silently swallowed the v40-v44 forward-reference bug for four
    -- releases. The local is forward-declared at the top of the file, so if this
    -- ever regresses it should raise a visible error rather than quietly no-op.
    if serverId == ownServerId() and shortTacklePhysicsActive() then
        -- v40 tackle isolation: while a short local ped is tackling/being tackled,
        -- never feed the ped through stair, landing, ledge or ground correction.
        -- Preserve the native root exactly and let GTA own the ragdoll transform.
        appliedZ = position.z
    elseif isVerticalTraversal(ped, serverId) then
        -- Critical v19 behavior: preserve GTA's native root Z throughout a
        -- climb/vault/jump instead of dragging it toward the ground ray. The
        -- basis is still scaled every frame, so the player NEVER snaps to 1.00.
        appliedZ = position.z
    else
        local targetZ = desiredRootZ(ped, scale, position, serverId)
        local speed = GetEntitySpeed(ped)
        appliedZ = targetZ

        -- v25 doorway threshold dead-zone (LOCAL owner only).
        -- Some MLO doorways have a raised WORLD collision seam only a few cm
        -- above the surrounding floor. Accepting that as a real floor lifts the
        -- network-owned ped, which causes a local camera zoom and makes remote
        -- observers see the player hop into the air. Real GTA stair risers are
        -- substantially taller, so ignore these micro floor changes entirely
        -- while moving instead of accepting them after a timer.
        if cached and cached.ped == ped and cached.rootZ and speed > (tonumber(ground.SmoothingStartSpeed) or 0.20) then
            local microDeadband = tonumber(ground.DoorwayMicroDeadband) or 0.070
            local rawDiff = targetZ - cached.rootZ
            if math.abs(rawDiff) <= microDeadband then
                targetZ = cached.rootZ
                appliedZ = cached.rootZ
            end
        end

        if speed > (tonumber(ground.SmoothingStartSpeed) or 0.20) and cached and cached.ped == ped and cached.rootZ then
            local previousZ = cached.rootZ
            local diff = targetZ - previousZ
            local snapUp = tonumber(ground.SnapUpDistance) or 0.30
            local ledgeDrop = tonumber(ground.LedgeDropThreshold) or 0.22

            -- v20: If the ground suddenly disappears by more than a normal
            -- stair riser, DO NOT ease the matrix down to the lower surface.
            -- Hand Z control back to GTA so gravity can create the native
            -- short-fall / landing animation. IsPedFalling() will take over on
            -- the following frames and the normal traversal release delay keeps
            -- grounding disabled until the landing has settled.
            if diff <= -ledgeDrop then
                appliedZ = position.z
                if serverId then
                    traversalState[serverId] = GetGameTimer() + (tonumber(ground.LedgeReleaseDelayMs) or 450)
                end
            elseif math.abs(diff) > snapUp then
                appliedZ = targetZ
            else
                -- v38: use a middle ground between v36 (too much lag) and
                -- v37 (too fast to hide each tread). This is still time-based,
                -- so the feel does not change with FPS, but it blends a stair
                -- transition across several frames instead of exposing the ray
                -- cast's discrete tread-to-tread height change.
                local dt = GetFrameTime()
                if not dt or dt <= 0.0 or dt > 0.10 then dt = 1.0 / 60.0 end
                local tau = diff >= 0.0 and (tonumber(ground.LocalStairUpTimeConstant) or 0.060)
                    or (tonumber(ground.LocalStairDownTimeConstant) or 0.065)
                local alpha = 1.0 - math.exp(-dt / math.max(tau, 0.001))
                local step = diff * alpha
                local maxSpeed = diff >= 0.0 and (tonumber(ground.LocalStairMaxUpSpeed) or 3.20)
                    or (tonumber(ground.LocalStairMaxDownSpeed) or 3.00)
                local maxStep = maxSpeed * dt
                if step > maxStep then step = maxStep end
                if step < -maxStep then step = -maxStep end
                appliedZ = previousZ + step
            end
        end
    end

    setScaledMatrixAtZ(ped, scale, forward, right, up, position, appliedZ)

    if serverId then
        appliedGroundOffsets[serverId] = {
            ped = ped,
            rootZ = appliedZ,
            -- Preserve v22's short-lived doorway candidate across frames.
            pendingDoorwayZ = cached and cached.pendingDoorwayZ or nil,
            pendingDoorwaySince = cached and cached.pendingDoorwaySince or nil
        }
    end
end

local function clearMatrixScale(ped, serverId)
    -- Put the basis back to 1.00 once, then stop touching it so GTA resumes
    -- normal collision/animation placement.
    --
    -- v45: this used to write desiredRootZ(...) -- a freshly raycast GROUND
    -- ANCHOR -- rather than the ped's current Z. Because clearMatrixScale runs
    -- exactly when a ped stops qualifying for scaling (it died, entered a
    -- vehicle, got attached to a stretcher, or was frozen), that final write
    -- teleported the ped to the computed floor height. On a frozen or attached
    -- ped it displaced them permanently.
    --
    -- Restore the unit basis AT THE PED'S CURRENT POSITION, and skip entirely
    -- for peds we must not move.
    if ped == 0 or not DoesEntityExist(ped) then
        if serverId then
            appliedGroundOffsets[serverId] = nil
            groundZCache[serverId] = nil
            traversalState[serverId] = nil
        end
        return
    end

    if not IsEntityAttached(ped) and not IsEntityPositionFrozen(ped) then
        local forward, right, up, position = GetEntityMatrix(ped)
        if forward and right and up and position then
            forward = normalizeVector(forward)
            right = normalizeVector(right)
            up = normalizeVector(up)
            setScaledMatrixAtZ(ped, Config.Scale.Default, forward, right, up, position, position.z)
        end
    end

    if serverId then
        appliedGroundOffsets[serverId] = nil
        groundZCache[serverId] = nil
        traversalState[serverId] = nil
    end
end

local function shouldScalePed(ped, serverId)
    if ped == 0 or not DoesEntityExist(ped) then return false end
    -- v30: Ped scaling/ground calibration is designed for human peds. Animal
    -- peds (dog RP, etc.) have completely different skeleton/root heights and
    -- must never inherit a human character's scale during a character swap.
    if Config.Scale.HumanPedsOnly ~= false and not IsPedHuman(ped) then return false end
    -- v45: DisableWhenDead used to test IsEntityDead only, which is FALSE for
    -- the whole last-stand and often the fully-dead window on qbx_medical-style
    -- medical resources (they resurrect the ped and hold it at a fixed health).
    -- The scaler therefore kept ground-anchoring a prone, bleeding-out body.
    if Config.Scale.DisableWhenDead and isPedDowned(ped, serverId) then return false end
    if Config.Scale.DisableWhenInvisible and not IsEntityVisible(ped) then return false end
    if Config.Scale.DisableInVehicles and IsPedInAnyVehicle(ped, false) then return false end
    if IsEntityAttached(ped) or IsEntityPositionFrozen(ped) then return false end
    return true
end

local function setScaleState(serverId, scale)
    serverId = tonumber(serverId)
    if not serverId then return end

    local normalized = clampScale(scale)
    if isDefaultScale(normalized) then
        scaleState[serverId] = nil
    else
        scaleState[serverId] = normalized
    end
end

local function resetOwnCharacterScaleState()
    local sid = ownServerId()
    scaleState[sid] = nil
    ownSavedScale = clampScale(Config.Scale.Default)
    previewScale = nil
    lastApplied[sid] = nil
    appliedGroundOffsets[sid] = nil
    groundZCache[sid] = nil
    traversalState[sid] = nil
end

local function beginCharacterTransition()
    resetOwnCharacterScaleState()
    TriggerServerEvent('crimson-pedscale:server:characterTransition')
end

RegisterNetEvent('crimson-pedscale:client:fullSync', function(data, ownScale)
    scaleState = {}
    if type(data) == 'table' then
        for serverId, scale in pairs(data) do
            setScaleState(serverId, scale)
        end
    end
    ownSavedScale = clampScale(ownScale)
end)

RegisterNetEvent('crimson-pedscale:client:updateScale', function(serverId, scale)
    setScaleState(serverId, scale)
    if tonumber(serverId) == ownServerId() then
        ownSavedScale = clampScale(scale)
    end
end)

RegisterNetEvent('crimson-pedscale:client:removeScale', function(serverId)
    serverId = tonumber(serverId)
    if not serverId then return end
    scaleState[serverId] = nil
    lastApplied[serverId] = nil
    appliedGroundOffsets[serverId] = nil
    traversalState[serverId] = nil
    -- v45: groundZCache and remoteAimState were never pruned, so both grew by
    -- one entry per player seen, for the lifetime of the client session.
    groundZCache[serverId] = nil
    remoteAimState[serverId] = nil
    downedStateCache[serverId] = nil
end)

RegisterNetEvent('crimson-pedscale:client:openMenu', function(payload)
    payload = payload or {}
    uiOpen = true
    previewScale = clampScale(payload.scale or ownSavedScale)

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        scale = previewScale,
        min = payload.min or Config.Scale.Min,
        max = payload.max or Config.Scale.Max,
        step = payload.step or Config.Scale.Step,
        openedBy = payload.openedBy or 'Crimson RP'
    })
end)

local function closeMenu(revertPreview)
    uiOpen = false
    if revertPreview then
        previewScale = nil
    end
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterNUICallback('preview', function(data, cb)
    previewScale = clampScale(data and data.scale)
    cb({ ok = true })
end)

RegisterNUICallback('save', function(data, cb)
    local scale = clampScale(data and data.scale or previewScale)
    previewScale = nil
    TriggerServerEvent('crimson-pedscale:server:saveScale', scale)
    closeMenu(false)
    cb({ ok = true })
end)

RegisterNUICallback('reset', function(_, cb)
    previewScale = nil
    TriggerServerEvent('crimson-pedscale:server:resetScale')
    closeMenu(false)
    cb({ ok = true })
end)

RegisterNUICallback('close', function(_, cb)
    closeMenu(true)
    cb({ ok = true })
end)

local function requestCharacterScaleAfterLoad(delay)
    CreateThread(function()
        Wait(delay or 750)
        TriggerServerEvent('crimson-pedscale:server:requestData')
    end)
end

CreateThread(function()
    Wait(1000)
    beginCharacterTransition()
    requestCharacterScaleAfterLoad(750)
end)

-- Qbox/QBCore character lifecycle. We listen to both compatibility names so
-- this survives framework updates and multicharacter resources that reuse them.
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    beginCharacterTransition()
end)

RegisterNetEvent('qbx_core:client:onPlayerUnload', function()
    beginCharacterTransition()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    beginCharacterTransition()
    requestCharacterScaleAfterLoad(500)
end)

RegisterNetEvent('qbx_core:client:onPlayerLoaded', function()
    beginCharacterTransition()
    requestCharacterScaleAfterLoad(500)
end)

AddEventHandler('playerSpawned', function()
    -- playerSpawned can fire during normal respawns too. Requesting is safe: the
    -- server reads the CURRENT citizenid and republishes only that character's scale.
    requestCharacterScaleAfterLoad(750)
end)

-- Last line of defense for custom multicharacter scripts: if PlayerPedId changes,
-- immediately clear the old scale locally before the new model gets one rendered
-- frame at the previous character's height. This also protects animal peds.
CreateThread(function()
    local previousPed = PlayerPedId()
    while true do
        Wait(100)
        local currentPed = PlayerPedId()
        if currentPed ~= 0 and previousPed ~= 0 and currentPed ~= previousPed then
            previousPed = currentPed
            beginCharacterTransition()
            requestCharacterScaleAfterLoad(750)
        elseif currentPed ~= 0 then
            previousPed = currentPed
        end
    end
end)

-- v45: the v24 "doorway camera" helper was removed.
--
-- suppressScaledDoorwayCameraCollision and its object-scan helper were never
-- called from anywhere, Config.Scale.DoorwayCamera.Enabled was already false,
-- and the scan walked the entire CObject game pool on a timer. The comment
-- also named the wrong native for hash 0x2AED6301F67007D5.
--
-- Config.Scale.DoorwayCamera is retained in config.lua purely so existing
-- config files keep loading; it no longer does anything.


CreateThread(function()
    while true do
        local sleep = 250
        local localPed = PlayerPedId()
        local localCoords = GetEntityCoords(localPed)
        local renderDistance = tonumber(Config.Scale.RenderDistance) or 100.0

        for _, player in ipairs(GetActivePlayers()) do
            if NetworkIsPlayerActive(player) then
                local serverId = GetPlayerServerId(player)
                local ped = GetPlayerPed(player)
                local scale = effectiveScale(serverId)
                local shouldApply = not isDefaultScale(scale)
                    and shouldScalePed(ped, serverId)
                    and #(GetEntityCoords(ped) - localCoords) <= renderDistance

                if shouldApply then
                    applyMatrixScale(ped, scale, serverId)
                    lastApplied[serverId] = true
                    sleep = 0
                elseif lastApplied[serverId] then
                    clearMatrixScale(ped, serverId)
                    lastApplied[serverId] = nil
                end
            end
        end

        Wait(sleep)
    end
end)


-- v44: burst-only initial remote aim resync for SHORT scaled peds.
--
-- v43 fixed the initial wrong aim direction by forcing a streamed animation
-- rebuild every rendered frame while the remote short ped merely had a weapon
-- equipped. That was too broad: ForcePedAiAndAnimationUpdate can also advance
-- locomotion / combat-roll presentation on the observer client, making the
-- short ped appear to run or roll faster than the owning player.
--
-- Keep IK channels available while armed, but only force animation updates
-- during a short burst when remote free-aim/shooting actually begins. Once the
-- burst expires we fall back to a light maintenance refresh while the player is
-- still aiming. Merely carrying a weapon no longer forces animation updates.
-- remoteAimState is declared at the top of the file so the removeScale /
-- onResourceStop cleanup paths (which appear earlier) can prune it.
local unarmedHash = joaat('WEAPON_UNARMED')
local AIM_START_BURST_MS = 280
local AIM_MAINTENANCE_MS = 110

CreateThread(function()
    while true do
        local active = false
        local now = GetGameTimer()
        local localPed = PlayerPedId()
        local localCoords = GetEntityCoords(localPed)
        local renderDistance = tonumber(Config.Scale.RenderDistance) or 100.0

        for _, player in ipairs(GetActivePlayers()) do
            if player ~= PlayerId() and NetworkIsPlayerActive(player) then
                local serverId = GetPlayerServerId(player)
                local scale = effectiveScale(serverId)
                local state = remoteAimState[serverId]

                if scale < 0.999 then
                    local ped = GetPlayerPed(player)
                    if ped ~= 0 and DoesEntityExist(ped) and shouldScalePed(ped, serverId)
                        and #(GetEntityCoords(ped) - localCoords) <= renderDistance then
                        local weapon = GetSelectedPedWeapon(ped)
                        local armed = weapon and weapon ~= 0 and weapon ~= unarmedHash
                            and not IsPedRagdoll(ped) and not IsPedGettingUp(ped)

                        if armed then
                            active = true

                            -- Keeping the IK channels enabled does not advance the
                            -- locomotion animation. The expensive/animation-affecting
                            -- ForcePedAiAndAnimationUpdate call is gated below.
                            SetPedCanArmIk(ped, true)
                            SetPedCanTorsoIk(ped, true)
                            SetPedCanHeadIk(ped, true)

                            local aiming = IsPlayerFreeAiming(player) or IsPedShooting(ped)
                            state = state or { aiming = false, burstUntil = 0, nextRefresh = 0 }

                            if aiming and not state.aiming then
                                -- First frame GTA/FiveM reports the remote aim state:
                                -- immediately enter a short per-frame resync burst so
                                -- observers do not keep the stale hip-fire direction.
                                state.burstUntil = now + AIM_START_BURST_MS
                                state.nextRefresh = 0
                            end

                            if aiming then
                                if now <= (state.burstUntil or 0) then
                                    ForcePedAiAndAnimationUpdate(ped, false, false)
                                elseif now >= (state.nextRefresh or 0) then
                                    ForcePedAiAndAnimationUpdate(ped, false, false)
                                    state.nextRefresh = now + AIM_MAINTENANCE_MS
                                end
                            else
                                -- Absolutely no forced animation rebuild while simply
                                -- moving/rolling with a weapon equipped.
                                state.burstUntil = 0
                                state.nextRefresh = 0
                            end

                            state.aiming = aiming
                            remoteAimState[serverId] = state
                        else
                            remoteAimState[serverId] = nil
                        end
                    else
                        remoteAimState[serverId] = nil
                    end
                else
                    remoteAimState[serverId] = nil
                end
            end
        end

        Wait(active and 0 or 100)
    end
end)


-- v18: Damage-impact stabilization for matrix-scaled peds.
-- GTA can apply a very large upward physics impulse when a bullet hits an
-- entity whose basis is being scaled with SetEntityMatrix. Do NOT pause the
-- scale matrix (that makes the ped snap back to 1.00). Instead, keep the
-- visual scale active and suppress only the short-lived vertical/ragdoll
-- impulse on the LOCAL victim.
local impactStabilizeUntil = 0
local impactStabilizePed = 0
local impactRagdollWasDisabled = false

local function scaledLocalPed()
    local ped = PlayerPedId()
    if ped == 0 or not DoesEntityExist(ped) then return nil, nil end
    local scale = effectiveScale(ownServerId())
    if isDefaultScale(scale) then return nil, nil end
    return ped, scale
end


-- v40: dedicated short-ped tackle physics window.
--
-- v39 fixed the remote landing/ledge visuals, but short peds could still receive
-- a collision impulse at tackle contact. Once the ragdoll started, the older v32
-- guard stopped clamping because ragdoll was treated as a legitimate vertical
-- action. That allowed the .87 ped to launch upward and GTA then interpreted the
-- artificial drop as fall/collision damage.
--
-- Keep a short, LOCAL-only physics window around player-to-player tackle contact.
-- During the window we NEVER ground-anchor the owner's Z, cap only bogus UPWARD
-- velocity, and ignore non-firearm physics damage caused by the launch/landing.
-- Horizontal velocity and GTA ragdoll are left intact, so the tackle still looks
-- and feels native.
local shortTacklePhysicsUntil = 0

-- Assigns to the local forward-declared at the top of the file, so the
-- applyMatrixScale tackle branch can actually see it.
shortTacklePhysicsActive = function()
    return shortTacklePhysicsUntil > GetGameTimer()
end

local function hasNearbyPlayerForTackle(localPed, radius)
    local coords = GetEntityCoords(localPed)
    local radiusSq = radius * radius
    for _, player in ipairs(GetActivePlayers()) do
        if player ~= PlayerId() and NetworkIsPlayerActive(player) then
            local otherPed = GetPlayerPed(player)
            if otherPed ~= 0 and DoesEntityExist(otherPed) and not IsEntityDead(otherPed) then
                local other = GetEntityCoords(otherPed)
                local dx, dy, dz = coords.x - other.x, coords.y - other.y, coords.z - other.z
                if (dx * dx + dy * dy + dz * dz) <= radiusSq then
                    return true
                end
            end
        end
    end
    return false
end

CreateThread(function()
    while true do
        local cfg = (Config.Scale and Config.Scale.TackleGuard) or {}
        local idlePoll = tonumber(cfg.IdlePollMs) or 120

        if cfg.Enabled == false then
            shortTacklePhysicsUntil = 0
            Wait(500)
            goto continue
        end

        do
            local ped, scale = scaledLocalPed()
            if not ped or scale >= 0.999 or isPedDowned(ped, ownServerId())
                or IsPedInAnyVehicle(ped, false) then
                shortTacklePhysicsUntil = 0
                Wait(idlePoll)
            else
                local now = GetGameTimer()
                local vel = GetEntityVelocity(ped)
                local horizontalSpeed = math.sqrt((vel.x * vel.x) + (vel.y * vel.y))
                local radius = tonumber(cfg.NearbyPlayerRadius) or 2.35
                local nearby = hasNearbyPlayerForTackle(ped, radius)
                local deliberateTraversal = IsPedJumping(ped)
                    or IsPedClimbing(ped)
                    or IsPedVaulting(ped)
                    or IsPedFalling(ped)
                local tackleRagdoll = IsPedRagdoll(ped) or IsPedGettingUp(ped)

                -- Arm BEFORE the ragdoll when the short tackler receives the initial
                -- upward impulse. Also arm when the short ped is the tackle TARGET
                -- and enters ragdoll beside another player. A real jump/vault/fall
                -- never arms this state.
                local tackleContact = nearby and not deliberateTraversal and (
                    tackleRagdoll
                    or (vel.z > 0.18 and horizontalSpeed > 0.55)
                )

                if tackleContact then
                    shortTacklePhysicsUntil = now + (tonumber(cfg.PhysicsWindowMs) or 900)
                end

                -- v45: velocity clamping ONLY. The health restore that used to
                -- live here refunded every kind of non-firearm damage inside a
                -- re-armable window, which was a godmode bug. Keep GTA's
                -- horizontal motion and ragdoll, remove only the bogus skyward
                -- kick the scaled matrix generates. Downward gravity untouched.
                local active = shortTacklePhysicsUntil > now
                if active then
                    vel = GetEntityVelocity(ped)
                    local maxUp = tonumber(cfg.MaxUpwardVelocity) or 0.08
                    if vel.z > maxUp then
                        SetEntityVelocity(ped, vel.x, vel.y, maxUp)
                    end
                end

                -- v45: only spin per-frame while a tackle window is actually
                -- open. The old loop ran Wait(0) permanently for every scaled
                -- player, doing an O(players) scan every single frame.
                Wait(active and 0 or idlePoll)
            end
        end

        ::continue::
    end
end)

local function beginDamageImpactStabilizer(victim)
    local ped = scaledLocalPed()
    if not ped or victim ~= ped or IsEntityDead(ped) then return end

    local cfg = (Config.Scale and Config.Scale.DamageImpactStabilizer) or {}
    if cfg.Enabled == false then return end

    impactStabilizePed = ped
    impactStabilizeUntil = GetGameTimer() + (tonumber(cfg.DurationMs) or 325)

    -- Prevent the bullet impulse from turning into a full physics ragdoll while
    -- the scaled matrix is active. Normal ragdoll is restored immediately after
    -- the very short stabilization window.
    if cfg.DisableRagdoll ~= false then
        SetPedCanRagdoll(ped, false)
        impactRagdollWasDisabled = true
    end
end

-- v29: IMPORTANT: only stabilize actual FIREARM hits.
--
-- v18 originally listened to CEventNetworkEntityDamage, which also fires for
-- vehicle crashes, falls and other physics damage. On a motorcycle crash that
-- meant SetPedCanRagdoll(false) + the vertical-velocity clamp could activate at
-- the exact moment GTA was trying to eject/ragdoll the rider. The visible
-- result was a scaled player snapping upright instead of naturally crashing.
--
-- FiveM's entityDamaged event gives us the weapon hash directly, so classify
-- the damage by weapon group and leave vehicle/fall/explosion/melee physics
-- completely untouched.
local firearmGroups = {
    [GetHashKey('GROUP_PISTOL')] = true,
    [GetHashKey('GROUP_SMG')] = true,
    [GetHashKey('GROUP_RIFLE')] = true,
    [GetHashKey('GROUP_MG')] = true,
    [GetHashKey('GROUP_SHOTGUN')] = true,
    [GetHashKey('GROUP_SNIPER')] = true
}

local function isFirearmDamageWeapon(weaponHash)
    weaponHash = tonumber(weaponHash) or 0
    if weaponHash == 0 then return false end

    local group = GetWeapontypeGroup(weaponHash)
    return firearmGroups[group] == true
end

AddEventHandler('entityDamaged', function(victim, _culprit, weapon, _baseDamage)
    if not victim or victim == 0 then return end

    -- v45: the v40-v44 short-ped tackle "protection" is REMOVED.
    --
    -- It used to restore health whenever a ped scaled below 0.999 took any
    -- NON-FIREARM damage inside a 900 ms window that re-armed whenever another
    -- player stood within 2.35 m. Because "non-firearm" covered melee, thrown,
    -- explosive, fire, vehicle and fall damage, that was an indefinitely
    -- re-armable damage-immunity window: stand near anyone as a 0.87 ped and
    -- melee, car rams and explosions were all refunded.
    --
    -- It was also a client raising its own health, which is the single most
    -- commonly flagged anticheat pattern, and it made the medical resource see
    -- negative damage.
    --
    -- The bogus upward impulse that motivated it is handled where it belongs:
    -- by clamping VELOCITY in the tackle thread. Health is never rewritten.

    if not isFirearmDamageWeapon(weapon) then return end
    beginDamageImpactStabilizer(victim)
end)

CreateThread(function()
    while true do
        local now = GetGameTimer()
        if impactStabilizeUntil > now and impactStabilizePed ~= 0 and DoesEntityExist(impactStabilizePed) then
            local ped = impactStabilizePed
            local cfg = (Config.Scale and Config.Scale.DamageImpactStabilizer) or {}
            local vel = GetEntityVelocity(ped)
            local maxUp = tonumber(cfg.MaxUpwardVelocity) or 0.05
            local maxDown = tonumber(cfg.MaxDownwardVelocity) or -2.5
            local z = vel.z

            -- Bullet hits are allowed to preserve horizontal movement, but the
            -- bogus upward launch is removed. Keep a modest downward allowance
            -- so stairs/slopes and normal grounding still feel natural.
            if z > maxUp then z = maxUp end
            if z < maxDown then z = maxDown end
            if math.abs(z - vel.z) > 0.001 then
                SetEntityVelocity(ped, vel.x, vel.y, z)
            end

            Wait(0)
        else
            if impactRagdollWasDisabled and impactStabilizePed ~= 0 and DoesEntityExist(impactStabilizePed) then
                SetPedCanRagdoll(impactStabilizePed, true)
            end
            impactRagdollWasDisabled = false
            impactStabilizePed = 0
            impactStabilizeUntil = 0
            Wait(100)
        end
    end
end)

local function buildDamageMap()
    if damageByHash then return damageByHash end

    damageByHash = {}
    for weaponName, damage in pairs(Config.HitboxGuard.WeaponChestDamage or {}) do
        damageByHash[GetHashKey(weaponName)] = tonumber(damage) or 0
    end

    return damageByHash
end

local function chestDamageForWeapon(weaponHash)
    local map = buildDamageMap()
    local configured = map[tonumber(weaponHash)]
    if configured ~= nil then return configured end
    return tonumber(Config.HitboxGuard.DefaultChestDamage) or 0
end

local function cameraRay()
    local startPos = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local rz = math.rad(rot.z)
    local rx = math.rad(rot.x)
    local cosX = math.abs(math.cos(rx))
    local direction = vector3(-math.sin(rz) * cosX, math.cos(rz) * cosX, math.sin(rx))
    return startPos, direction
end

local function pointRayDistance(point, rayStart, rayDirection)
    local rel = point - rayStart
    local t = rel.x * rayDirection.x + rel.y * rayDirection.y + rel.z * rayDirection.z
    if t <= 0.0 then return 9999.0, t end

    local nearest = rayStart + rayDirection * t
    return #(point - nearest), t
end

local function rayHitsVisualHead(rayStart, rayDirection, ped, scale)
    local head = Config.HitboxGuard.Head or {}
    local normalized = clampScale(scale)

    -- Use the rendered head bone instead of GTA's native damage capsule.
    -- SetEntityMatrix visually scales the skeleton, but the native hit capsule
    -- does not always follow it at .87 / 1.10. Bone position DOES follow the
    -- rendered ped, so this tracks what the shooter is actually aiming at.
    local headBone = GetPedBoneIndex(ped, 31086) -- SKEL_Head
    if not headBone or headBone == -1 then return false, 0.0 end

    local center = GetWorldPositionOfEntityBone(ped, headBone)
    if not center then return false, 0.0 end

    local radiusBase = tonumber(head.Radius) or 0.18
    local radius = radiusBase * math.max(0.90, normalized)
    local zOffset = (tonumber(head.ZOffset) or 0.015) * normalized
    center = vector3(center.x, center.y, center.z + zOffset)

    local distance, t = pointRayDistance(center, rayStart, rayDirection)
    return distance <= radius, t
end

local function torsoBounds(ped, scale)
    local base = GetEntityCoords(ped)
    local torso = Config.HitboxGuard.Torso or {}
    local lowerBase = tonumber(torso.Lower) or 0.96
    local upperBase = tonumber(torso.Upper) or 1.49
    local radiusBase = tonumber(torso.Radius) or 0.32
    local unknownRadius = tonumber(torso.UnknownRadius) or 0.34
    local knownScale = scale and not isDefaultScale(scale)

    if knownScale then
        local normalized = clampScale(scale)
        return base.z + lowerBase * normalized, base.z + upperBase * normalized, radiusBase * math.max(0.95, normalized)
    end

    local _, minScale, maxScale = scaleDefaults()
    return base.z + lowerBase * minScale, base.z + upperBase * maxScale, unknownRadius
end

local function rayHitsVisualTorso(rayStart, rayDirection, ped, scale)
    local lowerZ, upperZ, radius = torsoBounds(ped, scale)
    local base = GetEntityCoords(ped)
    local center = vector3(base.x, base.y, (lowerZ + upperZ) * 0.5)
    local bestDistance = 9999.0
    local bestT = 0.0

    for i = 0, 16 do
        local z = lowerZ + (upperZ - lowerZ) * (i / 16.0)
        local point = vector3(center.x, center.y, z)
        local distance, t = pointRayDistance(point, rayStart, rayDirection)
        if distance < bestDistance then
            bestDistance = distance
            bestT = t
        end
    end

    return bestDistance <= radius, bestT
end

local function findVisualHitTarget(localPed)
    local rayStart, rayDirection = cameraRay()
    local localCoords = GetEntityCoords(localPed)
    local maxDistance = tonumber(Config.HitboxGuard.CandidateDistance) or 200.0
    local bestHead = nil
    local bestChest = nil

    for _, player in ipairs(GetActivePlayers()) do
        if player ~= PlayerId() and NetworkIsPlayerActive(player) then
            local targetPed = GetPlayerPed(player)
            local targetServerId = GetPlayerServerId(player)
            local targetScale = effectiveScale(targetServerId)

            -- v45: never target a downed / bleeding-out / dead player. Medical
            -- resources keep those peds alive at a fixed health, so the old
            -- IsEntityDead check inside shouldScalePed did not exclude them and
            -- a downed player could be executed, skipping the EMS revive window.
            if not (Config.HitboxGuard.OnlyScaledTargets and isDefaultScale(targetScale))
                and not isPedDowned(targetPed, targetServerId)
                and shouldScalePed(targetPed, targetServerId)
                and #(GetEntityCoords(targetPed) - localCoords) <= maxDistance
                and HasEntityClearLosToEntity(localPed, targetPed, 17)
            then
                local headHit, headT = rayHitsVisualHead(rayStart, rayDirection, targetPed, targetScale)
                if headHit and (not bestHead or headT < bestHead.t) then
                    bestHead = {
                        serverId = targetServerId,
                        t = headT,
                        kind = 'head'
                    }
                end

                local chestHit, chestT = rayHitsVisualTorso(rayStart, rayDirection, targetPed, targetScale)
                if chestHit and (not bestChest or chestT < bestChest.t) then
                    bestChest = {
                        serverId = targetServerId,
                        t = chestT,
                        kind = 'chest'
                    }
                end
            end
        end
    end

    -- Head always wins when the crosshair intersects the visual head. This is
    -- what restores one-tap headshots when the native capsule is misaligned.
    return bestHead or bestChest
end

CreateThread(function()
    while true do
        Wait(50)

        local ped = PlayerPedId()
        if ped ~= observedPed then
            observedPed = ped
            observedHealth = GetEntityHealth(ped)
            observedArmor = GetPedArmour(ped)
        end

        local health = GetEntityHealth(ped)
        local armor = GetPedArmour(ped)
        local now = GetGameTimer()

        if observedHealth and observedArmor and (health < observedHealth or armor < observedArmor) then
            if now > suppressDamageObservationUntil then
                lastNativeDamageAt = now
            end
        end

        observedHealth = health
        observedArmor = armor
    end
end)

CreateThread(function()
    while true do
        if not Config.HitboxGuard.Enabled then
            Wait(1000)
        else
            Wait(0)

            local ped = PlayerPedId()
            if ped ~= 0 and not IsEntityDead(ped) and IsPedShooting(ped) then
                local now = GetGameTimer()
                local cooldown = tonumber(Config.HitboxGuard.ShotCooldownMs) or 115
                if now - lastShotAt >= cooldown then
                    lastShotAt = now

                    local weaponHash = GetSelectedPedWeapon(ped)
                    -- v45: IsPedShooting is also true for snowballs, balls,
                    -- flare guns, petrol cans and fire extinguishers. Reject
                    -- anything that is not a real firearm before reporting,
                    -- so those can never register as a compensated hit.
                    local damage = isFirearmDamageWeapon(weaponHash) and chestDamageForWeapon(weaponHash) or 0
                    if damage > 0 and damage <= (tonumber(Config.HitboxGuard.MaxDamage) or 250) then
                        local target = findVisualHitTarget(ped)
                        if target then
                            local isHead = target.kind == 'head'
                                and (Config.HitboxGuard.Head or {}).Enabled ~= false
                            -- Both paths now wait for the native damage window so
                            -- the victim can corroborate the shot locally. The head
                            -- path used to skip this and command an instant kill.
                            CreateThread(function()
                                Wait(tonumber(Config.HitboxGuard.NativeDamageDelayMs) or 175)
                                TriggerServerEvent(isHead
                                    and 'crimson-pedscale:server:visualHeadHit'
                                    or 'crimson-pedscale:server:visualChestHit',
                                    target.serverId, weaponHash)
                            end)
                        end
                    end
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- v45 victim-side compensation.
--
-- Replaces applyVisualHeadshot + applyVisualChestDamage with ONE handler that
-- can never kill and never fires on a shooter's word alone.
--
-- What changed and why:
--  * The head path used to be SetEntityHealth(ped, 0) with no corroboration,
--    no armour, no range check. Any player could drive it ~10x/second against
--    any scaled player. It is gone.
--  * Compensation now requires the victim's OWN client to have independently
--    observed real native damage inside CorroborationWindowMs. An attacker who
--    never actually shot produces no native damage here, so nothing applies.
--  * Total compensation is capped per rolling window, and can never take the
--    victim below MinHealthAfterCompensation. The killing blow must come from
--    GTA's own damage so the medical resource sees a real death with a real
--    killer instead of an unattributed self-death.
-- ---------------------------------------------------------------------------
local compensationWindowStart = 0
local compensationInWindow = 0

RegisterNetEvent('crimson-pedscale:client:applyVisualDamage', function(damage, _shooter, _weaponHash, isHeadshot)
    if not Config.HitboxGuard.Enabled then return end

    local guard = Config.HitboxGuard
    damage = math.floor((tonumber(damage) or 0) + 0.5)
    if damage <= 0 or damage > (tonumber(guard.MaxDamage) or 250) then return end

    local ped = PlayerPedId()
    if ped == 0 then return end

    -- Never touch a downed, dying or dead player. Medical resources keep such
    -- peds ALIVE at a non-zero health, so IsEntityDead alone is not enough:
    -- without this a second report finished off a bleeding-out player and
    -- skipped the entire EMS revive window.
    if isPedDowned(ped, ownServerId()) then return end

    local now = GetGameTimer()

    -- Corroboration: only top up damage the engine actually delivered here.
    if guard.RequireNativeCorroboration ~= false then
        local window = tonumber(guard.CorroborationWindowMs) or 400
        if lastNativeDamageAt <= 0 or (now - lastNativeDamageAt) > window then
            return
        end
    end

    -- Rolling cap on how much compensation this client will accept.
    local windowMs = tonumber(guard.CompensationWindowMs) or 1000
    if (now - compensationWindowStart) > windowMs then
        compensationWindowStart = now
        compensationInWindow = 0
    end

    local allowance = math.max(0, (tonumber(guard.MaxCompensationPerWindow) or 60) - compensationInWindow)
    if allowance <= 0 then return end
    if damage > allowance then damage = allowance end

    -- Never deal the killing blow.
    local minHealth = math.max(0, tonumber(guard.MinHealthAfterCompensation) or 2)
    local health = GetEntityHealth(ped)
    local armor = GetPedArmour(ped)
    local headroom = math.max(0, (health - minHealth) + armor)
    if headroom <= 0 then return end
    if damage > headroom then damage = headroom end
    if damage <= 0 then return end

    compensationInWindow = compensationInWindow + damage
    suppressDamageObservationUntil = now + 150

    local remaining = damage
    if armor > 0 then
        local absorbed = math.min(armor, remaining)
        SetPedArmour(ped, armor - absorbed)
        remaining = remaining - absorbed
    end

    if remaining > 0 then
        SetEntityHealth(ped, math.max(minHealth, health - remaining))
    end

    observedHealth = GetEntityHealth(ped)
    observedArmor = GetPedArmour(ped)

    if Config.Debug then
        print(('^3[crimson-pedscale]^0 compensation applied: %d (%s)')
            :format(damage, isHeadshot and 'head' or 'chest'))
    end
end)


-- ---------------------------------------------------------------------------
-- v45 resource lifecycle cleanup.
--
-- The resource previously had NO onResourceStop handler. Two things leaked
-- across a stop/restart:
--
--  * SetNuiFocus(true, true) was never released. Restarting the resource
--    while a player had the menu open left them with input focus locked to a
--    now-dead NUI frame -- effectively a frozen player who had to relog.
--  * SetPedCanRagdoll(ped, false) from the damage-impact stabiliser could be
--    latched. If the resource stopped inside that ~325 ms window the ped kept
--    ragdoll disabled indefinitely, silently breaking every other resource's
--    ragdoll (tackles, falls, medical takedowns).
--
-- Also restores every scaled ped's basis so no one is left visually scaled.
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    -- Always release input focus, whatever state the menu was in.
    SetNuiFocus(false, false)
    uiOpen = false
    previewScale = nil

    -- Un-latch ragdoll on any ped we disabled it for.
    if impactRagdollWasDisabled and impactStabilizePed ~= 0 and DoesEntityExist(impactStabilizePed) then
        SetPedCanRagdoll(impactStabilizePed, true)
    end
    impactRagdollWasDisabled = false
    impactStabilizePed = 0
    impactStabilizeUntil = 0

    local localPed = PlayerPedId()
    if localPed ~= 0 and DoesEntityExist(localPed) then
        SetPedCanRagdoll(localPed, true)
    end

    -- Restore every ped we were scaling back to a unit basis in place.
    for _, player in ipairs(GetActivePlayers()) do
        local serverId = GetPlayerServerId(player)
        if lastApplied[serverId] then
            local ped = GetPlayerPed(player)
            clearMatrixScale(ped, serverId)
            lastApplied[serverId] = nil
        end
    end

    scaleState = {}
    remoteAimState = {}
    appliedGroundOffsets = {}
    groundZCache = {}
    traversalState = {}
    downedStateCache = {}
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    ReportPedScaleConfig('client')
end)
