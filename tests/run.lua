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

-- Widget mock: records geometry, scripts, textures, and state so the UI
-- sections below can assert real layout (bounds, overlaps, refresh sync).
local function makeWidget(kind, parent, name)
  local w = {
    kind = kind, parent = parent, name = name,
    points = {}, children = {}, scripts = {},
    shown = true, text = "",
  }
  function w:SetPoint(point, a, b, c, d)
    local rel, relPoint, x, y
    if type(a) == "table" then
      rel, relPoint, x, y = a, b, c, d
    else
      rel, relPoint, x, y = parent, point, a, b
    end
    table.insert(self.points, {
      point = point, rel = rel, relPoint = relPoint or point, x = x or 0, y = y or 0,
    })
  end
  function w:ClearAllPoints() self.points = {} end
  function w:SetWidth(v) self.w = v end
  function w:SetHeight(v) self.h = v end
  function w:SetSize(a, b) self.w, self.h = a, b end
  function w:GetWidth() return self.w end
  function w:GetHeight() return self.h end
  function w:SetAllPoints(t) self.allpoints = t or self.parent end
  function w:GetName() return self.name end
  function w:GetParent() return self.parent end
  function w:SetScript(ev, fn) self.scripts[ev] = fn; handlers[ev] = fn end
  function w:GetScript(ev) return self.scripts[ev] end
  function w:RegisterEvent() end
  function w:RegisterForDrag() end
  function w:RegisterForClicks() end
  function w:EnableMouse() end
  function w:EnableMouseWheel() end
  function w:SetMovable() end
  function w:SetClampedToScreen() end
  function w:SetFrameStrata() end
  function w:SetToplevel() end
  function w:SetAutoFocus() end
  function w:ClearFocus() end
  function w:SetObeyStepOnDrag() end
  function w:SetBackdrop(def) self.backdrop = def end
  function w:SetBackdropColor(...) self.backdropColor = { ... } end
  function w:SetScrollChild(c) self.scrollChild = c end
  function w:SetVerticalScroll(v) self.vertical = v end
  function w:GetVerticalScroll() return self.vertical or 0 end
  function w:SetHighlightTexture(t) self.highlight = t end
  function w:SetMinMaxValues(a, b) self.min, self.max = a, b end
  function w:GetMinMaxValues() return self.min or 0, self.max or 0 end
  function w:SetValue(v) self.value = v end
  function w:GetValue() return self.value or 0 end
  function w:SetValueStep() end
  function w:SetChecked(v) self.checked = v and true or false end
  function w:GetChecked() return self.checked end
  function w:SetText(t) self.text = t end
  function w:GetText() return self.text end
  function w:SetFontObject(f) self.font = f end
  function w:SetJustifyH(j) self.justify = j end
  function w:SetTextColor(...) self.textColor = { ... } end
  function w:SetShown(v) self.shown = v and true or false end
  function w:Show() self.shown = true end
  function w:Hide() self.shown = false end
  function w:IsShown() return self.shown end
  function w:CreateTexture()
    local t = makeWidget("texture", self)
    function t:SetTexture(p) self.texture = p end
    function t:SetColorTexture(...) self.color = { ... } end
    function t:SetTexCoord(...) self.texcoord = { ... } end
    table.insert(self.children, t)
    return t
  end
  function w:CreateFontString(_, font)
    local fs = makeWidget("fontstring", self)
    fs.font = font
    table.insert(self.children, fs)
    return fs
  end
  return w
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
  local w = makeWidget(ftype, parent, name)
  w.template = template
  if parent then table.insert(parent.children, w) end
  if name then
    _G[name] = w
    if template == "UICheckButtonTemplate" then
      _G[name .. "Text"] = makeWidget("fontstring", w, name .. "Text")
    elseif template == "OptionsSliderTemplate" then
      _G[name .. "Text"] = makeWidget("fontstring", w, name .. "Text")
      _G[name .. "Low"] = makeWidget("fontstring", w, name .. "Low")
      _G[name .. "High"] = makeWidget("fontstring", w, name .. "High")
    end
  end
  return w
end

-- UI globals the panel and minimap button need at load time.
_G.UIParent = makeWidget("Frame", nil, "UIParent")
_G.Minimap = makeWidget("Frame", nil, "Minimap")
function _G.Minimap:GetCenter() return 100, 100 end
_G.UISpecialFrames = {}
_G.TIPSTATE = {}
_G.GameTooltip = {
  SetOwner = function(_, owner) _G.TIPSTATE.owner = owner end,
  SetText = function(_, t) _G.TIPSTATE.text = t end,
  AddLine = function(_, t) _G.TIPSTATE.line = t end,
  SetHyperlink = function(_, l) _G.TIPSTATE.hyperlink = l end,
  Show = function() _G.TIPSTATE.shown = true end,
  Hide = function() _G.TIPSTATE.shown = false end,
}

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

-- ---------- 23. protected items stay usable (sell guard fails open) ----------

nocursor()
_G.SLOTS["0:7"] = "item:6948" -- Hearthstone: always protected, must stay usable
setTip({})
_G._MERCHANT, _G.USE_CALLS = false, {}
local okUse = pcall(UseContainerItem, 0, 7)
check(okUse and #_G.USE_CALLS == 1, "protected item usable with merchant closed")
_G._MERCHANT, _G.USE_CALLS = true, {}
local okSell = pcall(UseContainerItem, 0, 7)
check(okSell and #_G.USE_CALLS == 0, "protected item still sell-blocked with merchant open")
_G.MerchantFrame = { IsShown = function() error("boom") end }
_G._MERCHANT, _G.USE_CALLS = false, {}
local okBoom = pcall(UseContainerItem, 0, 7)
check(okBoom and #_G.USE_CALLS == 1, "merchant-check error fails open (use works)")
_G.MerchantFrame = { IsShown = function() return _G._MERCHANT end }

-- ---------- 24. settings panel: native dialog build, layout, widgets ----------

wg("") -- first open builds the panel
local P = _G.WhatsGoodPanel
check(P ~= nil, "panel builds on first /wg")
check(P and P.shown == true, "first /wg shows the panel")
local escOk = false
for _, n in ipairs(_G.UISpecialFrames) do
  if n == "WhatsGoodPanel" then escOk = true end
end
check(escOk, "panel registered for Esc close")
check(P.backdrop and P.backdrop.edgeFile == "Interface\\DialogFrame\\UI-DialogBox-Border",
  "panel uses the classic dialog border")
local W, H = P.w, P.h
check(W == 464 and H and H >= 600 and H <= 720, "panel dimensions sane")

-- Resolve a widget's top-left rect in panel coordinates from its anchors.
local function anchor(w, h, point)
  if point == "TOP" then return w / 2, 0 end
  if point == "TOPRIGHT" then return w, 0 end
  if point == "LEFT" then return 0, -h / 2 end
  if point == "RIGHT" then return w, -h / 2 end
  if point == "CENTER" then return w / 2, -h / 2 end
  if point == "BOTTOMLEFT" then return 0, -h end
  if point == "BOTTOM" then return w / 2, -h end
  if point == "BOTTOMRIGHT" then return w, -h end
  return 0, 0 -- TOPLEFT
end
local function rect(w)
  local p = w.points[1]
  if not p then return nil end
  local rw, rh = w.w or 0, w.h or 0
  local rel = p.rel or w.parent
  local rx, ry, rw2, rh2
  if rel == nil or rel == P then
    rx, ry, rw2, rh2 = 0, 0, W, H
  else
    local r = rect(rel)
    if not r then return nil end
    rx, ry, rw2, rh2 = r.x, r.y, r.w, r.h
  end
  local ax, ay = anchor(rw2, rh2, p.relPoint)
  local px, py = anchor(rw, rh, p.point)
  return { x = rx + ax + p.x - px, y = ry + ay + p.y - py, w = rw, h = rh }
end
local function overlaps(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y > b.y - b.h and b.y > a.y - a.h
end

local names = {
  "WhatsGoodCheckQuest", "WhatsGoodCheckSoulbound", "WhatsGoodCheckHearth",
  "WhatsGoodCheckTrade", "WhatsGoodCheckMail", "WhatsGoodCheckAuction",
  "WhatsGoodCheckAutosell", "WhatsGoodCheckSound", "WhatsGoodCheckMinimap", "WhatsGoodCheckQuestLog",
  "WhatsGoodQuality0", "WhatsGoodQuality1", "WhatsGoodQuality2",
  "WhatsGoodQuality3", "WhatsGoodQuality4", "WhatsGoodQuality5",
  "WhatsGoodCustomInset", "WhatsGoodCustomInput",
  "WhatsGoodAddButton", "WhatsGoodRemoveButton",
}
local rects = {}
local inBounds, noOverlap = true, true
for _, n in ipairs(names) do
  local r = rect(_G[n])
  if not r then
    inBounds = false
  else
    rects[n] = r
    if r.x < 0 or r.x + r.w > W or r.y > 0 or r.y - r.h < -H then inBounds = false end
  end
end
for i = 1, #names do
  for j = i + 1, #names do
    local a, b = rects[names[i]], rects[names[j]]
    if a and b and overlaps(a, b) then noOverlap = false end
  end
end
check(inBounds, "every panel widget stays inside the dialog")
check(noOverlap, "no two panel widgets overlap")
check(rects.WhatsGoodCheckTrade.x - rects.WhatsGoodCheckQuest.x == 212,
  "toggle columns evenly split")
check(rects.WhatsGoodCheckQuest.y - rects.WhatsGoodCheckSoulbound.y == 30,
  "toggle rows keep a 30px pitch")

local banner
for _, c in ipairs(P.children) do
  if c.texture == "Interface\\DialogFrame\\UI-DialogBox-Header" then banner = c end
end
check(banner ~= nil and rect(banner).y == 12, "title banner crowns the dialog")

local footer = {}
for _, c in ipairs(P.children) do
  if c.kind == "Button" and c.template == "UIPanelButtonTemplate" then
    footer[c.text] = c
  end
end
check(footer["Sell Junk"] and footer["Reset"] and footer["Close"], "footer buttons present")
local fr = {}
for _, n in ipairs({ "Sell Junk", "Reset", "Close" }) do fr[n] = rect(footer[n]) end
check(fr["Sell Junk"].x == 20 and fr["Close"].x + fr["Close"].w == W - 20,
  "footer margins match the content padding")
check(not overlaps(fr["Sell Junk"], fr["Reset"]) and not overlaps(fr["Reset"], fr["Close"]),
  "footer buttons do not overlap")
check(fr["Close"].y - fr["Close"].h == -H + 18, "footer sits 18px above the bottom edge")

-- Refresh sync: slash commands and panel widgets stay in step.
wg("quest off")
check(_G.WhatsGoodCheckQuest.checked == false, "panel checkbox follows slash toggle")
wg("quest on")
check(_G.WhatsGoodCheckQuest.checked == true, "panel checkbox follows slash toggle back")
wg("threshold 4")
local lit = {}
for i = 0, 5 do
  if _G["WhatsGoodQuality" .. i].wgSelected then table.insert(lit, i) end
end
check(#lit == 1 and lit[1] == 4, "only the active quality chip is lit")
local qt, status
for _, c in ipairs(P.children) do
  if c.kind == "fontstring" and c.text:find("Protects:", 1, true) then qt = c.text end
  if c.kind == "fontstring" and c.text:find("Guarding", 1, true) then status = c.text end
end
check(qt and qt:find("Epic", 1, true) and qt:find("|cffa335ee", 1, true),
  "quality line colors the live quality")
check(status and status:find("Guarding", 1, true) and status:find("Epic", 1, true),
  "header status names the active threshold")
_G.WhatsGoodQuality2.scripts.OnClick(_G.WhatsGoodQuality2)
check(_G.WhatsGoodDB.qualityThreshold == 2 and _G.WhatsGoodQuality2.wgSelected,
  "clicking a quality chip sets the threshold")
wg("threshold 3")
_G.WhatsGoodCheckQuest.scripts.OnEnter(_G.WhatsGoodCheckQuest)
check(_G.TIPSTATE.text == "Quest items", "checkbox hover explains the rule")

-- Custom list: rows, tooltips, per-row remove, input flow, scrolling.
wg("add 3001")
local child = _G.WhatsGoodCustomChild
local scroll = _G.WhatsGoodCustomScroll
local bar = _G.WhatsGoodCustomScrollBar
local function visibleRows()
  local rows = {}
  for _, c in ipairs(child.children) do
    if c.kind == "Button" and c.shown then table.insert(rows, c) end
  end
  return rows
end
local rows = visibleRows()
check(#rows == 1 and rows[1].name.text:find("Lucky Charm", 1, true),
  "custom list shows the item by name")
check(bar.shown == false, "scrollbar hidden while the list fits")
rows[1].scripts.OnEnter(rows[1])
check(_G.TIPSTATE.hyperlink == "item:3001", "list row shows the item tooltip")
rows[1].scripts.OnLeave(rows[1])
wg("add 4002")
rows = visibleRows()
check(#rows == 2, "second custom item gets its own row")
local xbtn
for _, c in ipairs(rows[2].children) do
  if c.kind == "Button" then xbtn = c end
end
check(xbtn ~= nil, "row has a remove button")
xbtn.scripts.OnClick()
check(_G.WhatsGoodDB.custom[4002] == nil, "row remove button unprotects")
local input = _G.WhatsGoodCustomInput
input:SetText("5001")
input.scripts.OnEnterPressed(input)
check(_G.WhatsGoodDB.custom[5001] == true, "enter in the input box adds")
check(input.text == "Shift-click an item here", "input resets to its hint")
input:SetText("5002")
_G.WhatsGoodAddButton.scripts.OnClick()
check(_G.WhatsGoodDB.custom[5002] == true, "Add button adds from the input")
input:SetText("5002")
_G.WhatsGoodRemoveButton.scripts.OnClick()
check(_G.WhatsGoodDB.custom[5002] == nil, "Remove button removes from the input")
for i = 1, 8 do wg("add " .. (7000 + i)) end
check(bar.shown == true and bar.max > 0, "scrollbar appears when the list overflows")
bar.scripts.OnValueChanged(bar, 24)
check(scroll.vertical == 24, "scrollbar drives the scroll frame")
wg("reset")
check(#visibleRows() == 0, "reset empties the list rows")
local empty
for _, c in ipairs(child.children) do
  if c.kind == "fontstring" and c.text:find("No custom items", 1, true) then empty = c end
end
check(empty and empty.shown == true, "empty state note returns")

-- Close paths: corner X, footer Close, and reopen.
local closeX
for _, c in ipairs(P.children) do
  if c.template == "UIPanelCloseButton" then closeX = c end
end
check(closeX ~= nil, "corner close button present")
closeX.scripts.OnClick()
check(P.shown == false, "corner X closes the panel")
wg("")
check(P.shown == true, "/wg reopens the panel")
footer["Close"].scripts.OnClick()
check(P.shown == false, "footer Close closes the panel")

-- Minimap button shows the custom badge art, not a stock bag icon.
local mm = _G.WhatsGoodMinimapButton
local iconTex = nil
for _, c in ipairs(mm.children) do
  if c.texture and tostring(c.texture):find("WhatsGoodMinimap.tga", 1, true) then iconTex = c end
end
check(mm and mm.w == 31 and iconTex ~= nil, "minimap button uses the custom badge icon")
check(iconTex and iconTex.w == 28, "custom badge sits at 28px inside the 31px button")

-- The shipped TGA is real: 64x64, 32-bit, top-left origin, so the client
-- decodes it as the art we generated.
local tga = io.open(dir .. "../Media/WhatsGoodMinimap.tga", "rb")
check(tga ~= nil, "minimap badge file ships in Media/")
if tga then
  local hdr = tga:read(18)
  tga:close()
  if hdr and #hdr == 18 then
    local b = { hdr:byte(1, 18) }
    local w = b[13] + b[14] * 256
    local h = b[15] + b[16] * 256
    check(b[3] == 2 and w == 64 and h == 64 and b[17] == 32 and b[18] == 0x28,
      "badge is an uncompressed 64x64 32-bit TGA")
  else
    check(false, "badge header readable")
  end
end

-- ---------- 25. quest-log items: learned from the log, not the tooltip ----------

-- Quest log stub: two entries, the first one needs a special item.
_G.QLOG_SPECIALS = { "Lucky Coin" }
_G.GetNumQuestLogEntries = function() return 2 end
_G.GetQuestLogSpecialItemInfo = function(i) return _G.QLOG_SPECIALS[i] end
_G.INFO[7001] = { name = "Lucky Coin", quality = 1, itype = "Miscellaneous" }
_G.INFO[7002] = { name = "Spare Trinket", quality = 1, itype = "Miscellaneous" }
_G.SLOTS["0:2"] = "item:7001"
_G.SLOTS["0:3"] = "item:7002"
setTip({})

wg("questlog on")
_G.WhatsGoodDB.learned[7001] = nil
_G.WhatsGoodDB.learned[7002] = nil
onEvent(nil, "QUEST_LOG_UPDATE")
check(_G.WhatsGoodDB.learned[7001] == true, "quest-log item is learned from the log")
check(_G.WhatsGoodDB.learned[7002] == nil, "bag items the log does not name are not learned")
local prot, reason = _G.WhatsGood_Reason(0, 2)
check(prot == true and reason == "learned", "quest-log item reports as learned")

-- Learned memory outlives the quest: clearing the log keeps the item guarded.
_G.QLOG_SPECIALS = {}
onEvent(nil, "QUEST_LOG_UPDATE")
check(_G.WhatsGoodDB.learned[7001] == true, "learned quest-log item survives the quest ending")

-- Toggle off: no new learning, the panel checkbox follows the toggle.
wg("questlog off")
check(_G.WhatsGoodCheckQuestLog.checked == false, "panel checkbox follows questlog off")
_G.QLOG_SPECIALS = { "Spare Trinket" }
_G.WhatsGoodDB.learned[7002] = nil
onEvent(nil, "BAG_UPDATE")
check(_G.WhatsGoodDB.learned[7002] == nil, "questlog off stops new learning")
wg("questlog on")
check(_G.WhatsGoodCheckQuestLog.checked == true, "panel checkbox follows questlog on")
onEvent(nil, "BAG_UPDATE")
check(_G.WhatsGoodDB.learned[7002] == true, "questlog on learns from bag changes too")

-- No quest-log API (retail-only clients): fails open, nothing learned, no error.
local savedSpecial = _G.GetQuestLogSpecialItemInfo
_G.GetQuestLogSpecialItemInfo = nil
_G.WhatsGoodDB.learned[7002] = nil
local okNo = pcall(onEvent, nil, "QUEST_LOG_UPDATE")
check(okNo and _G.WhatsGoodDB.learned[7002] == nil, "missing quest-log API fails open")
_G.GetQuestLogSpecialItemInfo = savedSpecial

-- ---------- summary ----------

print(string.format("done: %d pass %d fail", PASS, FAIL))
os.exit(FAIL > 0 and 1 or 0)
