------------------------------------------------------------
-- wow_ui.lua - the UI setup surface of the WoW mock (#10): Edit Mode
-- layouts, action bar toggles, CVars and chat windows. Load after
-- wow_stubs.lua and wow_game.lua; drive it through WoW.ui.setup{...}.
--
-- Shapes follow the API dump (70450) and docs/forever-api-notes.md:
-- GetLayouts().activeLayout counts the presets first (3 presets, measured
-- 70338) and .layouts holds only the saved ones; GetActionBarToggles returns
-- seven booleans (bars 2-8); GetCVarInfo returns value, default,
-- isStoredServerAccount, isStoredServerCharacter, isLockedFromUser, isSecure,
-- isReadOnly. The chat functions model Mainline's FloatingChatFrame:
-- FCF_OpenNewWindow(name, noDefaultChannels) docks the new window in the
-- first free unreserved slot; without the second argument it gets default
-- groups. Unmeasured on Forever: that is what the in-game check is for.
------------------------------------------------------------

local U = {}
WoW.ui = U

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = type(v) == "table" and copy(v) or v end
    return c
end

local DEFAULT_GROUPS = { "SAY", "EMOTE", "YELL", "GUILD", "PARTY", "WHISPER", "BN_WHISPER", "SYSTEM", "CHANNEL" }

function U.setup(opts)
    opts = opts or {}
    U.presets = { "Modern", "Classic", "Gamepad" }
    U.layouts = opts.layouts or { { layoutName = "My UI", layoutType = 1 } }
    U.active = opts.active or 1
    U.bars = opts.bars or { false, false, false, false, false, false, false }
    U.cvars = opts.cvars or {
        damageMeterEnabled = "0", damageMeterResetOnNewInstance = "0", raidFramesDisplayClassColor = "0",
        raidFramesDisplayPowerBars = "0", raidFramesHealthBarColorBG = "ff333333", enableMouseoverCast = "0",
    }
    U.cvarInfo = opts.cvarInfo or {}
    U.editMode, U.chatConfig = false, false
    U.ignoreNoDefault = opts.ignoreNoDefault  -- a client that gives a new window its defaults anyway
    U.calls = {}
    U.after = {}            -- [call name] = function() end, run after that call (e.g. combat starts)
    U.windows = {}
    for i = 1, 10 do
        U.windows[i] = { name = "", shown = false, docked = false, uninteractable = false, groups = {} }
    end
    U.windows[1] = { name = "General", shown = true, docked = true, uninteractable = false,
                     groups = copy(DEFAULT_GROUPS) }
    U.windows[2] = { name = "Combat Log", shown = false, docked = true, uninteractable = false, groups = {} }
    U.windows[3] = { name = "Voice", shown = false, docked = true, uninteractable = false, groups = {} }
    for i, w in pairs(opts.windows or {}) do U.windows[i] = w end
    for i = 1, 10 do
        _G["ChatFrame" .. i] = { id = i, GetID = function(self) return self.id end }
    end
    U.setupMeter(opts)
end

local function call(name)
    U.calls[#U.calls + 1] = name
end
local function after(name) if U.after[name] then U.after[name]() end end

function U.count(name)
    local n = 0
    for _, c in ipairs(U.calls) do if c == name then n = n + 1 end end
    return n
end

C_EditMode = C_EditMode or {}
C_EditMode.GetLayouts = function()
    return { layouts = copy(U.layouts), activeLayout = U.active }
end
C_EditMode.SetActiveLayout = function(i)
    call("SetActiveLayout")
    assert(type(i) == "number" and i >= 1 and i <= #U.presets + #U.layouts, "SetActiveLayout: bad index")
    U.active = i
    after("SetActiveLayout")
end
EditModePresetLayoutManager = {
    GetCopyOfPresetLayouts = function()
        local p = {}
        for i, n in ipairs(U.presets) do p[i] = { layoutName = n, layoutType = 0 } end
        return p
    end,
}
EditModeManagerFrame = {
    IsEditModeActive = function() return U.editMode end,
    IsShown = function() return U.editMode end,
}
ChatConfigFrame = { IsShown = function() return U.chatConfig end }

function GetActionBarToggles() return unpack(U.bars, 1, 7) end
function SetActionBarToggles(...)
    call("SetActionBarToggles")
    local n = select("#", ...)
    assert(n == 7, "SetActionBarToggles: seven values")
    for i = 1, 7 do
        local v = select(i, ...)
        assert(type(v) == "boolean", "SetActionBarToggles: booleans")
        U.bars[i] = v
    end
    after("SetActionBarToggles")
end

C_CVar = C_CVar or {}
C_CVar.GetCVar = function(name) return U.cvars[name] end
C_CVar.SetCVar = function(name, value)
    call("SetCVar:" .. name)
    local info = U.cvarInfo[name] or {}
    if info.secure or info.readOnly or info.locked then error("protected CVar " .. name .. " written", 2) end
    U.cvars[name] = tostring(value)
    after("SetCVar:" .. name)
    return true
end
C_CVar.GetCVarInfo = function(name)
    if U.cvars[name] == nil then return nil end
    local i = U.cvarInfo[name] or {}
    return U.cvars[name], "0", i.account or false, not i.account, i.locked or false, i.secure or false,
        i.readOnly or false
end

NUM_CHAT_WINDOWS = 10
ChatTypeGroup = {}
for _, g in ipairs({ "SAY", "EMOTE", "YELL", "GUILD", "OFFICER", "PARTY", "RAID", "WHISPER", "BN_WHISPER",
                     "SYSTEM", "CHANNEL", "COMBAT_XP_GAIN", "LOOT", "MONEY" }) do
    ChatTypeGroup[g] = { "CHAT_MSG_" .. g }
end

function GetChatWindowInfo(i)
    local w = U.windows[i]
    if not w then return nil end
    return w.name, 14, 0, 0, 0, 1, w.shown, false, w.docked, w.uninteractable
end
function GetChatWindowMessages(i)
    if U.readFail then error("GetChatWindowMessages failed", 2) end   -- a test turns reads off mid-operation
    local w = U.windows[i]
    return unpack(w and w.groups or {})
end
function FCF_IsChatWindowIndexActive(i)
    local w = U.windows[i]
    return w and (w.shown or w.docked) and true or false
end
function FCF_IsChatWindowIndexReserved(i) return i == 2 end

local function indexOf(t, v)
    for i, x in ipairs(t) do if x == v then return i end end
end

function ChatFrame_AddMessageGroup(frame, g)
    call("AddMessageGroup:" .. g)
    local w = U.windows[frame.id]
    if ChatTypeGroup[g] and not indexOf(w.groups, g) then w.groups[#w.groups + 1] = g end
    after("AddMessageGroup:" .. g)
end
function ChatFrame_RemoveMessageGroup(frame, g)
    call("RemoveMessageGroup:" .. g)
    local w = U.windows[frame.id]
    local i = indexOf(w.groups, g)
    if ChatTypeGroup[g] and i then table.remove(w.groups, i) end
    after("RemoveMessageGroup:" .. g)
end
function FCF_OpenNewWindow(name, noDefaultChannels)
    call("FCF_OpenNewWindow")
    for i = 3, NUM_CHAT_WINDOWS do
        local w = U.windows[i]
        if not (w.shown or w.docked) and not FCF_IsChatWindowIndexReserved(i) then
            U.windows[i] = { name = name, shown = false, docked = true, uninteractable = false,
                             groups = (noDefaultChannels and not U.ignoreNoDefault) and {} or copy(DEFAULT_GROUPS) }
            after("FCF_OpenNewWindow")
            return _G["ChatFrame" .. i]
        end
    end
end
function FCF_Close() error("FCF_Close must never be called by AltStableSync", 2) end

------------------------------------------------------------
-- The damage meter (Blizzard_DamageMeter): a copy of the Mainline mixin's
-- window logic (wow-ui-source live, 12.1.5 (70448), DamageMeter.lua and
-- DamageMeterSessionWindow.lua). UNMEASURED on Forever: the PR's in-game
-- check is what proves the client matches. Driven by WoW.ui.setup{ meter = {
--   windows = { [i] = { type, sessionType, sessionID, locked, shown, rect } } } }
-- (window 1 always exists and is shown) or { noMeter = true } (API absent).
-- U.dmSaved is Blizzard's DamageMeterPerCharacterSettings: only this stub's
-- "Blizzard" code writes it, as only Blizzard's SetSavedWindowData does.
------------------------------------------------------------

Enum = Enum or {}
Enum.DamageMeterType = { DamageDone = 0, Dps = 1, HealingDone = 2, Hps = 3, Absorbs = 4, Interrupts = 5,
                         Dispels = 6, DamageTaken = 7, AvoidableDamageTaken = 8, Deaths = 9, EnemyDamageTaken = 10 }
Enum.DamageMeterSessionType = { Overall = 0, Current = 1, Expired = 2 }

local MAX_DM = 3

local function NewSessionWindow(owner, i)
    local w = { index = i, shown = false, owner = owner,
                rect = { point = "TOPLEFT", relativeTo = UIParent, relativePoint = "TOPLEFT",
                         x = (i - 1) * 40, y = (i - 1) * -40, width = 300, height = 200 } }
    function w:GetDamageMeterType() return self.damageMeterType end
    function w:GetSessionType() return self.sessionType end
    function w:GetSessionID() return self.sessionID end
    function w:IsLocked() return self.isLocked end
    function w:IsShown() return self.shown end
    function w:Show() self.shown = true end
    function w:Hide() self.shown = false end
    function w:GetSessionWindowIndex() return self.index end
    function w:GetNumPoints() return self.rect and 1 or 0 end
    function w:GetPoint(n)
        local r = self.rect
        if n ~= 1 or not r then return nil end
        return r.point, r.relativeTo, r.relativePoint, r.x, r.y
    end
    function w:GetWidth() return self.rect and self.rect.width end
    function w:GetHeight() return self.rect and self.rect.height end
    _G["DamageMeterSessionWindow" .. i] = w
    return w
end

local function SaveWindow(i, d)
    U.dmSaved.windowDataList[i] = U.dmSaved.windowDataList[i] or {}
    local s = U.dmSaved.windowDataList[i]
    s.damageMeterType, s.sessionType = d.damageMeterType, d.sessionType
    s.shown = d.sessionWindow and d.sessionWindow:IsShown() or false
    s.locked = d.locked
end

local function Setup(dm, i, d)
    local w = d.sessionWindow or NewSessionWindow(dm, i)
    d.sessionWindow = w
    w.damageMeterType, w.sessionType, w.sessionID = d.damageMeterType, d.sessionType, d.sessionID
    w:Show()
    if d.locked then w.isLocked = true end
end

local function NewDamageMeter()
    local dm = { windowDataList = {}, sessionType = Enum.DamageMeterSessionType.Overall }
    local function data(w) return w.index, dm.windowDataList[w.index] end
    function dm:GetSessionWindow(i) return self.windowDataList[i] and self.windowDataList[i].sessionWindow or nil end
    function dm:GetMaxSessionWindowCount() return MAX_DM end
    function dm:GetWindowDataList() return self.windowDataList end
    function dm:GetCurrentSessionWindowCount()
        local n = 0
        for _, d in pairs(self.windowDataList) do if d.sessionWindow and d.sessionWindow:IsShown() then n = n + 1 end end
        return n
    end
    function dm:ShowNewSecondarySessionWindow()
        call("ShowNewSecondarySessionWindow")
        if self:GetCurrentSessionWindowCount() >= MAX_DM then return end
        -- An existing window that isn't shown is reused with its old data.
        for i = 2, MAX_DM do
            local d = self.windowDataList[i]
            if d and (d.sessionWindow == nil or not d.sessionWindow:IsShown()) then
                Setup(self, i, d)
                SaveWindow(i, d)
                after("ShowNewSecondarySessionWindow")
                return
            end
        end
        for i = 2, MAX_DM do
            if not self.windowDataList[i] then
                local d = { damageMeterType = Enum.DamageMeterType.DamageDone, sessionType = self.sessionType }
                self.windowDataList[i] = d
                Setup(self, i, d)
                SaveWindow(i, d)
                after("ShowNewSecondarySessionWindow")
                return
            end
        end
    end
    function dm:HideSessionWindow(w)
        call("HideSessionWindow:" .. tostring(w and w.index))
        if w == nil or w == self:GetSessionWindow(1) then return end
        local i, d = data(w)
        d.sessionWindow:Hide()
        SaveWindow(i, d)
        after("HideSessionWindow")
    end
    function dm:SetSessionWindowDamageMeterType(w, t)
        call("SetSessionWindowDamageMeterType:" .. w.index)
        if U.dmIgnore == "type" then return end   -- a client that drops the write
        local i, d = data(w)
        d.damageMeterType = t
        SaveWindow(i, d)
        w.damageMeterType = t
        after("SetSessionWindowDamageMeterType")
    end
    function dm:GetSessionWindowDamageMeterType(w) local _, d = data(w); return d.damageMeterType end
    function dm:SetSessionWindowSessionID(w, sessionType, sessionID)
        call("SetSessionWindowSessionID:" .. w.index)
        local i, d = data(w)
        d.sessionType, d.sessionID = sessionType, sessionID
        SaveWindow(i, d)
        w.sessionType, w.sessionID = sessionType, sessionID
        after("SetSessionWindowSessionID")
    end
    function dm:SetSessionWindowLocked(w, locked)
        call("SetSessionWindowLocked:" .. w.index)
        local i, d = data(w)
        d.locked = locked
        SaveWindow(i, d)
        w.isLocked = locked
        after("SetSessionWindowLocked")
    end
    return dm
end

function U.setupMeter(opts)
    U.dmIgnore = nil
    for i = 1, MAX_DM do _G["DamageMeterSessionWindow" .. i] = nil end
    if opts.noMeter then
        DamageMeter, DamageMeterPerCharacterSettings = nil, nil
        return
    end
    U.dmSaved = { windowDataList = {} }
    DamageMeterPerCharacterSettings = U.dmSaved
    DamageMeter = NewDamageMeter()
    local spec = (opts.meter and opts.meter.windows) or {}
    spec[1] = spec[1] or {}
    for i = 1, MAX_DM do
        local s = spec[i]
        if s then
            local d = { damageMeterType = s.type or Enum.DamageMeterType.DamageDone,
                        sessionType = s.sessionType == nil and (not s.sessionID and 0 or nil) or s.sessionType,
                        sessionID = s.sessionID, locked = s.locked }
            DamageMeter.windowDataList[i] = d
            if i == 1 or s.shown ~= false then
                Setup(DamageMeter, i, d)
                if s.rect ~= nil then d.sessionWindow.rect = s.rect or nil end
            end
            SaveWindow(i, d)
        end
    end
end
