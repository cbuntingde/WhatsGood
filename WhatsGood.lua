-- WhatsGood: dim quest + important bag items, block accidental vendor/delete.
-- Standalone, no libraries. Works on WoW Forever 1.16.0 (Interface 16001).
-- Protection can be bypassed by holding Shift.

local ADDON = ...
if type(ADDON) ~= "string" then ADDON = "WhatsGood" end

local HEARTHSTONE_ID = 6948
local DEFAULTS = {
  qualityThreshold = 3, -- 0 poor .. 5 legendary: auto-protect at/above this
  protectQuest = true,
  protectSoulbound = true, -- only for quality >= 2 (green+), junk greys stay sellable
  protectHearth = true,
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
  for i = 1, tip:NumLines() do
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
      if line == ITEM_SOULBOUND or lower == "soulbound" then
        cached.soulbound = true
      end
    end
  end
  tip:ClearLines()
  cached.scanned = true
  return cached
end

-- ---------- classification ----------

local function WG_Classify(itemID, link)
  -- returns protected (bool), reason (string)
  if not itemID then return false, "none" end
  if db.custom[itemID] then return true, "listed" end
  if db.protectHearth and itemID == HEARTHSTONE_ID then return true, "hearthstone" end

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

  local isQuest = (itype == "Quest") or (cached and (cached.quest or cached.starter))
  if db.protectQuest and isQuest then
    if cached and cached.starter then return true, "quest starter" end
    return true, "quest item"
  end

  if quality == nil then return false, "unknown" end
  if quality <= 0 and not isQuest then return false, "junk" end
  if quality >= (db.qualityThreshold or 3) then return true, "rare+" end
  if db.protectSoulbound and cached and cached.soulbound and quality >= 2 then
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
    shade:SetTexture(0, 0, 0, 0.55)
    if icon then shade:SetAllPoints(icon) else shade:SetAllPoints(button) end
    button.wgShade = shade
  end
  button.wgShade:Show()
  if icon and icon.SetDesaturated then pcall(icon.SetDesaturated, icon, 1) end
  button.wgDimmed = true
end

local function WG_ClearDim(button)
  if button.wgShade then button.wgShade:Hide() end
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
  for i = 1, 30 do
    local frame = _G["ContainerFrame" .. i]
    if frame == nil then break end
    if frame.Items then WG_UpdateCombinedFrame(frame) else WG_UpdateClassicFrame(frame) end
  end
  if ContainerFrameCombinedBags then
    if ContainerFrameCombinedBags.Items then
      WG_UpdateCombinedFrame(ContainerFrameCombinedBags)
    else
      WG_UpdateClassicFrame(ContainerFrameCombinedBags)
    end
  end
end

local function WG_QueueUpdate()
  updateQueued = true
end

-- ---------- sell / delete protection ----------

local origUse, origPickup, origDelete, origClearCursor

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

local function WG_InstallBlocks()
  if not origUse and type(UseContainerItem) == "function" then
    origUse = UseContainerItem
    UseContainerItem = function(bag, slot, ...)
      if bag ~= nil and slot ~= nil and MerchantFrame and MerchantFrame.IsShown
        and MerchantFrame:IsShown() and not IsShiftKeyDown() then
        local ok, protected = pcall(WG_IsProtectedSlot, bag, slot)
        if ok and protected then
          Warn("Not selling " .. WG_LinkText(bag, slot) .. " (protected). Hold Shift to force.")
          return
        end
      end
      return origUse(bag, slot, ...)
    end
  end

  if not origPickup and type(PickupContainerItem) == "function" then
    origPickup = PickupContainerItem
    PickupContainerItem = function(bag, slot, ...)
      if bag ~= nil and slot ~= nil then
        local ok, protected = pcall(WG_IsProtectedSlot, bag, slot)
        lastPickup = { protected = ok and protected }
      else
        lastPickup = nil
      end
      return origPickup(bag, slot, ...)
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
end

-- ---------- tooltip note ----------

local function WG_InstallTooltipHook()
  if type(hooksecurefunc) ~= "function" then return end
  if not GameTooltip or not GameTooltip.SetBagItem then return end
  pcall(hooksecurefunc, GameTooltip, "SetBagItem", function(_, bag, slot)
    local ok, protected = pcall(WG_IsProtectedSlot, bag, slot)
    if ok and protected then
      GameTooltip:AddLine("WhatsGood: protected (won't auto-sell)", 1, 0.3, 0.3)
      GameTooltip:Show()
    end
  end)
end

-- ---------- settings panel ----------

local QUALITY_NAMES = {
  "Poor (grey)", "Common (white)", "Uncommon (green)",
  "Rare (blue)", "Epic (purple)", "Legendary (orange)",
}

local panel, cbQuest, cbSoul, cbHearth, cbMini
local qSlider, qLabel, customLine
local panelBuilt, panelUpdating = false, false
local WG_RefreshPanel, WG_SyncMinimap -- forward declarations (used before defined)

-- Re-classify every bag slot and sync the panel widgets.
local function WG_ApplyAndRefresh()
  infoCache = {}
  WG_UpdateAll()
  WG_RefreshPanel()
end

function WG_RefreshPanel()
  if not panelBuilt then return end
  panelUpdating = true
  cbQuest:SetChecked(db.protectQuest and true or false)
  cbSoul:SetChecked(db.protectSoulbound and true or false)
  cbHearth:SetChecked(db.protectHearth and true or false)
  cbMini:SetChecked(db.minimapShown ~= false)
  qSlider:SetValue(db.qualityThreshold or 3)
  qLabel:SetText("Protects: " .. QUALITY_NAMES[(db.qualityThreshold or 3) + 1] .. " and better")
  customLine:SetText("Custom list: " .. WG_CustomCount() .. " items  ( /wg add [Shift-click item] )")
  panelUpdating = false
end

local function WG_MakeCheck(name, label, y, set)
  local cb = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", 20, y)
  _G[name .. "Text"]:SetText(label)
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
  panel:SetWidth(360)
  panel:SetHeight(372)
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
  title:SetText("WhatsGood")

  local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  desc:SetPoint("TOPLEFT", 20, -44)
  desc:SetWidth(320)
  desc:SetJustifyH("LEFT")
  desc:SetText("Dims quest and important bag items so they can't be sold or deleted by accident. Hold Shift to bypass protection.")

  cbQuest = WG_MakeCheck("WhatsGoodCheckQuest", "Protect quest items", -104,
    function(v) db.protectQuest = v end)
  cbSoul = WG_MakeCheck("WhatsGoodCheckSoulbound", "Protect soulbound gear (green+)", -132,
    function(v) db.protectSoulbound = v end)
  cbHearth = WG_MakeCheck("WhatsGoodCheckHearth", "Protect Hearthstone", -160,
    function(v) db.protectHearth = v end)
  cbMini = WG_MakeCheck("WhatsGoodCheckMinimap", "Show minimap button", -188,
    function(v) db.minimapShown = v; WG_SyncMinimap() end)

  qSlider = CreateFrame("Slider", "WhatsGoodQualitySlider", panel, "OptionsSliderTemplate")
  qSlider:SetPoint("TOPLEFT", 20, -238)
  qSlider:SetWidth(316)
  qSlider:SetMinMaxValues(0, 5)
  qSlider:SetValueStep(1)
  if qSlider.SetObeyStepOnDrag then qSlider:SetObeyStepOnDrag(true) end
  _G["WhatsGoodQualitySliderLow"]:SetText("Grey")
  _G["WhatsGoodQualitySliderHigh"]:SetText("Legend.")
  _G["WhatsGoodQualitySliderText"]:SetText("Minimum quality")
  qSlider:SetScript("OnValueChanged", function(_, value)
    value = math.floor((value or 0) + 0.5)
    qLabel:SetText("Protects: " .. QUALITY_NAMES[value + 1] .. " and better")
    if panelUpdating then return end
    if value ~= db.qualityThreshold then
      db.qualityThreshold = value
      WG_ApplyAndRefresh()
    end
  end)

  qLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  qLabel:SetPoint("TOPLEFT", 20, -282)
  qLabel:SetWidth(320)
  qLabel:SetJustifyH("LEFT")

  customLine = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  customLine:SetPoint("TOPLEFT", 20, -306)
  customLine:SetWidth(320)
  customLine:SetJustifyH("LEFT")

  local close = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  close:SetWidth(96)
  close:SetHeight(24)
  close:SetPoint("BOTTOM", 0, 16)
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
  local a = math.rad(db.minimapAngle or 215)
  mmBtn:ClearAllPoints()
  mmBtn:SetPoint("CENTER", Minimap, "CENTER", 78 * math.cos(a), 78 * math.sin(a))
end

local function WG_MinimapDragUpdate()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local s = UIParent:GetEffectiveScale()
  cx, cy = cx / s, cy / s
  if mmBtn._sx and (math.abs(cx - mmBtn._sx) + math.abs(cy - mmBtn._sy) > 6) then
    mmBtn._moved = true
  end
  db.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
  WG_MinimapReposition()
end

function WG_SyncMinimap()
  if mmBtn and db then mmBtn:SetShown(db.minimapShown ~= false) end
end

local function WG_BuildMinimapButton()
  if mmBtn or not Minimap then return end
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
      .. QUALITY_NAMES[(db.qualityThreshold or 3) + 1] .. "+, "
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
  Msg(string.format("quest=%s soulbound=%s hearth=%s quality>=%d custom=%d (Shift bypasses; /wg help)",
    tostring(db.protectQuest), tostring(db.protectSoulbound), tostring(db.protectHearth),
    tonumber(db.qualityThreshold) or 3, WG_CustomCount()))
end

local function WG_HandleSlash(input)
  if not db then Msg("still loading, try again in a moment."); return end
  input = WG_Trim(input)
  local cmd, rest = string.match(input, "^(%S*)%s*(.*)$")
  cmd = string.lower(cmd or "")
  rest = WG_Trim(rest)
  if cmd == "" then WG_TogglePanel(); return end
  if cmd == "help" then
    Msg("/wg opens settings. threshold 0-5 | quest on|off | soulbound on|off | hearth on|off | minimap on|off | add <link|id> | remove <link|id> | list | refresh")
    return
  end
  if cmd == "status" then WG_Status(); return end
  if cmd == "refresh" then WG_UpdateAll(); Msg("bags refreshed."); return end
  if cmd == "threshold" then
    local n = tonumber(rest)
    if n and n >= 0 and n <= 5 then
      db.qualityThreshold = math.floor(n)
      WG_ApplyAndRefresh()
      Msg("now protecting quality " .. db.qualityThreshold .. "+ (0=poor ... 5=legendary).")
    else
      Msg("usage: /wg threshold 0-5 (current " .. tostring(db.qualityThreshold) .. ")")
    end
    return
  end
  if cmd == "quest" or cmd == "soulbound" or cmd == "hearth" or cmd == "minimap" then
    local key = cmd == "quest" and "protectQuest"
      or cmd == "soulbound" and "protectSoulbound"
      or cmd == "hearth" and "protectHearth"
      or "minimapShown"
    if rest == "on" then db[key] = true
    elseif rest == "off" then db[key] = false
    else Msg("usage: /wg " .. cmd .. " on|off"); return end
    if cmd == "minimap" then
      WG_SyncMinimap()
      Msg("minimap button " .. (db.minimapShown and "shown." or "hidden."))
    else
      WG_ApplyAndRefresh()
      Msg(cmd .. " protection " .. rest .. ".")
    end
    return
  end
  if cmd == "add" or cmd == "remove" then
    local id = tonumber(string.match(rest, "item:(%d+)")) or tonumber(rest)
    if not id then Msg("usage: /wg " .. cmd .. " <shift-click link|itemID>"); return end
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

WG:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    WhatsGoodDB = WhatsGoodDB or {}
    db = WhatsGoodDB
    for k, v in pairs(DEFAULTS) do
      if db[k] == nil then db[k] = v end
    end
    if type(db.custom) ~= "table" then db.custom = {} end
    if type(db.qualityThreshold) ~= "number" then db.qualityThreshold = 3 end
    if type(db.minimapAngle) ~= "number" then db.minimapAngle = 215 end
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
    Msg("loaded. Protected items are dimmed (see /wg). Hold Shift to force sell/delete.")
  elseif event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED"
    or event == "PLAYERBANKSLOTS_CHANGED" or event == "MERCHANT_SHOW"
    or event == "GET_ITEM_INFO_RECEIVED" then
    WG_QueueUpdate()
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
