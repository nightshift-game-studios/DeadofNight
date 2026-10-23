# Scrap (Economy v2, save v6)

Scrap is a persistent currency, kept on death. It is earned only by scrapping (salvaging) gear (stash, Kit, Armory),
grenade items included. It pays for Armory weapon Rework tiers, and attachments and optics can be bought with it (or with
Gravemarks; playtest 2026-10-22 #2, main 41bd224). Gravemarks still buy Merchant stock.

## Progress (autoload)
- `scrap_balance() -> int`
- `add_scrap(n, source := "") -> int`: returns the new balance.
- `spend_scrap(n) -> bool`: false if short (Batch C respecs use this).
- `scrap_value(item) -> int`: what scrapping pays.
- `scrap_item(item, inv := bound inventory, source := "stash") -> int`: removes the item through `Inventory.dismantle`,
  pays Scrap, saves, and returns the Scrap paid (0 = refused, e.g. equipped).
- Vars: `scrap`, `scrap_lifetime`, `match_scrap`.
- Signals: `scrap_changed(balance)`, `scrap_gained(amount, source)`.

`Inventory.dismantle(item, source := "stash", pay_scrap := true) -> int` now pays Scrap. The character screen's existing
right-click scrap already goes through it.

## Yield (`data/armory.json -> scrap`)
- Per rarity: Common 1, Uncommon 3, Rare 6, Legendary 12, Mythic 25 (was 1/2/4/8/15).
- Plus 1 per 50 Item Power above 100 (`item_power_step`).
- Lookup: `Armory.scrap_yield(rarity, ip)`.

## Salvage API (2026-10-22 #2)
- `Progress.salvage_preview(item, inv := bound) -> {scrap, rarity, rarity_id, item_power, ok, reason}`: reason is
  "Equipped" or "Not in your stash"; the Scrap amount is still shown so the card can display it.
- `Progress.salvage_table(ip := 100)` / `Armory.salvage_table(ip)`: `[{rarity, rarity_id, name, scrap}]` C to M.
- To scrap: `Progress.scrap_item(item)` as before.
- No loop: the best salvage at each rarity (even at IP 210) is below that rarity's Scrap attachment price and its
  Merchant Gravemark price. Attachments are unlocks and can't be salvaged. grenade_items_test checks this.

## Attachments for Scrap (`armory.json -> attachment_shop`)
| Rarity | Scrap price | Salvage (IP 100) | Parts |
|---|---|---|---|
| Common | 8 | 1 | 10 |
| Uncommon | 14 | 3 | 16 |
| Rare | 24 | 6 | 9 |
| Legendary | 40 | 12 | 6 |
| Mythic | 65 | 25 | 3 (Second Mouth, Ember Window Mag, Echo Drum) |

- Rarity comes from `Armory.attachment_rarity(id)`. It uses the optic's rarity if it has one. Otherwise it maps the
  Gravemark cost (2 C, 3-4 U, 5-6 R, 7-8 L), raises that to the tier floor (T2 Rare, T3 Legendary), then moves unique
  parts up one tier.
- All 44 parts together cost 955 Scrap, about 21 Medium matches.
- `Armory.attachment_prices(id)` gives `{"scrap": n, "gravemark": n}`. `attachment_price(id, cur)`,
  `attachment_currencies()`, `attachment_currency()` (the default) and `attachment_price_table()` are also available.
- Instance calls: `api.purchase_with(id, "scrap" | "gravemark")` and `api.cost_in(id, cur)`. `purchase_check(id, cur)`
  gives the refusal text, e.g. "Need 14 Scrap (you have 13)".
- `list_attachments` and `optic_choices` rows gain `currency`, `rarity`, `prices`, `scrap_cost`, `gravemark_cost`,
  `can_afford_scrap` and `can_afford_gravemark`.
- **Default currency is Scrap (2026-10-22, v070 #4).** `attachment_shop.default_currency` is now `"scrap"`, so
  `attachment_currency()`, `cost_of(id)`, `purchase(id)`, `buy_attachment(id)`, `list_attachments().currency` and
  `purchase_check(id)` all use Scrap. Gravemarks still work everywhere with an explicit currency:
  `purchase_with(id, "gravemark")`, `cost_in(id, "gravemark")`, `cost_of(id, "gravemark")` and `purchase_check(id, "gravemark")`.
  An unknown currency is refused (`attachment_currency("bogus") == ""`). Upgrades were already Scrap-only.
  Gooey's Armory card (9f71266) shows both prices with a BUY per currency, so no UI change is needed.

## Spending
- `armory.json -> upgrades.currency = "scrap"`. Tier costs are 10 / 25 / 50 / 90 / 150, and the rocket launcher x1.25.
- `gravemark_cost` keeps the old 3/6/11/20/36, used when currency is set back to `"gravemark"`.
- Armory helpers:
  - `upgrade_currency()`
  - `balance(currency)`
  - `currency_word(currency)`
  - `purchase_check` refusal text, e.g. "Need 25 Scrap (you have 10)"
- `list_upgrades()` entries and their tiers carry `"currency"` (Gooey: show Scrap on the Rework track).

## Save
- SAVE_VERSION 6 adds `[scrap] version=1, balance, lifetime`.
- Older saves load with Scrap 0.
- XP is re-based onto the XP curve (`Progress.rebase_xp`, which keeps level and fraction; `xp_rebased_from` records the old
  value).
- Character files (Batch C) get `stats/xp_curve=1`, so they are re-based once and never twice.
- Writes stay crash-safe: .tmp, then .bak, then rename. A torn main file recovers Scrap from the .bak (econ_test).

## Model
`Armory.expected_match_scrap(diff, rounds)` / `matches_to_max()` (also `attachments_scrap_cost` and
`attachments_in_scrap`). With the new yields, Medium r10 pays about 46 Scrap a match (was 31). One weapon reaches V in
about 8 matches (was 10-11), and all attachments take about 21 matches if bought with Scrap.
