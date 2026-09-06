# Crimson Ped Scale v45 — hitbox guard removed, security hardened

Based on v44. **This is a security release.** The scaling, grounding,
stair/ledge and remote-aim behaviour from v44 is unchanged. What changed is
everything that could hurt a player or the server — and the hitbox guard, which
is gone.

Scale range is unchanged at **0.87 – 1.10**.

---

## The headline: the hitbox guard has been removed

v44's guard compensated for GTA's damage capsule not following the visual matrix
scale. The shooter's client ray-tested the rendered head and torso, reported a
hit to the server, and the server told the **victim's** client to damage or kill
itself.

It is removed rather than hardened, for two independent reasons.

**1. It was unsafe, and could not be made safe.** FiveM gives the server no way
to verify a shot actually happened. Reproduced by executing the v44 code:

| Exploit | Measured on v44 |
|---|---|
| Unauthenticated remote kill via `visualHeadHit` | 200 crafted events → **200 forced deaths** (~10/sec, any scaled player, 220 m, through walls, no permissions needed) |
| Non-firearm one-tap | snowball, ball, flare gun, petrol can, **fire extinguisher** all killed |
| Broadcast amplification via `characterTransition` | 1000 spam calls → **1000** server-wide broadcasts |
| Damage immunity for short peds | melee / vehicle / explosion / fire refunded in a re-armable 900 ms window near any player |

**2. It could not be made correct either.** The guard exists to compensate shots
the engine scored as a **miss**. Any check that the shot really landed therefore
refuses exactly the case the guard exists for, while double-damaging the hits
that already landed. Safety and function are mutually exclusive here — there is
no version of this feature that is both.

An intermediate v45 draft added exactly that check and inverted the guard. That
draft was discarded in favour of removing the feature.

### What this costs you

A matrix-scaled ped keeps a small native hitbox mismatch. At 0.87 the damage
capsule sits slightly outside the rendered body, so some shots that look good
will miss; at 1.10 the reverse. **This is now accepted as a characteristic of
matrix scaling rather than corrected with client-authoritative damage.**

If it becomes a problem in practice, narrowing `Config.Scale.Min` / `Max` toward
1.00 reduces the mismatch. There is no script-side fix that is safe.

### What went with it

Every `SetEntityHealth` and `SetPedArmour` write in the resource, the shooter
ray-test, the shot-detection thread, the health observer, both server hit
events, and `Config.HitboxGuard` in its entirety — roughly 700 lines.

The resource no longer writes player health or armour **at all**.

---

## Other critical fixes

**Damage-immunity window removed.** v40–v44 restored the local player's health
whenever a ped scaled below 0.999 took any *non-firearm* damage inside a 900 ms
window that re-armed whenever another player stood within 2.35 m. "Non-firearm"
covered melee, thrown, explosive, fire, vehicle and fall damage — so standing
near anyone as a 0.87 ped refunded all of it. A client raising its own health is
also the single most commonly flagged anticheat pattern. The velocity clamp it
was working around is retained.

**Downed players no longer ground-anchored.** Medical resources resurrect a
downed ped and hold it at a fixed health, so `IsEntityDead` is **false** through
last stand. `Config.Scale.DisableWhenDead` tested `IsEntityDead` alone, so the
scaler kept re-anchoring a prone, bleeding-out body every frame. `Config.Compat`
now reads statebags those resources already publish. **No other resource is
modified.**

**Rate limiting.** `requestData` and `characterTransition` were unauthenticated
and each fanned out a `TriggerClientEvent(-1)` — one client turned one event
into one packet per player.

---

## Correctness fixes

- **Dead tackle branch.** `applyMatrixScale` referenced `shortTacklePhysicsActive`
  500 lines before its `local function` declaration. Lua bound it as a nil
  **global**, and the `x and x()` guard swallowed it — so the v40 tackle
  isolation never executed once in four releases. Forward-declared; the masking
  nil-guard was removed deliberately so a regression fails loudly.
- **No `onResourceStop`.** Restarting with the menu open left `SetNuiFocus`
  latched — a frozen player who had to relog. `SetPedCanRagdoll(false)` could
  also stay latched, silently breaking every other resource's ragdolls.
- **`clearMatrixScale` teleported peds.** It wrote a freshly raycast ground
  anchor rather than the ped's current Z — and it runs exactly when a ped dies,
  enters a vehicle, or is attached to a stretcher.
- **Stale ground cache on teleport.** A respawn, admin teleport, interior load or
  medical revive re-anchored the player to their *previous* location's floor.
- **Dead Qbox lifecycle handlers.** `qbx_core:client:onPlayerLoaded` and
  `:onPlayerUnload` do not exist — qbx_core never fires either. Replaced with
  `qbx_core:client:playerLoggedOut` plus the QBCore compat names, debounced
  **per event kind** (a shared debounce made an unload swallow the load that
  follows it on a character switch).
- **NUI focus theft.** `/givepedscale` on a player mid-X-ray or mid-MRI stole
  focus; whichever menu closed first stranded the other.
- **ACE mismatch.** `RestrictCommandsWithAce = true` required an undocumented
  `command.<name>` ace, blocking all four commands on a stock install.
- Shape-test status checked; unbounded tables pruned; config validated at start;
  dead code removed (`setScaledLegIk`, `legIkDisabled`, `primaryIdentifier`, the
  uncalled doorway-camera helper).

## Performance

- `desiredRootZ` issued up to **4 shape-test probes per scaled ped per frame**
  with no caching. Now cached per ped with a short TTL.
- The tackle thread ran `Wait(0)` permanently for any scaled player, with an
  O(players) scan every frame. It now idles and only spins during a tackle.

---

## Verification

A FiveM native stub harness executes the resource directly. Two suites:

| Suite | v44 | v45 |
|---|---|---|
| `suite.lua` — 14 invariants | 11 fail | **all pass** |
| `test_lifecycle.lua` — character switching | — | **all pass** |

Four of those invariants assert the *absence* of every damage primitive, which
is a stronger and more durable claim than "the guard is safe". Two more assert
that scaling still works end to end, since the removal deleted ~700 lines.

`luacheck` clean on all three Lua files; `node --check` on the NUI.

## Anticheat note

The resource no longer writes player health or armour at all, which removes the
two behaviours most likely to attract attention: health *increases*, and deaths
with no corresponding damage event. It still clamps velocity briefly after a
firearm hit and writes `SetEntityMatrix` to remote peds each frame — inherent to
matrix scaling. Verify on a dev server before going live.
