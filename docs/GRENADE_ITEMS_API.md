# Grenade items (playtest 2026-10-22 #5, DESIGN §25), main 41bd224

Grenades are now gear. The `GrenadeItem` (scripts/items/grenade_item.gd, a GearItem) in the Inventory **"grenade"** slot
is the grenade you throw. Swapping it changes the type and its rolled **Fittings**. Grenade count (charges and cooldown
refill) stays on the player and is never reset by a swap. If the slot is empty, you throw the class grenade
(PlayerClass.grenade_id). The terms are original: the item type is "Grenade", the rolled parts are "Fittings", and the
maker is the manufacturer.

## Item
- `grenade_id`: the grenades.json id, which is also the ThrownProjectile variant. It is never renamed.
- `rarity`: always the type's rarity, forced on load so Netz's variant and rarity check still holds.
- `item_power`: rolled like other gear. Each damage key is multiplied by (1 + (IP-100) x 0.003).
- `fittings`: a dict of fitting id to rolled value, rolled 1/1/2/2/3 by rarity (C/U/R/L/M). Starter items have none.

| Fitting | Effect |
|---|---|
| Heavy Packing | +6-15% damage |
| Wide Casing | +6-15% radius |
| Quick Rearm | -6-14% cooldown |
| Short Wick | -15-30% fuse; fused types only |
| Long Arm | +12-25% throw |
| Steeped | +10-25% type effect; not on frag or pulse |

- `throw_data()` builds the thrown grenade from the grenades.json base, then Item Power, then Fittings. That result is
  `player.grenade_data` and `spec.data`.
- `to_dict()` is the normal GearItem dict plus `"class":"grenade"`, `"grenade_id"`, `"variant"`, `"fittings"` (the
  `"rarity"` int and `"item_power"` come from GearItem).

## API rows for Gooey
| Call | Returns / notes |
|---|---|
| `Inventory.GRENADE_SLOTS` / `ALL_SLOTS` / `SLOT_LABELS.grenade` | `["grenade"]`, all 9 slots, "Grenade" |
| `inv.equipped_grenade()` | GrenadeItem or null (null means the class grenade) |
| `inv.equip_grenade(item)` / `inv.unequip_grenade()` | bool. The normal `equip(item)` and Hold-E `take_and_equip` also work |
| `inv.grenade_equipped(item)` signal | fires on every grenade slot change; `player.grenade_changed` also fires |
| `item.card_stats()` | 4 rows (Damage, Radius, Cooldown, Fuse), same shape as weapon/armor, so `inv.compare(item)` works. `compare()` rows are `{label, delta, better, worse, text, numeric}`: a row whose text isn't a number (Fuse `impact`) comes back `numeric: false`, `delta 0`, `text ""`, neither better nor worse |
| `item.fitting_rows()` | `[{id, name, value, pct, text}]`, e.g. "Quick Rearm: -10% cooldown" |
| `item.effect_line()` / `get_summary()` | the type's one-line effect / the full card text |
| `item.effect_color()` / `world_model()` | the tint #hex / `[glb, scale]` |
| Icon key | `grenade_<grenade_id>` (`grenade_pulse` is still missing, see Desi) |
| `Merchant.grenade_stock()` | `[{offer_id, item, grenade_id, rarity, rarity_id, rarity_name, item_power, fittings, price, currency:"gravemark", sold, owned, can_afford, reason}]`. 2 offers, same refresh and reroll as the guns |
| `Merchant.buy_grenade(offer_id)` | `{ok, reason, item}`, same as `buy()`; signal `grenade_purchased(offer_id, item, price)` |
| Salvage | same as other gear: `Progress.salvage_preview(item)`, `scrap_item(item)` (see SCRAP_API.md) |

Drops: loot-table `{kind: grenade}` entries now roll a GrenadeItem; the odds are unchanged. The pickup shows the grenade
model. Tap E puts it in the backpack; hold E equips it. A legacy grenade consumable becomes an equipped item.
Merchant price is rarity price x 0.5 x 0.5: 3 / 7 / 16 / 39 / 79 Gravemarks.

## Save
Stash v2 adds the "grenade" slot. `Progress.migrate_stash` adds it empty, and the first restore fills it with the class
grenade as a Common starter item (IP 100, no Fittings). Weapons and armor are untouched. A removed grenade type loads as
null and is dropped.

## player.gd
It already works on main with no shared-file change. The item rides on the §24c meta (`grenade_override = "@<item_id>"`
leads to `GearDB.grenade()`, which returns the item's throw data), so apply_stats, respec and class change all keep it.
`patches/grenade_items_player.gd.diff` (1 line) swaps that bridge for `GrenadeItem.resolve(self, grenade_data)`. It is
optional cleanup.

## Netz sync note
1. Replicate the equipped grenade's `item.to_dict()`. Send it on join and on every `Inventory.grenade_equipped(item)`
   (null means the class grenade, so send `{}`).
2. The host stores it per peer and rebuilds the stats with `GrenadeItem.throw_data_from_dict(d)`. That call is static,
   so the host needs no item instance.
3. On each throw, check `spec.variant == d.grenade_id` and `spec.rarity == d.rarity` (the rarity is the type's, so the
   existing check holds). Then spawn with `spec.data = the rebuilt dict`, never the client's numbers.
4. Puppets fly and show FX from `spec.variant` and `data.color`. Damage and RNG stay on the host copy. The thrower
   keeps charges and cooldown.

## Desi icons
- `grenade_pulse`: Tremor Charge. Reuse the frag silhouette with a #7FB8FF band and 3 ripple rings. It is the only
  grenade type with no icon.
- `slot_grenade`: an empty grenade-slot ghost (a frag outline with the pin, 40% alpha) for the character screen.
- Fitting glyphs, small (24 px), monochrome, tinted by the UI:

| Icon | Look |
|---|---|
| `fit_heavy_packing` | stacked powder charges |
| `fit_wide_casing` | burst ring |
| `fit_quick_rearm` | hourglass with a pin |
| `fit_short_wick` | a short lit fuse |
| `fit_long_arm` | an arc arrow |
| `fit_steeped` | a drop in a flask |

- Reuse: `grenade_frag` / `cinderjar` / `shiverglass` / `tallyhook` / `rookery` / `gravewell` / `leechbell` /
  `requiem_bell` as the item icons. There are no rarity-frame PNGs; UIStyle tile frames already tint by
  `Rarity.color`. The `ci_*` class-item icons don't fit grenades and are not reused.
