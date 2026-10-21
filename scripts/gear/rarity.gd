class_name Rarity
## Rarity tiers and their (saturated) colours.

enum { COMMON, UNCOMMON, RARE, LEGENDARY, MYTHIC }

const IDS: Array[String] = ["common", "uncommon", "rare", "legendary", "mythic"]
const NAMES: Array[String] = ["Common", "Uncommon", "Rare", "Legendary", "Mythic"]
const COLORS: Array[Color] = [ # punchy, saturated
	Color(0.86, 0.86, 0.82), # common    - bone white
	Color(0.22, 0.88, 0.28), # uncommon  - green
	Color(0.18, 0.55, 1.00), # rare      - blue
	Color(0.68, 0.28, 1.00), # legendary - purple
	Color(1.00, 0.62, 0.05), # mythic    - molten orange-gold
]
const STAT_BONUS: Array[int] = [0, 3, 6, 10, 14] ## added to weapon stat rolls
const PERK_SLOTS: Array[int] = [0, 1, 2, 3, 3] ## named attributes rolled per rarity (playtest #33; data/perks.json attribute_counts wins); a Mythic adds its signature


static func from_id(id: String) -> int:
	return max(IDS.find(id), 0)


static func color(r: int) -> Color:
	return COLORS[clampi(r, 0, 4)]


static func name_of(r: int) -> String:
	return NAMES[clampi(r, 0, 4)]
