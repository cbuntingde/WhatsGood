-- WhatsGood: dim quest + important bag items, block accidental vendor/delete.
-- Standalone, no libraries. Works on WoW Forever 1.16.1 (Interface 16001).
-- Protection can be bypassed by holding Shift.

local ADDON = ...
if type(ADDON) ~= "string" then ADDON = "WhatsGood" end

local VERSION = "1.6.0"

-- Classic Hearthstone plus room for future stones (matched by ID or name).
local HEARTHSTONE_IDS = { [6948] = true } -- extend here for future stones
local DEFAULTS = {
  qualityThreshold = 3, -- 0 poor .. 5 legendary: auto-protect at/above this
  protectQuest = true,
  protectQuestLog = true, -- learn items your active quests need as soon as they show up in bags
  protectSoulbound = true, -- only for quality >= 2 (green+), junk greys stay sellable; also covers Bind-on-Equip/Pickup greens+
  protectHearth = true,
  protectTrade = true,
  protectMail = true,
  protectAuction = true,
  autosell = false, -- auto-run /wg selljunk on MERCHANT_SHOW
  warnSound = false,
  minimapShown = true,
  minimapAngle = 215, -- degrees around the minimap, 0 = east
  custom = {}, -- [itemID] = true, always protected
  customNames = {}, -- [itemID] = name, so list rows show names before the client caches the item
  learned = {}, -- [itemID] = true, quest items remembered across sessions
}

local db --- SavedVariables table (WhatsGoodDB)
local infoCache = {} -- [itemID] = { quality, itype, quest, starter, soulbound }
local lastPickup = nil -- { protected = bool }
local updateQueued = false

local WG = CreateFrame("Frame")
local scanTip = nil

local function Msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cff7fd4ffWhatsGood:|r " .. tostring(text))
end

local function Warn(text)
  -- Guard path: a broken chat/UI frame must never turn a block into a Lua
  -- error that bricks the hooked action, so every sink here fails silent.
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    pcall(DEFAULT_CHAT_FRAME.AddMessage, DEFAULT_CHAT_FRAME, "|cffff4040WhatsGood:|r " .. tostring(text))
  end
  if UIErrorsFrame and UIErrorsFrame.AddMessage then
    pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, "WhatsGood: " .. tostring(text), 1, 0.25, 0.25, 1, 5)
  end
  if db and db.warnSound and type(PlaySound) == "function" then
    pcall(PlaySound, "igQuestFailed")
  end
end

-- ---------- API wrappers (retail C_Container vs vanilla globals) ----------

-- strtrim exists on every client; string.trim only on some. Never assume either.
local function WG_Trim(s)
  s = s or ""
  if strtrim then return strtrim(s) end
  if string and string.trim then return string.trim(s) end
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function WG_CustomCount()
  local n = 0
  if db and type(db.custom) == "table" then
    for _ in pairs(db.custom) do n = n + 1 end
  end
  return n
end

local function WG_GetLink(bag, slot)
  if C_Container and C_Container.GetContainerItemLink then
    local ok, link = pcall(C_Container.GetContainerItemLink, bag, slot)
    if ok then return link end
  end
  if GetContainerItemLink then
    local ok, link = pcall(GetContainerItemLink, bag, slot)
    if ok then return link end
  end
  return nil
end

local function WG_ItemID(link, fallback)
  if link then
    local id = tonumber(string.match(link, "item:(%d+)"))
    if id then return id end
  end
  return fallback
end

-- Bag slot count, retail first then vanilla. Fails open to 0 when neither
-- client API exists (headless tests stub only the vanilla one).
local function WG_GetNumSlots(bag)
  if C_Container and type(C_Container.GetContainerNumSlots) == "function" then
    local ok, n = pcall(C_Container.GetContainerNumSlots, bag)
    if ok and type(n) == "number" then return n end
  end
  if type(GetContainerNumSlots) == "function" then
    local ok, n = pcall(GetContainerNumSlots, bag)
    if ok and type(n) == "number" then return n end
  end
  return 0
end

-- ---------- tooltip scan (quest / soulbound / quest-starter) ----------

local function WG_BuildScanTip()
  if scanTip then return scanTip end
  local ok, tip = pcall(CreateFrame, "GameTooltip", "WhatsGoodScanTooltip", UIParent, "GameTooltipTemplate")
  if not ok or not tip then return nil end
  tip:SetOwner(UIParent, "ANCHOR_NONE")
  scanTip = tip
  return tip
end

local function WG_Scan(itemID, link)
  local cached = infoCache[itemID]
  if not cached then
    cached = {}
    infoCache[itemID] = cached
  end
  if cached.scanned then return cached end
  local tip = WG_BuildScanTip()
  if not tip then return cached end
  tip:ClearLines()
  local ok = pcall(tip.SetHyperlink, tip, link or ("item:" .. itemID))
  if not ok then return cached end
  local lines = tip:NumLines()
  -- Localized bind/quest globals when the client provides them, plus
  -- English fallbacks so headless tests and enUS clients both match.
  local soulboundText = type(ITEM_SOULBOUND) == "string" and string.lower(ITEM_SOULBOUND) or "soulbound"
  for i = 1, lines do
    local line = _G["WhatsGoodScanTooltipTextLeft" .. i]
    line = line and line:GetText()
    if line then
      local lower = string.lower(line)
      if string.find(lower, "this item begins a quest", 1, true) then
        cached.starter = true
        cached.quest = true
      elseif string.find(lower, "quest item", 1, true) then
        cached.quest = true
      end
      if line == ITEM_SOULBOUND or lower == "soulbound" or lower == soulboundText
        or string.find(lower, "soulbound", 1, true) then
        cached.soulbound = true
      end
      -- Bind-on-pickup/equip/use lines: the item is (or will be) bound, so
      -- treat it like soulbound for the green+ rule. Covers BoE greens that
      -- never show the literal "Soulbound" line while unequipped.
      if string.find(lower, "binds when picked up", 1, true)
        or string.find(lower, "binds when equipped", 1, true)
        or string.find(lower, "binds when used", 1, true)
        or string.find(lower, "bind on pickup", 1, true)
        or string.find(lower, "bind on equip", 1, true)
        or string.find(lower, "bind on use", 1, true) then
        cached.binds = true
      end
    end
  end
  -- Remember quest finds across sessions: the next login protects this
  -- item from the first sighting, no rescan needed. Factual observation,
  -- not a setting, so it survives /wg reset.
  if (cached.quest or cached.starter) and db ~= nil and type(db.learned) == "table" then
    db.learned[itemID] = true
  end
  tip:ClearLines()
  -- Only trust the scan once the tooltip actually resolved. Items whose info
  -- has not arrived yet keep rescanning on later updates (e.g. after
  -- GET_ITEM_INFO_RECEIVED) instead of trusting empty flags forever.
  if lines > 0 then cached.scanned = true end
  return cached
end

-- ---------- classification ----------

local function WG_Classify(itemID, link)
  -- returns protected (bool), reason (string)
  if not itemID then return false, "none" end
  if not db then return false, "none" end
  if db.custom[itemID] then return true, "listed" end
  if type(db.learned) == "table" and db.learned[itemID] then return true, "learned" end
  if db.protectHearth and HEARTHSTONE_IDS[itemID] then return true, "hearthstone" end

  local name, _, quality, _, _, itype
  if link then
    local origLink = link
    local ok, gName, gLink, gQ, _, _, gType = pcall(GetItemInfo, link)
    if ok then
      name, link, quality, itype = gName, gLink, gQ, gType
    else
      -- Keep the original link for the tooltip scan; the error string
      -- from pcall must never replace it.
      name, link, quality, itype = nil, origLink, nil, nil
    end
  end
  if quality == nil then
    local ok2, _, _, q2, _, _, t2 = pcall(GetItemInfo, itemID)
    if ok2 then quality, itype = q2, t2 end
  end

  local cached = infoCache[itemID]
  if quality ~= nil then
    if not cached then cached = {}; infoCache[itemID] = cached end
    cached.quality = quality
    cached.itype = itype
  elseif cached then
    quality = cached.quality
    itype = cached.itype or itype
  end

  -- Tooltip scan fills quest/soulbound flags; cheap after first scan (cached).
  if link or quality ~= nil or not cached or not cached.scanned then
    cached = WG_Scan(itemID, link)
  end

  -- Hearthstone variants (future stones, other-language clients): match by
  -- name as well as ID. Name comes from the client, so unknown items skip it.
  if db.protectHearth and name and string.find(string.lower(tostring(name)), "hearthstone", 1, true) then
    return true, "hearthstone"
  end

  local isQuest = (itype == "Quest") or (cached and (cached.quest or cached.starter))
  if db.protectQuest and isQuest then
    if cached and cached.starter then return true, "quest starter" end
    return true, "quest item"
  end

  if quality == nil then return false, "unknown" end
  if quality <= 0 and not isQuest then return false, "junk" end
  if quality >= (db.qualityThreshold or 3) then return true, "rare+" end
  if db.protectSoulbound and cached and quality >= 2
    and (cached.soulbound or cached.binds) then
    if cached.binds and not cached.soulbound then return true, "bound item" end
    return true, "soulbound"
  end
  return false, "normal"
end

local function WG_IsProtectedSlot(bag, slot)
  if bag == nil or slot == nil then return false end
  local link = WG_GetLink(bag, slot)
  if not link then return false end
  local id = WG_ItemID(link)
  if not id then return false end
  local protected = WG_Classify(id, link)
  return protected
end

local function WG_LinkText(bag, slot)
  local link = WG_GetLink(bag, slot)
  return link or ("bag " .. tostring(bag) .. " slot " .. tostring(slot))
end

-- ---------- visuals: dim protected slots ----------

local function WG_FindIcon(button)
  if not button then return nil end
  if button.icon then return button.icon end
  if button.Icon then return button.Icon end
  if button.IconTexture then return button.IconTexture end
  if button.iconTexture then return button.iconTexture end
  local name = button.GetName and button:GetName()
  if name then
    local tex = _G[name .. "IconTexture"]
    if tex then return tex end
  end
  return nil
end

-- Reason -> tint. Used for both the dim shade and the thin slot outline,
-- so you can tell at a glance why an item is protected.
local WG_TINTS = {
  ["rare+"]         = { 0.35, 0.55, 0.95 }, -- blue: quality at/above threshold
  ["soulbound"]     = { 0.85, 0.25, 0.25 }, -- red: bound gear
  ["bound item"]    = { 0.85, 0.25, 0.25 },
  ["quest item"]    = { 0.90, 0.75, 0.25 }, -- gold: quest items and starters
  ["quest starter"] = { 0.90, 0.75, 0.25 },
  ["learned"]       = { 0.90, 0.75, 0.25 },
  ["hearthstone"]   = { 0.95, 0.55, 0.15 }, -- orange: hearthstone variants
  ["listed"]        = { 0.30, 0.85, 0.40 }, -- green: custom list
}

local function WG_TintFor(reason)
  local t = reason and WG_TINTS[reason]
  if t then return t[1], t[2], t[3] end
  return 0.6, 0.6, 0.6 -- unknown reasons get a neutral grey
end

local function WG_ApplyDim(button, reason)
  local r, g, b = WG_TintFor(reason)
  local icon = WG_FindIcon(button)
  if not button.wgShade then
    local shade = button:CreateTexture(nil, "OVERLAY")
    if shade then
      if icon then
        pcall(shade.SetAllPoints, shade, icon)
      else
        pcall(shade.SetAllPoints, shade, button)
      end
    end
    button.wgShade = shade
  end
  -- Tinted dim: the reason color at half alpha over the desaturated icon.
  if button.wgShade then
    if button.wgShade.SetColorTexture then
      pcall(button.wgShade.SetColorTexture, button.wgShade, r, g, b, 0.5)
    elseif button.wgShade.SetTexture then
      pcall(button.wgShade.SetTexture, button.wgShade, r, g, b, 0.5)
    end
    if button.wgShade.Show then pcall(button.wgShade.Show, button.wgShade) end
  end
  if icon and icon.SetDesaturated then pcall(icon.SetDesaturated, icon, 1) end
  -- Thin outline matching the tint, drawn as four color strips so no art
  -- file is needed and every client renders the same clean edge.
  local bo = button.wgBorders
  if not bo then
    bo = {}
    button.wgBorders = bo
    local anchor = icon or button
    local function edge(c1, c2, x2, y2)
      local tex = button:CreateTexture(nil, "OVERLAY")
      if tex then
        pcall(tex.SetColorTexture, tex, r, g, b, 0.95)
        pcall(tex.SetPoint, tex, c1, anchor, c1, 0, 0)
        pcall(tex.SetPoint, tex, c2, anchor, c2, x2, y2)
      end
      return tex
    end
    bo.top = edge("TOPLEFT", "TOPRIGHT", 0, -1.5)
    bo.bottom = edge("BOTTOMLEFT", "BOTTOMRIGHT", 0, 1.5)
    bo.left = edge("TOPLEFT", "BOTTOMLEFT", 1.5, 0)
    bo.right = edge("TOPRIGHT", "BOTTOMRIGHT", -1.5, 0)
  else
    -- Recolor the existing border when the reason changed.
    for _, tex in pairs(bo) do
      if tex and tex.SetColorTexture then
        pcall(tex.SetColorTexture, tex, r, g, b, 0.95)
      end
    end
  end
  for _, tex in pairs(bo) do
    if tex and tex.Show then pcall(tex.Show, tex) end
  end
  button.wgDimmed = true
end

local function WG_ClearDim(button)
  if button.wgShade and button.wgShade.Hide then pcall(button.wgShade.Hide, button.wgShade) end
  local bo = button.wgBorders
  if bo then
    for _, tex in pairs(bo) do
      if tex and tex.Hide then pcall(tex.Hide, tex) end
    end
  end
  if button.wgDimmed then
    local icon = WG_FindIcon(button)
    if icon and icon.SetDesaturated then pcall(icon.SetDesaturated, icon, 0) end
  end
  button.wgDimmed = nil
  button.wgReason = nil
end

local function WG_UpdateButton(button, bag, slot)
  if not button or bag == nil or slot == nil then return end
  local link = WG_GetLink(bag, slot)
  if not link then WG_ClearDim(button); return end
  local id = WG_ItemID(link)
  if not id then WG_ClearDim(button); return end
  local protected, reason = WG_Classify(id, link)
  if protected then
    button.wgReason = reason
    WG_ApplyDim(button, reason)
  else
    WG_ClearDim(button)
  end
end

-- One classic container frame (ContainerFrame1..N): buttons are $parentItem1..N.
local function WG_UpdateClassicFrame(frame)
  if not frame or not frame.GetName then return end
  local prefix = frame:GetName() .. "Item"
  local i = 1
  while true do
    local button = _G[prefix .. i]
    if not button then break end
    local bag, slot
    if button.bagID ~= nil then bag = button.bagID else bag = frame:GetID() end
    slot = button:GetID()
    if button.IsShown and button:IsShown() then
      WG_UpdateButton(button, bag, slot)
    end
    i = i + 1
    if i > 48 then break end
  end
end

local function WG_UpdateCombinedFrame(frame)
  if not frame or not frame.Items then return end
  for _, button in pairs(frame.Items) do
    local bag, slot = button.bagID, button.slotID or button.slotIndex
    if bag == nil and button.GetBagID then pcall(function() bag = button:GetBagID() end) end
    if slot == nil and button.GetID then slot = button:GetID() end
    if bag ~= nil and slot ~= nil then
      WG_UpdateButton(button, bag, slot)
    end
  end
end

local function WG_UpdateAll()
  -- Never break on the first missing frame: gaps happen (skipped numbers,
  -- unloaded bank bags), and a break would hide every frame after the gap.
  local maxFrames = (type(NUM_CONTAINER_FRAMES) == "number" and NUM_CONTAINER_FRAMES) or 30
  if maxFrames < 30 then maxFrames = 30 end
  for i = 1, maxFrames do
    local frame = _G["ContainerFrame" .. i]
    if frame ~= nil then
      if frame.Items then WG_UpdateCombinedFrame(frame) else WG_UpdateClassicFrame(frame) end
    end
  end
  if ContainerFrameCombinedBags then
    if ContainerFrameCombinedBags.Items then
      WG_UpdateCombinedFrame(ContainerFrameCombinedBags)
    else
      WG_UpdateClassicFrame(ContainerFrameCombinedBags)
    end
  end
  -- Main bank window (BankFrameItem1..24). Bank bags ride along in the
  -- ContainerFrame loop above; only the 24 built-in slots need this pass.
  -- BANK_CONTAINER (-1) is valid for the container APIs on both clients.
  if BankFrame and BankFrame.IsShown and BankFrame:IsShown() then
    local bankBag = BANK_CONTAINER or -1
    for i = 1, 24 do
      local button = _G["BankFrameItem" .. i]
      if button and (not button.IsShown or button:IsShown()) then
        local slot = (button.GetID and button:GetID()) or i
        WG_UpdateButton(button, bankBag, slot)
      end
    end
  end
end

local function WG_QueueUpdate()
  updateQueued = true
end

-- ---------- sell / delete protection ----------

local origUse, origPickup, origDelete, origClearCursor
local origTradeClick, origMailClick, origAuctionClick
local origAcceptTrade, origSendMail, origStartAuction
local origCUse, origCPickup

-- The cursor can hold a protected item from paths other than
-- PickupContainerItem (split stack, character sheet, ...), so ask the
-- cursor itself. Pickup history is only a fallback for clients without
-- GetCursorInfo.
local function WG_CursorProtected()
  if type(GetCursorInfo) == "function" then
    local ok, ctype, cid, clink = pcall(GetCursorInfo)
    if ok and ctype == "item" and cid ~= nil then
      if type(cid) == "string" then
        clink = clink or cid
        cid = WG_ItemID(cid)
      end
      if cid then
        local ok2, prot = pcall(WG_Classify, cid, clink)
        if ok2 then return prot end
      end
    elseif ok and ctype ~= nil then
      return false -- money, spells, etc. are not our business
    end
  end
  return lastPickup and lastPickup.protected or false
end

-- Destination guards (trade / mail / auction) share the cursor pattern: only
-- block when the cursor actually holds a protected item, so clicks that pick
-- an already-placed item back up still work. Shift bypasses, like elsewhere.
-- Money and spells on the cursor are never items, so they always pass.
local function WG_CursorDropBlocked(action, flag)
  if not db or not db[flag] then return false end
  if type(IsShiftKeyDown) == "function" then
    local okS, down = pcall(IsShiftKeyDown)
    if okS and down then return false end
  end
  local hasCursor = not CursorHasItem or CursorHasItem()
  if not hasCursor then return false end
  local ok, protected = pcall(WG_CursorProtected)
  if ok and protected then
    Warn("Not " .. action .. " a protected item. Hold Shift to force.")
    return true
  end
  return false
end

-- Merchant visibility, fail-open: any missing global or client error means
-- "not open". Protection must never brick UseContainerItem (using a
-- hearthstone, potion, or food) just because this check misfires.
local function WG_MerchantOpen()
  if type(MerchantFrame) ~= "table" then return false end
  if type(MerchantFrame.IsShown) ~= "function" then return false end
  local ok, shown = pcall(MerchantFrame.IsShown, MerchantFrame)
  return ok and shown and true or false
end

-- Shared merchant-sell check so the global and C_Container entry points
-- enforce the same rule. Returns true when the sale must be blocked.
local function WG_SellBlocked(bag, slot)
  if bag == nil or slot == nil then return false end
  if not WG_MerchantOpen() then
    return false
  end
  if IsShiftKeyDown and IsShiftKeyDown() then return false end
  local ok, protected = pcall(WG_IsProtectedSlot, bag, slot)
  if ok and protected then
    Warn("Not selling " .. WG_LinkText(bag, slot) .. " (protected). Hold Shift to force.")
    return true
  end
  return false
end

local function WG_RecordPickup(bag, slot)
  if bag ~= nil and slot ~= nil then
    local ok, protected = pcall(WG_IsProtectedSlot, bag, slot)
    lastPickup = { protected = ok and protected }
  else
    lastPickup = nil
  end
end

-- Best-effort scan of an already-filled destination slot set. Each getter
-- is probed with pcall and must yield something containing "item:%d+";
-- anything missing or unreadable fails open (allows) by design.
local function WG_SlotSetBlocked(action, flag, count, getter)
  if not db or not db[flag] then return false end
  if type(IsShiftKeyDown) == "function" then
    local okS, down = pcall(IsShiftKeyDown)
    if okS and down then return false end
  end
  if type(getter) ~= "function" or type(count) ~= "number" then return false end
  for i = 1, count do
    local results = { pcall(getter, i) }
    if results[1] == true then
      for j = 2, #results do
        local v = results[j]
        local id, link = nil, nil
        if type(v) == "number" and v > 0 and v == math.floor(v) then
          id = v
        elseif type(v) == "string" and string.find(v, "item:%d+") then
          local num = WG_ItemID(v, nil)
          if type(num) == "number" then id, link = num, v end
        elseif type(v) == "string" and v ~= "" and not string.find(v, "item:%d+") then
          -- Name-only returns (auction sell info): resolve via GetItemInfo.
          if type(GetItemInfo) == "function" then
            local okI, _, link2 = pcall(GetItemInfo, v)
            if okI and type(link2) == "string" then
              local num = WG_ItemID(link2, nil)
              if type(num) == "number" then id, link = num, link2 end
            end
          end
        end
        if id then
          local okP, prot = pcall(WG_Classify, id, link)
          if okP and prot then
            Warn("Not " .. action .. " a protected item. Hold Shift to force.")
            return true
          end
          break
        end
      end
    end
  end
  return false
end

local function WG_InstallBlocks()
  if not origUse and type(UseContainerItem) == "function" then
    origUse = UseContainerItem
    UseContainerItem = function(bag, slot, ...)
      -- Fail-open: any error in the sell check must still let the item be
      -- used; only a confirmed protected+merchant-open sale is blocked.
      local okB, blocked = pcall(WG_SellBlocked, bag, slot)
      if okB and blocked then return end
      return origUse(bag, slot, ...)
    end
  end

  -- Retail entry point: C_Container.UseContainerItem. Hooked with the same
  -- rule so retail clients get identical protection.
  if not origCUse and C_Container and type(C_Container.UseContainerItem) == "function" then
    origCUse = C_Container.UseContainerItem
    C_Container.UseContainerItem = function(bag, slot, ...)
      -- Fail-open, same rule as the vanilla entry point above.
      local okB, blocked = pcall(WG_SellBlocked, bag, slot)
      if okB and blocked then return end
      return origCUse(bag, slot, ...)
    end
  end

  if not origPickup and type(PickupContainerItem) == "function" then
    origPickup = PickupContainerItem
    PickupContainerItem = function(bag, slot, ...)
      WG_RecordPickup(bag, slot)
      return origPickup(bag, slot, ...)
    end
  end

  if not origCPickup and C_Container and type(C_Container.PickupContainerItem) == "function" then
    origCPickup = C_Container.PickupContainerItem
    C_Container.PickupContainerItem = function(bag, slot, ...)
      WG_RecordPickup(bag, slot)
      return origCPickup(bag, slot, ...)
    end
  end

  if not origDelete and type(DeleteCursorItem) == "function" then
    origDelete = DeleteCursorItem
    DeleteCursorItem = function(...)
      local hasCursor = false
      if type(CursorHasItem) == "function" then
        local okC, held = pcall(CursorHasItem)
        hasCursor = okC and held or false
      else
        hasCursor = lastPickup ~= nil
      end
      local shifted = false
      if type(IsShiftKeyDown) == "function" then
        local okS, down = pcall(IsShiftKeyDown)
        shifted = okS and down or false
      end
      if hasCursor and not shifted then
        local ok, protected = pcall(WG_CursorProtected)
        if ok and protected then
          Warn("Not deleting: that item is protected. Hold Shift to force, then put it back first.")
          return
        end
      end
      return origDelete(...)
    end
  end

  if not origClearCursor and type(ClearCursor) == "function" then
    origClearCursor = ClearCursor
    ClearCursor = function(...)
      lastPickup = nil
      return origClearCursor(...)
    end
  end

  if not origTradeClick and type(ClickTradeButton) == "function" then
    origTradeClick = ClickTradeButton
    ClickTradeButton = function(id, ...)
      if id ~= nil and WG_CursorDropBlocked("trading", "protectTrade") then return end
      return origTradeClick(id, ...)
    end
  end

  if not origMailClick and type(ClickSendMailItemButton) == "function" then
    origMailClick = ClickSendMailItemButton
    ClickSendMailItemButton = function(index, ...)
      if index ~= nil and WG_CursorDropBlocked("mailing", "protectMail") then return end
      return origMailClick(index, ...)
    end
  end

  if not origAuctionClick and type(ClickAuctionSellItemButton) == "function" then
    origAuctionClick = ClickAuctionSellItemButton
    ClickAuctionSellItemButton = function(...)
      if WG_CursorDropBlocked("auctioning", "protectAuction") then return end
      return origAuctionClick(...)
    end
  end

  -- Defense in depth: the placement guards above are primary, but an item
  -- placed before protection was enabled (or by another addon calling the
  -- original sink directly) could still be confirmed. These final-action
  -- guards scan the filled slots and fail open when the client lacks the
  -- query API, so they never break normal trade/mail/auction flow.
  if not origAcceptTrade and type(AcceptTrade) == "function" then
    origAcceptTrade = AcceptTrade
    AcceptTrade = function(...)
      if type(GetTradePlayerItemLink) == "function" then
        if WG_SlotSetBlocked("trading", "protectTrade", 7, GetTradePlayerItemLink) then return end
      end
      return origAcceptTrade(...)
    end
  end

  if not origSendMail and type(SendMail) == "function" then
    origSendMail = SendMail
    SendMail = function(...)
      if type(GetSendMailItem) == "function" then
        if WG_SlotSetBlocked("mailing", "protectMail", 12, GetSendMailItem) then return end
      end
      return origSendMail(...)
    end
  end

  if not origStartAuction and type(StartAuction) == "function" then
    origStartAuction = StartAuction
    StartAuction = function(...)
      if type(GetAuctionSellItemInfo) == "function" and db and db.protectAuction then
        local results = { pcall(GetAuctionSellItemInfo) }
        if results[1] == true then
          local id, link = nil, nil
          for j = 2, #results do
            local v = results[j]
            if type(v) == "number" and v > 0 and v == math.floor(v) then
              id = v; break
            elseif type(v) == "string" and string.find(v, "item:%d+") then
              local num = WG_ItemID(v, nil)
              if type(num) == "number" then id, link = num, v; break end
            end
          end
          -- Name-only result: GetAuctionSellItemInfo returns the item name,
          -- never a link, so resolve it the same way as the tooltip scan.
          if not id and type(results[2]) == "string" and results[2] ~= ""
            and type(GetItemInfo) == "function" then
            local okI, _, link2 = pcall(GetItemInfo, results[2])
            if okI and type(link2) == "string" then
              local num = WG_ItemID(link2, nil)
              if type(num) == "number" then id, link = num, link2 end
            end
          end
          if id then
            local okP, prot = pcall(WG_Classify, id, link)
            if okP and prot then
              local shifted = false
              if type(IsShiftKeyDown) == "function" then
                local okS, down = pcall(IsShiftKeyDown)
                shifted = okS and down or false
              end
              if not shifted then
                Warn("Not auctioning a protected item. Hold Shift to force.")
                return
              end
            end
          end
        end
      end
      return origStartAuction(...)
    end
  end
end

-- ---------- tooltip note ----------

local function WG_TooltipNote()
  if GameTooltip and GameTooltip.AddLine then
    pcall(GameTooltip.AddLine, GameTooltip, "WhatsGood: protected (won't auto-sell)", 1, 0.3, 0.3)
  end
  if GameTooltip and GameTooltip.Show then
    pcall(GameTooltip.Show, GameTooltip)
  end
end

local function WG_InstallTooltipHook()
  if type(hooksecurefunc) ~= "function" then return end
  if not GameTooltip then return end
  if GameTooltip.SetBagItem then
    pcall(hooksecurefunc, GameTooltip, "SetBagItem", function(_, bag, slot)
      local ok, protected = pcall(WG_IsProtectedSlot, bag, slot)
      if ok and protected then WG_TooltipNote() end
    end)
  end
  -- Bank slots, equipped gear, and character-sheet tooltips go through
  -- SetInventoryItem on both classic and retail clients.
  if GameTooltip.SetInventoryItem then
    pcall(hooksecurefunc, GameTooltip, "SetInventoryItem", function(_, unit, slot)
      if type(GetInventoryItemLink) ~= "function" then return end
      local okL, link = pcall(GetInventoryItemLink, unit or "player", slot)
      if not okL or not link then return end
      local id = WG_ItemID(link, link)
      if not id then return end
      local okP, protected = pcall(WG_Classify, id, link)
      if okP and protected then WG_TooltipNote() end
    end)
  end
end

-- ---------- settings panel ----------

local QUALITY_NAMES = {
  "Poor (grey)", "Common (white)", "Uncommon (green)",
  "Rare (blue)", "Epic (purple)", "Legendary (orange)",
}

local panel, cbQuest, cbQuestLog, cbSoul, cbHearth, cbMini, cbTrade, cbMail, cbAuction, cbSound, cbAuto
local swatches = {} -- quality chips, index = quality + 1
local qText, statusText
local panelBuilt, panelUpdating = false, false
local WG_RefreshPanel, WG_SyncMinimap -- forward declarations (used before defined)

-- Clamp a possibly-corrupt SavedVariable quality into 0..5.
local function WG_ClampQuality(q)
  if type(q) ~= "number" then return 3 end
  if q < 0 then return 0 end
  if q > 5 then return 5 end
  return math.floor(q + 0.5)
end

-- Re-classify every bag slot and sync the panel widgets.
local function WG_ApplyAndRefresh()
  infoCache = {}
  WG_UpdateAll()
  WG_RefreshPanel()
end

-- Parse an item link, a raw item: link, or a plain number into an item ID.
local function WG_ParseItemText(text)
  if type(text) ~= "string" then return nil end
  text = WG_Trim(text)
  if text == "" then return nil end
  return tonumber(string.match(text, "item:(%d+)")) or tonumber(text)
end

-- Custom list entries: shared by the panel buttons and /wg add|remove so
-- both surfaces enforce the same validation and messages.
-- "[Name] (item 1234)" when the name is known, else "item 1234". The link
-- (if any) supplies the name first, so a just-dropped item shows even before
-- the client has cached it; GetItemInfo covers typed IDs.
-- The display name inside an item link ("|h[Name]|h"), or nil.
local function WG_NameFromLink(link)
  if type(link) ~= "string" then return nil end
  return string.match(link, "|h%[(.-)%]|h")
end

-- Best known name for an item: the client cache first, then the name we saved
-- when it was added (the cache can be empty for a while after a fresh login).
local function WG_ItemName(id)
  if type(GetItemInfo) == "function" then
    local okI, gName = pcall(GetItemInfo, id)
    if okI and type(gName) == "string" and gName ~= "" then
      if db and type(db.customNames) == "table" then db.customNames[id] = gName end
      return gName
    end
  end
  if db and type(db.customNames) == "table" and type(db.customNames[id]) == "string" then
    return db.customNames[id]
  end
  return nil
end

local function WG_ItemLabel(id, link)
  local name = WG_NameFromLink(link) or WG_ItemName(id)
  if name then return "[" .. name .. "] (item " .. id .. ")" end
  return "item " .. id
end

local function WG_AddCustom(id, link)
  if not db then Msg("still loading, try again in a moment."); return end
  if not id or id <= 0 or id ~= math.floor(id) then
    Msg("usage: /wg add <item link|itemID>")
    return
  end
  db.custom[id] = true
  local linkName = WG_NameFromLink(link)
  if linkName and type(db.customNames) == "table" then db.customNames[id] = linkName end
  Msg("protecting " .. WG_ItemLabel(id, link) .. ".")
  infoCache[id] = nil
  WG_ApplyAndRefresh()
end

local function WG_RemoveCustom(id)
  if not db then Msg("still loading, try again in a moment."); return end
  if not id or id <= 0 or id ~= math.floor(id) then
    Msg("usage: /wg remove <item link|itemID>")
    return
  end
  db.custom[id] = nil
  if type(db.customNames) == "table" then db.customNames[id] = nil end
  Msg("unprotected item " .. id .. ".")
  infoCache[id] = nil
  WG_ApplyAndRefresh()
end

-- Drag-to-add: an item dragged from a bag lands on the cursor. Dropping it on
-- the custom list (OnReceiveDrag, or a click while holding it) protects it and
-- clears the cursor, which returns the item to its bag slot. Non-item cursor
-- contents (money, spells, ...) are ignored.
local function WG_CursorDrop()
  if type(GetCursorInfo) ~= "function" then return end
  local okC, ctype, cid, clink = pcall(GetCursorInfo)
  if not okC or ctype ~= "item" then return end
  local id = tonumber(cid) or WG_ParseItemText(clink)
  if not id then return end
  WG_AddCustom(id, clink)
  if type(ClearCursor) == "function" then pcall(ClearCursor) end
end

-- Quality color escapes: the client's table when present, else the standard
-- palette so headless tests and odd clients still color item names.
local QUALITY_HEX = {
  "|cff9d9d9d", "|cffffffff", "|cff1eff00",
  "|cff0070dd", "|cffa335ee", "|cffff8000",
}

local function WG_QualityHex(q)
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c and c.hex then return c.hex end
  return QUALITY_HEX[(q or 1) + 1] or "|cffffffff"
end

local function WG_QualityText(q)
  return "Protects: " .. WG_QualityHex(q) .. QUALITY_NAMES[q + 1] .. "|r and better"
end

-- Quality chips: the six quality colors as clickable swatches in the panel.
-- Fixed RGB values (not the client table) so they render identically everywhere.
local SWATCH_LABELS = { "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary" }
local SWATCH_RGB = {
  { 0.62, 0.62, 0.62 }, { 1.00, 1.00, 1.00 }, { 0.12, 1.00, 0.00 },
  { 0.00, 0.44, 0.87 }, { 0.64, 0.21, 0.93 }, { 1.00, 0.50, 0.00 },
}
local SWATCH_W, SWATCH_H, SWATCH_GAP = 68, 24, 3

-- The active threshold's chip gets a bright fill and a gold edge; the rest
-- stay dim in their own quality color so the whole scale still reads.
local function WG_SyncSwatches(threshold)
  for i, btn in ipairs(swatches) do
    local on = (i - 1) == threshold
    local r, g, b = SWATCH_RGB[i][1], SWATCH_RGB[i][2], SWATCH_RGB[i][3]
    btn.wgSelected = on
    btn.wgFill:SetColorTexture(r, g, b, on and 0.55 or 0.10)
    for _, t in ipairs(btn.wgEdges) do
      if on then t:SetColorTexture(1, 0.82, 0, 1)
      else t:SetColorTexture(r, g, b, 0.55) end
    end
  end
end

-- Header status line: what is guarded right now, in one glance.
local function WG_StatusText()
  local q = WG_ClampQuality(db.qualityThreshold)
  local head = "Guarding " .. WG_QualityHex(q) .. SWATCH_LABELS[q + 1] .. "|r+"
  local extras = {}
  if db.protectQuest then table.insert(extras, "quest") end
  if db.protectSoulbound then table.insert(extras, "bound") end
  if db.protectHearth then table.insert(extras, "hearth") end
  table.insert(extras, WG_CustomCount() .. " custom")
  return head .. " - " .. table.concat(extras, ", ")
end

-- ---------- shared frame dressing (classic WoW dialog style) ----------

-- One spacing system for the whole panel: PAD is the content margin inside
-- the dialog border, sections breathe more above their header than below,
-- and the panel height is derived from the layout cursor, never guessed.
local PAD = 20
local PANEL_W = 464
local CHECK_SIZE = 26
local ROW_PITCH = 30
local LIST_ROW_H = 24
local LIST_H = 120

local DIALOG_BACKDROP = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
}
local INSET_BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 5, right = 5, top = 5, bottom = 5 },
}

-- Native stone + border art first; clients without SetBackdrop on plain
-- frames fall back to the painted color textures below.
local function WG_Backdrop(frame, def, r, g, b, a)
  if frame.SetBackdrop then
    local ok = pcall(frame.SetBackdrop, frame, def)
    if ok then
      if r and frame.SetBackdropColor then
        pcall(frame.SetBackdropColor, frame, r, g, b, a or 1)
      end
      return true
    end
  end
  return false
end

-- Custom item list: a real scroll frame with one row per item (icon,
-- quality-colored name, remove button), rows recycled across refreshes.
local customScroll, customChild, customBar, customEmpty, customCount
local listRows = {}

local function WG_MakeListRow()
  local row = CreateFrame("Button", nil, customChild)
  row:SetHeight(LIST_ROW_H)
  row:RegisterForClicks("LeftButtonUp")
  row:SetScript("OnReceiveDrag", WG_CursorDrop)
  row:SetScript("OnMouseUp", WG_CursorDrop)
  if row.SetHighlightTexture then
    pcall(row.SetHighlightTexture, row, "Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  end
  local icon = row:CreateTexture(nil, "ARTWORK")
  icon:SetWidth(18)
  icon:SetHeight(18)
  icon:SetPoint("LEFT", 6, 0)
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  row.icon = icon
  local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  name:SetPoint("LEFT", 30, 0)
  name:SetJustifyH("LEFT")
  row.name = name
  local x = CreateFrame("Button", nil, row)
  x:SetWidth(16)
  x:SetHeight(16)
  x:SetPoint("RIGHT", -6, 0)
  local xt = x:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  xt:SetPoint("CENTER", 0, 0)
  xt:SetText("X")
  xt:SetTextColor(0.75, 0.25, 0.25)
  x:SetScript("OnEnter", function()
    xt:SetTextColor(1, 0.4, 0.4)
    if GameTooltip then
      GameTooltip:SetOwner(x, "ANCHOR_RIGHT")
      GameTooltip:SetText("Remove from custom list")
      GameTooltip:Show()
    end
  end)
  x:SetScript("OnLeave", function()
    xt:SetTextColor(0.75, 0.25, 0.25)
    local enter = row.GetScript and row:GetScript("OnEnter")
    if enter then enter(row) elseif GameTooltip then GameTooltip:Hide() end
  end)
  x:SetScript("OnClick", function()
    if row.id then WG_RemoveCustom(row.id) end
  end)
  row:SetScript("OnEnter", function(self)
    if not (GameTooltip and self.id) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. self.id)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
  end)
  return row
end

local function WG_RefreshCustomList()
  if not customChild then return end
  local ids = {}
  if db and type(db.custom) == "table" then
    for id in pairs(db.custom) do table.insert(ids, id) end
  end
  table.sort(ids)
  for _, row in ipairs(listRows) do row:Hide() end
  for i, id in ipairs(ids) do
    local row = listRows[i]
    if not row then row = WG_MakeListRow(); listRows[i] = row end
    row.id = id
    row:SetWidth(customChild:GetWidth())
    row:SetPoint("TOPLEFT", 0, -(i - 1) * LIST_ROW_H)
    local ok, _, _, quality, _, _, _, _, _, _, tex = pcall(GetItemInfo, id)
    if not ok then name, quality, tex = nil, nil, nil end
    row.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
    -- Live client name when cached, else the saved name, else the raw ID.
    local shown = WG_ItemName(id) or ("item:" .. id)
    row.name:SetText(WG_QualityHex(quality) .. shown .. "|r")
    row:Show()
  end
  local viewH = (customScroll.GetHeight and customScroll:GetHeight()) or LIST_H
  -- Empty list keeps a full-height child so the empty note stays centered.
  local h = (#ids > 0) and (#ids * LIST_ROW_H) or viewH
  customChild:SetHeight(h)
  if customEmpty then
    if #ids == 0 then customEmpty:Show() else customEmpty:Hide() end
  end
  local range = math.max(0, h - viewH)
  customBar:SetMinMaxValues(0, range)
  customBar:SetValue(math.min(customBar:GetValue() or 0, range))
  if range > 0 then customBar:Show() else customBar:Hide() end
  if customCount then
    customCount:SetText(#ids .. (#ids == 1 and " item" or " items"))
  end
end

function WG_RefreshPanel()
  if not panelBuilt then return end
  panelUpdating = true
  db.qualityThreshold = WG_ClampQuality(db.qualityThreshold)
  local function setChecked(cb, v)
    if cb and cb.SetChecked then pcall(cb.SetChecked, cb, v and true or false) end
  end
  setChecked(cbQuest, db.protectQuest)
  setChecked(cbQuestLog, db.protectQuestLog)
  setChecked(cbSoul, db.protectSoulbound)
  setChecked(cbHearth, db.protectHearth)
  setChecked(cbTrade, db.protectTrade)
  setChecked(cbMail, db.protectMail)
  setChecked(cbAuction, db.protectAuction)
  setChecked(cbAuto, db.autosell)
  setChecked(cbMini, db.minimapShown ~= false)
  setChecked(cbSound, db.warnSound)
  WG_SyncSwatches(db.qualityThreshold)
  if qText then qText:SetText(WG_QualityText(db.qualityThreshold)) end
  if statusText then statusText:SetText(WG_StatusText()) end
  WG_RefreshCustomList()
  panelUpdating = false
end

-- ---------- shared frame dressing (flat dark addon style) ----------

-- Flat 1px outline drawn with color textures: no border art file needed,
-- so every client renders the same clean edge.
local function WG_FlatBorder(frame, r, g, b, a)
  local s = 1
  local function tex(c1, x1, y1, c2, x2, y2)
    local t = frame:CreateTexture(nil, "OVERLAY")
    if not t then return end
    pcall(t.SetColorTexture, t, r, g, b, a)
    pcall(t.SetPoint, t, c1, frame, c1, x1, y1)
    pcall(t.SetPoint, t, c2, frame, c2, x2, y2)
  end
  tex("TOPLEFT", s, -s, "TOPRIGHT", -s, -s)      -- top
  tex("BOTTOMLEFT", s, s, "BOTTOMRIGHT", -s, s)  -- bottom
  tex("TOPLEFT", s, -s, "BOTTOMLEFT", s, s)      -- left
  tex("TOPRIGHT", -s, -s, "BOTTOMRIGHT", -s, s)  -- right
end

-- Paint a flat dark background with a color texture: SetBackdrop is not
-- available on plain frames in modern clients (they require the
-- BackdropTemplate mixin), so painting works everywhere.
local function WG_PaintBg(frame, r, g, b, a)
  local bg = frame:CreateTexture(nil, "BACKGROUND")
  if bg then
    pcall(bg.SetColorTexture, bg, r, g, b, a)
    pcall(bg.SetAllPoints, bg)
  end
end

local function WG_Divider(frame, y, r, g, b, a)
  local t = frame:CreateTexture(nil, "ARTWORK")
  if t then
    pcall(t.SetColorTexture, t, r, g, b, a or 0.5)
    pcall(t.SetPoint, t, "TOPLEFT", frame, "TOPLEFT", PAD, y)
    pcall(t.SetPoint, t, "TOPRIGHT", frame, "TOPRIGHT", -PAD, y)
    pcall(t.SetHeight, t, 1)
  end
end

local function WG_SectionHeader(frame, text, y)
  local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if fs then
    pcall(fs.SetPoint, fs, "TOPLEFT", PAD, y)
    pcall(fs.SetJustifyH, fs, "LEFT")
    pcall(fs.SetText, fs, text)
  end
  return fs
end

local function WG_MakeCheck(name, label, x, y, set, tip)
  local cb = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
  if not cb then return nil end
  cb:SetWidth(CHECK_SIZE)
  cb:SetHeight(CHECK_SIZE)
  cb:SetPoint("TOPLEFT", x, y)
  local fs = _G[name .. "Text"]
  if fs then
    if fs.SetFontObject then pcall(fs.SetFontObject, fs, "GameFontHighlight") end
    if fs.ClearAllPoints then pcall(fs.ClearAllPoints, fs) end
    if fs.SetPoint then pcall(fs.SetPoint, fs, "LEFT", cb, "RIGHT", 4, 0) end
    if fs.SetJustifyH then pcall(fs.SetJustifyH, fs, "LEFT") end
    if fs.SetText then pcall(fs.SetText, fs, label) end
  end
  cb:SetScript("OnClick", function(self)
    if panelUpdating then return end
    set(self:GetChecked() and true or false)
    WG_ApplyAndRefresh()
  end)
  if tip then
    cb:SetScript("OnEnter", function(self)
      if not GameTooltip then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(label)
      GameTooltip:AddLine(tip, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function()
      if GameTooltip then GameTooltip:Hide() end
    end)
  end
  return cb
end

-- Thin quality-colored edge drawn with four color textures. Returned so the
-- caller can recolor it (the quality chips change their edge on selection).
local function WG_Edges(frame, thick)
  local edges = {}
  local function tex(p1, x1, y1, p2, x2, y2)
    local t = frame:CreateTexture(nil, "OVERLAY")
    t:SetPoint(p1, frame, p1, x1, y1)
    t:SetPoint(p2, frame, p2, x2, y2)
    table.insert(edges, t)
  end
  tex("TOPLEFT", 0, 0, "TOPRIGHT", 0, -thick)
  tex("BOTTOMLEFT", 0, 0, "BOTTOMRIGHT", 0, thick)
  tex("TOPLEFT", 0, 0, "BOTTOMLEFT", thick, 0)
  tex("TOPRIGHT", 0, 0, "BOTTOMRIGHT", -thick, 0)
  return edges
end

-- One quality chip: clicking it sets the protection threshold to that quality.
local function WG_MakeSwatch(i, x, y)
  local q = i - 1
  local r, g, b = SWATCH_RGB[i][1], SWATCH_RGB[i][2], SWATCH_RGB[i][3]
  local btn = CreateFrame("Button", "WhatsGoodQuality" .. q, panel)
  btn:SetWidth(SWATCH_W)
  btn:SetHeight(SWATCH_H)
  btn:SetPoint("TOPLEFT", x, y)
  btn:RegisterForClicks("LeftButtonUp")
  btn.wgFill = btn:CreateTexture(nil, "BACKGROUND")
  btn.wgFill:SetAllPoints(btn)
  btn.wgEdges = WG_Edges(btn, 2)
  -- White label on every chip: the quality color lives in the edge and fill,
  -- so the text stays readable on the blue, purple, and grey chips alike.
  local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("CENTER", 0, 0)
  label:SetText(SWATCH_LABELS[i])
  btn:SetScript("OnClick", function()
    if panelUpdating then return end
    db.qualityThreshold = q
    WG_ApplyAndRefresh()
  end)
  btn:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(SWATCH_LABELS[i], r, g, b)
    GameTooltip:AddLine("Protect " .. string.lower(SWATCH_LABELS[i]) .. " items and better.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
  end)
  return btn
end

local function WG_BuildPanel()
  local ok, frame = pcall(CreateFrame, "Frame", "WhatsGoodPanel", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  if not ok or not frame then
    ok, frame = pcall(CreateFrame, "Frame", "WhatsGoodPanel", UIParent)
  end
  if not ok or not frame then return end
  panel = frame
  if panel.SetFrameStrata then pcall(panel.SetFrameStrata, panel, "DIALOG") end
  if panel.SetToplevel then pcall(panel.SetToplevel, panel, true) end
  panel:SetWidth(PANEL_W)
  if not WG_Backdrop(panel, DIALOG_BACKDROP) then
    WG_PaintBg(panel, 0.06, 0.06, 0.08, 0.97)
    WG_FlatBorder(panel, 0.84, 0.70, 0.33, 0.9)
  end
  panel:SetPoint("CENTER")
  panel:SetMovable(true)
  panel:EnableMouse(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function() panel:StartMoving() end)
  panel:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)
  panel:SetClampedToScreen(true)
  panel:SetScript("OnShow", WG_RefreshPanel)
  if UISpecialFrames then table.insert(UISpecialFrames, "WhatsGoodPanel") end

  -- Title banner and corner close, like a Blizzard dialog.
  local banner = panel:CreateTexture(nil, "ARTWORK")
  banner:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
  banner:SetWidth(310)
  banner:SetHeight(68)
  banner:SetPoint("TOP", 0, 12)
  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", banner, "TOP", 0, -15)
  title:SetText("WhatsGood")
  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -8, -8)
  close:SetScript("OnClick", function() panel:Hide() end)

  -- Layout cursor: every block advances y by its own height plus a gap.
  local y = -68

  -- Header: framed addon icon, one-line pitch, and a live status line that
  -- answers "what is being guarded right now?" without opening anything.
  local icon = panel:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
  icon:SetWidth(40)
  icon:SetHeight(40)
  icon:SetPoint("TOPLEFT", PAD, y)
  local iconFrame = panel:CreateTexture(nil, "OVERLAY")
  iconFrame:SetTexture("Interface\\Common\\WhiteIconFrame")
  iconFrame:SetAllPoints(icon)
  local version = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  version:SetPoint("TOPRIGHT", -PAD, y)
  version:SetText("v" .. VERSION)
  local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  desc:SetPoint("TOPLEFT", PAD + 50, y)
  desc:SetWidth(PANEL_W - PAD * 2 - 94)
  desc:SetJustifyH("LEFT")
  desc:SetText("Guards quest and valuable items from accidental sale, trade, mail, auction, or deletion.")
  statusText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  statusText:SetPoint("TOPLEFT", PAD + 50, y - 36)
  statusText:SetWidth(PANEL_W - PAD * 2 - 94)
  statusText:SetJustifyH("LEFT")
  y = y - 52

  local function divider()
    y = y - 14
    WG_Divider(panel, y, 0.84, 0.70, 0.33, 0.35)
  end
  local function section(text)
    y = y - 10
    WG_SectionHeader(panel, text, y)
    y = y - 20
  end

  -- Quality threshold: six chips in the game's own quality colors.
  divider()
  section("Quality threshold")
  local swY = y
  for i = 1, 6 do
    local x = PAD + (i - 1) * (SWATCH_W + SWATCH_GAP)
    swatches[i] = WG_MakeSwatch(i, x, swY)
  end
  y = swY - SWATCH_H - 8
  qText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  qText:SetPoint("TOPLEFT", PAD, y)
  qText:SetWidth(PANEL_W - PAD * 2)
  qText:SetJustifyH("LEFT")
  y = y - 20

  -- Protection: the six guards in two columns.
  divider()
  section("Protection")
  local grid = y
  cbQuest = WG_MakeCheck("WhatsGoodCheckQuest", "Quest items", PAD, grid,
    function(v) db.protectQuest = v end,
    "Quest items and quest starters are never sold, traded, mailed, auctioned, or deleted.")
  cbTrade = WG_MakeCheck("WhatsGoodCheckTrade", "From trade", PAD + 212, grid,
    function(v) db.protectTrade = v end,
    "Block placing protected items into the trade window.")
  cbSoul = WG_MakeCheck("WhatsGoodCheckSoulbound", "Bound gear (green+)", PAD, grid - ROW_PITCH,
    function(v) db.protectSoulbound = v end,
    "Soulbound and bind-on-pickup/equip items of Uncommon quality or better are guarded.")
  cbMail = WG_MakeCheck("WhatsGoodCheckMail", "From mail", PAD + 212, grid - ROW_PITCH,
    function(v) db.protectMail = v end,
    "Block attaching protected items to mail.")
  cbHearth = WG_MakeCheck("WhatsGoodCheckHearth", "Hearthstone", PAD, grid - ROW_PITCH * 2,
    function(v) db.protectHearth = v end,
    "Your hearthstone and its variants stay protected.")
  cbAuction = WG_MakeCheck("WhatsGoodCheckAuction", "From auction", PAD + 212, grid - ROW_PITCH * 2,
    function(v) db.protectAuction = v end,
    "Block listing protected items on the auction house.")
  y = grid - ROW_PITCH * 3 + (ROW_PITCH - CHECK_SIZE)
  local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", PAD, y - 6)
  hint:SetText("Hold Shift to bypass any block.")
  y = y - 16

  -- Options: behavior toggles.
  divider()
  section("Options")
  grid = y
  cbAuto = WG_MakeCheck("WhatsGoodCheckAutosell", "Auto-sell junk", PAD, grid,
    function(v) db.autosell = v end,
    "Automatically sell unprotected grey items when a merchant window opens.")
  cbSound = WG_MakeCheck("WhatsGoodCheckSound", "Sound on block", PAD + 212, grid,
    function(v) db.warnSound = v end,
    "Play a sound whenever an action is blocked.")
  cbMini = WG_MakeCheck("WhatsGoodCheckMinimap", "Minimap button", PAD, grid - ROW_PITCH,
    function(v) db.minimapShown = v; WG_SyncMinimap() end,
    "Show the WhatsGood button around the minimap.")
  cbQuestLog = WG_MakeCheck("WhatsGoodCheckQuestLog", "Quest-log items", PAD + 212, grid - ROW_PITCH,
    function(v) db.protectQuestLog = v end,
    "Items your active quests need are protected as soon as they appear in your bags.")
  y = grid - ROW_PITCH * 2 + (ROW_PITCH - CHECK_SIZE)

  -- Custom items: scrolling list with icons, tooltips, and per-row remove.
  divider()
  y = y - 10
  WG_SectionHeader(panel, "Custom Items", y)
  customCount = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  customCount:SetPoint("TOPRIGHT", -PAD, y)
  y = y - 20

  local inset = CreateFrame("Frame", "WhatsGoodCustomInset", panel)
  inset:SetPoint("TOPLEFT", PAD, y)
  inset:SetWidth(PANEL_W - PAD * 2)
  inset:SetHeight(LIST_H)
  if not WG_Backdrop(inset, INSET_BACKDROP, 1, 1, 1, 0.9) then
    WG_PaintBg(inset, 0, 0, 0, 0.55)
    WG_FlatBorder(inset, 0.25, 0.25, 0.25, 0.9)
  end
  customScroll = CreateFrame("ScrollFrame", "WhatsGoodCustomScroll", inset)
  customScroll:SetPoint("TOPLEFT", 5, -5)
  customScroll:SetPoint("BOTTOMRIGHT", -31, 5)
  customChild = CreateFrame("Frame", "WhatsGoodCustomChild", customScroll)
  customChild:SetWidth(PANEL_W - PAD * 2 - 36)
  customChild:SetHeight(1)
  customScroll:SetScrollChild(customChild)
  -- Drop targets: the list area and its child (empty space) take bag drops.
  for _, f in ipairs({ customScroll, customChild }) do
    pcall(f.EnableMouse, f, true)
    f:SetScript("OnReceiveDrag", WG_CursorDrop)
    f:SetScript("OnMouseUp", WG_CursorDrop)
  end
  customBar = CreateFrame("Slider", "WhatsGoodCustomScrollBar", customScroll,
    "UIPanelScrollBarTemplate")
  customBar:SetPoint("TOPLEFT", customScroll, "TOPRIGHT", 2, -16)
  customBar:SetPoint("BOTTOMLEFT", customScroll, "BOTTOMRIGHT", 2, 16)
  customBar:SetScript("OnValueChanged", function(_, value)
    customScroll:SetVerticalScroll(value)
  end)
  customScroll:SetScript("OnVerticalScroll", function(_, offset)
    customBar:SetValue(offset)
  end)
  pcall(customScroll.EnableMouseWheel, customScroll, true)
  pcall(customScroll.SetScript, customScroll, "OnMouseWheel", function(_, delta)
    local _, maxV = customBar:GetMinMaxValues()
    customBar:SetValue(math.max(0, math.min(customBar:GetValue() - delta * LIST_ROW_H, maxV)))
  end)
  customEmpty = customChild:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  customEmpty:SetPoint("CENTER", customChild, "CENTER", 0, 0)
  customEmpty:SetJustifyH("CENTER")
  customEmpty:SetText("No custom items yet.\nDrag an item from your bags onto this list.")
  y = y - LIST_H - 10

  y = y - 16

  -- Footer: height derives from the cursor, so nothing ever overlaps.
  local footerH = 24
  panel:SetHeight(-y + footerH + 18)
  local junk = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  junk:SetWidth(110)
  junk:SetHeight(footerH)
  junk:SetPoint("BOTTOMLEFT", PAD, 18)
  junk:SetText("Sell Junk")
  junk:SetScript("OnClick", function() WG_SellJunk() end)

  local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  reset:SetWidth(110)
  reset:SetHeight(footerH)
  reset:SetPoint("BOTTOM", 0, 18)
  reset:SetText("Reset")
  reset:SetScript("OnClick", function() WG_ResetDB() end)

  local closeBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  closeBtn:SetWidth(110)
  closeBtn:SetHeight(footerH)
  closeBtn:SetPoint("BOTTOMRIGHT", -PAD, 18)
  closeBtn:SetText("Close")
  closeBtn:SetScript("OnClick", function() panel:Hide() end)

  panelBuilt = true
  panel:Hide() -- deterministic first open: /wg always shows a fresh panel
  WG_RefreshPanel()
end

local function WG_TogglePanel()
  if not db then return end
  if not panelBuilt then
    local ok, err = pcall(WG_BuildPanel)
    if not ok or not panel then
      Msg("settings panel failed to build: " .. tostring(err))
      return
    end
  end
  if panel:IsShown() then panel:Hide() else panel:Show() end
end

-- ---------- minimap button ----------

local mmBtn = nil
-- Addon-folder path: the folder name must stay "WhatsGood" to match.
local WG_MINIMAP_ICON = "Interface\\AddOns\\WhatsGood\\Media\\WhatsGoodMinimap.tga"

local function WG_MinimapReposition()
  if not mmBtn then return end
  if type(Minimap) ~= "table" then return end
  if not db then return end
  local a = math.rad(db.minimapAngle or 215)
  if mmBtn.ClearAllPoints then pcall(mmBtn.ClearAllPoints, mmBtn) end
  if mmBtn.SetPoint then pcall(mmBtn.SetPoint, mmBtn, "CENTER", Minimap, "CENTER", 78 * math.cos(a), 78 * math.sin(a)) end
end

local function WG_MinimapDragUpdate()
  if not db then return end
  if type(Minimap) ~= "table" or type(Minimap.GetCenter) ~= "function" then return end
  if type(GetCursorPosition) ~= "function" then return end
  if not (UIParent and UIParent.GetEffectiveScale) then return end
  local mx, my = Minimap:GetCenter()
  if not mx or not my then return end
  local cx, cy = GetCursorPosition()
  if not cx or not cy then return end
  local s = UIParent:GetEffectiveScale()
  if not s or s == 0 then return end
  cx, cy = cx / s, cy / s
  if mmBtn._sx and (math.abs(cx - mmBtn._sx) + math.abs(cy - mmBtn._sy) > 6) then
    mmBtn._moved = true
  end
  db.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
  WG_MinimapReposition()
end

function WG_SyncMinimap()
  if not (mmBtn and db) then return end
  local show = db.minimapShown ~= false
  if mmBtn.SetShown then
    pcall(mmBtn.SetShown, mmBtn, show)
  elseif show then
    if mmBtn.Show then pcall(mmBtn.Show, mmBtn) end
  else
    if mmBtn.Hide then pcall(mmBtn.Hide, mmBtn) end
  end
end

local function WG_BuildMinimapButton()
  if mmBtn then return end
  if type(Minimap) ~= "table" then return end
  local btn = CreateFrame("Button", "WhatsGoodMinimapButton", Minimap)
  btn:SetWidth(31)
  btn:SetHeight(31)
  -- Custom round badge (gold rim, leather bag, gold coin) drawn by
  -- Media/WhatsGoodMinimap.tga. The art carries its own rim, so no
  -- Blizzard tracking ring is layered on top.
  local icon = btn:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture(WG_MINIMAP_ICON)
  icon:SetWidth(28)
  icon:SetHeight(28)
  icon:SetPoint("CENTER", 0, 0)
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnDragStart", function()
    if type(GetCursorPosition) ~= "function" then return end
    if type(UIParent) ~= "table" or type(UIParent.GetEffectiveScale) ~= "function" then return end
    local cx, cy = GetCursorPosition()
    if not cx or not cy then return end
    local s = UIParent:GetEffectiveScale()
    if not s or s == 0 then return end
    btn._sx, btn._sy, btn._moved = cx / s, cy / s, nil
    btn:SetScript("OnUpdate", WG_MinimapDragUpdate)
  end)
  btn:SetScript("OnDragStop", function()
    btn:SetScript("OnUpdate", nil)
  end)
  btn:SetScript("OnClick", function(_, mouseBtn)
    if btn._moved then btn._moved = nil; return end
    if not db then return end
    if mouseBtn == "RightButton" then
      db.protectQuest = not db.protectQuest
      WG_ApplyAndRefresh()
      Msg("quest protection " .. (db.protectQuest and "on." or "off."))
    else
      WG_TogglePanel()
    end
  end)
  btn:SetScript("OnEnter", function()
    if not db then return end
    if not GameTooltip then return end
    GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
    GameTooltip:SetText("WhatsGood")
    GameTooltip:AddLine("Click: open settings", 1, 1, 1)
    GameTooltip:AddLine("Right-click: quest protection on/off", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
    GameTooltip:AddLine("Protecting: " .. (db.protectQuest and "quest, " or "")
      .. QUALITY_NAMES[WG_ClampQuality(db.qualityThreshold) + 1] .. "+, "
      .. WG_CustomCount() .. " custom", 0.5, 0.8, 1)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  mmBtn = btn
  WG_MinimapReposition()
  WG_SyncMinimap()
end

-- ---------- slash commands ----------

local function WG_Status()
  local learnedN = 0
  if type(db.learned) == "table" then
    for _ in pairs(db.learned) do learnedN = learnedN + 1 end
  end
  Msg(string.format("WhatsGood %s: quest=%s bound=%s hearth=%s trade=%s mail=%s auction=%s autosell=%s sound=%s quality>=%d custom=%d learned=%d (Shift bypasses; /wg help)",
    VERSION,
    tostring(db.protectQuest), tostring(db.protectSoulbound), tostring(db.protectHearth),
    tostring(db.protectTrade), tostring(db.protectMail), tostring(db.protectAuction),
    tostring(db.autosell),
    tostring(db.warnSound),
    WG_ClampQuality(db.qualityThreshold), WG_CustomCount(), learnedN))
end

-- Restore every setting to its default (clears the custom list too).
-- Global so the settings panel Reset button can reach it.
function WG_ResetDB()
  if not db then Msg("still loading, try again in a moment."); return end
  -- Learned quest items are observed facts, not settings: keep them.
  local keep = db.learned
  for k, v in pairs(DEFAULTS) do
    if k == "custom" or k == "customNames" or k == "learned" then db[k] = {} else db[k] = v end
  end
  if type(keep) == "table" then db.learned = keep end
  WG_ApplyAndRefresh()
  WG_SyncMinimap()
  Msg("settings reset to defaults (learned quest items kept).")
end

-- Manual junk run: sells unprotected poor-quality bag items to the open
-- merchant. Global so the settings panel button can reach it. Protected
-- items are never touched; call the saved original to skip our own guard.
-- Quest items are never junk, even grey ones with quest protection off:
-- check the type/flags directly instead of trusting the toggle.
local function WG_IsJunkSlot(bag, slot)
  local link = WG_GetLink(bag, slot)
  if not link then return false end
  local id = WG_ItemID(link)
  if not id then return false end
  local okP, protected = pcall(WG_IsProtectedSlot, bag, slot)
  if not okP then return false end
  if protected then return false end
  local okI, _, _, quality, _, itype = pcall(GetItemInfo, id)
  if not okI or quality ~= 0 then return false end
  if itype == "Quest" then return false end
  local cached = infoCache[id]
  if cached and (cached.quest or cached.starter) then return false end
  return true
end

function WG_SellJunk()
  if not db then Msg("still loading, try again in a moment."); return end
  if not (MerchantFrame and MerchantFrame.IsShown and MerchantFrame:IsShown()) then
    Msg("open a merchant first, then /wg selljunk."); return
  end
  if type(CursorHasItem) == "function" then
    local okC, held = pcall(CursorHasItem)
    if okC and held then
      Msg("put away what is on the cursor first, then /wg selljunk."); return
    end
  end
  local sell = origUse or UseContainerItem
  if type(sell) ~= "function" then Msg("selling is not available here."); return end
  local n = 0
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    local slots = WG_GetNumSlots(bag)
    for slot = 1, slots do
      if WG_IsJunkSlot(bag, slot) then
        local okS = pcall(sell, bag, slot)
        if okS then n = n + 1 end
      end
    end
  end
  Msg("sold " .. n .. " junk item(s).")
end

-- Read-only gap finder: lists bag items nothing protects, with the reason
-- each one was left alone, so misses can be added with /wg add. Never
-- sells, moves, or protects anything itself.
local function WG_Audit()
  if not db then Msg("still loading, try again in a moment."); return end
  local seen, order = {}, {}
  local total, nunprot = 0, 0
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    local slots = WG_GetNumSlots(bag)
    for slot = 1, slots do
      local link = WG_GetLink(bag, slot)
      if link then
        total = total + 1
        local id = WG_ItemID(link)
        if id then
          local okP, protected, reason = pcall(WG_Classify, id, link)
          if okP and not protected then
            nunprot = nunprot + 1
            local e = seen[id]
            if not e then
              e = { link = link, count = 0, reason = reason or "normal" }
              seen[id] = e
              table.insert(order, id)
            end
            e.count = e.count + 1
          end
        end
      end
    end
  end
  if nunprot == 0 then
    Msg(string.format("audit: everything in your bags is protected (%d item(s) checked).", total))
    return
  end
  local shown = math.min(#order, 25)
  for i = 1, shown do
    local e = seen[order[i]]
    Msg(" - " .. tostring(e.link) .. (e.count > 1 and (" x" .. e.count) or "")
      .. " (" .. tostring(e.reason) .. ")")
  end
  Msg(string.format("audit: %d unprotected item(s) of %d checked%s. /wg add <link|id> protects one.",
    nunprot, total, (#order > shown) and (" (+" .. (#order - shown) .. " more)") or ""))
end

local function WG_HandleSlash(input)
  if not db then Msg("still loading, try again in a moment."); return end
  input = WG_Trim(input)
  local cmd, rest = string.match(input, "^(%S*)%s*(.*)$")
  cmd = string.lower(cmd or "")
  rest = WG_Trim(rest)
  if cmd == "" then WG_TogglePanel(); return end
  if cmd == "help" then
    Msg("/wg opens settings. threshold 0-5 | quest|questlog|soulbound|hearth|trade|mail|auction|autosell|minimap|sound on|off | add <link|id> | remove <link|id> | list | audit | selljunk | reset | refresh | status")
    return
  end
  if cmd == "status" then WG_Status(); return end
  if cmd == "refresh" then WG_UpdateAll(); Msg("bags refreshed."); return end
  if cmd == "selljunk" then WG_SellJunk(); return end
  if cmd == "audit" then WG_Audit(); return end
  if cmd == "reset" then WG_ResetDB(); return end
  if cmd == "threshold" then
    local n = tonumber(rest)
    if n and n >= 0 and n <= 5 then
      db.qualityThreshold = math.floor(n)
      WG_ApplyAndRefresh()
      Msg("now protecting quality " .. db.qualityThreshold .. "+ (0=poor ... 5=legendary).")
    else
      Msg("usage: /wg threshold 0-5 (current " .. tostring(WG_ClampQuality(db.qualityThreshold)) .. ")")
    end
    return
  end
  if cmd == "quest" or cmd == "soulbound" or cmd == "hearth" or cmd == "minimap"
    or cmd == "trade" or cmd == "mail" or cmd == "auction" or cmd == "autosell" or cmd == "sound"
    or cmd == "questlog" then
    local key = cmd == "quest" and "protectQuest"
      or cmd == "soulbound" and "protectSoulbound"
      or cmd == "hearth" and "protectHearth"
      or cmd == "trade" and "protectTrade"
      or cmd == "mail" and "protectMail"
      or cmd == "auction" and "protectAuction"
      or cmd == "autosell" and "autosell"
      or cmd == "sound" and "warnSound"
      or cmd == "questlog" and "protectQuestLog"
      or "minimapShown"
    if rest == "on" then db[key] = true
    elseif rest == "off" then db[key] = false
    else Msg("usage: /wg " .. cmd .. " on|off"); return end
    if cmd == "minimap" then
      WG_SyncMinimap()
      WG_RefreshPanel()
      Msg("minimap button " .. (db.minimapShown and "shown." or "hidden."))
    elseif cmd == "sound" then
      WG_RefreshPanel()
      Msg("block sound " .. rest .. ".")
    elseif cmd == "autosell" then
      WG_RefreshPanel()
      Msg("auto-sell junk " .. rest .. ".")
    else
      WG_ApplyAndRefresh()
      Msg(cmd .. " protection " .. rest .. ".")
    end
    return
  end
  if cmd == "add" or cmd == "remove" then
    local id = WG_ParseItemText(rest)
    if cmd == "add" then WG_AddCustom(id, rest) else WG_RemoveCustom(id) end
    return
  end
  if cmd == "list" then
    local n = 0
    for id in pairs(db.custom) do
      n = n + 1
      local ok, name = pcall(GetItemInfo, id)
      Msg(" - " .. tostring(id) .. ((ok and name) and (" (" .. name .. ")") or ""))
    end
    if n == 0 then Msg("custom list is empty.") end
    return
  end
  Msg("unknown command. /wg help")
end

-- ---------- quest-log item memory ----------
-- The quest log names the special items its quests need (starter kits, quest
-- tools). Matching is by item name, since the log gives names rather than
-- links. A bag item whose name matches is learned, so it is protected on
-- first sight and stays protected after the quest ends (like tooltip learning).
-- Fails open: clients without the quest-log API just learn nothing new.

local function WG_QuestLogItemNames()
  local names = {}
  local okN, n = false, nil
  if C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function" then
    okN, n = pcall(C_QuestLog.GetNumQuestLogEntries)
  end
  if not (okN and type(n) == "number") and type(GetNumQuestLogEntries) == "function" then
    okN, n = pcall(GetNumQuestLogEntries)
  end
  if not (okN and type(n) == "number") or type(GetQuestLogSpecialItemInfo) ~= "function" then
    return names
  end
  for i = 1, n do
    local ok, name = pcall(GetQuestLogSpecialItemInfo, i)
    if ok and type(name) == "string" and name ~= "" then names[name] = true end
  end
  return names
end

-- Returns how many items were newly learned this pass.
local function WG_SyncQuestLog()
  if not db or not db.protectQuestLog or type(db.learned) ~= "table" then return 0 end
  local names = WG_QuestLogItemNames()
  if next(names) == nil then return 0 end
  local added = 0
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, WG_GetNumSlots(bag) do
      local link = WG_GetLink(bag, slot)
      local id = link and WG_ItemID(link)
      if id and not db.learned[id] then
        local okI, name = pcall(GetItemInfo, link)
        if okI and type(name) == "string" and names[name] then
          db.learned[id] = true
          added = added + 1
        end
      end
    end
  end
  return added
end

-- ---------- events ----------

WG:SetScript("OnUpdate", function(_, elapsed)
  if updateQueued then
    updateQueued = false
    pcall(WG_UpdateAll)
  end
end)

-- Coerce a loaded SavedVariables table back into shape: corrupt or
-- hand-edited values fall back to defaults instead of breaking guards.
local function WG_SanitizeDB()
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil then
      -- Copy tables by value: sharing a DEFAULTS table by reference would
      -- let /wg add mutate the defaults for the rest of the session.
      if k == "custom" or k == "customNames" or k == "learned" then db[k] = {} else db[k] = v end
    end
  end
  if type(db.custom) ~= "table" then db.custom = {} end
  if type(db.customNames) ~= "table" then db.customNames = {} end
  if type(db.learned) ~= "table" then db.learned = {} end
  for id, name in pairs(db.customNames) do
    if type(id) ~= "number" or id <= 0 or type(name) ~= "string" then db.customNames[id] = nil end
  end
  for id in pairs(db.learned) do
    if type(id) ~= "number" or id <= 0 then db.learned[id] = nil end
  end
  for id in pairs(db.custom) do
    if type(id) ~= "number" or id <= 0 then db.custom[id] = nil end
  end
  db.qualityThreshold = WG_ClampQuality(db.qualityThreshold)
  if type(db.minimapAngle) ~= "number" then db.minimapAngle = 215 end
  for _, k in ipairs({ "protectQuest", "protectSoulbound", "protectHearth",
    "protectTrade", "protectMail", "protectAuction", "autosell",
    "warnSound", "minimapShown", "protectQuestLog" }) do
    if type(db[k]) ~= "boolean" then db[k] = DEFAULTS[k] end
  end
end

WG:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    if type(WhatsGoodDB) ~= "table" then WhatsGoodDB = {} end
    db = WhatsGoodDB
    WG_SanitizeDB()
    WG_BuildScanTip()
    WG_InstallBlocks()
    WG_InstallTooltipHook()
    WG_BuildMinimapButton()
    if type(hooksecurefunc) == "function" and ContainerFrame_Update then
      pcall(hooksecurefunc, "ContainerFrame_Update", function() WG_QueueUpdate() end)
    end
    if type(hooksecurefunc) == "function" and ContainerFrameCombinedBags and ContainerFrameCombinedBags.Update then
      pcall(hooksecurefunc, ContainerFrameCombinedBags, "Update", function() WG_QueueUpdate() end)
    end
  elseif event == "PLAYER_LOGIN" then
    pcall(WG_SyncQuestLog)
    WG_QueueUpdate()
    Msg("WhatsGood " .. VERSION .. " loaded. Protected items are dimmed (see /wg). Hold Shift to force sell/delete.")
  elseif event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED"
    or event == "PLAYERBANKSLOTS_CHANGED"
    or event == "GET_ITEM_INFO_RECEIVED" then
    -- Drop the stale entry so the queued update re-scans this item now that
    -- its info (and tooltip lines) should resolve.
    if event == "GET_ITEM_INFO_RECEIVED" and type(arg1) == "number" then
      infoCache[arg1] = nil
      -- Item names in the open custom list resolve as soon as info arrives.
      if panelBuilt and panel and panel.IsShown and panel:IsShown() then
        pcall(WG_RefreshPanel)
      end
    end
    pcall(WG_SyncQuestLog)
    WG_QueueUpdate()
  elseif event == "QUEST_LOG_UPDATE" then
    pcall(WG_SyncQuestLog)
    WG_QueueUpdate()
  elseif event == "MERCHANT_SHOW" then
    WG_QueueUpdate()
    -- Auto-sell is opt-in (off by default): run the same manual junk pass.
    if db and db.autosell then WG_SellJunk() end
  end
end)

WG:RegisterEvent("ADDON_LOADED")
WG:RegisterEvent("PLAYER_LOGIN")
WG:RegisterEvent("BAG_UPDATE")
WG:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
WG:RegisterEvent("MERCHANT_SHOW")
pcall(WG.RegisterEvent, WG, "BAG_UPDATE_DELAYED")
pcall(WG.RegisterEvent, WG, "GET_ITEM_INFO_RECEIVED")
pcall(WG.RegisterEvent, WG, "QUEST_LOG_UPDATE")

SLASH_WHATSGOOD1 = "/whatsgood"
SLASH_WHATSGOOD2 = "/wg"
SlashCmdList["WHATSGOOD"] = WG_HandleSlash

-- ---------- public API (for other addons / Bagnon-style skins) ----------
--
-- WhatsGood_IsProtected(bag, slot) -> boolean (never errors; false on misuse)
-- WhatsGood_Reason(bag, slot) -> protected (bool), reason (string)
-- WhatsGood_IsProtectedID(itemID, link) -> boolean

function WhatsGood_IsProtected(bag, slot)
  local ok, protected = pcall(WG_IsProtectedSlot, bag, slot)
  return ok and protected or false
end

function WhatsGood_Reason(bag, slot)
  local link = WG_GetLink(bag, slot)
  if not link then return false, "empty" end
  local id = WG_ItemID(link)
  if not id then return false, "unknown" end
  local ok, protected, reason = pcall(WG_Classify, id, link)
  if not ok then return false, "error" end
  return protected and true or false, reason or "normal"
end

function WhatsGood_IsProtectedID(itemID, link)
  if type(itemID) ~= "number" then return false end
  local ok, protected = pcall(WG_Classify, itemID, link)
  return ok and protected or false
end
