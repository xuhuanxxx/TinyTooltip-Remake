
local LibEvent = LibStub:GetLibrary("LibEvent.7000")
local LibSchedule = LibStub:GetLibrary("LibSchedule.7000")

local GetMouseFocus = GetMouseFocus or GetMouseFoci

local addon = TinyTooltip

local function AnchorCursorOnExecute(self)
    if (not self.tip:IsShown()) then return true end
    if (self.tip:GetAnchorType() ~= "ANCHOR_CURSOR") then return true end
    local x, y = GetCursorPosition()
    self.tip:ClearAllPoints()
    self.tip:SetPoint(self.cp, UIParent, "BOTTOMLEFT", floor(x/self.scale+self.cx), floor(y/self.scale+self.cy))
end

local function AnchorCursor(tip, parent, cp, cx, cy)
    local x, y = GetCursorPosition()
    local scale = tip:GetEffectiveScale()
    cp, cx, cy = cp or "BOTTOM", cx or 0, cy or 20
    tip:ClearAllPoints()
    tip:SetPoint(cp, UIParent, "BOTTOMLEFT", floor(x/scale+cx), floor(y/scale+cy))
    LibSchedule:AddTask({
        identity = tostring(tip),
        elasped  = 0.01,
        expired  = GetTime() + 300,
        override = true,
        tip      = tip,
        cp       = cp,
        cx       = cx,
        cy       = cy,
        scale    = scale,
        onExecute = AnchorCursorOnExecute,
    })
end

local function AnchorDefaultPosition(tip, parent, anchor, finally)
    if (finally) then
        LibEvent:trigger("tooltip.anchor.static", tip, parent, anchor.x, anchor.y)
    elseif (anchor.position == "inherit") then
        AnchorDefaultPosition(tip, parent, addon.db.general.anchor, true)
    else
        LibEvent:trigger("tooltip.anchor.static", tip, parent, anchor.x, anchor.y, anchor.p)
    end
end

local function AnchorFrame(tip, parent, anchor, isUnitFrame, finally)
    if (not anchor) then return end
    if (anchor.hiddenInCombat and InCombatLockdown()) then
        return LibEvent:trigger("tooltip.anchor.none", tip, parent)
    end
    if (anchor.returnInCombat and InCombatLockdown()) then return AnchorDefaultPosition(tip, parent, anchor, finally) end
    if (anchor.returnOnUnitFrame and isUnitFrame) then return AnchorDefaultPosition(tip, parent, anchor, finally) end
    if (anchor.position == "cursorRight") then
        LibEvent:trigger("tooltip.anchor.cursor.right", tip, parent)
    elseif (anchor.position == "cursor") then
        LibEvent:trigger("tooltip.anchor.cursor", tip, parent)
        AnchorCursor(tip, parent, anchor.cp, anchor.cx, anchor.cy)
    elseif (anchor.position == "inherit" and not finally) then
        AnchorFrame(tip, parent, addon.db.general.anchor, isUnitFrame, true)
    elseif (anchor.position == "static") then
        LibEvent:trigger("tooltip.anchor.static", tip, parent, anchor.x, anchor.y, anchor.p)
    end
end

-- 获取 NPC anchor 配置（支持回退到 general）
local function GetNpcAnchor()
    local npcAnchor = addon.db.unit.npc.anchor
    return npcAnchor or addon.db.general.anchor
end

-- 获取玩家 anchor 配置（支持回退到 general）
local function GetPlayerAnchor()
    local playerAnchor = addon.db.unit.player.anchor
    return playerAnchor or addon.db.general.anchor
end

-- 检查是否需要立即设置位置（用于SetOwner时防止闪烁）
local function ShouldSetPositionImmediate(anchor, isUnitFrame)
    if (not anchor) then return false end
    if (anchor.hiddenInCombat and InCombatLockdown()) then return false end
    if (anchor.returnInCombat and InCombatLockdown()) then return false end
    if (anchor.returnOnUnitFrame and isUnitFrame) then return true end
    local position = anchor.position
    if (position == "inherit") then
        local generalAnchor = addon.db.general.anchor
        if (generalAnchor) then
            return ShouldSetPositionImmediate(generalAnchor, isUnitFrame)
        end
        return false
    elseif (position == "cursor" or position == "cursorRight" or position == "static") then
        return true
    else
        -- default 或 nil 位置：也需要立即设置到系统默认位置（右下角）以防止闪烁
        return true
    end
end

-- 立即设置tooltip位置（用于SetOwner时防止闪烁）
local function SetTooltipPositionImmediate(tip, owner, anchor, isUnitFrame)
    if (not anchor) then return end
    if (anchor.hiddenInCombat and InCombatLockdown()) then return end
    if (anchor.returnInCombat and InCombatLockdown()) then return end
    if (anchor.returnOnUnitFrame and isUnitFrame) then
        -- returnOnUnitFrame 时使用默认位置
        local x = (anchor.x) or (-CONTAINER_OFFSET_X - 13)
        local y = (anchor.y) or CONTAINER_OFFSET_Y
        local p = (anchor.p) or "BOTTOMRIGHT"
        tip:ClearAllPoints()
        tip:SetPoint(p, UIParent, p, x, y)
        return
    end
    
    local position = anchor.position
    if (position == "inherit") then
        local generalAnchor = addon.db.general.anchor
        if (generalAnchor) then
            SetTooltipPositionImmediate(tip, owner, generalAnchor, isUnitFrame)
        end
        return
    elseif (position == "cursor") then
        -- 立即设置cursor位置
        AnchorCursor(tip, owner, anchor.cp, anchor.cx, anchor.cy)
    elseif (position == "cursorRight") then
        -- 立即设置cursorRight位置，使用事件触发（避免在 SetOwner hook 中再次调用 SetOwner）
        LibEvent:trigger("tooltip.anchor.cursor.right", tip, owner)
    elseif (position == "static") then
        -- 立即设置静态位置
        local x = (anchor.x) or (-CONTAINER_OFFSET_X - 13)
        local y = (anchor.y) or CONTAINER_OFFSET_Y
        local p = (anchor.p) or "BOTTOMRIGHT"
        tip:ClearAllPoints()
        tip:SetPoint(p, UIParent, p, x, y)
    else
        -- default 或 nil 位置：使用系统默认位置（右下角）
        local x = (-CONTAINER_OFFSET_X - 13)
        local y = CONTAINER_OFFSET_Y
        local p = "BOTTOMRIGHT"
        tip:ClearAllPoints()
        tip:SetPoint(p, UIParent, p, x, y)
    end
end

LibEvent:attachTrigger("tooltip:anchor", function(self, tip, parent)
    if (tip ~= GameTooltip) then return end
    local unit
    local focus = GetMouseFocus()
    local isUnitFrame = false
    if (focus and focus.unit) then
        unit = focus.unit
        isUnitFrame = true
    end
    if (not unit and focus and focus.GetAttribute) then
        unit = focus:GetAttribute("unit")
    end
    if (not unit) then
        unit = "mouseover"
    end
    if (UnitIsPlayer(unit)) then
        AnchorFrame(tip, parent, addon.db.unit.player.anchor, isUnitFrame)
    elseif (UnitExists(unit)) then
        AnchorFrame(tip, parent, addon.db.unit.npc.anchor, isUnitFrame)
    else
        AnchorFrame(tip, parent, addon.db.general.anchor, isUnitFrame)
    end
    
    -- 如果是单位框体，在 tooltip:anchor 之后立即设置位置（防止闪烁）
    -- cursor 已经在 SetOwner 时设置了，cursorRight 需要在这里确保正确设置
    if (unitFrameOwner and (unitFrameOwner == focus)) then
        local ok, isPlayer = pcall(UnitIsPlayer, unit)
        isPlayer = ok and isPlayer
        local anchorToUse = isPlayer and GetPlayerAnchor() or GetNpcAnchor()
        if (anchorToUse) then
            if (anchorToUse.position == "cursorRight") then
                -- cursorRight 需要确保正确设置（可能 AnchorFrame 处理时机不对）
                LibEvent:trigger("tooltip.anchor.cursor.right", tip, unitFrameOwner)
            elseif (anchorToUse.position ~= "cursor") then
                -- cursor 已经在 SetOwner 时设置了，跳过
                SetTooltipPositionImmediate(tip, unitFrameOwner, anchorToUse, true)
            end
        end
    end
end)

-- 修复单位框体 tooltip 跳动问题
local unitFrameOwner = nil
local pendingUnitReposition = false
local isUnitFramePlayer = false

-- Hook SetOwner：检测单位框体并预设位置
-- Hook SetOwner：检测单位框体并预设位置
-- (Logic removed due to Taint issues causing empty tooltips in secure environments)


-- Hook OnHide：清除标记
GameTooltip:HookScript("OnHide", function(self)
    unitFrameOwner = nil
    pendingUnitReposition = false
end)

-- tooltip:unit 事件：备份重定位
LibEvent:attachTrigger("tooltip:unit", function(self, tip, unit)
    if (tip ~= GameTooltip) then return end
    if (not unit) then return end
    
    local ok, isPlayer = pcall(UnitIsPlayer, unit)
    isPlayer = ok and isPlayer
    
    if (unitFrameOwner or pendingUnitReposition) then
        -- 确保位置正确设置（包括 default 位置）
        local anchorToUse = isPlayer and GetPlayerAnchor() or GetNpcAnchor()
        if (anchorToUse and unitFrameOwner) then
            -- 对于 cursorRight，确保正确设置（可能 AnchorFrame 处理时机不对）
            if (anchorToUse.position == "cursorRight") then
                LibEvent:trigger("tooltip.anchor.cursor.right", tip, unitFrameOwner)
            else
                SetTooltipPositionImmediate(tip, unitFrameOwner, anchorToUse, true)
            end
        end
        pendingUnitReposition = false
    elseif (unitFrameOwner) then
        -- 即使没有 pendingUnitReposition，如果是单位框体，也需要设置位置
        local anchorToUse = isPlayer and GetPlayerAnchor() or GetNpcAnchor()
        if (anchorToUse and unitFrameOwner) then
            if (anchorToUse.position == "cursorRight") then
                LibEvent:trigger("tooltip.anchor.cursor.right", tip, unitFrameOwner)
            elseif (anchorToUse.position ~= "cursor") then
                SetTooltipPositionImmediate(tip, unitFrameOwner, anchorToUse, true)
            end
        end
    end
end)

-- tooltip:item 和 tooltip:spell 事件：清除单位重定位标志
-- 当 tooltip 显示物品或法术内容时，不应使用单位静态位置
LibEvent:attachTrigger("tooltip:item", function(self, tip)
    if (tip ~= GameTooltip) then return end
    if (pendingUnitReposition) then
        pendingUnitReposition = false
    end
end)

LibEvent:attachTrigger("tooltip:spell", function(self, tip)
    if (tip ~= GameTooltip) then return end
    if (pendingUnitReposition) then
        pendingUnitReposition = false
    end
end)

-- Hook OnShow：显示时立即重定位
GameTooltip:HookScript("OnShow", function(self)
    if (pendingUnitReposition) then
        local unit = select(2, self:GetUnit())
        if (unit) then
            -- 检查单位类型，确保使用正确的 anchor
            local ok, isPlayer = pcall(UnitIsPlayer, unit)
            isPlayer = ok and isPlayer
            -- 确保位置正确设置
            local anchorToUse = isPlayer and GetPlayerAnchor() or GetNpcAnchor()
            if (anchorToUse and unitFrameOwner) then
                if (anchorToUse.position == "cursorRight") then
                    LibEvent:trigger("tooltip.anchor.cursor.right", self, unitFrameOwner)
                else
                    SetTooltipPositionImmediate(self, unitFrameOwner, anchorToUse, true)
                end
            end
        else
            pendingUnitReposition = false
        end
    elseif (unitFrameOwner) then
        -- 即使没有 pendingUnitReposition，如果是单位框体，也需要设置位置
        local unit = select(2, self:GetUnit())
        if (unit) then
            local ok, isPlayer = pcall(UnitIsPlayer, unit)
            isPlayer = ok and isPlayer
            local anchorToUse = isPlayer and GetPlayerAnchor() or GetNpcAnchor()
            if (anchorToUse and unitFrameOwner) then
                if (anchorToUse.position == "cursorRight") then
                    LibEvent:trigger("tooltip.anchor.cursor.right", self, unitFrameOwner)
                elseif (anchorToUse.position ~= "cursor") then
                    SetTooltipPositionImmediate(self, unitFrameOwner, anchorToUse, true)
                end
            end
        end
    end
end)
