# Crimson Ped Scale v45 — security hardening

Based on v44. **v45 is a security and correctness release.** The scaling,
grounding, stair/ledge and remote-aim behaviour from v44 is unchanged; what
changed is everything that could hurt a player or the server.

Read the "Hitbox guard" section before upgrading — its default has changed.

---

## Breaking changes

| Setting | Was | Now | Why |
|---|---|---|---|
| `Config.HitboxGuard.Enabled` | `true` | **`false`** | The guard is client-authoritative. See below. |
| `Config.Permission.RestrictCommandsWithAce` | `true` | **`false`** | `true` required a `command.<name>` ace that was never documented, so all four commands were blocked. |
| `Config.HitboxGuard.DefaultChestDamage` | `50` | **`0`** | The fallback let any unlisted weapon hash register as a hit. |

Events `crimson-pedscale:client:applyVisualHeadshot` and
`:applyVisualChestDamage` are replaced by a single
`crimson-pedscale:client:applyVisualDamage`. Nothing outside this resource
referenced them.

---

## Critical fixes

### 1. Remote instant-kill removed

`server:visualHeadHit` relayed to a victim-side `SetEntityHealth(ped, 0)` with
no proof a shot happened. Any player, with no permissions, could force any
scaled player's client to zero its own health — measured at **~10 forced
deaths per second**, at up to 220 m, through walls.

It also produced a death with no killer, so the medical resource logged it as
an unknown self-death.

Now: head hits apply capped, multiplied **damage** through the same
corroborated path as chest hits. Compensation can never deal the killing blow
(`MinHealthAfterCompensation`), so the lethal shot always comes from GTA's own
damage and the killer is attributed normally.

### 2. Victim-side corroboration

The victim's own client must have independently observed a real **firearm
damage event** within `CorroborationWindowMs` before applying anything. An
attacker who never actually fired produces no such event on the victim, so
nothing applies.

This is the load-bearing defence. The server-side checks bound the abuse rate;
this is what makes fabricated reports inert.

Corroboration keys on the `entityDamaged` game event (which carries the weapon
hash), **not** on a bare health drop. A medical resource's bleed tick, a fall,
fire or drowning all lower health, and accepting those would let a fabricated
report land whenever the victim happened to be taking any damage at all.

### 3. Non-firearms rejected

`IsPedShooting` is true for snowballs, balls, flare guns, petrol cans and fire
extinguishers. Combined with the `DefaultChestDamage` fallback, all of them
one-tapped a scaled target.

Three independent layers now block this, on both client and server:

1. **`NeverCompensate`** — an unconditional deny list, checked first. Nothing on
   it can ever compensate, whatever its group, whatever the damage table says,
   even with `RejectUnknownWeapons` turned off.
2. **`AllowedWeaponGroups`** — must be a real firearm group.
3. **`RejectUnknownWeapons`** — must be explicitly listed in `WeaponChestDamage`.

The deny list is not redundant. GTA classifies `WEAPON_FLAREGUN` as
`GROUP_PISTOL`, so a group whitelist alone lets it through. This is verified by
a test that runs under the weakest config a server owner could plausibly set,
and which also checks real firearms still work so the guard is not over-blocking.

### 3b. Compensation is tied to rounds actually fired

`IsPedShooting` is a *state* — true for a whole automatic burst and for a tail
after each shot. Gating on it plus a 115 ms timer gave roughly 8.7 "free"
compensations per second, and on slow weapons more compensations than bullets.
It now requires the shooter's ammo count to actually drop
(`RequireAmmoDecrease`), so at most one compensation exists per round.

### 4. Damage-immunity window removed

v40–v44 restored the local player's health whenever a ped scaled below 0.999
took any **non-firearm** damage inside a 900 ms window that re-armed whenever
another player stood within 2.35 m. "Non-firearm" covered melee, thrown,
explosive, fire, vehicle and fall damage — so standing near anyone as a 0.87
ped refunded all of it. That is a godmode bug, and a client raising its own
health is the single most commonly flagged anticheat pattern.

The health write is gone. The bogus upward impulse it was working around is
handled by clamping **velocity**, which the guard already did.

### 5. Downed and last-stand players protected

Medical resources do not leave a downed ped dead — they resurrect it and hold
it at a fixed health so it can play a bleed-out animation. `IsEntityDead()` is
therefore **false** for the whole last-stand window.

`Config.Scale.DisableWhenDead` tested `IsEntityDead` alone, so:

* a bleeding-out player was still a valid hitbox-guard target and could be
  finished off, skipping the EMS revive window entirely; and
* the scaler kept ground-anchoring a prone body every frame.

`Config.Compat` now reads the statebags and flags those resources already
publish (`LocalPlayer.state.dead`, `Player(id).state`, `IsPedFatallyInjured`,
plus a health threshold). **It modifies no other resource.**

### 6. Rate limiting

`requestData` and `characterTransition` were unauthenticated and each fanned
out a `TriggerClientEvent(-1)` broadcast — one client turned one event into one
packet per player. Measured: **1000 spam calls → 1000 server-wide broadcasts**;
now 1000 → 1. Hit reports additionally go through a per-shooter token bucket
that bounds a shooter's total rate across every target.

---

## Correctness fixes

* **Dead tackle branch.** `applyMatrixScale` referenced
  `shortTacklePhysicsActive` 500 lines before its `local function`
  declaration. Lua bound it as a nil **global**, and the `x and x()` guard
  swallowed it — so the v40 tackle isolation never executed once in four
  releases. Fixed with a forward declaration; the masking nil-guard was
  deliberately removed so a regression fails loudly.
* **No `onResourceStop`.** Restarting with the menu open left `SetNuiFocus`
  latched — a frozen player who had to relog. `SetPedCanRagdoll(false)` could
  also be left permanently latched, silently breaking every other resource's
  ragdolls. Both now cleaned up, along with every scaled ped's basis.
* **`clearMatrixScale` teleported peds.** It wrote a freshly raycast ground
  anchor rather than the ped's current Z — and it runs exactly when a ped stops
  qualifying (died, entered a vehicle, got attached to a stretcher, was frozen).
  It now restores the unit basis in place and skips attached/frozen peds.
* **Stale ground cache on teleport.** When every ground probe failed,
  `desiredRootZ` fell back to an absolute world Z cached from wherever the ped
  last stood — so an admin teleport, a respawn, an interior load or a medical
  revive re-anchored the player to their *previous* location's floor height.
  Teleports are now detected and the cached state dropped, and correction is
  skipped until collision has streamed in.
* **Shape-test status discarded.** `GetShapeTestResult`'s status was ignored, so
  an incomplete probe read as a genuine miss and fed the stale-cache fallback.
* **Dead Qbox lifecycle handlers.** `qbx_core:client:onPlayerLoaded` and
  `:onPlayerUnload` do not exist — qbx_core never fires either string. Replaced
  with `qbx_core:client:playerLoggedOut` plus the QBCore compat names, and the
  handlers are now debounced so a framework emitting more than one name does not
  run the transition (and its server-wide broadcast) twice per character load.
* **NUI focus theft.** `SetNuiFocus` is a single process-wide flag. This menu is
  pushed from the server, so `/givepedscale` on a player mid-X-ray or mid-MRI
  stole focus, and whichever menu closed first stranded the other. It now
  refuses to open over an existing NUI and only releases focus it took itself.
* **Unbounded tables.** `groundZCache` and `remoteAimState` were never pruned.
  `lastVisualHit` freed a leaving player's own row but left them as a *target*
  in every other shooter's row.
* **Config validation.** `Config` is now validated and clamped at start, with
  warnings printed for anything that cannot be clamped.
* **Dead code removed.** `setScaledLegIk` (empty stub), `legIkDisabled`,
  `shortTackleGuardUntil`, `primaryIdentifier`/`findIdentifier`, and the
  56-line doorway-camera helper that was never called.

## Performance

* `desiredRootZ` issued up to **4 shape-test probes per scaled ped per frame**
  with no caching. Results are now cached per ped with a short TTL and
  re-probed only on meaningful movement.
* The tackle thread ran `Wait(0)` permanently for any scaled player, doing an
  O(players) scan every frame. It now idles at `TackleGuard.IdlePollMs` and
  only spins per-frame while a tackle window is actually open.

---

## Hitbox guard: read before enabling

The guard is **client-authoritative by design**. The shooter's client decides
it landed a hit; FiveM gives the server no way to verify a shot happened. v45
bounds that with firearm whitelisting, weapon-match checks, a token bucket,
damage caps, a no-kill floor and victim-side corroboration.

**Those bound the abuse. They do not eliminate it.** A modified client can
still convert this into a capped damage advantage. That is why it ships
disabled.

If you enable it, test on a dev server first:

1. Enable it with `Config.Debug = true` and confirm normal firefights behave.
2. Have a test player scale to 0.87, go into last stand, and confirm they
   **cannot** be finished off by the guard.
3. Confirm kills still produce a proper death with the correct killer in your
   medical resource's logs.
4. Watch your anticheat's logs across a full firefight before going live.

## Anticheat note

This resource writes `SetEntityHealth` / `SetPedArmour` on the victim,
clamps velocity, and writes `SetEntityMatrix` to remote peds every frame.
Those are behaviours anticheats commonly inspect. v45 removes the two worst
offenders (health *increases*, and deaths with no damage event), but whether
your particular anticheat build reacts to what remains must be verified on a
dev server — it cannot be determined by reading this resource.
