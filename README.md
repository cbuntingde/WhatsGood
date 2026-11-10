# WhatsGood

Dims quest and important bag items so you don't vendor or delete them by accident. Standalone, no libraries.

Built for **WoW Forever 1.16.0** (`Interface: 16001`).

## What it does

- **Dims protected bag slots** (dark overlay + desaturated icon) in classic (`ContainerFrame1..N`) and combined-bag frames.
- **Blocks accidental vendor sales** by hooking `UseContainerItem` while the merchant window is open.
- **Blocks accidental deletes** by hooking `DeleteCursorItem` when the cursor holds a protected item.
- **Hold Shift to bypass** protection for both sell and delete.
- **Tooltip note:** protected bag items get a `WhatsGood: protected (won't auto-sell)` line via `GameTooltip:SetBagItem`.

## What gets protected

| Rule | Default | Notes |
|---|---|---|
| Quality at/above threshold | `3` (Rare/blue+) | Slider / `/wg threshold 0-5` (0=Poor ... 5=Legendary) |
| Quest items + quest-starters | on | Detected via item type `Quest` and tooltip scan |
| Soulbound gear | on | Only quality `>= 2` (green+), so junk greys stay sellable |
| Hearthstone (ID `6948`) | on | Always protected when enabled |
| Custom list | empty | `/wg add` / `/wg remove`, always protected |

Junk (quality `0`) is never protected unless it is a quest item or on the custom list.

## Usage

- `/wg` or `/whatsgood` — open settings panel
- `/wg help` — full command list
- `/wg status` — show current settings
- `/wg threshold 0-5` — minimum protected quality
- `/wg quest on|off` — toggle quest protection
- `/wg soulbound on|off` — toggle soulbound protection
- `/wg hearth on|off` — toggle Hearthstone protection
- `/wg minimap on|off` — toggle minimap button
- `/wg add <shift-click link|itemID>` — always protect an item
- `/wg remove <shift-click link|itemID>` — unprotect a custom item
- `/wg list` — show custom list
- `/wg refresh` — re-dim all bags

Settings panel (`/wg`) has checkboxes, a quality slider, a custom-list count, and a Close button (draggable, `Esc` closes).

Minimap button: left-click opens settings, right-click toggles quest protection, drag to reposition. Angle is saved in `WhatsGoodDB.minimapAngle`.

## Installation

1. Download or clone this repo.
2. Copy the `WhatsGood` folder (containing `WhatsGood.toc` and `WhatsGood.lua`) into:
   `World of Warcraft\_forever_\Interface\AddOns\`
3. Restart the client (or `/reload` if the client supports it).
4. Look for `WhatsGood: loaded...` in chat and open `/wg` to configure.

Settings persist per account in the `WhatsGoodDB` SavedVariable.

## Compatibility

- Standalone Lua, no external libraries.
- Works with both `C_Container.GetContainerItemLink` (retail API) and the vanilla `GetContainerItemLink` global, with `pcall` guards.
- Tooltip scanning uses its own hidden `GameTooltip` (`WhatsGoodScanTooltip`) and caches per item ID.
- Bag refresh hooks `ContainerFrame_Update` / `ContainerFrameCombinedBags:Update` when available, plus `BAG_UPDATE`, `BAG_UPDATE_DELAYED`, `MERCHANT_SHOW`, and `GET_ITEM_INFO_RECEIVED`.

## Files

- `WhatsGood.toc` — addon manifest (`Interface: 16001`, version `1.1.0`)
- `WhatsGood.lua` — all logic (classification, dimming, sell/delete guards, panel, minimap button, slash commands)
- `CHANGELOG.md` — release notes

## License

MIT — see [LICENSE](LICENSE).
