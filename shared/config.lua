Config = {}

Config.Debug = false

Config.Commands = {
    OpenMenu = 'pedscale',
    GiveMenu = 'givepedscale',
    SetScale = 'setpedscale',
    ResetScale = 'resetpedscale'
}

Config.Permission = {
    -- Set true if every player may open /pedscale for themselves.
    AllowEveryoneSelfMenu = false,

    -- Ask FiveM to block the commands before the script handler runs.
    --
    -- IMPORTANT: RegisterCommand(name, fn, true) makes FiveM check the ace
    -- object `command.<name>` -- NOT Config.Permission.Ace. Leaving this true
    -- while only granting `crimson.pedscale` blocks all four commands for
    -- everyone, which is why it now defaults to false. The in-handler
    -- permission check below still runs either way, so false is safe.
    --
    -- Set this back to true ONLY if you also add, for every command name:
    --   add_ace group.admin command.pedscale allow
    --   add_ace group.admin command.givepedscale allow
    --   add_ace group.admin command.setpedscale allow
    --   add_ace group.admin command.resetpedscale allow
    RestrictCommandsWithAce = false,

    -- Recommended: add_ace group.admin crimson.pedscale allow
    UseAce = true,
    Ace = 'crimson.pedscale',

    -- Full identifiers can be added here, for example "license:abc123".
    Identifiers = {},

    -- Used when qb-core/qbx_core/es_extended are running and expose permissions.
    --
    -- NOTE for Qbox: exports.qbx_core:HasPermission is marked @deprecated
    -- upstream and its body is just IsPlayerAceAllowed(source, permission),
    -- i.e. it checks the BARE ace object ('admin'), not 'group.admin'. A stock
    -- Qbox install grants no 'god' ace at all, so that entry is inert there.
    -- The reliable path on Qbox is the ace check above:
    --   add_ace group.admin crimson.pedscale allow
    QBCoreGroups = { 'admin', 'god' },
    ESXGroups = { 'admin', 'superadmin' }
}

Config.Scale = {
    Default = 1.0,
    Min = 0.87,
    Max = 1.10,
    Step = 0.01,
    RenderDistance = 100.0,

    -- v30: the matrix/grounding calibration is for human peds only. This keeps
    -- dog/animal RP characters at their native model scale and ground height.
    HumanPedsOnly = true,

    -- v7 grounding: anchor the scaled ped directly to the actual world ground.
    -- Do not use scale-delta offsets or foot-bone feedback. Those methods fight
    -- GTA's native collision/IK and are what caused floating, sinking, knee
    -- pumping and the visible up/down stutter in earlier revisions.
    Grounding = {
        -- Freemode peds use an entity/root height of roughly 1.0m above their
        -- soles. Scaling that root height with the visual matrix keeps both
        -- .87 and 1.10 centered on the same physical ground plane.
        BaseRootHeight = 1.00,
        SoleClearance = 0.040,

        -- Fine calibration for taller-than-default peds only. 0.87 stays
        -- exactly where v7 placed it. At 1.10 this lowers the root by 2.5cm
        -- so the soles sit on the pavement instead of hovering slightly.
        TallMaxScaleCorrection = -0.025,

        -- Global short-scale calibration. The .87 ped was still hovering for
        -- both the owner and remote observers, so this correction applies to
        -- EVERYONE. At .87 it lowers the root by 2.5cm and blends back to zero
        -- at 1.00. Do not stack an owner-only short correction on top of it.
        ShortMaxScaleCorrection = -0.025,
        LocalShortMaxCorrection = 0.000,

        -- Owner-only tall-scale visual calibration. The global tall correction
        -- already grounds the ped for other observers, but the owner can still
        -- render their own 1.10 soles a little high. At 1.10 this adds another
        -- 1.2cm downward correction only for the LOCAL player.
        LocalTallMaxCorrection = -0.012,

        -- v27: begin floor rays only slightly above the entity root. Starting
        -- 2m overhead allowed MLO ceilings/doorway geometry to be mistaken for
        -- the floor and physically lifted the scaled ped.
        RaycastRootHeadroom = 0.18,
        -- Any valid floor must be at least this far below the ped root.
        MinGroundBelowRoot = 0.35,
        RaycastBelow = 3.0,
        FallbackRaycastBelow = 6.0,

        -- v21 doorway/camera fix. Ground rays prefer WORLD collision before
        -- OBJECT collision, so animated door props cannot make the ped root
        -- bounce between two Z values. Object fallback is accepted only when
        -- the surface normal points upward enough to be a real floor.
        MinWalkableSurfaceNormalZ = 0.65,

        -- v25: Ignore tiny raised MLO doorway thresholds instead of moving the
        -- owning ped onto them. Normal stair risers are much taller than this.
        DoorwayMicroDeadband = 0.070,
        -- v31 traversal handling. While GTA is vaulting/climbing/jumping,
        -- ragdolling, or physically airborne (including tackle leaps), keep the
        -- visual matrix scale but let GTA control root Z. The short release
        -- delay prevents an immediate ground snap at the end of the animation.
        TraversalReleaseDelayMs = 260,

        -- v20 ledge handling. A sudden downward change larger than a normal
        -- stair riser is treated as a real drop instead of terrain to smooth.
        -- The scaler preserves scale but releases root-Z so GTA can play its
        -- native fall/landing animation.
        LedgeDropThreshold = 0.22,
        LedgeReleaseDelayMs = 450,

        -- v38 local stair/slope smoothing. This sits between v36 (too much
        -- vertical lag) and v37 (still visibly stepping from tread to tread).
        -- Bigger ledges still use LedgeDropThreshold and GTA's native gravity.
        SmoothingStartSpeed = 0.20,
        LocalStairUpTimeConstant = 0.060,
        LocalStairDownTimeConstant = 0.065,
        LocalStairMaxUpSpeed = 3.20,
        LocalStairMaxDownSpeed = 3.00,
        SnapUpDistance = 0.30,

        -- v38 observer stair smoothing. Blend one tread across several frames,
        -- but never allow the visual ped to trail by more than roughly one stair.
        RemoteStairSmoothMaxDelta = 0.28,
        RemoteStairUpTimeConstant = 0.050,
        RemoteStairDownTimeConstant = 0.055,
        RemoteStairMaxUpSpeed = 4.00,
        RemoteStairMaxDownSpeed = 3.80,

        -- v33 remote ledge visual continuity. Remote clients carry the last
        -- grounded scale offset through a real jump/fall instead of switching
        -- abruptly to raw network Z, then ease back to grounded placement after
        -- landing. These values affect OBSERVERS only; the owner's ledge physics
        -- and animation remain exactly as in v32.
        RemoteTraversalMaxOffset = 0.22,
        RemoteLandingSmoothing = 0.22,
        RemoteLandingMaxCorrectionPerFrame = 0.015,
        RemoteLandingSnapTolerance = 0.006,

        -- v39 remote landing settle. FiveM can drop the airborne flag before a
        -- remote scaled ped has visually reached the floor. Keep descending at
        -- a natural rate until close, then settle short peds faster so .87 does
        -- not hover above the landing surface.
        RemoteLandingContinueFallThreshold = 0.18,
        RemoteLandingCatchupSpeed = 4.50,
        RemoteLandingCatchupMinStep = 0.018,
        ShortLandingScaleThreshold = 0.92,
        ShortRemoteLandingCatchupSpeed = 5.25,
        ShortRemoteLandingSmoothing = 0.62,
        ShortRemoteLandingMaxCorrectionPerFrame = 0.050,
        ShortRemoteLandingSnapTolerance = 0.012,

        -- v40 short-ped tackle protection is intentionally implemented in the
        -- client physics state rather than the grounding values here. Tackle
        -- ragdolls bypass all Z anchoring for ~0.9s, cap only positive launch
        -- velocity, and suppress the resulting non-firearm collision/fall damage.

        -- v35 observer-side ledge interpolation. FiveM network updates for a
        -- remote ped can arrive as discrete downward Z steps. These settings
        -- visually interpolate only normal-sized downward steps; true teleports
        -- (> RemoteLedgeSmoothMaxDrop) are left untouched.
        RemoteLedgeSmoothMinDrop = 0.015,
        -- v38: also trigger smoothing when the observer receives a substantial
        -- downward packet before FiveM reports IsEntityInAir/IsPedFalling.
        RemoteLedgeTriggerDrop = 0.24,
        RemoteLedgeSmoothMaxDrop = 3.00,
        RemoteLedgeVisualFallSpeed = 3.6,
        RemoteLedgeMinStepPerFrame = 0.010
    },

    -- v29: Keep matrix scaling active when shot, but suppress the bogus
    -- vertical physics impulse ONLY for firearm hits. Vehicle crashes, falls,
    -- explosions and melee damage are intentionally excluded so GTA can ragdoll
    -- and eject the player normally.
    -- This still prevents firearm hits from launching scaled peds/cameras.
    -- This replaces the v17 approach that paused scaling and made the victim
    -- snap back to normal height.
    -- v24: while the LOCAL player is scaled, ignore gameplay-camera
    -- collision with nearby OBJECT entities (automatic doors/door leaves) for
    -- the current frame. This does not affect the player's physical collision.
    DoorwayCamera = {
        Enabled = false,
        ObjectIgnoreRadius = 2.35,
        ObjectScanIntervalMs = 120
    },

    DamageImpactStabilizer = {
        Enabled = true,
        DurationMs = 325,
        DisableRagdoll = true,
        MaxUpwardVelocity = 0.05,
        MaxDownwardVelocity = -2.50
    },

    -- v40 short-ped tackle handling, reworked in v45.
    --
    -- v40-v44 restored the local player's health whenever a short ped took
    -- ANY non-firearm damage inside a 900 ms window that re-armed whenever
    -- another player stood within 2.35 m. Because "non-firearm" covered
    -- melee, thrown, explosive, fire, vehicle and fall damage, that was an
    -- indefinitely re-armable damage-immunity window -- a godmode bug, and
    -- exactly the pattern a server anticheat looks for.
    --
    -- v45 removes the health write entirely. The bogus upward impulse that
    -- caused the original problem is dealt with where it belongs: by
    -- clamping VELOCITY, which this guard already did.
    TackleGuard = {
        Enabled = true,
        NearbyPlayerRadius = 2.35,
        PhysicsWindowMs = 900,
        MaxUpwardVelocity = 0.08,
        -- Poll interval while a short ped is idle. The old code spun at
        -- Wait(0) permanently for every scaled player.
        IdlePollMs = 120,

        -- Left for reference; v45 never restores health under any setting.
        -- Kept so an existing config file does not error on load.
        RestoreHealth = false
    },

    -- Matrix scaling peds inside vehicles is prone to visual jitter.
    DisableInVehicles = true,
    DisableWhenInvisible = true,
    DisableWhenDead = true
}

-- v45 compatibility layer.
--
-- Medical resources (qbx_medical, sc-ambulance, qb-ambulancejob, ...) keep a
-- "downed" player's ped ALIVE -- they call NetworkResurrectLocalPlayer and
-- then set health to a non-zero value so the ped can play a bleed-out
-- animation. IsEntityDead() is therefore FALSE for the whole last-stand and
-- even the fully-dead window.
--
-- Config.Scale.DisableWhenDead relies on IsEntityDead, so without this
-- layer the scaler keeps ground-anchoring a prone body and the hitbox guard
-- keeps treating a bleeding-out player as a valid target -- which let a
-- downed player be finished off, skipping the EMS revive window entirely.
--
-- Nothing here modifies another resource. It only READS state those
-- resources already publish.
Config.Compat = {
    -- Statebags to consult on the LOCAL player. Checked with
    -- LocalPlayer.state[<name>]; any truthy value means "downed".
    LocalStateFlags = { 'dead', 'isDead', 'laststand', 'inLaststand', 'buckled' },

    -- Statebags to consult on OTHER players, via Player(serverId).state.
    PlayerStateFlags = { 'dead', 'isDead', 'laststand', 'inLaststand' },

    -- Also treat a ped as downed when GTA itself reports it fatally injured.
    UseIsPedFatallyInjured = true,

    -- Health at or below this counts as downed even if no statebag is set.
    -- Medical resources commonly park last-stand players at a fixed value.
    DownedHealthThreshold = 1
}

-- v45 inbound event rate limiting (server side).
--
-- Every client-callable event used to be unauthenticated AND unbounded, and
-- requestData / characterTransition each fan out a TriggerClientEvent(-1)
-- broadcast to every player. One client could turn 1 event into N packets.
Config.Limits = {
    Enabled = true,
    -- Minimum milliseconds between accepted calls, per player, per event.
    PerEventCooldownMs = {
        requestData = 2000,
        characterTransition = 1500,
        saveScale = 750,
        resetScale = 750
    },
    DefaultCooldownMs = 500,

    -- Drop a player's traffic entirely for this long after they exceed the
    -- allowance repeatedly, so spam cannot be sustained.
    AbusePenaltyMs = 10000,
    AbuseStrikes = 8
}

Config.Persistence = {
    Enabled = true,
    IdentifierPriority = { 'license', 'license2', 'fivem', 'discord', 'steam' }
}

Config.MenuGrantSeconds = 120

Config.Notifications = {
    Prefix = 'Crimson Ped Scale',
    UseChat = true
}

Config.HitboxGuard = {
    -- Entity-matrix scaling changes the visual body more than GTA's native
    -- damage capsule. This guard compensates chest shots that visually land.
    --
    -- ############################################################### --
    -- ##  READ THIS BEFORE SETTING Enabled = true                  ## --
    -- ############################################################### --
    --
    -- This guard is CLIENT-AUTHORITATIVE by design: the shooter's client
    -- decides it landed a hit, and the victim's client then damages itself.
    -- FiveM gives the server no way to verify that a shot happened, so a
    -- modified client can report hits it never fired.
    --
    -- v45 removes the instant-kill primitive and adds firearm whitelisting,
    -- token-bucket rate limiting, damage caps and victim-side corroboration.
    -- Those bound the abuse; they do not eliminate it. A determined cheater
    -- can still convert this into a capped damage advantage.
    --
    -- It therefore ships DISABLED. Turn it on only if you accept that
    -- trade-off, and read the "Hitbox guard" section of the README first.
    Enabled = false,
    OnlyScaledTargets = true,

    RayDistance = 220.0,
    CandidateDistance = 200.0,
    ShotCooldownMs = 115,
    NativeDamageDelayMs = 175,
    NativeDamageWindowMs = 350,
    ServerCooldownMs = 95,

    -- v45 hardening ------------------------------------------------------
    -- Only weapons whose GetWeapontypeGroup is in this set may ever produce
    -- a compensated hit. This is what stops snowballs, balls, flare guns,
    -- petrol cans and fire extinguishers from being accepted as gunshots
    -- (IsPedShooting is true for all of them).
    AllowedWeaponGroups = {
        'GROUP_PISTOL', 'GROUP_SMG', 'GROUP_RIFLE',
        'GROUP_MG', 'GROUP_SHOTGUN', 'GROUP_SNIPER'
    },

    -- Unconditional deny list, checked FIRST and independently of everything
    -- else. Nothing here can ever produce compensated damage, whatever its
    -- weapon group, whatever the damage table says, and even if
    -- RejectUnknownWeapons is turned off.
    --
    -- Group membership alone is NOT enough to keep these out. GTA classifies
    -- WEAPON_FLAREGUN as GROUP_PISTOL and WEAPON_FIREEXTINGUISHER /
    -- WEAPON_PETROLCAN as GROUP_PETROLCAN, and IsPedShooting() is true for all
    -- of them -- which is how a fire extinguisher was one-tapping scaled
    -- players. This list is the belt to the group whitelist's braces.
    NeverCompensate = {
        'WEAPON_FIREEXTINGUISHER',
        'WEAPON_PETROLCAN',
        'WEAPON_FERTILIZERCAN',
        'WEAPON_HAZARDCAN',
        'WEAPON_FLAREGUN',
        'WEAPON_FLARE',
        'WEAPON_SNOWBALL',
        'WEAPON_BALL',
        'WEAPON_MOLOTOV',
        'WEAPON_STUNGUN',
        'WEAPON_STUNGUN_MP',
        'WEAPON_FIREWORK',
        'WEAPON_DIGISCANNER',
        'WEAPON_GARBAGEBAG',
        'WEAPON_HANDCUFFS',
        'WEAPON_METALDETECTOR',
        'WEAPON_BRIEFCASE',
        'WEAPON_BRIEFCASE_02',
        'WEAPON_UNARMED'
    },

    -- Reject any weapon hash that is not explicitly listed in
    -- WeaponChestDamage. The old DefaultChestDamage fallback meant ANY
    -- unlisted or garbage hash was treated as 50 damage.
    RejectUnknownWeapons = true,

    -- The victim's own client must have independently observed real native
    -- damage in this window before it will apply any compensation. This is
    -- the main defence: an attacker who never actually shot produces no
    -- native damage on the victim, so nothing is applied.
    RequireNativeCorroboration = true,
    CorroborationWindowMs = 400,

    -- How the victim decides it really was shot.
    --   'firearm'   (default, correct) -- the entityDamaged game event fired for
    --               this ped with a firearm weapon hash.
    --   'anyDamage' (legacy, WEAKER)   -- also accepts a bare health drop, which
    --               a medical bleed tick, a fall, fire or drowning all satisfy,
    --               so a fabricated report can ride on unrelated damage.
    CorroborationMode = 'firearm',

    -- Hard ceiling on compensation the victim will accept, regardless of
    -- what the server relays. Prevents burst-kills through any hole above.
    MaxCompensationPerWindow = 60,
    CompensationWindowMs = 1000,

    -- Never let compensation reduce the victim below
    -- (PlayerDeathThreshold + MinHealthAfterCompensation). Killing blows must
    -- come from GTA's own damage so the medical resource sees a real death
    -- with a real killer.
    --
    -- PlayerDeathThreshold matters: a GTA V player ped is widely treated as
    -- dead at 100, not 0 (health runs 100..200 for players, which is why
    -- medical resources display health - 100). A bare floor of 2 was therefore
    -- BELOW the death threshold and did not actually prevent a kill.
    -- If your server uses a different model, adjust this.
    PlayerDeathThreshold = 100,
    MinHealthAfterCompensation = 2,

    -- Require the shooter's ammo count to actually drop before a hit can be
    -- reported. IsPedShooting alone is a state that stays true for a whole
    -- automatic burst, which decoupled compensation from rounds fired.
    RequireAmmoDecrease = true,

    -- Server-side token bucket, per shooter, across ALL targets.
    RateLimit = {
        Burst = 5,
        RefillPerSecond = 4.0
    },

    -- Visual headshot compensation for scaled peds. GTA's native head
    -- capsule stays close to the original 1.00 skeleton even when the ped is
    -- rendered at .87 or 1.10, so aim against the rendered SKEL_Head bone.
    --
    -- v45: a head hit is NO LONGER an instant kill. The old behaviour was
    -- SetEntityHealth(ped, 0) driven by a net event from another player,
    -- which was both a remote-execute primitive and a death with no killer
    -- (the medical resource logged it as an unknown self-death). It now
    -- applies a multiplied, capped damage instead, so a lethal shot still
    -- goes through GTA's own damage path with proper attribution.
    Head = {
        Enabled = true,
        Radius = 0.18,
        ZOffset = 0.015,
        DamageMultiplier = 2.5
    },

    Torso = {
        Lower = 0.96,
        Upper = 1.49,
        Radius = 0.32,
        UnknownRadius = 0.34
    },

    -- KNOWN LIMITATIONS of the compensation model, documented rather than
    -- silently shipped:
    --
    --  * The values below are a hard-coded table, not your server's
    --    weapons.meta. They are roughly 2x vanilla and ignore any damage
    --    modifiers you run, so they can shift TTK. MaxCompensationPerWindow
    --    bounds the effect; tune these to your server if you enable the guard.
    --  * The compensation ray starts at the gameplay CAMERA, not the weapon
    --    muzzle, so hip-fire, recoil spread and third-person parallax are not
    --    modelled. A shot that visually misses can still be scored a hit.
    --  * The LOS check is ped-to-ped with trace flag 17, so vehicles and other
    --    players do not block a compensated hit the way they block a bullet.
    --  * At 0.87 a ped is already harder to hit natively; compensating on top
    --    of that can over-correct. Consider enabling the guard only for scales
    --    above 1.00 if your players report this.
    MaxDamage = 250,

    -- Fallback for weapons not listed in WeaponChestDamage. This is only
    -- consulted when RejectUnknownWeapons is false; leaving that true (the
    -- default) is strongly recommended, because this fallback is what let
    -- any unlisted hash -- including non-firearms -- register as a hit.
    DefaultChestDamage = 0,

    -- Stun guns are excluded so they do not trigger injury-style damage.
    WeaponChestDamage = {
        WEAPON_STUNGUN = 0,
        WEAPON_STUNGUN_MP = 0,

        WEAPON_PISTOL = 55,
        WEAPON_COMBATPISTOL = 58,
        WEAPON_APPISTOL = 40,
        WEAPON_HEAVYPISTOL = 65,
        WEAPON_SNSPISTOL = 48,
        WEAPON_VINTAGEPISTOL = 52,

        WEAPON_MICROSMG = 34,
        WEAPON_MINISMG = 35,
        WEAPON_SMG = 38,
        WEAPON_ASSAULTSMG = 40,

        WEAPON_ASSAULTRIFLE = 55,
        WEAPON_CARBINERIFLE = 57,
        WEAPON_SPECIALCARBINE = 58,
        WEAPON_BULLPUPRIFLE = 55,

        WEAPON_PUMPSHOTGUN = 95,
        WEAPON_SAWNOFFSHOTGUN = 90,
        WEAPON_MARKSMANRIFLE = 115,
        WEAPON_SNIPERRIFLE = 150,
        WEAPON_HEAVYSNIPER = 220
    }
}

-- ---------------------------------------------------------------------------
-- v45 config validation.
--
-- Previously a bad Config value failed silently (Min > Max quietly swapped,
-- a nil command name crashed RegisterCommand, an absurd damage value was
-- accepted). Validate once at start, clamp what can be clamped, and print a
-- clear warning for what cannot.
-- ---------------------------------------------------------------------------
function ValidatePedScaleConfig()
    local problems = {}

    local function warn(fmt, ...)
        problems[#problems + 1] = select('#', ...) > 0 and fmt:format(...) or fmt
    end

    local scale = Config.Scale or {}
    scale.Min = tonumber(scale.Min) or 0.87
    scale.Max = tonumber(scale.Max) or 1.10
    scale.Default = tonumber(scale.Default) or 1.0

    if scale.Min > scale.Max then
        warn('Scale.Min (%.2f) was greater than Scale.Max (%.2f); swapped.', scale.Min, scale.Max)
        scale.Min, scale.Max = scale.Max, scale.Min
    end
    if scale.Min <= 0.0 then
        warn('Scale.Min must be > 0; clamped to 0.5.')
        scale.Min = 0.5
    end
    if scale.Default < scale.Min or scale.Default > scale.Max then
        warn('Scale.Default (%.2f) outside [%.2f, %.2f]; clamped.', scale.Default, scale.Min, scale.Max)
        scale.Default = math.min(scale.Max, math.max(scale.Min, scale.Default))
    end
    scale.RenderDistance = math.max(10.0, tonumber(scale.RenderDistance) or 100.0)

    local commands = Config.Commands or {}
    for _, key in ipairs({ 'OpenMenu', 'GiveMenu', 'SetScale', 'ResetScale' }) do
        local name = commands[key]
        if type(name) ~= 'string' or name == '' then
            warn('Commands.%s is not a non-empty string; that command is disabled.', key)
            commands[key] = nil
        end
    end

    local guard = Config.HitboxGuard or {}
    guard.MaxDamage = math.max(1, math.min(1000, tonumber(guard.MaxDamage) or 250))
    guard.DefaultChestDamage = math.max(0, tonumber(guard.DefaultChestDamage) or 0)
    if guard.DefaultChestDamage > 0 and guard.RejectUnknownWeapons == false then
        warn('HitboxGuard: RejectUnknownWeapons=false with DefaultChestDamage=%d lets ANY '
            .. 'unlisted weapon hash register a hit. This is strongly discouraged.',
            guard.DefaultChestDamage)
    end
    for weaponName, damage in pairs(guard.WeaponChestDamage or {}) do
        local value = tonumber(damage)
        if not value or value < 0 or value > guard.MaxDamage then
            warn('HitboxGuard.WeaponChestDamage.%s (%s) is invalid or above MaxDamage; set to 0.',
                tostring(weaponName), tostring(damage))
            guard.WeaponChestDamage[weaponName] = 0
        end
    end
    guard.MaxCompensationPerWindow = math.max(0, tonumber(guard.MaxCompensationPerWindow) or 60)
    guard.MinHealthAfterCompensation = math.max(0, tonumber(guard.MinHealthAfterCompensation) or 2)

    if guard.Enabled and guard.RequireNativeCorroboration == false then
        warn('HitboxGuard is enabled with RequireNativeCorroboration=false. The victim will '
            .. 'then apply damage on a shooter\'s word alone. Do not run this on a live server.')
    end

    return problems
end

function ReportPedScaleConfig(sideLabel)
    local problems = ValidatePedScaleConfig()
    if #problems == 0 then return end
    print(('^3[crimson-pedscale]^0 %s config warnings (%d):'):format(sideLabel, #problems))
    for i = 1, #problems do
        print(('^3[crimson-pedscale]^0   %d. %s'):format(i, problems[i]))
    end
end
