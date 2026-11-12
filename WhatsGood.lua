-- WhatsGood: dim quest + important bag items, block accidental vendor/delete.
-- Standalone, no libraries. Works on WoW Forever 1.60.1 (Interface 16001).
-- Protection can be bypassed by holding Shift.

local ADDON = ...
if type(ADDON) ~= "string" then ADDON = "WhatsGood" end

local VERSION = "1.3.0"

-- Classic Hearthstone plus room for future stones (matched by ID or name).
local HEARTHSTONE_IDS = { [6948] = true } -- extend here for future stones
local DEFAULTS = {
  qualityThreshold = 3, -- 0 poor .. 5 legendary: auto-protect at/above this
  protectQuest = true,
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
  DEFAULT_CHAT_FRAME:AddMessage("|cffff4040WhatsGood:|r " .. tostring(text))
  if UIErrorsFrame and UIErrorsFrame.AddMessage then
    UIErrorsFrame:AddMessage("WhatsGood: " .. tostring(text), 1, 0.25, 0.25, 1, 5)
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
  if db.custom[itemID] then return true, "listed" end
  if db.protectHearth and HEARTHSTONE_IDS[itemID] then return true, "hearthstone" end

  local name, _, quality, _, _, itype
  if link then
    local ok
    ok, name, link, quality, _, _, itype = pcall(GetItemInfo, link)
    if not ok then name, quality, itype = nil, nil, nil end
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

local function WG_ApplyDim(button)
  local icon = WG_FindIcon(button)
  if not button.wgShade then
    local shade = button:CreateTexture(nil, "OVERLAY")
    if shade then
      if shade.SetColorTexture then
        pcall(shade.SetColorTexture, shade, 0, 0, 0, 0.55)
      else
        pcall(shade.SetTexture, shade, 0, 0, 0, 0.55)
      end
      if icon then
        pcall(shade.SetAllPoints, shade, icon)
      else
        pcall(shade.SetAllPoints, shade, button)
      end
    end
    button.wgShade = shade
  end
  if button.wgShade and button.wgShade.Show then pcall(button.wgShade.Show, button.wgShade) end
  if icon and icon.SetDesaturated then pcall(icon.SetDesaturated, icon, 1) end
  button.wgDimmed = true
end

local function WG_ClearDim(button)
  if button.wgShade and button.wgShade.Hide then pcall(button.wgShade.Hide, button.wgShade) end
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
    WG_ApplyDim(button)
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
  if IsShiftKeyDown and IsShiftKeyDown() then return false end
  local hasCursor = not CursorHasItem or CursorHasItem()
  if not hasCursor then return false end
  local ok, protected = pcall(WG_CursorProtected)
  if ok and protected then
    Warn("Not " .. action .. " a protected item. Hold Shift to force.")
    return true
  end
  return false
end

-- Shared merchant-sell check so the global and C_Container entry points
-- enforce the same rule. Returns true when the sale must be blocked.
local function WG_SellBlocked(bag, slot)
  if bag == nil or slot == nil then return false end
  if not (MerchantFrame and MerchantFrame.IsShown and MerchantFrame:IsShown()) then
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
  if IsShiftKeyDown and IsShiftKeyDown() then return false end
  if type(getter) ~= "function" or type(count) ~= "number" then return false end
  for i = 1, count do
    local results = { pcall(getter, i) }
    if results[1] == true then
      for j = 2, #results do
        local v = results[j]
        if type(v) == "string" and string.find(v, "item:%d+") then
          local id = WG_ItemID(v, v)
          if id then
            local okP, prot = pcall(WG_Classify, id, v)
            if okP and prot then
              Warn("Not " .. action .. " a protected item. Hold Shift to force.")
              return true
            end
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
      if WG_SellBlocked(bag, slot) then return end
      return origUse(bag, slot, ...)
    end
  end

  -- Retail entry point: C_Container.UseContainerItem. Hooked with the same
  -- rule so retail clients get identical protection.
  if not origCUse and C_Container and type(C_Container.UseContainerItem) == "function" then
    origCUse = C_Container.UseContainerItem
    C_Container.UseContainerItem = function(bag, slot, ...)
      if WG_SellBlocked(bag, slot) then return end
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
      local hasCursor = not CursorHasItem or CursorHasItem()
      if hasCursor and not IsShiftKeyDown() then
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
      if type(GetAuctionSellItemInfo) == "function" then
        local ok, name = pcall(GetAuctionSellItemInfo)
        if ok and type(name) == "string" and string.find(name, "item:%d+") then
          local id = WG_ItemID(name, name)
          if id then
            local okP, prot = pcall(WG_Classify, id, name)
            if okP and prot and db and db.protectAuction then
              if not (IsShiftKeyDown and IsShiftKeyDown()) then
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

local panel, cbQuest, cbSoul, cbHearth, cbMini, cbTrade, cbMail, cbAuction, cbSound, cbAuto
local qSlider, qLabel, customLine, customBox
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

-- First entries of the custom list for the panel, with names when the
-- client knows them. Full list stays on /wg list (chat text has no limit).
local function WG_CustomListText()
  local ids = {}
  if db and type(db.custom) == "table" then
    for id in pairs(db.custom) do table.insert(ids, id) end
  end
  table.sort(ids)
  if #ids == 0 then return "Custom list is empty.  ( /wg add [Shift-click item] )" end
  local lines = {}
  for i = 1, math.min(#ids, 5) do
    local ok, name = pcall(GetItemInfo, ids[i])
    table.insert(lines, "- " .. ((ok and name) or ("item:" .. tostring(ids[i]))))
  end
  if #ids > 5 then table.insert(lines, "+ " .. (#ids - 5) .. " more (see /wg list)") end
  return table.concat(lines, "\n")
end

function WG_RefreshPanel()
  if not panelBuilt then return end
  panelUpdating = true
  db.qualityThreshold = WG_ClampQuality(db.qualityThreshold)
  local function setChecked(cb, v)
    if cb and cb.SetChecked then pcall(cb.SetChecked, cb, v and true or false) end
  end
  setChecked(cbQuest, db.protectQuest)
  setChecked(cbSoul, db.protectSoulbound)
  setChecked(cbHearth, db.protectHearth)
  setChecked(cbTrade, db.protectTrade)
  setChecked(cbMail, db.protectMail)
  setChecked(cbAuction, db.protectAuction)
  setChecked(cbAuto, db.autosell)
  setChecked(cbMini, db.minimapShown ~= false)
  setChecked(cbSound, db.warnSound)
  if qSlider and qSlider.SetValue then pcall(qSlider.SetValue, qSlider, db.qualityThreshold) end
  if qLabel and qLabel.SetText then
    qLabel:SetText("Protects: " .. QUALITY_NAMES[db.qualityThreshold + 1] .. " and better")
  end
  customLine:SetText("Custom list: " .. WG_CustomCount() .. " items  ( /wg add [Shift-click item] )")
  customBox:SetText(WG_CustomListText())
  panelUpdating = false
end

local function WG_MakeCheck(name, label, y, set)
  local cb = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
  if not cb then return nil end
  if cb.SetPoint then cb:SetPoint("TOPLEFT", 20, y) end
  local fs = _G[name .. "Text"]
  if fs and fs.SetText then pcall(fs.SetText, fs, label) end
  cb:SetScript("OnClick", function(self)
    if panelUpdating then return end
    set(self:GetChecked() and true or false)
    WG_ApplyAndRefresh()
  end)
  return cb
end

local function WG_BuildPanel()
  local ok, frame = pcall(CreateFrame, "Frame", "WhatsGoodPanel", UIParent, "UIPanelDialogTemplate")
  if not ok or not frame then
    frame = CreateFrame("Frame", "WhatsGoodPanel", UIParent)
    pcall(frame.SetBackdrop, frame, {
      bgFile = "Interface/DialogFrame/UI-DialogBox-Background",
      edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
  end
  panel = frame
  if panel.SetWidth then panel:SetWidth(360) end
  if panel.SetHeight then panel:SetHeight(584) end
  panel:SetPoint("CENTER")
  panel:SetMovable(true)
  panel:EnableMouse(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function() panel:StartMoving() end)
  panel:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)
  panel:SetClampedToScreen(true)
  panel:SetScript("OnShow", WG_RefreshPanel)
  if UISpecialFrames then table.insert(UISpecialFrames, "WhatsGoodPanel") end

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 18, -16)
  title:SetText("WhatsGood " .. VERSION)

  local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  desc:SetPoint("TOPLEFT", 20, -44)
  desc:SetWidth(320)
  desc:SetJustifyH("LEFT")
  desc:SetText("Dims quest and important bag items so they can't be sold, traded, mailed, auctioned, or deleted by accident. Hold Shift to bypass protection.")

  cbQuest = WG_MakeCheck("WhatsGoodCheckQuest", "Protect quest items", -100,
    function(v) db.protectQuest = v end)
  cbSoul = WG_MakeCheck("WhatsGoodCheckSoulbound", "Protect bound gear (green+)", -124,
    function(v) db.protectSoulbound = v end)
  cbHearth = WG_MakeCheck("WhatsGoodCheckHearth", "Protect Hearthstone", -148,
    function(v) db.protectHearth = v end)
  cbTrade = WG_MakeCheck("WhatsGoodCheckTrade", "Protect from trade", -172,
    function(v) db.protectTrade = v end)
  cbMail = WG_MakeCheck("WhatsGoodCheckMail", "Protect from mail", -196,
    function(v) db.protectMail = v end)
  cbAuction = WG_MakeCheck("WhatsGoodCheckAuction", "Protect from auction", -220,
    function(v) db.protectAuction = v end)
  cbAuto = WG_MakeCheck("WhatsGoodCheckAutosell", "Auto-sell junk at vendor", -244,
    function(v) db.autosell = v end)
  cbMini = WG_MakeCheck("WhatsGoodCheckMinimap", "Show minimap button", -268,
    function(v) db.minimapShown = v; WG_SyncMinimap() end)
  cbSound = WG_MakeCheck("WhatsGoodCheckSound", "Play sound on blocked action", -292,
    function(v) db.warnSound = v end)

  qSlider = CreateFrame("Slider", "WhatsGoodQualitySlider", panel, "OptionsSliderTemplate")
  if qSlider == nil then return end
  qSlider:SetPoint("TOPLEFT", 20, -342)
  qSlider:SetWidth(316)
  qSlider:SetMinMaxValues(0, 5)
  qSlider:SetValueStep(1)
  if qSlider.SetObeyStepOnDrag then qSlider:SetObeyStepOnDrag(true) end
  local slow = _G["WhatsGoodQualitySliderLow"]
  if slow and slow.SetText then slow:SetText("Grey") end
  local shigh = _G["WhatsGoodQualitySliderHigh"]
  if shigh and shigh.SetText then shigh:SetText("Legend.") end
  local stext = _G["WhatsGoodQualitySliderText"]
  if stext and stext.SetText then stext:SetText("Minimum quality") end
  qSlider:SetScript("OnValueChanged", function(_, value)
    value = WG_ClampQuality(value)
    if qLabel and qLabel.SetText then
      qLabel:SetText("Protects: " .. QUALITY_NAMES[value + 1] .. " and better")
    end
    if panelUpdating then return end
    if value ~= db.qualityThreshold then
      db.qualityThreshold = value
      WG_ApplyAndRefresh()
    end
  end)

  qLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  qLabel:SetPoint("TOPLEFT", 20, -386)
  qLabel:SetWidth(320)
  qLabel:SetJustifyH("LEFT")

  customLine = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  customLine:SetPoint("TOPLEFT", 20, -410)
  customLine:SetWidth(320)
  customLine:SetJustifyH("LEFT")

  customBox = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  customBox:SetPoint("TOPLEFT", 20, -434)
  customBox:SetWidth(320)
  customBox:SetJustifyH("LEFT")

  local junk = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  junk:SetWidth(96)
  junk:SetHeight(24)
  junk:SetPoint("BOTTOMLEFT", 16, 16)
  junk:SetText("Sell Junk")
  junk:SetScript("OnClick", function() WG_SellJunk() end)

  local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  reset:SetWidth(96)
  reset:SetHeight(24)
  reset:SetPoint("BOTTOM", 0, 16)
  reset:SetText("Reset")
  reset:SetScript("OnClick", function() WG_ResetDB() end)

  local close = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  close:SetWidth(96)
  close:SetHeight(24)
  close:SetPoint("BOTTOMRIGHT", -16, 16)
  close:SetText("Close")
  close:SetScript("OnClick", function() panel:Hide() end)

  local dlgClose = _G["WhatsGoodPanelClose"]
  if dlgClose and dlgClose.SetScript then
    dlgClose:SetScript("OnClick", function() panel:Hide() end)
  end

  panelBuilt = true
  WG_RefreshPanel()
end

local function WG_TogglePanel()
  if not db then return end
  if not panelBuilt then WG_BuildPanel() end
  if panel:IsShown() then panel:Hide() else panel:Show() end
end

-- ---------- minimap button ----------

local mmBtn = nil

local function WG_MinimapReposition()
  if not mmBtn then return end
  if type(Minimap) ~= "table" then return end
  if not db then return end
  local a = math.rad(db.minimapAngle or 215)
  if mmBtn.ClearAllPoints then pcall(mmBtn.ClearAllPoints, mmBtn) end
  if mmBtn.SetPoint then pcall(mmBtn.SetPoint, mmBtn, "CENTER", Minimap, "CENTER", 78 * math.cos(a), 78 * math.sin(a)) end
end

local function WG_MinimapDragUpdate()
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
  btn:SetWidth(32)
  btn:SetHeight(32)
  btn:SetNormalTexture("Interface\\Icons\\INV_Misc_Bag_10")
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local ring = btn:CreateTexture(nil, "OVERLAY")
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetWidth(54)
  ring:SetHeight(54)
  ring:SetPoint("CENTER")
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnDragStart", function()
    local cx, cy = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    btn._sx, btn._sy, btn._moved = cx / s, cy / s, nil
    btn:SetScript("OnUpdate", WG_MinimapDragUpdate)
  end)
  btn:SetScript("OnDragStop", function()
    btn:SetScript("OnUpdate", nil)
  end)
  btn:SetScript("OnClick", function(_, mouseBtn)
    if btn._moved then btn._moved = nil; return end
    if mouseBtn == "RightButton" then
      db.protectQuest = not db.protectQuest
      WG_ApplyAndRefresh()
      Msg("quest protection " .. (db.protectQuest and "on." or "off."))
    else
      WG_TogglePanel()
    end
  end)
  btn:SetScript("OnEnter", function()
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
  Msg(string.format("WhatsGood %s: quest=%s bound=%s hearth=%s trade=%s mail=%s auction=%s autosell=%s sound=%s quality>=%d custom=%d (Shift bypasses; /wg help)",
    VERSION,
    tostring(db.protectQuest), tostring(db.protectSoulbound), tostring(db.protectHearth),
    tostring(db.protectTrade), tostring(db.protectMail), tostring(db.protectAuction),
    tostring(db.autosell),
    tostring(db.warnSound),
    WG_ClampQuality(db.qualityThreshold), WG_CustomCount()))
end

-- Restore every setting to its default (clears the custom list too).
-- Global so the settings panel Reset button can reach it.
function WG_ResetDB()
  if not db then Msg("still loading, try again in a moment."); return end
  for k, v in pairs(DEFAULTS) do
    if k == "custom" then db[k] = {} else db[k] = v end
  end
  WG_ApplyAndRefresh()
  WG_SyncMinimap()
  Msg("settings reset to defaults.")
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
    local slots = 0
    if type(GetContainerNumSlots) == "function" then
      local ok, count = pcall(GetContainerNumSlots, bag)
      if ok and type(count) == "number" then slots = count end
    end
    for slot = 1, slots do
      if WG_IsJunkSlot(bag, slot) then
        local okS = pcall(sell, bag, slot)
        if okS then n = n + 1 end
      end
    end
  end
  Msg("sold " .. n .. " junk item(s).")
end

local function WG_HandleSlash(input)
  if not db then Msg("still loading, try again in a moment."); return end
  input = WG_Trim(input)
  local cmd, rest = string.match(input, "^(%S*)%s*(.*)$")
  cmd = string.lower(cmd or "")
  rest = WG_Trim(rest)
  if cmd == "" then WG_TogglePanel(); return end
  if cmd == "help" then
    Msg("/wg opens settings. threshold 0-5 | quest|soulbound|hearth|trade|mail|auction|autosell|minimap|sound on|off | add <link|id> | remove <link|id> | list | selljunk | reset | refresh | status")
    return
  end
  if cmd == "status" then WG_Status(); return end
  if cmd == "refresh" then WG_UpdateAll(); Msg("bags refreshed."); return end
  if cmd == "selljunk" then WG_SellJunk(); return end
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
    or cmd == "trade" or cmd == "mail" or cmd == "auction" or cmd == "autosell" or cmd == "sound" then
    local key = cmd == "quest" and "protectQuest"
      or cmd == "soulbound" and "protectSoulbound"
      or cmd == "hearth" and "protectHearth"
      or cmd == "trade" and "protectTrade"
      or cmd == "mail" and "protectMail"
      or cmd == "auction" and "protectAuction"
      or cmd == "autosell" and "autosell"
      or cmd == "sound" and "warnSound"
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
    local id = tonumber(string.match(rest, "item:(%d+)")) or tonumber(rest)
    if not id or id <= 0 or id ~= math.floor(id) then
      Msg("usage: /wg " .. cmd .. " <shift-click link|itemID>")
      return
    end
    if cmd == "add" then
      db.custom[id] = true
      Msg("protecting item " .. id .. ".")
    else
      db.custom[id] = nil
      Msg("unprotected item " .. id .. ".")
    end
    infoCache[id] = nil
    WG_ApplyAndRefresh()
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
      -- Copy tables by value: sharing DEFAULTS.custom by reference would
      -- let /wg add mutate the defaults for the rest of the session.
      if k == "custom" then db[k] = {} else db[k] = v end
    end
  end
  if type(db.custom) ~= "table" then db.custom = {} end
  for id in pairs(db.custom) do
    if type(id) ~= "number" or id <= 0 then db.custom[id] = nil end
  end
  db.qualityThreshold = WG_ClampQuality(db.qualityThreshold)
  if type(db.minimapAngle) ~= "number" then db.minimapAngle = 215 end
  for _, k in ipairs({ "protectQuest", "protectSoulbound", "protectHearth",
    "protectTrade", "protectMail", "protectAuction", "autosell",
    "warnSound", "minimapShown" }) do
    if type(db[k]) ~= "boolean" then db[k] = DEFAULTS[k] end
  end
end

WG:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    WhatsGoodDB = WhatsGoodDB or {}
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
    WG_QueueUpdate()
    Msg("WhatsGood " .. VERSION .. " loaded. Protected items are dimmed (see /wg). Hold Shift to force sell/delete.")
  elseif event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED"
    or event == "PLAYERBANKSLOTS_CHANGED"
    or event == "GET_ITEM_INFO_RECEIVED" then
    -- Drop the stale entry so the queued update re-scans this item now that
    -- its info (and tooltip lines) should resolve.
    if event == "GET_ITEM_INFO_RECEIVED" and type(arg1) == "number" then
      infoCache[arg1] = nil
    end
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
