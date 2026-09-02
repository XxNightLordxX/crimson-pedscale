# Crimson Ped Scale v44 — initial aim burst + normal movement speed

Based on v43.

- Keeps the v43 initial remote short-ped aim correction.
- Removes `ForcePedAiAndAnimationUpdate` from the every-frame "weapon merely equipped" path.
- Uses a ~280 ms per-frame burst only when remote free-aim/shooting starts, then a light 110 ms maintenance refresh while aim remains active.
- No forced animation rebuild while simply running, sprinting, or combat-rolling with a weapon equipped, so observer-side movement/roll speed should remain native.
- Does not rotate the ped, create an aim task, redirect bullets, or change hitboxes/damage/grounding/tackle/ledge/stair logic.
