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
    DamageMeter = nil
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

-- Source-shaped Mainline meter (b9be9379); unmeasured on Forever. Frame and
-- manager selections are separate so a manager-only write cannot pass read-back.
function U.meterSetup(opts)
    opts = opts or {}
    Enum = Enum or {}
    Enum.DamageMeterType = { DamageDone = 0, Dps = 1, HealingDone = 2, Hps = 3, Absorbs = 4, Interrupts = 5, Dispels = 6, DamageTaken = 7, AvoidableDamageTaken = 8, Deaths = 9, EnemyDamageTaken = 10 }
    UIParent = { GetEffectiveScale = function() return 1 end,
        GetWidth = function() return 1920 end, GetHeight = function() return 1080 end }
    local data = {}
    U.meter = data
    local anchor = { BOTTOMLEFT={0,0}, TOPLEFT={0,1}, CENTER={.5,.5}, TOPRIGHT={1,1} }
    local function frame(i, d)
        local w = { index=i, shown=d.shown ~= false, meterType=d.damageMeterType,
            sessionType=d.sessionType, sessionID=d.sessionID, locked=d.locked,
            x=100, y=500, width=400, height=200, userPlaced=false, point="BOTTOMLEFT", relativePoint="BOTTOMLEFT" }
        function w:GetSessionWindowIndex() return self.index end
        function w:IsShown() if U.meterShownFail then error("unreadable") end return self.shown end
        function w:GetDamageMeterType() if U.meterReadFail then error("unreadable") end return self.meterType end
        function w:GetSessionType() return self.sessionType end
        function w:GetSessionID() return self.sessionID end
        function w:IsLocked() return self.locked end -- nil on a fresh window
        function w:IsMinimized() return self.minimized end
        function w:IsResizing() return self.resizing end
        function w:GetNumPoints() return 1 end
        function w:GetPoint() return self.point, UIParent, self.relativePoint, 0, 0 end
        function w:GetEffectiveScale() return 1 end
        function w:GetRect() return self.x,self.y,self.width,self.height end
        function w:IsUserPlaced() return self.userPlaced end
        function w:SetSize(width,height)
            call("MeterSize"); self.width,self.height=width,height; after("MeterSize")
        end
        function w:SetPoint(p, relative, rp, x, y)
            call("MeterPoint"); assert(relative == UIParent)
            self.point,self.relativePoint=p,rp
            self.x=x+anchor[rp][1]*1920-anchor[p][1]*self.width
            self.y=y+anchor[rp][2]*1080-anchor[p][2]*self.height
            after("MeterPoint")
        end
        function w:SetUserPlaced(v) call("MeterPlaced"); self.userPlaced=v; after("MeterPlaced") end
        return w
    end
    local function add(i, values)
        local d=copy(values or {damageMeterType=0,sessionType=0})
        data[i]=d; d.sessionWindow=frame(i,d)
        return d
    end
    add(1,opts[1])
    for i=2,3 do if opts[i] then add(i,opts[i]) end end
    local m={}
    DamageMeter=m
    function m:GetWindowDataList() return data end
    function m:GetSessionWindow(i) return data[i] and data[i].sessionWindow end
    function m:GetSessionWindowDamageMeterType(w) return data[w.index].damageMeterType end
    function m:CanShowNewSecondarySessionWindow()
        local n=0; for _,d in pairs(data) do if d.sessionWindow and d.sessionWindow:IsShown() then n=n+1 end end
        return n<3
    end
    function m:GetAvailableSecondarySessionWindowIndex()
        for i=2,3 do if data[i] and (not data[i].sessionWindow or not data[i].sessionWindow:IsShown()) then return i end end
    end
    function m:GetAvailableSecondaryWindowDataIndex() for i=2,3 do if not data[i] then return i end end end
    function m:ShowNewSecondarySessionWindow()
        call("MeterOpen")
        local i=self:GetAvailableSecondarySessionWindowIndex() or self:GetAvailableSecondaryWindowDataIndex()
        local d=data[i] or add(i)
        local w=d.sessionWindow
        -- SetupSessionWindow resets anchors and userPlaced, even for hidden frames.
        w.shown=true; w.point="TOPLEFT"; w.relativePoint="TOPLEFT"
        w.x=(i-1)*40; w.y=1080-(i-1)*40-w.height; w.userPlaced=false
        after("MeterOpen")
    end
    function m:SetSessionWindowDamageMeterType(w,t)
        call("MeterType"); data[w.index].damageMeterType=t
        if not U.meterManagerOnly then w.meterType=t end
        after("MeterType")
    end
    function m:SetSessionWindowSessionID(w,t,id)
        call("MeterSession"); data[w.index].sessionType=t; data[w.index].sessionID=id
        w.sessionType=t; w.sessionID=id; after("MeterSession")
    end
    function m:SetSessionWindowLocked(w,v)
        call("MeterLock"); data[w.index].locked=v; w.locked=v; after("MeterLock")
    end
    function m:HideSessionWindow(w)
        call("MeterHide"); assert(w.index~=1); w.shown=false; after("MeterHide")
    end
    DamageMeterPerCharacterSettings=setmetatable({}, {__index=function() error("SV read") end,
        __newindex=function() error("SV write") end})
    U.meterReadFail,U.meterShownFail,U.meterManagerOnly=false,false,false
end
