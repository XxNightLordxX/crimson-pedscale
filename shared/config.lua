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

    -- Also let FiveM block the commands before the script handler runs.
    RestrictCommandsWithAce = true,

    -- Recommended: add_ace group.admin crimson.pedscale allow
    UseAce = true,
    Ace = 'crimson.pedscale',

    -- Full identifiers can be added here, for example "license:abc123".
    Identifiers = {},

    -- Used when qb-core/qbx_core/es_extended are running and expose permissions.
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

    -- Matrix scaling peds inside vehicles is prone to visual jitter.
    DisableInVehicles = true,
    DisableWhenInvisible = true,
    DisableWhenDead = true
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
    Enabled = true,
    OnlyScaledTargets = true,

    RayDistance = 220.0,
    CandidateDistance = 200.0,
    ShotCooldownMs = 115,
    NativeDamageDelayMs = 175,
    NativeDamageWindowMs = 350,
    ServerCooldownMs = 95,

    -- Visual headshot compensation for scaled peds. GTA's native head
    -- capsule stays close to the original 1.00 skeleton even when the ped is
    -- rendered at .87 or 1.10, so aim against the rendered SKEL_Head bone.
    -- Any valid firearm hit inside this sphere is a one-tap kill.
    Head = {
        Enabled = true,
        Radius = 0.18,
        ZOffset = 0.015
    },

    Torso = {
        Lower = 0.96,
        Upper = 1.49,
        Radius = 0.32,
        UnknownRadius = 0.34
    },

    MaxDamage = 250,
    DefaultChestDamage = 50,

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
