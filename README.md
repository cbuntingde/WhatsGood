# WhatsGood

Dims quest and important bag items so you don't vendor or delete them by accident. Standalone, no libraries.

Built for **WoW Forever** (game version 1.16.1, `Interface: 16001`).

## What it does

- **Dims protected slots** (reason-tinted shade, colored outline + desaturated icon) in classic (`ContainerFrame1..N`), combined-bag, and main bank frames. Colors: blue = rare+, red = bound gear, gold = quest item, orange = hearthstone, green = custom list.
- **Blocks accidental vendor sales** by hooking `UseContainerItem` (and `C_Container.UseContainerItem` on retail) while the merchant window is open.
- **Blocks accidental deletes** by hooking `DeleteCursorItem` when the cursor holds a protected item.
- **Blocks accidental trade / mail / auction** by hooking the slot-click sinks when the cursor holds a protected item, plus `AcceptTrade` / `SendMail` / `StartAuction` final-action guards for items placed before protection was enabled (fail-open when the client lacks the query API).
- **Hold Shift to bypass** protection on every guard.
- **Tooltip note:** protected bag, bank, and equipped items get a `WhatsGood: protected (won't auto-sell)` line via `GameTooltip:SetBagItem` / `SetInventoryItem`.
- **Learns quest items:** quest items found by tooltip, and items your active quests need (read from the quest log), are remembered across sessions, so they are protected from the first sighting after every login.
- **`/wg audit`:** read-only gap finder listing unprotected bag items with reasons, so misses can be added with `/wg add`.

## What gets protected

| Rule | Default | Notes |
|---|---|---|
| Quality at/above threshold | `3` (Rare/blue+) | Quality chips in the panel / `/wg threshold 0-5` (0=Poor ... 5=Legendary) |
| Quest items + quest-starters | on | Detected via item type `Quest` and tooltip scan |
| Quest-log items | on | Special items your active quests need, matched by name in bags and learned on first sight (`/wg questlog on\|off`); stays protected after the quest ends |
| Soulbound gear | on | Only quality `>= 2` (green+), so junk greys stay sellable; also covers Bind-on-Equip/Pickup/Use lines |
| Hearthstone (ID `6948`, matched by ID or name) | on | Always protected when enabled |
| Custom list | empty | `/wg add` / `/wg remove`, always protected |

Junk (quality `0`) is never protected unless it is a quest item (with quest protection on), a learned quest-log or quest item, or on the custom list. The junk pass additionally never sells quest items, even grey ones with quest protection off.

## Usage

- `/wg` or `/whatsgood` — open settings panel
- `/wg help` — full command list
- `/wg status` — show current settings
- `/wg threshold 0-5` — minimum protected quality
- `/wg quest on|off` — toggle quest protection
- `/wg questlog on|off` — learn items your active quests need as soon as they show up in bags (default on; turning it off stops new learning, already-learned items stay protected)
- `/wg soulbound on|off` — toggle soulbound protection
- `/wg hearth on|off` — toggle Hearthstone protection
- `/wg trade on|off` — toggle trade protection
- `/wg mail on|off` — toggle mail protection
- `/wg auction on|off` — toggle auction protection
- `/wg autosell on|off` — auto-sell junk when a merchant opens (default off)
- `/wg minimap on|off` — toggle minimap button
- `/wg sound on|off` — play a sound when an action is blocked (default off)
- `/wg add <item link|itemID>` — always protect an item
- `/wg remove <item link|itemID>` — unprotect a custom item
- `/wg list` — show custom list
- `/wg audit` — list unprotected bag items with reasons (read-only)
- `/wg selljunk` — sell unprotected poor-quality bag items to the open merchant
- `/wg reset` — restore all settings to defaults (clears the custom list, keeps learned quest items)
- `/wg refresh` — re-dim all bags

Settings panel (`/wg`) is a classic WoW dialog: stone background and gold border, title banner, corner close button, six quality chips in the game's own colors (the active one lit, with a live "Guarding ..." status line in the header), two-column protection and options toggles with hover explanations, a scrolling custom-item list (icons, quality-colored names, item tooltips, per-row remove; drag a bag item onto the list to protect it and see its name and ID), plus Sell Junk / Reset / Close (draggable, `Esc` closes). Corrupt settings are sanitized on load.

Minimap button: a custom round badge (gold rim, leather bag, gold coin; `Media/WhatsGoodMinimap.tga`). Left-click opens settings, right-click toggles quest protection, drag to reposition. Angle is saved in `WhatsGoodDB.minimapAngle`.

## Installation

1. Download or clone this repo.
2. Copy the `WhatsGood` folder (containing `WhatsGood.toc` and `WhatsGood.lua`) into:
   `World of Warcraft\_forever_\Interface\AddOns\`
3. Restart the client (or `/reload` if the client supports it).
4. Look for the `WhatsGood ... loaded. Protected items are dimmed ...` line in chat and open `/wg` to configure.

Settings persist per account in the `WhatsGoodDB` SavedVariable.

## Compatibility

- Standalone Lua, no external libraries.
- Works with both `C_Container.GetContainerItemLink` (retail API) and the vanilla `GetContainerItemLink` global, with `pcall` guards.
- Tooltip scanning uses its own hidden `GameTooltip` (`WhatsGoodScanTooltip`) and caches per item ID.
- Bag refresh hooks `ContainerFrame_Update` / `ContainerFrameCombinedBags:Update` when available, plus `PLAYER_LOGIN`, `BAG_UPDATE`, `BAG_UPDATE_DELAYED`, `PLAYERBANKSLOTS_CHANGED`, `QUEST_LOG_UPDATE`, `MERCHANT_SHOW`, and `GET_ITEM_INFO_RECEIVED`.

## Files

- `WhatsGood.toc` — addon manifest (`Interface: 16001`, version `1.7.0`)
- `WhatsGood.lua` — all logic (classification, dimming, sell/delete/trade/mail/auction guards, panel, minimap button, slash commands)
- `Media/WhatsGoodMinimap.tga` — 64x64 minimap badge art (generated; loaded by path, so keep the folder named `WhatsGood`)
- `tests/run.lua` — headless stub-harness tests (`lua tests/run.lua`, no client needed, 127 checks)
- Public API for other addons/skins: `WhatsGood_IsProtected(bag, slot)`, `WhatsGood_Reason(bag, slot)`, `WhatsGood_IsProtectedID(itemID, link)` — all fail-safe (never error)
- `.github/workflows/ci.yml` — syntax check + tests on Lua 5.1
- `CHANGELOG.md` — release notes

## License

MIT — see [LICENSE](LICENSE).
