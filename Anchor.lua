
local LibEvent = LibStub:GetLibrary("LibEvent.7000")
local LibSchedule = LibStub:GetLibrary("LibSchedule.7000")

local GetMouseFocus = GetMouseFocus or GetMouseFoci

local addon = TinyTooltip

-- ============================================================================
-- DEBUG
-- ============================================================================
local DEBUG_ANCHOR = false  -- Set to true to enable debug prints

local function DebugPrint(...)
    if DEBUG_ANCHOR then
        print("|cff00ff00[AnchorDebug]|r", ...)
    end
end

-- ============================================================================
-- UNIFIED ANCHOR DECISION MATRIX
-- ============================================================================

--[[
    Multi-Dimensional Decision Matrix for Tooltip Anchoring
    
    Input Dimensions:
    - targetType: "PLAYER" | "NPC" | "OTHER"
    - sourceType: "WORLD" | "UNITFRAME"
    - config: anchor configuration table
    
    Output: Deterministic action object
    {
        action = "HIDE" | "CURSOR" | "CURSOR_RIGHT" | "STATIC" | "DEFAULT",
        point = "BOTTOMRIGHT" | ...,
        x = number,
        y = number,
        cp = string (for CURSOR),
        cx = number (for CURSOR),
        cy = number (for CURSOR)
    }
]]

-- Core resolver: takes all context and returns deterministic action
local function ResolveAnchorAction(targetType, sourceType, config, depth)
    depth = depth or 0
    if (depth > 10) then
        -- Prevent infinite recursion
        return { action = "DEFAULT" }
    end
    
    if (not config) then
        return { action = "DEFAULT" }
    end
    
    local inCombat = InCombatLockdown()
    
    -- 1. Check hiddenInCombat
    if (config.hiddenInCombat and inCombat) then
        return { action = "HIDE" }
    end
    
    -- 2. Check returnInCombat
    if (config.returnInCombat and inCombat) then
        return ResolveAnchorAction(targetType, sourceType, addon.db.general.anchor, depth + 1)
    end
    
    -- 3. Check returnOnUnitFrame
    if (config.returnOnUnitFrame and sourceType == "UNITFRAME") then
        return ResolveAnchorAction(targetType, sourceType, addon.db.general.anchor, depth + 1)
    end
    
    -- 4. Resolve position
    local position = config.position
    
    if (position == "inherit") then
        return ResolveAnchorAction(targetType, sourceType, addon.db.general.anchor, depth + 1)
    elseif (position == "cursor") then
        return {
            action = "CURSOR",
            cp = config.cp or "BOTTOM",
            cx = config.cx or 0,
            cy = config.cy or 20
        }
    elseif (position == "cursorRight") then
        return { action = "CURSOR_RIGHT" }
    elseif (position == "static") then
        return {
            action = "STATIC",
            point = config.p or "BOTTOMRIGHT",
            x = config.x or (-CONTAINER_OFFSET_X - 13),
            y = config.y or CONTAINER_OFFSET_Y
        }
    else
        -- "default" or nil
        return { action = "DEFAULT" }
    end
end

-- Unified executor: applies resolved action to tooltip
local function ExecuteAnchorAction(tip, owner, action)
    if (not action) then return end
    
    if (action.action == "HIDE") then
        tip:Hide()
        return
    elseif (action.action == "CURSOR") then
        -- Trigger event for compatibility
        LibEvent:trigger("tooltip.anchor.cursor", tip, owner)
        -- Set cursor position with continuous tracking
        local x, y = GetCursorPosition()
        local scale = tip:GetEffectiveScale()
        local cp, cx, cy = action.cp, action.cx, action.cy
        tip:ClearAllPoints()
        tip:SetPoint(cp, UIParent, "BOTTOMLEFT", floor(x/scale+cx), floor(y/scale+cy))
        -- Setup continuous tracking
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
            onExecute = function(self)
                if (not self.tip:IsShown()) then return true end
                if (self.tip:GetAnchorType() ~= "ANCHOR_CURSOR") then return true end
                local x, y = GetCursorPosition()
                self.tip:ClearAllPoints()
                self.tip:SetPoint(self.cp, UIParent, "BOTTOMLEFT", floor(x/self.scale+self.cx), floor(y/self.scale+self.cy))
            end,
        })
    elseif (action.action == "CURSOR_RIGHT") then
        -- Trigger event for compatibility
        LibEvent:trigger("tooltip.anchor.cursor.right", tip, owner)
        -- Directly set CURSOR_RIGHT position WITHOUT calling SetOwner
        -- (which can cause Taint issues). Instead, manually position to cursor right.
        local x, y = GetCursorPosition()
        local scale = tip:GetEffectiveScale()
        tip:ClearAllPoints()
        tip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", floor(x/scale + 36), floor(y/scale - 12))
    elseif (action.action == "STATIC") then
        LibEvent:trigger("tooltip.anchor.static", tip, owner, action.x, action.y, action.point)
        tip:ClearAllPoints()
        tip:SetPoint(action.point, UIParent, action.point, action.x, action.y)
    elseif (action.action == "DEFAULT") then
        -- Use system default position (bottom right)
        tip:ClearAllPoints()
        tip:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -CONTAINER_OFFSET_X - 13, CONTAINER_OFFSET_Y)
    end
end

-- Helper: Get anchor config for target type
local function GetAnchorConfig(targetType)
    if (targetType == "PLAYER") then
        return addon.db.unit.player.anchor or addon.db.general.anchor
    elseif (targetType == "NPC") then
        return addon.db.unit.npc.anchor or addon.db.general.anchor
    else
        return addon.db.general.anchor
    end
end

-- ============================================================================
-- STATE MANAGEMENT
-- ============================================================================

local unitFrameOwner = nil
local pendingUnitReposition = false

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

LibEvent:attachTrigger("tooltip:anchor", function(self, tip, parent)
    if (tip ~= GameTooltip) then return end
    
    DebugPrint("[tooltip:anchor] START")
    
    -- Gather context
    local unit
    local focus = GetMouseFocus()
    local sourceType = "WORLD"
    
    if (focus and focus.unit) then
        unit = focus.unit
        sourceType = "UNITFRAME"
        unitFrameOwner = focus
        pendingUnitReposition = true
    else
        unitFrameOwner = nil
        pendingUnitReposition = false
    end
    
    if (not unit and focus and focus.GetAttribute) then
        unit = focus:GetAttribute("unit")
        if (unit) then
            sourceType = "UNITFRAME"
            unitFrameOwner = focus
            pendingUnitReposition = true
        end
    end
    
    if (not unit) then
        unit = "mouseover"
    end
    
    -- CRITICAL FIX: For UnitFrame tooltips, defer positioning to OnShow/tooltip:unit
    -- where unit information is guaranteed to be available.
    -- This prevents targetType from being misidentified as "OTHER" when unit info is not ready yet.
    if (sourceType == "UNITFRAME") then
        DebugPrint("[tooltip:anchor] UnitFrame detected, deferring to OnShow/tooltip:unit")
        -- Only record state, do NOT execute positioning
        -- Let OnShow/tooltip:unit handle it when unit info is ready
        return
    end
    
    -- For WORLD tooltips, execute positioning immediately
    local targetType = "OTHER"
    if (UnitIsPlayer(unit)) then
        targetType = "PLAYER"
    elseif (UnitExists(unit)) then
        targetType = "NPC"
    end
    
    -- ADDITIONAL FIX: If targetType is still "OTHER", it means unit info is not ready yet.
    -- This can happen when hovering UnitFrames that don't have .unit or GetAttribute.
    -- Defer positioning to OnShow where unit info will be available.
    if (targetType == "OTHER") then
        DebugPrint("[tooltip:anchor] targetType=OTHER, unit info not ready, deferring to OnShow")
        unitFrameOwner = GetMouseFocus()  -- Record focus for later
        pendingUnitReposition = true
        return
    end
    
    DebugPrint("[tooltip:anchor] WORLD unit - targetType:", targetType, "unit:", unit)
    
    local config = GetAnchorConfig(targetType)
    local action = ResolveAnchorAction(targetType, sourceType, config)
    DebugPrint("[tooltip:anchor] Executing action:", action.action)
    ExecuteAnchorAction(tip, parent, action)
end)

-- Hook SetOwner：检测单位框体并预设位置
-- Hook SetOwner：检测单位框体并预设位置
-- (Logic removed due to Taint issues causing empty tooltips in secure environments)


-- Hook OnHide：清除标记
GameTooltip:HookScript("OnHide", function(self)
    unitFrameOwner = nil
    pendingUnitReposition = false
end)

-- tooltip:unit 事件：锚点一致性维护
LibEvent:attachTrigger("tooltip:unit", function(self, tip, unit)
    if (tip ~= GameTooltip) then return end
    if (not unit) then return end
    if (not unitFrameOwner and not pendingUnitReposition) then return end
    
    DebugPrint("[tooltip:unit] START - unit:", unit)
    
    -- Determine target type
    local ok, isPlayer = pcall(UnitIsPlayer, unit)
    local targetType = (ok and isPlayer) and "PLAYER" or "NPC"
    
    DebugPrint("[tooltip:unit] targetType:", targetType)
    
    -- Get appropriate config
    local config = GetAnchorConfig(targetType)
    
    -- Resolve action with UNITFRAME source type
    local action = ResolveAnchorAction(targetType, "UNITFRAME", config)
    
    DebugPrint("[tooltip:unit] Executing action:", action.action, "position:", config.position)
    
    -- Execute action
    ExecuteAnchorAction(tip, unitFrameOwner, action)
    
    pendingUnitReposition = false
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

-- Hook OnShow：显示时立即重定位（确保 UnitFrame 正确显示）
GameTooltip:HookScript("OnShow", function(self)
    if (not unitFrameOwner and not pendingUnitReposition) then return end
    
    local unit = select(2, self:GetUnit())
    if (not unit) then
        pendingUnitReposition = false
        return
    end
    
    DebugPrint("[OnShow] START - unit:", unit)
    
    -- Determine target type
    local ok, isPlayer = pcall(UnitIsPlayer, unit)
    local targetType = (ok and isPlayer) and "PLAYER" or "NPC"
    
    DebugPrint("[OnShow] targetType:", targetType)
    
    -- Get appropriate config
    local config = GetAnchorConfig(targetType)
    
    -- Resolve action with UNITFRAME source type
    local action = ResolveAnchorAction(targetType, "UNITFRAME", config)
    
    DebugPrint("[OnShow] Executing action:", action.action, "position:", config.position)
    
    -- Execute action
    ExecuteAnchorAction(self, unitFrameOwner, action)
end)
