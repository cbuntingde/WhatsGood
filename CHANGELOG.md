# Changelog

All notable changes to WhatsGood are documented here.

## [1.6.0] - 2026-11-11

- Quest-log item memory: items named by your active quests (the quest
  log's special items) are learned as soon as they appear in your bags,
  so they are protected before any tooltip scan. Learned items stay
  protected after the quest ends. Toggle with `/wg questlog on|off` or
  the Options checkbox (on by default). Clients without the quest-log API
  fail open.
- Custom minimap icon: a 64x64 gold-rimmed badge (leather bag, gold coin)
  in `Media/WhatsGoodMinimap.tga` replaces the stock bag icon. The badge
  carries its own rim, so Blizzard's tracking ring is no longer layered on.
- Quality threshold is six quality chips in the game's own colors, not a
  slider. The active chip is lit with a gold edge, and a live "Guarding ..."
  status line in the header names what is protected.
- Native WoW dialog look: the settings panel now wears the classic
  DialogBox stone background and gold border, a title banner with the
  addon name, and a corner close button, instead of the flat dark
  rectangle. Clients without `SetBackdrop` keep the painted fallback.
- One spacing system: content padding, section rhythm, and row pitch are
  constants, and the panel height is derived from a layout cursor, so
  widgets can no longer overlap or drift.
- Protection guards and behavior toggles split into two sections; every
  checkbox explains its rule on hover.
- Custom items are a real scrolling list: item icon, quality-colored
  name, item tooltip on hover, and a per-row remove button, with an
  empty-state note and a live count. Names resolve as soon as item info
  arrives while the panel is open.
- Version references corrected to WoW Forever 1.16.1.
- Headless tests: 115 checks, including widget-mock layout assertions
  (bounds, overlaps, column/row pitch), refresh sync, list
  add/remove/scroll, every close path, quest-log learning, and the
  minimap badge file.

## [1.5.0] - 2026-11-11

- New settings panel look, in the modern dark addon style: translucent dark
  panel with a flat gold outline, header icon and version, gold section
  headers with divider lines, a two-column protection-toggles grid, a dark
  inset box for the custom item list, and a shift-click input box with
  Add / Remove buttons (same validation as `/wg add|remove`).
- Protected bag slots are now tinted by reason instead of a flat black dim,
  with a matching thin outline: blue = rare+, red = bound gear, gold = quest
  item/starter/learned, orange = hearthstone, green = custom list. Outline
  is drawn with color textures, so no art files are required.
- `/wg add|remove` and the panel buttons share one validation path, so both
  surfaces behave identically.
- Panel rendering fixes for clients where plain frames can't use
  `SetBackdrop` (modern clients need the `BackdropTemplate` mixin): the dark
  background is now painted with color textures, so the panel is no longer
  see-through. Toggle labels use the small font with wider row spacing so
  the two columns no longer overlap, and the slider's redundant center text
  was dropped. A failed panel build now reports the error in chat instead
  of failing silently.
- No settings, commands, or saved variables changed; the panel is still
  draggable, `Esc`-closable, and fully `pcall`-guarded.

## [1.4.1] - 2026-11-12

- Fixed: protected items (Hearthstone, potions, food, ...) are always usable
  again. The `UseContainerItem` sell guard is now fail-open: the
  merchant-visibility check is `pcall`-guarded, the hook lets the original
  call through on any error, and block warnings can no longer throw. Selling
  a protected item to an open merchant is still blocked; Shift still forces.
- Headless stub-harness tests extended (`lua tests/run.lua`, 63 checks),
  including a merchant-check-error case proving use still works.

## [1.4.0] - 2026-11-12

- Learned quest memory: tooltip-discovered quest items are remembered in
  `WhatsGoodDB.learned`, so they stay protected from the first sighting after
  every login. Survives `/wg reset`; corrupt entries are pruned on load.
- `/wg audit`: read-only gap finder listing unprotected bag items with the
  reason each was left alone (capped at 25 lines plus a summary count).
- `/wg status` now reports the learned count too.
- Headless stub-harness tests extended (`lua tests/run.lua`, 60 checks),
  including a simulated fresh login proving learned protection persists.

## [1.3.0] - 2026-11-12

- Bound-item protection: the soulbound rule now also covers Bind-on-Equip /
  Bind-on-Pickup / Bind-on-Use lines, so green BoE gear is protected even
  before it shows the literal "Soulbound" line. Tooltip matches the localized
  `ITEM_SOULBOUND` global when the client provides one.
- Hearthstone matched by ID and by name, so variant stones are protected too.
- Defense in depth: `AcceptTrade` / `SendMail` / `StartAuction` final-action
  guards block a protected item placed before protection was enabled. Each
  probe fails open when the client lacks the query API.
- Retail entry points: `C_Container.UseContainerItem` / `PickupContainerItem`
  hooked with the same rules when present.
- Auto-sell junk: `/wg autosell on|off` (off by default) runs the junk pass
  on `MERCHANT_SHOW`; the panel has a matching checkbox.
- `/wg reset` (and a panel Reset button) restores all defaults; corrupt
  SavedVariables are sanitized on load and the threshold is clamped 0-5.
- Junk pass never sells quest items (even grey ones with quest protection off)
  and refuses while the cursor holds something.
- Dimming scan no longer stops at the first missing `ContainerFrame` number;
  tooltip note added to `SetInventoryItem` (bank, equipped gear) as well.
- Public API for other addons: `WhatsGood_IsProtected`,
  `WhatsGood_Reason`, `WhatsGood_IsProtectedID` (all fail-safe).
- Headless stub-harness tests extended (`lua tests/run.lua`, 52 checks).

## [1.2.0] - 2026-11-10

- Trade / mail / auction guards: protected items can't be placed into trade,
  mail, or auction slots by accident (`/wg trade|mail|auction on|off`, all on
  by default). Empty-cursor clicks still pick items back up; Shift forces.
- Bank dimming: protected slots in the main bank window get the same overlay.
- Manual junk run: `/wg selljunk` (or the panel's Sell Junk button) sells only
  unprotected poor-quality bag items to the open merchant.
- Optional block sound: `/wg sound on|off` (off by default).
- Settings panel lists the first custom entries by name, not just the count.
- Fixes: tooltip cache re-scans items whose info arrives late instead of
  trusting an empty first scan; per-character `custom` table no longer shares
  a reference with the defaults; `/wg minimap` refreshes the panel checkbox.
- Headless stub-harness tests (`lua tests/run.lua`, 30 checks) + CI.

## [1.1.0] - 2026-11-07

- Settings panel (`/wg`) with quest / soulbound / hearth / minimap toggles, quality slider, custom-list count.
- Minimap button: click opens settings, right-click toggles quest protection, drag to reposition.
- Custom protect list: `/wg add|remove|list <link|itemID>`.
- Slash commands: `threshold`, `quest|soulbound|hearth|minimap on|off`, `status`, `refresh`, `help`.
- Sell guard (merchant open) and delete guard (cursor item), both bypassed with Shift.
- Dimmed overlay for protected bag slots (classic + combined frames) and GameTooltip note.
