-- WhatsGood headless tests (Lua 5.1+ and 5.4+ compatible).
--
-- The addon is plain Lua with WoW API calls, so this harness stubs the client
-- globals (bags, cursor, merchant, chat, hookable sinks) and drives the real
-- addon file through its public surface: slash commands and hooked globals.
-- No WoW client needed.
--
-- Conventions: _CURSOR/_CURSOR_TYPE/_CURSOR_ID/_CURSOR_LINK describe the
-- cursor, _SHIFT is the Shift state, _MERCHANT toggles MerchantFrame:IsShown.
-- Run:  lua tests/run.lua   (from the addon folder)

local PASS, FAIL = 0, 0
local function check(cond, name)
  if cond then
    PASS = PASS + 1
  else
    FAIL = FAIL + 1
    print("FAIL - " .. tostring(name))
  end
end

-- ---------- client stubs (must exist before the addon loads) ----------

_G.strtrim = function(s)
  return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local handlers = {}
local function makeFrame()
  local f = {}
  function f:SetScript(ev, fn) handlers[ev] = fn end
  function f:RegisterEvent(ev) end
  return f
end

_G.TIP_LINES = 0
_G.TIP_TEXT = {}
local function makeTip()
  local tip = {}
  function tip:SetOwner() end
  function tip:ClearLines() end
  function tip:SetHyperlink() return true end
  function tip:NumLines() return _G.TIP_LINES end
  return tip
end

_G.CreateFrame = function(ftype, name, parent, template)
  if template == "GameTooltipTemplate" then return makeTip() end
  return makeFrame()
end

local function setTip(lines)
  _G.TIP_LINES = #lines
  _G.TIP_TEXT = lines
  for i = 1, #lines do
    local idx = i
    _G["WhatsGoodScanTooltipTextLeft" .. i] = {
      GetText = function() return _G.TIP_TEXT[idx] end,
    }
  end
end

_G.INFO = {} -- [itemID] = { name, quality, itype }
_G.GetItemInfo = function(idOrLink)
  local id = tonumber(tostring(idOrLink):match("item:(%d+)")) or idOrLink
  local e = _G.INFO[id]
  if not e then return nil end
  return e.name, e.link or ("item:" .. id), e.quality, nil, nil, e.itype
end

_G.SLOTS = {} -- ["bag:slot"] = item link
_G.GetContainerItemLink = function(bag, slot) return _G.SLOTS[bag .. ":" .. slot] end
_G.NUMSLOTS = {}
_G.GetContainerNumSlots = function(bag) return _G.NUMSLOTS[bag] or 0 end
_G.NUM_BAG_SLOTS = 4

_G._CURSOR, _G._CURSOR_TYPE, _G._CURSOR_ID, _G._CURSOR_LINK = false, nil, nil, nil
_G.GetCursorInfo = function()
  if not _G._CURSOR then return nil end
  return _G._CURSOR_TYPE or "item", _G._CURSOR_ID, _G._CURSOR_LINK
end
_G.CursorHasItem = function() return _G._CURSOR and true or false end
_G._SHIFT = false
_G.IsShiftKeyDown = function() return _G._SHIFT end

_G._MERCHANT = false
_G.MerchantFrame = { IsShown = function() return _G._MERCHANT end }

_G.CHAT = {}
_G.DEFAULT_CHAT_FRAME = {
  AddMessage = function(_, msg) table.insert(_G.CHAT, tostring(msg)) end,
}
_G.UIErrorsFrame = nil
_G.SOUNDS = 0
_G.PlaySound = function() _G.SOUNDS = _G.SOUNDS + 1 end
_G.ITEM_SOULBOUND = "Soulbound"

-- Hookable sinks: the addon wraps these; counters observe the originals.
_G.USE_CALLS = {}
_G.UseContainerItem = function(bag, slot)
  table.insert(_G.USE_CALLS, bag .. ":" .. slot)
end
_G.PickupContainerItem = function() end
_G.DELETE_CALLS = 0
_G.DeleteCursorItem = function() _G.DELETE_CALLS = _G.DELETE_CALLS + 1 end
_G.ClearCursor = function() _G._CURSOR = false end
_G.TRADE_CALLS = 0
_G.ClickTradeButton = function() _G.TRADE_CALLS = _G.TRADE_CALLS + 1 end
_G.MAIL_CALLS = 0
_G.ClickSendMailItemButton = function() _G.MAIL_CALLS = _G.MAIL_CALLS + 1 end
_G.AUCTION_CALLS = 0
_G.ClickAuctionSellItemButton = function() _G.AUCTION_CALLS = _G.AUCTION_CALLS + 1 end
-- Final-action sinks: present before the addon loads so its defense-in-depth
-- guards wrap them. Slot getters fail open (nil) unless a test fills them.
_G.TRADE_SLOT_LINK = {}
_G.GetTradePlayerItemLink = function(i) return _G.TRADE_SLOT_LINK[i] end
_G.ACCEPT_CALLS = 0
_G.AcceptTrade = function() _G.ACCEPT_CALLS = _G.ACCEPT_CALLS + 1 end
_G.MAIL_SLOT_LINK = {}
_G.GetSendMailItem = function(i) return _G.MAIL_SLOT_LINK[i] end
_G.SEND_CALLS = 0
_G.SendMail = function() _G.SEND_CALLS = _G.SEND_CALLS + 1 end
_G.AUCTION_INFO = nil
_G.GetAuctionSellItemInfo = function() return _G.AUCTION_INFO end
_G.START_CALLS = 0
_G.StartAuction = function() _G.START_CALLS = _G.START_CALLS + 1 end
_G.GetInventoryItemLink = function() return nil end
_G.SlashCmdList = {}

-- ---------- load the real addon ----------

local src = debug.getinfo(1, "S").source
local dir = src:match("@(.*[\\/])") or ""
dofile(dir .. "../WhatsGood.lua")

local onEvent = handlers.OnEvent
check(type(onEvent) == "function", "addon registers OnEvent")
onEvent(nil, "ADDON_LOADED", "WhatsGood")

local function wg(cmd) _G.SlashCmdList["WHATSGOOD"](cmd) end
local function nocursor()
  _G._CURSOR, _G._CURSOR_TYPE, _G._CURSOR_ID, _G._CURSOR_LINK = false, nil, nil, nil
  _G._SHIFT = false
end
local function holdProtected()
  nocursor()
  _G._CURSOR, _G._CURSOR_TYPE, _G._CURSOR_ID, _G._CURSOR_LINK =
    true, "item", 6948, "item:6948"
end

_G.INFO[6948] = { name = "Hearthstone", quality = 1, itype = "Miscellaneous" }
setTip({})

-- ---------- 1. unknown items fail open (documented), quest items protect ----------

_G.SLOTS["0:1"] = "item:1001" -- no INFO: client has never seen it
_G._MERCHANT, _G.USE_CALLS = true, {}
UseContainerItem(0, 1)
check(#_G.USE_CALLS == 1, "uncached unknown item still sells (fail-open window)")

-- ---------- 2. tooltip cache refreshes after info arrives (stale-cache fix) ----------

-- Pre-scan while the client knows nothing: empty tooltip, no info.
_G.INFO[2002] = nil
_G.SLOTS["0:2"] = "item:2002"
setTip({})
_G.USE_CALLS = {}
UseContainerItem(0, 2)
check(#_G.USE_CALLS == 1, "pre-info scan does not protect blindly")

-- Info arrives, but GetItemInfo still reports a useless type; only the
-- tooltip says quest. The rescan must pick that up.
_G.INFO[2002] = { name = "Mysterious Object", quality = 1, itype = "Miscellaneous" }
setTip({ "Quest Item" })
onEvent(nil, "GET_ITEM_INFO_RECEIVED", 2002)
_G.USE_CALLS = {}
UseContainerItem(0, 2)
check(#_G.USE_CALLS == 0, "quest flag found on rescan after info arrives")

-- ---------- 3. custom add / remove roundtrip ----------

_G.INFO[3001] = { name = "Lucky Charm", quality = 1, itype = "Miscellaneous" }
_G.SLOTS["0:3"] = "item:3001"
setTip({}) -- stub tooltips are global: reset lines left over from section 2
wg("add 3001")
check(_G.WhatsGoodDB.custom[3001] == true, "custom add works")
_G.USE_CALLS = {}
UseContainerItem(0, 3)
check(#_G.USE_CALLS == 0, "custom-listed item is protected")
wg("remove 3001")
check(_G.WhatsGoodDB.custom[3001] == nil, "custom remove works")
_G.USE_CALLS = {}
UseContainerItem(0, 3)
check(#_G.USE_CALLS == 1, "removed item sells again")

-- ---------- 4. split-stack delete path: protected on cursor, no history ----------

ClearCursor() -- wrapped: drops pickup history, clears cursor
holdProtected()
_G.DELETE_CALLS = 0
DeleteCursorItem()
check(_G.DELETE_CALLS == 0, "split-stack protected item not deleted")

-- ---------- 5. money on cursor must never be blocked ----------

nocursor()
_G._CURSOR, _G._CURSOR_TYPE = true, "money"
_G.DELETE_CALLS = 0
DeleteCursorItem()
check(_G.DELETE_CALLS == 1, "money on cursor still deletable")

-- ---------- 6. Shift bypasses delete ----------

holdProtected()
_G._SHIFT = true
_G.DELETE_CALLS = 0
DeleteCursorItem()
check(_G.DELETE_CALLS == 1, "shift bypasses delete protection")

-- ---------- 7-9. trade / mail / auction destination guards ----------

holdProtected()
_G.TRADE_CALLS = 0
ClickTradeButton(1)
check(_G.TRADE_CALLS == 0, "protected item not placed into trade")
_G._SHIFT = true
ClickTradeButton(1)
check(_G.TRADE_CALLS == 1, "shift bypasses trade protection")
nocursor()
ClickTradeButton(1)
check(_G.TRADE_CALLS == 2, "empty cursor still retrieves trade items")

holdProtected()
_G.MAIL_CALLS = 0
ClickSendMailItemButton(1)
check(_G.MAIL_CALLS == 0, "protected item not attached to mail")
_G._SHIFT = true
ClickSendMailItemButton(1)
check(_G.MAIL_CALLS == 1, "shift bypasses mail protection")
nocursor()
ClickSendMailItemButton(1)
check(_G.MAIL_CALLS == 2, "empty cursor still detaches mail items")

holdProtected()
_G.AUCTION_CALLS = 0
ClickAuctionSellItemButton()
check(_G.AUCTION_CALLS == 0, "protected item not placed into auction")
_G._SHIFT = true
ClickAuctionSellItemButton()
check(_G.AUCTION_CALLS == 1, "shift bypasses auction protection")
nocursor()
ClickAuctionSellItemButton()
check(_G.AUCTION_CALLS == 2, "empty cursor still clears auction slot")

-- ---------- 10. trade toggle disables the guard ----------

holdProtected()
wg("trade off")
_G.TRADE_CALLS = 0
ClickTradeButton(1)
check(_G.TRADE_CALLS == 1, "trade guard obeys toggle off")
wg("trade on")
_G.TRADE_CALLS = 0
ClickTradeButton(1)
check(_G.TRADE_CALLS == 0, "trade guard back on")

-- ---------- 11. selljunk sells only unprotected greys ----------

_G.INFO[4001] = { name = "Broken Fang", quality = 0, itype = "Junk" }
_G.INFO[4002] = { name = "Epic Sword", quality = 4, itype = "Weapon" }
_G.SLOTS["0:1"], _G.SLOTS["0:2"] = "item:4001", "item:4002"
_G.NUMSLOTS = { [0] = 2 }
_G._MERCHANT, _G.USE_CALLS = true, {}
nocursor() -- selljunk refuses while the cursor holds anything
setTip({})
wg("selljunk")
local soldJunk, soldEpic = false, false
for _, s in ipairs(_G.USE_CALLS) do
  if s == "0:1" then soldJunk = true end
  if s == "0:2" then soldEpic = true end
end
check(soldJunk, "selljunk sells the grey")
check(not soldEpic, "selljunk spares the epic")

-- ---------- 12. minimap + sound toggles, threshold validation ----------

wg("minimap off")
check(_G.WhatsGoodDB.minimapShown == false, "minimap toggle persists")
wg("minimap on")
check(_G.WhatsGoodDB.minimapShown == true, "minimap toggle back on")

wg("sound on")
holdProtected()
_G.SOUNDS, _G.DELETE_CALLS = 0, 0
DeleteCursorItem()
check(_G.DELETE_CALLS == 0 and _G.SOUNDS == 1, "blocked action plays sound when enabled")
wg("sound off")
holdProtected()
_G.SOUNDS = 0
DeleteCursorItem()
check(_G.SOUNDS == 0, "no sound when disabled")

local before = _G.WhatsGoodDB.qualityThreshold
wg("threshold 9")
check(_G.WhatsGoodDB.qualityThreshold == before, "bad threshold rejected")
wg("threshold 1")
check(_G.WhatsGoodDB.qualityThreshold == 1, "threshold set")
wg("threshold 3")

-- ---------- 13. bound (BoE) greens protected under the soulbound rule ----------

_G.INFO[5001] = { name = "Green BoE Chest", quality = 2, itype = "Armor" }
_G.SLOTS["0:4"] = "item:5001"
setTip({ "Binds when equipped" })
nocursor()
_G._MERCHANT, _G.USE_CALLS = true, {}
UseContainerItem(0, 4)
check(#_G.USE_CALLS == 0, "boe green is protected")
wg("soulbound off")
_G.USE_CALLS = {}
UseContainerItem(0, 4)
check(#_G.USE_CALLS == 1, "boe green sells with soulbound off")
wg("soulbound on")

-- ---------- 14. hearthstone matched by name, not just ID ----------

_G.INFO[5002] = { name = "Lesser Hearthstone", quality = 1, itype = "Miscellaneous" }
_G.SLOTS["0:5"] = "item:5002"
setTip({})
_G.USE_CALLS = {}
UseContainerItem(0, 5)
check(#_G.USE_CALLS == 0, "hearthstone-by-name is protected")

-- ---------- 15. invalid custom IDs rejected ----------

wg("add 0")
check(_G.WhatsGoodDB.custom[0] == nil, "add 0 rejected")
wg("add -12")
check(_G.WhatsGoodDB.custom[-12] == nil, "negative add rejected")

-- ---------- 16. reset restores defaults ----------

wg("threshold 1")
wg("trade off")
wg("add 3001")
wg("reset")
check(_G.WhatsGoodDB.qualityThreshold == 3, "reset restores threshold")
check(_G.WhatsGoodDB.protectTrade == true, "reset restores trade guard")
check(_G.WhatsGoodDB.custom[3001] == nil, "reset clears custom list")

-- ---------- 17. autosell runs the junk pass on MERCHANT_SHOW ----------

nocursor()
_G.SLOTS["0:1"], _G.SLOTS["0:2"] = "item:4001", "item:4002"
_G.NUMSLOTS = { [0] = 2 }
_G._MERCHANT = true
setTip({})
wg("autosell on")
_G.USE_CALLS = {}
onEvent(nil, "MERCHANT_SHOW")
local autoJunk, autoEpic = false, false
for _, s in ipairs(_G.USE_CALLS) do
  if s == "0:1" then autoJunk = true end
  if s == "0:2" then autoEpic = true end
end
check(autoJunk, "autosell sells the grey on merchant open")
check(not autoEpic, "autosell spares the epic")
wg("autosell off")
_G.USE_CALLS = {}
onEvent(nil, "MERCHANT_SHOW")
check(#_G.USE_CALLS == 0, "merchant open sells nothing with autosell off")

-- ---------- 18. final-action guards: accept blocked, mail/auction fail open ----------

nocursor()
_G.TRADE_SLOT_LINK = { [1] = "item:6948" }
_G.ACCEPT_CALLS = 0
AcceptTrade()
check(_G.ACCEPT_CALLS == 0, "accept blocked with protected trade item placed")
_G._SHIFT = true
AcceptTrade()
check(_G.ACCEPT_CALLS == 1, "shift bypasses accept guard")
_G._SHIFT = false
_G.TRADE_SLOT_LINK = {}
AcceptTrade()
check(_G.ACCEPT_CALLS == 2, "accept passes with empty trade slots")
_G.MAIL_SLOT_LINK = {}
_G.SEND_CALLS = 0
SendMail()
check(_G.SEND_CALLS == 1, "send passes when no mail slot is readable")
_G.AUCTION_INFO = nil
_G.START_CALLS = 0
StartAuction()
check(_G.START_CALLS == 1, "auction starts when no sell item is readable")

-- ---------- 19. public API for other addons ----------

_G.SLOTS["0:1"] = "item:6948"
setTip({})
check(WhatsGood_IsProtected(0, 1) == true, "api reports hearthstone slot protected")
local ap, reason = WhatsGood_Reason(0, 1)
check(ap == true and reason == "hearthstone", "api reports hearthstone reason")
check(WhatsGood_IsProtectedID(3001) == false, "api reports unknown id unprotected")
check(WhatsGood_IsProtected(nil, nil) == false, "api fails closed on misuse")

-- ---------- 20. frame scan survives a gap in ContainerFrame numbers ----------

local function fakeButton(bag, slot)
  local icon = { SetDesaturated = function() end }
  local shade = {
    Show = function() end, Hide = function() end,
    SetAllPoints = function() end,
    SetColorTexture = function() end, SetTexture = function() end,
  }
  return {
    bagID = bag, slotID = slot, icon = icon,
    CreateTexture = function() return shade end,
  }
end
_G.SLOTS["0:1"] = "item:6948"
_G.SLOTS["0:2"] = "item:4002"
_G.ContainerFrame1 = { Items = { fakeButton(0, 1) } }
_G.ContainerFrame2 = nil
_G.ContainerFrame3 = { Items = { fakeButton(0, 2) } }
onEvent(nil, "BAG_UPDATE")
handlers.OnUpdate(nil, 0)
check(_G.ContainerFrame1.Items[1].wgDimmed == true, "frame before gap dimmed")
check(_G.ContainerFrame3.Items[1].wgDimmed == true, "frame after gap still scanned")
_G.ContainerFrame1, _G.ContainerFrame3 = nil, nil

-- ---------- 21. learned quest memory persists across sessions ----------

_G.INFO[6001] = { name = "Relic Fragment", quality = 1, itype = "Miscellaneous" }
_G.SLOTS["0:6"] = "item:6001"
setTip({ "Quest Item" })
nocursor()
_G._MERCHANT, _G.USE_CALLS = true, {}
UseContainerItem(0, 6)
check(#_G.USE_CALLS == 0, "quest item blocked on first sighting")
check(_G.WhatsGoodDB.learned[6001] == true, "quest find remembered")

-- Simulate a fresh login: reload the addon with the saved DB intact.
dofile(dir .. "../WhatsGood.lua")
onEvent = handlers.OnEvent
onEvent(nil, "ADDON_LOADED", "WhatsGood")
setTip({}) -- tooltip now resolves to nothing: learned memory must carry it
_G.USE_CALLS = {}
UseContainerItem(0, 6)
check(#_G.USE_CALLS == 0, "learned quest item stays protected after reload")

-- Reset keeps observed facts while restoring settings.
wg("threshold 1")
wg("reset")
check(_G.WhatsGoodDB.qualityThreshold == 3, "reset still restores threshold")
check(_G.WhatsGoodDB.learned[6001] == true, "reset keeps learned quest items")

-- ---------- 22. audit lists unprotected bag items with reasons ----------

_G.SLOTS["0:1"], _G.SLOTS["0:2"], _G.SLOTS["0:3"] = "item:4001", "item:4002", "item:6002"
_G.NUMSLOTS = { [0] = 3 }
setTip({})
local chatBefore = #_G.CHAT
wg("audit")
local foundJunk, foundSummary, leakedEpic = false, false, false
for i = chatBefore + 1, #_G.CHAT do
  local m = _G.CHAT[i]
  if m:find("item:4001", 1, true) then foundJunk = true end
  if m:find("audit:", 1, true) then foundSummary = true end
  if m:find("item:4002", 1, true) then leakedEpic = true end
end
check(foundJunk, "audit lists the unprotected grey")
check(foundSummary, "audit prints a summary line")
check(not leakedEpic, "audit omits protected items")

-- ---------- summary ----------

print(string.format("done: %d pass %d fail", PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
