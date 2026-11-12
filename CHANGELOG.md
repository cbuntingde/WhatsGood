# Changelog

All notable changes to WhatsGood are documented here.

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
