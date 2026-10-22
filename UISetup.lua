------------------------------------------------------------
-- UISetup.lua - UI setups: capture, plan, apply and exact restore (#10)
--
-- A UI setup is a catalog entry of kind "ui" with up to five parts, each
-- optional (docs/DESIGN.md "UI setups: parts"):
--   layout = { type = 1, name } | { type = 0, index, name }   -- select an existing
--            Edit Mode layout (Account by name, preset by index); never
--            create, import, edit or delete one
--   bars   = { [2..8] = bool }      -- SetActionBarToggles
--   cvars  = { [name] = "value" }   -- the allowlist below, each with a domain
--   chat   = { primary = { groups }, tabs = { { name, groups } } }
--   meter  = { windows = { { type, session }, { type, session, locked, rect } } }
--            -- the damage meter: window 1 the primary, then the shown
--            secondaries in index order; rect is recorded, never applied
-- Unknown keys (a newer build's parts) are kept and never applied.
--
-- The rules are the loadout's (docs/DESIGN.md safety model): Plan only
-- reads; Apply and Restore write only after the player confirmed a preview of
-- exactly the plan applied (the fingerprint); the touched parts are
-- snapshotted and pinned before the first write; every write is guarded and
-- read back; combat or a failed read-back stops and keeps the pin.
-- Chat on Apply is additive: an existing window only gains message groups;
-- a missing custom tab is created with exactly the saved groups. Restore is
-- exact per window, and keeps tabs an apply created (as a load's created
-- macros are kept): closing a tab loses its channels and position.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local UISetup = {}
ASS.UISetup = UISetup

local KNOWN = { layout = true, bars = true, cvars = true, chat = true, meter = true }

-- Enum.EditModeLayoutType.
local PRESET, ACCOUNT, CHARACTER = 0, 1, 2

-- The CVars a UI setup may write (#16), each with its value domain. Checked
-- again at plan time with GetCVarInfo (secure, read-only, locked: skipped).
-- Not here: enableMouseoverCast, which GetCVarInfo reports as protected
-- (measured on the beta, 2026-10-22): it stays a manual setting.
local CVARS = {
    damageMeterEnabled = "bool",
    damageMeterResetOnNewInstance = "bool",
    raidFramesDisplayClassColor = "bool",
    raidFramesDisplayPowerBars = "bool",
    raidFramesHealthBarColorBG = "color",
}
UISetup.CVARS = CVARS
local DOMAIN = {
    bool = function(v) return v == "0" or v == "1" end,
    color = function(v) return #v == 8 and v:match("^%x+$") ~= nil end,
}

local CVAR_LABEL = {
    damageMeterEnabled = "Damage meter",
    damageMeterResetOnNewInstance = "Damage meter: reset on a new instance",
    raidFramesDisplayClassColor = "Raid frames: class colours",
    raidFramesDisplayPowerBars = "Raid frames: power bars",
    raidFramesHealthBarColorBG = "Raid frames: health bar background",
}
local BAR_LABEL = { [2] = "Action Bar 2", [3] = "Action Bar 3", [4] = "Action Bar 4", [5] = "Action Bar 5",
                    [6] = "Action Bar 6", [7] = "Action Bar 7", [8] = "Action Bar 8" }

local function Copy(v) return ASS.Catalog.Copy(v) end

-- A deterministic text form of a plain table (sorted keys): the fingerprint.
local function Serialize(v)
    local t = type(v)
    if t ~= "table" then return t:sub(1, 1) .. tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. Serialize(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
UISetup.Serialize = Serialize

local function Sorted(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function Set(list)
    local s = {}
    for _, v in ipairs(list or {}) do s[v] = true end
    return s
end

------------------------------------------------------------
-- Edit Mode layouts: { active = index, list = { { index, type, name } } }.
-- Indices count the presets first, as GetLayouts().activeLayout does
-- (measured 70245); the saved layouts start after them (3 presets, 70338).
------------------------------------------------------------

local function Layouts()
    if not (C_EditMode and C_EditMode.GetLayouts) then return nil, "Edit Mode isn't available" end
    local ok, info = pcall(C_EditMode.GetLayouts)
    if not ok or type(info) ~= "table" or type(info.layouts) ~= "table" or type(info.activeLayout) ~= "number" then
        return nil, "couldn't read the Edit Mode layouts"
    end
    local okP, presets = pcall(function() return EditModePresetLayoutManager:GetCopyOfPresetLayouts() end)
    if not okP or type(presets) ~= "table" then return nil, "couldn't read the preset layouts" end
    local ls = { active = info.activeLayout, list = {} }
    for i, p in ipairs(presets) do
        ls.list[#ls.list + 1] = { index = i, type = PRESET, name = type(p) == "table" and tostring(p.layoutName) or "?" }
    end
    for i, l in ipairs(info.layouts) do
        if type(l) ~= "table" or type(l.layoutName) ~= "string" or type(l.layoutType) ~= "number" then
            return nil, "couldn't read the Edit Mode layouts"
        end
        ls.list[#ls.list + 1] = { index = #presets + i, type = l.layoutType, name = l.layoutName }
    end
    return ls
end

local function ActiveLayout(ls)
    for _, l in ipairs(ls.list) do
        if l.index == ls.active then return l end
    end
end

-- One layout or nil plus why: a preset by its index, any other by type and name.
local function FindLayout(ls, want)
    if want.type == PRESET then
        local l = ls.list[want.index]
        if l and l.type == PRESET then return l end
        return nil, "the preset layout isn't there"
    end
    local found
    for _, l in ipairs(ls.list) do
        if l.type == want.type and l.name == want.name then
            if found then return nil, ('two layouts are named "%s"'):format(tostring(want.name)) end
            found = l
        end
    end
    if not found then return nil, ('no layout named "%s" on this account'):format(tostring(want.name)) end
    return found
end

local function SameLayout(a, b)
    if not (a and b) or a.type ~= b.type then return false end
    if a.type == PRESET then return a.index == b.index end
    return a.name == b.name
end

local function LayoutText(l)
    if not l then return "?" end
    return l.type == PRESET and (tostring(l.name or ("preset " .. tostring(l.index))) .. " (a preset)")
        or ('"' .. tostring(l.name) .. '"')
end

-- The layout as a catalog part: Account and preset layouts only.
local function LayoutPart(l)
    if l.type == PRESET then return { type = PRESET, index = l.index, name = l.name } end
    if l.type == ACCOUNT then return { type = ACCOUNT, name = l.name } end
end

------------------------------------------------------------
-- Action bars 2-8 (SetActionBarToggles, measured 70338: seven booleans)
------------------------------------------------------------

local function ReadBars()
    if not GetActionBarToggles then return nil end
    local r = { pcall(GetActionBarToggles) }
    if not r[1] then return nil end
    -- r[2..8] are bars 2-8; anything but seven booleans is unreadable, never
    -- taken as "hidden".
    local bars = {}
    for i = 2, 8 do
        if type(r[i]) ~= "boolean" then return nil end
        bars[i] = r[i]
    end
    return bars
end

------------------------------------------------------------
-- CVars
------------------------------------------------------------

local function ReadCVar(name)
    if not (C_CVar and C_CVar.GetCVar) then return nil end
    local ok, v = pcall(C_CVar.GetCVar, name)
    if ok and type(v) == "string" then return v end
end

-- Why this CVar can't be written, or nil plus whether it is account-wide.
local function CVarBlocked(name, value)
    local domain = CVARS[name]
    if not domain then return "not supported on this build" end
    if type(value) ~= "string" or not DOMAIN[domain](value) then return "the saved value isn't valid" end
    if not (C_CVar and C_CVar.GetCVarInfo) then return "unknown to this client" end
    local ok, v, _, account, _, locked, secure, readOnly = pcall(C_CVar.GetCVarInfo, name)
    if not ok or v == nil then return "unknown to this client" end
    if secure or readOnly or locked then return "protected by the client" end
    return nil, account and true or false
end

------------------------------------------------------------
-- Chat windows. Window 1 is the primary window, matched by role (its name is
-- the player's, or localised). A custom tab is an active, unreserved window
-- other than 1, matched by name; two of one name are never guessed between.
------------------------------------------------------------

local function ChatFrameAt(i) return _G["ChatFrame" .. i] end

local function ReadGroups(i)
    local r = { pcall(GetChatWindowMessages, i) }
    if not r[1] then return nil end
    local groups = {}
    for j = 2, #r do
        if type(r[j]) ~= "string" then return nil end
        groups[#groups + 1] = r[j]
    end
    return groups
end

local function Known(g) return type(ChatTypeGroup) == "table" and ChatTypeGroup[g] ~= nil end

-- { n, [i] = { slot, name, active, reserved, docked, uninteractable, groups } } or nil.
local function ReadChat()
    local n = NUM_CHAT_WINDOWS
    if type(n) ~= "number" or not GetChatWindowInfo or not GetChatWindowMessages
        or not FCF_IsChatWindowIndexActive then
        return nil
    end
    local w = { n = n }
    for i = 1, n do
        local ok, name, _, _, _, _, _, _, _, docked, uninteractable = pcall(GetChatWindowInfo, i)
        if not ok then return nil end
        local okA, active = pcall(FCF_IsChatWindowIndexActive, i)
        if not okA then return nil end
        local reserved = false
        if FCF_IsChatWindowIndexReserved then
            local okR, r = pcall(FCF_IsChatWindowIndexReserved, i)
            if not okR then return nil end
            reserved = r and true or false
        end
        local frame = ChatFrameAt(i)
        local groups = ReadGroups(i)
        if not groups then return nil end
        w[i] = { slot = i, name = type(name) == "string" and name or "", active = active and true or false,
                 reserved = reserved, docked = (docked and true) or (frame and frame.isDocked and true) or false,
                 uninteractable = (uninteractable and true) or (frame and frame.isUninteractable and true) or false,
                 groups = groups }
    end
    return w
end

local function IsTab(w, i) return i ~= 1 and i ~= 2 and w[i].active and not w[i].reserved and w[i].name ~= "" end

-- The one active custom tab with this name: its slot, or nil plus why.
local function FindTab(w, name)
    local found
    for i = 1, w.n do
        if IsTab(w, i) and w[i].name == name then
            if found then return nil, ('two chat tabs are named "%s"'):format(name) end
            found = i
        end
    end
    return found
end

local function FreeSlots(w)
    local free = 0
    for i = 3, w.n do
        if not w[i].active and not w[i].reserved then free = free + 1 end
    end
    return free
end

------------------------------------------------------------
-- The damage meter (Blizzard_DamageMeter, Mainline source; UNMEASURED on
-- Forever: the PR's in-game check). Only Blizzard's own DamageMeter methods
-- write; DamageMeterPerCharacterSettings is Blizzard's and never touched here
-- (measured, #29). Window 1 is the primary: it can't be hidden, moved or
-- locked, and its place is the Edit Mode layout's.
------------------------------------------------------------

local DM_METHODS = { "GetSessionWindow", "GetWindowDataList", "GetMaxSessionWindowCount", "ShowNewSecondarySessionWindow",
                     "SetSessionWindowDamageMeterType", "SetSessionWindowSessionID", "SetSessionWindowLocked",
                     "HideSessionWindow" }
local DM_WINDOW = { "GetDamageMeterType", "GetSessionType", "GetSessionID", "IsLocked", "IsShown" }
local UNSUPPORTED = "not supported on this build"

-- Blizzard's DamageMeter frame, or nil plus why (a visible skip).
local function MeterAPI()
    local dm = DamageMeter
    if type(dm) ~= "table" then return nil, UNSUPPORTED end
    for _, k in ipairs(DM_METHODS) do
        if type(dm[k]) ~= "function" then return nil, UNSUPPORTED end
    end
    local t, s = Enum and Enum.DamageMeterType, Enum and Enum.DamageMeterSessionType
    if type(t) ~= "table" or type(s) ~= "table" or s.Overall ~= 0 or s.Current ~= 1 then return nil, UNSUPPORTED end
    return dm
end

local function KnownMeterType(v)
    if type(v) ~= "number" then return false end
    for _, x in pairs(Enum.DamageMeterType) do if x == v then return true end end
    return false
end
local function KnownSession(v) return v == 0 or v == 1 end

local METER_TYPE_LABEL = { [0] = "Damage Done", [1] = "DPS", [2] = "Healing Done", [3] = "HPS", [4] = "Absorbs",
                           [5] = "Interrupts", [6] = "Dispels", [7] = "Damage Taken", [8] = "Avoidable Damage Taken",
                           [9] = "Deaths", [10] = "Enemy Damage Taken" }
local function MeterTypeText(v) return METER_TYPE_LABEL[v] or ("meter type " .. tostring(v)) end
local function SessionText(v)
    if v == 1 then return "Current Segment" elseif v == 0 then return "Overall" end
    if v == nil then return "a single fight" end
    return "segment " .. tostring(v)
end

local function Plain(v)
    if issecretvalue then
        local ok, secret = pcall(issecretvalue, v)
        if not ok or secret then return false end
    end
    return type(v) == "number" and v == v and v > -100000 and v < 100000
end
local function Round(v) return math.floor(v * 10 + 0.5) / 10 end

-- A secondary window's rect, or nil: one anchor, to UIParent or the screen,
-- plain numbers. Recorded only, never applied.
local function ReadRect(f)
    local ok, n = pcall(f.GetNumPoints, f)
    if not ok or n ~= 1 then return nil end
    local okP, point, rel, relPoint, x, y = pcall(f.GetPoint, f, 1)
    if not okP or type(point) ~= "string" or type(relPoint) ~= "string" then return nil end
    if rel ~= nil and rel ~= UIParent then return nil end
    local okW, w = pcall(f.GetWidth, f)
    local okH, h = pcall(f.GetHeight, f)
    if not (okW and okH and Plain(x) and Plain(y) and Plain(w) and Plain(h)) or w <= 0 or h <= 0 then return nil end
    if not (point:match("^%u+$") and relPoint:match("^%u+$")) or #point > 16 or #relPoint > 16 then return nil end
    return { point = point, relativePoint = relPoint, x = Round(x), y = Round(y), width = Round(w), height = Round(h) }
end

-- One window: { index, shown, data, type, session, sessionID, locked, rect, frame }
-- or nil when unreadable (never taken as "absent"). `data`: Blizzard holds
-- settings for this index (a frame, or remembered window data a "Show new
-- window" reopens with). Values come from the frame, else, read only, from
-- the remembered data. No frame = not shown.
local function ReadMeterWindow(dm, i, list)
    local ok, f = pcall(dm.GetSessionWindow, dm, i)
    if not ok then return nil end
    if f == nil then
        local d = list[i]
        if d == nil then return { index = i, shown = false, data = false } end
        if type(d) ~= "table" or type(d.damageMeterType) ~= "number"
            or (d.sessionType ~= nil and type(d.sessionType) ~= "number") then
            return nil
        end
        return { index = i, shown = false, data = true, type = d.damageMeterType, session = d.sessionType,
                 locked = d.locked and true or false }
    end
    if type(f) ~= "table" then return nil end
    for _, k in ipairs(DM_WINDOW) do if type(f[k]) ~= "function" then return nil end end
    local okS, shown = pcall(f.IsShown, f)
    local okT, t = pcall(f.GetDamageMeterType, f)
    local okY, s = pcall(f.GetSessionType, f)
    local okI, id = pcall(f.GetSessionID, f)
    local okL, locked = pcall(f.IsLocked, f)
    if not (okS and okT and okY and okI and okL) or type(t) ~= "number" then return nil end
    if s ~= nil and type(s) ~= "number" then return nil end
    -- Blizzard's IsLocked is nil on a window never locked: false here.
    return { index = i, frame = f, shown = shown and true or false, data = true, type = t, session = s,
             sessionID = id, locked = locked and true or false, rect = i > 1 and ReadRect(f) or nil }
end

-- { max, [i] = window } for i = 1..max, or nil plus why.
local function ReadMeter()
    local dm, why = MeterAPI()
    if not dm then return nil, why end
    local ok, max = pcall(dm.GetMaxSessionWindowCount, dm)
    local okL, list = pcall(dm.GetWindowDataList, dm)
    if not ok or type(max) ~= "number" or max < 1 or not okL or type(list) ~= "table" then
        return nil, "couldn't read the damage meter"
    end
    local m = { max = math.min(max, 3) }
    for i = 1, m.max do
        m[i] = ReadMeterWindow(dm, i, list)
        if not m[i] then return nil, "couldn't read the damage meter" end
    end
    if not m[1].shown then return nil, "couldn't read the damage meter" end
    return m, nil, dm
end

-- What a window shows, as compared and fingerprinted: its type, its segment
-- (nil with a fight id: a single fight), its lock.
local function MeterValues(w)
    return { type = w.type, session = w.session, sessionID = w.sessionID, locked = w.locked }
end
local function SameValues(a, b)
    return a.type == b.type and a.session == b.session and a.sessionID == b.sessionID and a.locked == b.locked
end

-- The whole meter as the plan saw it (in the fingerprint): any change to a
-- window's state, shown or remembered, makes the preview stale.
local function MeterSeen(m)
    local s = {}
    for i = 1, m.max do
        local w = m[i]
        s[i] = { shown = w.shown, data = w.data, type = w.type, session = w.session, sessionID = w.sessionID,
                 locked = w.locked }
    end
    return s
end

-- Where `n` "Show new window" calls would put windows, by Blizzard's own
-- rule (DamageMeter.lua ShowNewSecondarySessionWindow): the lowest hidden
-- index Blizzard holds data for (reopened as it was), else the lowest index
-- it holds nothing for (new: Damage Done, Overall); none once max are shown.
-- Returns { { index, reopen } }, possibly fewer than n.
local function PredictOpens(m, n)
    local out, taken, shown = {}, {}, 0
    for i = 1, m.max do if m[i].shown then shown = shown + 1 end end
    for _ = 1, n do
        if shown >= m.max then break end
        local pick, reopen
        for i = 2, m.max do
            if not pick and not taken[i] and not m[i].shown and m[i].data then pick, reopen = i, true end
        end
        for i = 2, m.max do
            if not pick and not taken[i] and not m[i].data then pick, reopen = i, false end
        end
        if not pick then break end
        taken[pick], shown = true, shown + 1
        out[#out + 1] = { index = pick, reopen = reopen }
    end
    return out
end

-- The shown secondaries, in index order.
local function ShownSecondaries(m)
    local out = {}
    for i = 2, m.max do if m[i].shown then out[#out + 1] = i end end
    return out
end

------------------------------------------------------------
-- Blocked and capture
------------------------------------------------------------

local function EditModeActive()
    local f = EditModeManagerFrame
    if not f then return false end
    if f.IsEditModeActive then
        local ok, active = pcall(f.IsEditModeActive, f)
        if ok then return active and true or false end
    end
    return f.IsShown and f:IsShown() and true or false
end

-- What blocks a UI setup write right now, or nil.
function UISetup.Blocked()
    if ASS.disabled then return "AltStableSync is disabled: " .. tostring(ASS.disabled) end
    if InCombatLockdown() then return "Paused in combat. Try again when combat ends." end
    local ready, why = ASS.Ready.IsReady()
    if not ready then return "Waiting for character data (" .. tostring(why) .. ")." end
    if EditModeActive() then return "Close Edit Mode first." end
    if ChatConfigFrame and ChatConfigFrame.IsShown and ChatConfigFrame:IsShown() then
        return "Close the chat settings first."
    end
    return nil
end

-- This character's UI as an entry's modules, for Save As and Save. Returns
-- modules, notes (lines for the preview: what couldn't be captured, and why).
function UISetup.Capture()
    local m, notes = {}, {}
    local ls, why = Layouts()
    if ls then
        local a = ActiveLayout(ls)
        if not a then
            notes[#notes + 1] = "Layout: couldn't tell which layout is active; not saved."
        elseif a.type == CHARACTER then
            notes[#notes + 1] = ('Layout: "%s" is a Character layout, which only this character has; not saved.')
                :format(a.name)
        else
            m.layout = LayoutPart(a)
        end
    else
        notes[#notes + 1] = "Layout: " .. tostring(why) .. "; not saved."
    end
    local bars = ReadBars()
    if bars then m.bars = bars else notes[#notes + 1] = "Action bars: couldn't read which are shown; not saved." end
    local cv = {}
    for _, name in ipairs(Sorted(CVARS)) do
        local v = ReadCVar(name)
        if v then cv[name] = v else notes[#notes + 1] = ("%s: couldn't read; not saved."):format(CVAR_LABEL[name]) end
    end
    if next(cv) then m.cvars = cv end
    local w = ReadChat()
    if w then
        local chat = { primary = Copy(w[1].groups), tabs = {} }
        local count = {}
        for i = 1, w.n do if IsTab(w, i) then count[w[i].name] = (count[w[i].name] or 0) + 1 end end
        for i = 1, w.n do
            if IsTab(w, i) then
                if count[w[i].name] > 1 then
                    if count[w[i].name] ~= -1 then
                        notes[#notes + 1] = ('Chat: two tabs are named "%s"; neither is saved.'):format(w[i].name)
                        count[w[i].name] = -1
                    end
                elseif count[w[i].name] == 1 and #w[i].groups == 0 then
                    -- Channels only, or nothing (an addon's console tab): a
                    -- setup carries message types, so it would arrive empty.
                    notes[#notes + 1] = ('Chat: tab "%s" receives no message types; not saved.'):format(w[i].name)
                elseif count[w[i].name] == 1 and #chat.tabs < 9 then
                    chat.tabs[#chat.tabs + 1] = { name = w[i].name, groups = Copy(w[i].groups) }
                end
            end
        end
        if #chat.tabs == 0 then chat.tabs = nil end
        m.chat = chat
    else
        notes[#notes + 1] = "Chat: couldn't read the chat windows; not saved."
    end
    local dm, whyM = ReadMeter()
    if dm then
        local wins = {}
        local live = { 1 }
        for _, i in ipairs(ShownSecondaries(dm)) do live[#live + 1] = i end
        for _, i in ipairs(live) do
            local w = dm[i]
            local x = { type = w.type }
            if KnownSession(w.session) then
                x.session = w.session
            else
                -- A single fight (or an expired one): tied to this
                -- character's recent fights, so never saved.
                notes[#notes + 1] = ("Damage meter window %d shows a single fight; its segment isn't saved."):format(i)
            end
            if i > 1 then
                x.locked = w.locked
                x.rect = w.rect
                if not w.rect then
                    notes[#notes + 1] = ("Damage meter window %d: position couldn't be read; not saved."):format(i)
                end
            end
            wins[#wins + 1] = x
        end
        m.meter = { windows = wins }
    else
        notes[#notes + 1] = "Damage meter: " .. tostring(whyM) .. "; not saved."
    end
    return m, notes
end

------------------------------------------------------------
-- Plan: apply an entry
--
-- plan = { kind = "apply", id, version, name,
--          layout = { want, from } | nil, bars = { from, to } | nil,
--          cvars = { { name, from, to, account } }, chat = { add = { { slot, name, groups } },
--          create = { { name, groups } } }, skips = { { part, what, reason } },
--          unsupported = { key, ... }, noop, blocked, fingerprint }
------------------------------------------------------------

local function Finish(plan)
    local f = Copy(plan)
    f.fingerprint = nil
    plan.fingerprint = Serialize(f)
    return plan
end

-- `key`: the CVar's name, for Save to keep what the apply skipped.
local function Skip(plan, part, what, reason, key)
    plan.skips[#plan.skips + 1] = { part = part, what = what, reason = reason, key = key }
end

local function Empty(plan)
    return not plan.layout and not plan.bars and #plan.cvars == 0 and #plan.chat.add == 0 and #plan.chat.create == 0
        and #plan.meter.opens == 0 and #plan.meter.sets == 0 and #plan.meter.hides == 0
end

local function NewMeterPlan() return { opens = {}, sets = {}, hides = {} } end

-- The damage meter part of an apply plan. Entry window 1 is the primary;
-- entry window k >= 2 is the (k-1)th secondary of the shown set AFTER the
-- opens, in index order (an open may land below a shown window). Apply never
-- hides a window or touches one beyond the entry's count; an unset field
-- (no segment, no lock) is never written.
local function PlanMeter(plan, want)
    local m, why = ReadMeter()
    if not m then
        Skip(plan, "meter", "Damage meter", why, "*")
        return
    end
    local wins = want.windows
    plan.meter.seen = MeterSeen(m)
    local final = ShownSecondaries(m)
    local opens = PredictOpens(m, math.max(0, (#wins - 1) - #final))
    local opening = {}
    for _, o in ipairs(opens) do
        final[#final + 1] = o.index
        opening[o.index] = o
    end
    table.sort(final)
    for k, w in ipairs(wins) do
        local i = k == 1 and 1 or final[k - 1]
        if not i then
            Skip(plan, "meter", ("Damage meter: the setup's window %d"):format(k),
                 "no free damage meter window (three are shown)", k .. ":window")
        else
            local label = ("Damage meter window %d"):format(i)
            local o = opening[i]
            local cur = m[i]
            local op = { index = i }
            if not KnownMeterType(w.type) then
                Skip(plan, "meter", label .. ": " .. MeterTypeText(w.type), "not a meter type on this client", k .. ":type")
            elseif o or cur.type ~= w.type then
                op.type = w.type
            end
            if w.session ~= nil then
                if not KnownSession(w.session) then
                    Skip(plan, "meter", label .. ": " .. SessionText(w.session), "not a segment on this client", k .. ":session")
                elseif o or cur.session ~= w.session or cur.sessionID ~= nil then
                    op.session = w.session
                end
            end
            if k > 1 and w.locked ~= nil and (o or cur.locked ~= w.locked) then op.locked = w.locked end
            if o then
                op.open = true
                plan.meter.sets[#plan.meter.sets + 1] = op
            elseif op.type ~= nil or op.session ~= nil or op.locked ~= nil then
                op.from = MeterValues(cur)
                plan.meter.sets[#plan.meter.sets + 1] = op
            end
        end
    end
    -- In the order Blizzard picks them: Execute checks each lands as predicted.
    for _, o in ipairs(opens) do plan.meter.opens[#plan.meter.opens + 1] = { index = o.index, reopen = o.reopen } end
    table.sort(plan.meter.sets, function(a, b) return a.index < b.index end)
end

function UISetup.Plan(entry)
    local plan = { kind = "apply", cvars = {}, chat = { add = {}, create = {} }, meter = NewMeterPlan(), skips = {},
                   unsupported = {} }
    if type(entry) ~= "table" or entry.kind ~= "ui" or entry.deleted or type(entry.modules) ~= "table" then
        plan.blocked = "Not a UI setup."
        return Finish(plan)
    end
    plan.id, plan.version, plan.name = entry.id, entry.version, entry.name
    plan.blocked = UISetup.Blocked()
    if plan.blocked then return Finish(plan) end
    local m = entry.modules
    for _, k in ipairs(Sorted(m)) do
        if not KNOWN[k] then plan.unsupported[#plan.unsupported + 1] = tostring(k) end
    end

    if m.layout then
        local ls, why = Layouts()
        if not ls then
            Skip(plan, "layout", LayoutText(m.layout), why)
        else
            local cur = ActiveLayout(ls)
            local target, whyNot = FindLayout(ls, m.layout)
            if not cur then
                Skip(plan, "layout", LayoutText(m.layout), "couldn't tell which layout is active")
            elseif not target then
                Skip(plan, "layout", LayoutText(m.layout), whyNot)
            elseif not SameLayout(cur, target) then
                plan.layout = { want = { type = target.type, index = target.index, name = target.name },
                                from = { type = cur.type, index = cur.index, name = cur.name } }
            end
        end
    end

    if m.bars then
        local cur = ReadBars()
        if not cur then
            Skip(plan, "bars", "Action bars", "couldn't read which are shown")
        else
            local differs = false
            for i = 2, 8 do if cur[i] ~= m.bars[i] then differs = true end end
            if differs then plan.bars = { from = cur, to = Copy(m.bars) } end
        end
    end

    for _, name in ipairs(Sorted(m.cvars)) do
        local want = m.cvars[name]
        local why, account = CVarBlocked(name, want)
        local cur = not why and ReadCVar(name)
        if why then
            Skip(plan, "cvars", CVAR_LABEL[name] or name, why, name)
        elseif not cur then
            Skip(plan, "cvars", CVAR_LABEL[name] or name, "couldn't read it", name)
        elseif cur ~= want then
            plan.cvars[#plan.cvars + 1] = { name = name, from = cur, to = want, account = account }
        end
    end

    local chat = m.chat
    if chat then
        local w = ReadChat()
        if not w then
            Skip(plan, "chat", "Chat", "couldn't read the chat windows")
        else
            local function missing(have, want, label)
                local has, add = Set(have), {}
                for _, g in ipairs(want or {}) do
                    if not has[g] then
                        if Known(g) then add[#add + 1] = g
                        else Skip(plan, "chat", label .. ": " .. g, "not a chat type on this client") end
                    end
                end
                return add
            end
            if chat.primary then
                local add = missing(w[1].groups, chat.primary, "Main chat window")
                if #add > 0 then plan.chat.add[#plan.chat.add + 1] = { slot = 1, name = w[1].name, groups = add, from = Copy(w[1].groups) } end
            end
            local creates = {}
            for _, t in ipairs(chat.tabs or {}) do
                local slot, why = FindTab(w, t.name)
                if why then
                    Skip(plan, "chat", ('Tab "%s"'):format(t.name), why)
                elseif slot then
                    local add = missing(w[slot].groups, t.groups, ('Tab "%s"'):format(t.name))
                    if #add > 0 then plan.chat.add[#plan.chat.add + 1] = { slot = slot, name = t.name, groups = add, from = Copy(w[slot].groups) } end
                else
                    local groups = {}
                    for _, g in ipairs(t.groups) do
                        if Known(g) then groups[#groups + 1] = g
                        else Skip(plan, "chat", ('Tab "%s": %s'):format(t.name, g), "not a chat type on this client") end
                    end
                    if #groups == 0 then
                        -- A setup saved before Save As left such tabs out
                        -- (beta, 2026-10-22): an empty tab is never created.
                        Skip(plan, "chat", ('Tab "%s"'):format(t.name), "receives no message types; not created")
                    else
                        creates[#creates + 1] = { name = t.name, groups = groups }
                    end
                end
            end
            if #creates > 0 then
                local clickThrough = false
                for i = 1, w.n do
                    if w[i].docked and w[i].uninteractable then clickThrough = true end
                end
                local free = FreeSlots(w)
                for _, c in ipairs(creates) do
                    if clickThrough then
                        Skip(plan, "chat", ('Tab "%s"'):format(c.name),
                             "your chat tabs are set to click-through; create the tab by hand")
                    elseif free <= 0 then
                        Skip(plan, "chat", ('Tab "%s"'):format(c.name), "no free chat window")
                    else
                        free = free - 1
                        plan.chat.create[#plan.chat.create + 1] = c
                    end
                end
            end
        end
    end

    if type(m.meter) == "table" then PlanMeter(plan, m.meter) end

    plan.noop = Empty(plan) or nil
    return Finish(plan)
end

------------------------------------------------------------
-- Writes. Each returns true, or nil plus why; each reads back.
------------------------------------------------------------

local function Guard()
    if InCombatLockdown() then return "combat" end
    if EditModeActive() then return "Edit Mode opened" end
end

local function WriteLayout(want)
    local ls = Layouts()
    if not ls then return nil, "layouts unreadable" end
    local target = FindLayout(ls, want)
    if not target then return nil, "layout gone" end
    local ok = pcall(C_EditMode.SetActiveLayout, target.index)
    if not ok then return nil, "SetActiveLayout failed" end
    local after = Layouts()
    local a = after and ActiveLayout(after)
    if not SameLayout(a, want) then return nil, "layout read-back" end
    return true
end

local function WriteBars(to)
    local ok = pcall(SetActionBarToggles, to[2], to[3], to[4], to[5], to[6], to[7], to[8])
    if not ok then return nil, "SetActionBarToggles failed" end
    local now = ReadBars()
    if not now then return nil, "bars read-back" end
    for i = 2, 8 do if now[i] ~= to[i] then return nil, "bars read-back" end end
    return true
end

local function WriteCVar(name, value)
    local ok, set = pcall(C_CVar.SetCVar, name, value)
    if not ok or set == false then return nil, "SetCVar failed" end
    if ReadCVar(name) ~= value then return nil, name .. " read-back" end
    return true
end

local function HasGroup(slot, g)
    local now = ReadGroups(slot)
    if not now then return nil end
    return Set(now)[g] == true
end

local function SameSet(a, b)
    local x, y = Set(a), Set(b)
    for g in pairs(x) do if not y[g] then return false end end
    for g in pairs(y) do if not x[g] then return false end end
    return true
end

-- Add, then remove, one group at a time, each read back; a failed read
-- stops before any write (nil is never taken as "absent"). `from`: the
-- groups the plan saw, which the window must still hold before the first
-- write. After the writes the whole window is read again: it must be
-- exactly `exact` (a restore, a new tab), or else hold everything it held
-- plus `add` (an additive apply).
local function SetGroups(slot, add, remove, from, exact)
    local frame = ChatFrameAt(slot)
    if not frame then return nil, "chat window gone" end
    local before = ReadGroups(slot)
    if not before then return nil, "chat window unreadable" end
    if from and not SameSet(before, from) then return nil, "chat window changed since the preview" end
    for _, g in ipairs(add or {}) do
        local has = HasGroup(slot, g)
        if has == nil then return nil, "chat window unreadable" end
        if not has then
            local ok = pcall(ChatFrame_AddMessageGroup, frame, g)
            if not ok or HasGroup(slot, g) ~= true then return nil, "chat " .. g .. " read-back" end
        end
    end
    for _, g in ipairs(remove or {}) do
        local has = HasGroup(slot, g)
        if has == nil then return nil, "chat window unreadable" end
        if has then
            local ok = pcall(ChatFrame_RemoveMessageGroup, frame, g)
            if not ok or HasGroup(slot, g) ~= false then return nil, "chat " .. g .. " read-back" end
        end
    end
    local after = ReadGroups(slot)
    if not after then return nil, "chat window unreadable" end
    if exact then
        if not SameSet(after, exact) then return nil, "chat window doesn't match after the write" end
    else
        local has = Set(after)
        for _, g in ipairs(before) do if not has[g] then return nil, "chat window lost " .. g end end
        for _, g in ipairs(add or {}) do if not has[g] then return nil, "chat " .. g .. " read-back" end end
    end
    return true
end

-- The window must still be the one planned: same slot, same name.
local function SameWindow(slot, name)
    local ok, now = pcall(GetChatWindowInfo, slot)
    return ok and now == name
end

-- A new tab, given exactly `groups`. Returns its slot, or nil plus why.
local function CreateTab(name, groups)
    -- The second argument leaves out the default groups and channels a new
    -- window otherwise gets (Mainline; checked in game before release).
    local ok = pcall(FCF_OpenNewWindow, name, true)
    if not ok then return nil, "couldn't create the chat tab" end
    -- Found again by name rather than by the return value: exactly one
    -- active tab of that name, in a slot past the reserved ones.
    local w = ReadChat()
    local slot = w and FindTab(w, name)
    if type(slot) ~= "number" or slot <= 2 then return nil, "the new chat tab isn't the one asked for" end
    local have = ReadGroups(slot)
    if not have then return nil, "chat read-back" end
    local want, extra = Set(groups), {}
    for _, g in ipairs(have) do if not want[g] then extra[#extra + 1] = g end end
    local okG, why = SetGroups(slot, groups, extra, have, groups)
    if not okG then return nil, why end
    return slot
end

-- The damage meter. Every write goes through Blizzard's own DamageMeter
-- methods, is read back from the frame, and never touches
-- DamageMeterPerCharacterSettings (Blizzard's setters save it).

-- `snap.meter.opened`: the windows this apply opened, each with what the
-- apply last left in it (Restore hides one only while it still holds that).
local function RecordOpened(snap, w)
    local list = snap and snap.meter and snap.meter.opened
    if not list then return end
    local rec
    for _, r in ipairs(list) do if r.index == w.index then rec = r end end
    if not rec then
        rec = { index = w.index }
        list[#list + 1] = rec
    end
    rec.type, rec.session, rec.sessionID, rec.locked = w.type, w.session, w.sessionID, w.locked
end

local function MeterFieldIs(w, field, value)
    if field == "type" then return w.type == value end
    if field == "session" then return w.session == value and w.sessionID == nil end
    return w.locked == value
end

-- One field of shown window i, read back. Returns the window as it is now,
-- nil, and whether it wrote; or nil plus why. A field already as wanted
-- isn't written.
local function WriteMeterField(i, field, value)
    local m, _, dm = ReadMeter()
    local w = m and m[i]
    if not w or not w.shown or not w.frame then return nil, "couldn't read damage meter window " .. i end
    if MeterFieldIs(w, field, value) then return w, nil, false end
    local ok
    if field == "type" then
        ok = pcall(dm.SetSessionWindowDamageMeterType, dm, w.frame, value)
    elseif field == "session" then
        ok = pcall(dm.SetSessionWindowSessionID, dm, w.frame, value, nil)
    else
        ok = pcall(dm.SetSessionWindowLocked, dm, w.frame, value)
    end
    if not ok then return nil, "damage meter window " .. i .. " write failed" end
    local after = ReadMeter()
    local a = after and after[i]
    if not a or not a.shown or not MeterFieldIs(a, field, value) then
        return nil, "damage meter window " .. i .. " read-back"
    end
    return a, nil, true
end

-- "Show new window", which must open exactly window `expect`. Every window
-- that appeared is recorded as opened before the result is judged.
local function OpenMeterWindow(expect, snap)
    local m, why, dm = ReadMeter()
    if not m then return nil, why end
    if not m[expect] or m[expect].shown then return nil, "damage meter changed since the preview" end
    local ok = pcall(dm.ShowNewSecondarySessionWindow, dm)
    local after = ReadMeter()
    if not after then return nil, "couldn't read the damage meter" end
    local new = {}
    for i = 1, after.max do
        if after[i].shown and not (m[i] and m[i].shown) then
            new[#new + 1] = i
            RecordOpened(snap, after[i])
        end
    end
    if not ok then return nil, "couldn't open a damage meter window" end
    if #new ~= 1 or new[1] ~= expect or _G["DamageMeterSessionWindow" .. expect] ~= after[expect].frame then
        return nil, "the new damage meter window isn't the one planned"
    end
    return true
end

local function HideMeterWindow(i, from)
    local m, _, dm = ReadMeter()
    local w = m and m[i]
    if not w or not w.frame then return nil, "couldn't read damage meter window " .. i end
    if not w.shown or not SameValues(MeterValues(w), from) then return nil, "damage meter window changed" end
    local ok = pcall(dm.HideSessionWindow, dm, w.frame)
    if not ok then return nil, "couldn't hide damage meter window " .. i end
    local after = ReadMeter()
    if not after or after[i].shown then return nil, "damage meter window " .. i .. " read-back" end
    return true
end

------------------------------------------------------------
-- Snapshot (the backup) of what a plan touches
------------------------------------------------------------

local function Snapshot(plan, reason)
    local snap = { kind = "ui", reason = reason }
    if plan.layout then
        local ls = Layouts()
        local a = ls and ActiveLayout(ls)
        if not a then return nil end
        snap.layout = { type = a.type, name = a.name, index = a.type == PRESET and a.index or nil }
    end
    if plan.bars then
        snap.bars = ReadBars()
        if not snap.bars then return nil end
    end
    if #plan.cvars > 0 then
        snap.cvars = {}
        for _, op in ipairs(plan.cvars) do
            local v = ReadCVar(op.name)
            if not v then return nil end
            snap.cvars[op.name] = v
        end
    end
    if #plan.chat.add > 0 or #plan.chat.create > 0 then
        local w = ReadChat()
        if not w then return nil end
        snap.chat = { tabs = {}, creating = {} }
        for _, op in ipairs(plan.chat.add) do
            if op.slot == 1 then snap.chat.primary = { groups = Copy(w[1].groups) }
            else snap.chat.tabs[#snap.chat.tabs + 1] = { slot = op.slot, name = w[op.slot].name, groups = Copy(w[op.slot].groups) } end
        end
        for _, c in ipairs(plan.chat.create) do snap.chat.creating[#snap.chat.creating + 1] = c.name end
    end
    local mp = plan.meter
    if #mp.opens + #mp.sets + #mp.hides > 0 then
        -- Only the windows the plan touches (an open's too: a reopened
        -- window's remembered settings are put back before Restore hides it),
        -- as plain values; never the frame.
        local m = ReadMeter()
        if not m then return nil end
        local seen, windows = MeterSeen(m), {}
        for _, list in ipairs({ mp.opens, mp.sets, mp.hides }) do
            for _, op in ipairs(list) do windows[op.index] = seen[op.index] end
        end
        snap.meter = { windows = windows, opened = {} }
    end
    return snap
end

------------------------------------------------------------
-- Execute a plan (Apply's ops, or Restore's): fixed order layout, bars,
-- cvars, chat, damage meter. result = { changed, failed, at, created =
-- { names }, opened = { damage meter window numbers } }. `snap`: the backup
-- taken for this plan; the damage meter windows an apply opens are recorded
-- in it as they open.
------------------------------------------------------------

local function Execute(plan, snap)
    local result = { changed = 0, created = {}, opened = {} }
    local function stop(why, at)
        result.failed, result.at = why, at
        return result
    end
    local g = Guard()
    if plan.layout then
        if g then return stop(g, "layout") end
        local ok, why = WriteLayout(plan.layout.want)
        if not ok then return stop(why, "layout") end
        result.changed = result.changed + 1
    end
    if plan.bars then
        g = Guard()
        if g then return stop(g, "action bars") end
        local ok, why = WriteBars(plan.bars.to)
        if not ok then return stop(why, "action bars") end
        result.changed = result.changed + 1
        -- Written and read back, but shown only after a reload (measured on
        -- the beta, 2026-10-22): the report asks for one.
        result.reload = true
    end
    for _, op in ipairs(plan.cvars) do
        g = Guard()
        if g then return stop(g, op.name) end
        local ok, why = WriteCVar(op.name, op.to)
        if not ok then return stop(why, op.name) end
        result.changed = result.changed + 1
    end
    for _, op in ipairs(plan.chat.add) do
        g = Guard()
        if g then return stop(g, "chat") end
        if not SameWindow(op.slot, op.name) then return stop("chat window changed", "chat") end
        local ok, why = SetGroups(op.slot, op.groups, op.remove, op.from, op.exact)
        if not ok then return stop(why, "chat") end
        result.changed = result.changed + 1
    end
    for _, c in ipairs(plan.chat.create) do
        g = Guard()
        if g then return stop(g, "chat") end
        local slot, why = CreateTab(c.name, c.groups)
        if not slot then return stop(why, "chat") end
        result.created[#result.created + 1] = c.name
        result.changed = result.changed + 1
    end
    local mp = plan.meter
    if #mp.opens + #mp.sets + #mp.hides > 0 then
        g = Guard()
        if g then return stop(g, "damage meter") end
        local m, why = ReadMeter()
        if not m then return stop(why, "damage meter") end
        if Serialize(MeterSeen(m)) ~= Serialize(mp.seen) then return stop("damage meter changed since the preview", "damage meter") end
        for _, o in ipairs(mp.opens) do
            g = Guard()
            if g then return stop(g, "damage meter") end
            local ok, whyO = OpenMeterWindow(o.index, snap)
            if not ok then return stop(whyO, "damage meter") end
            result.opened[#result.opened + 1] = o.index
            result.changed = result.changed + 1
        end
        for _, op in ipairs(mp.sets) do
            if op.from then
                local now = ReadMeter()
                local w = now and now[op.index]
                if not w or not w.shown or not SameValues(MeterValues(w), op.from) then
                    return stop("damage meter window changed since the preview", "damage meter")
                end
            end
            for _, field in ipairs({ "type", "session", "locked" }) do
                if op[field] ~= nil then
                    g = Guard()
                    if g then return stop(g, "damage meter") end
                    local a, whyW, wrote = WriteMeterField(op.index, field, op[field])
                    if not a then return stop(whyW, "damage meter") end
                    if op.open then RecordOpened(snap, a) end
                    if wrote then result.changed = result.changed + 1 end
                end
            end
        end
        for _, h in ipairs(mp.hides) do
            g = Guard()
            if g then return stop(g, "damage meter") end
            local ok, whyH = HideMeterWindow(h.index, h.from)
            if not ok then return stop(whyH, "damage meter") end
            result.changed = result.changed + 1
        end
    end
    return result
end

------------------------------------------------------------
-- Apply
------------------------------------------------------------

local function Provenance() return ASS.Loadout.Provenance() end

-- What the apply skipped, by part, for Save to keep (docs/DESIGN.md).
local function Skipped(plan)
    local s = {}
    for _, k in ipairs(plan.skips) do
        if k.part == "layout" or k.part == "bars" then
            s[k.part] = k.reason
        elseif k.part == "cvars" and k.key then
            s.cvars = s.cvars or {}
            s.cvars[k.key] = k.reason
        elseif k.part == "meter" and k.key then
            -- "*": the whole part; "<k>:<field>": one window's field, or
            -- "<k>:window" for the whole window.
            s.meter = s.meter or {}
            if k.key == "*" then
                s.meter.all = k.reason
            else
                local n, field = k.key:match("^(%d+):(%a+)$")
                n = tonumber(n)
                if n then
                    s.meter[n] = s.meter[n] or {}
                    s.meter[n][field] = k.reason
                end
            end
        end
    end
    return s
end

local function Record(entry, complete, plan, result)
    ASS.char.loaded = ASS.char.loaded or {}
    ASS.char.loaded.ui = { id = entry.id, version = entry.version, baseline = Copy(entry.modules),
                           complete = complete or false, skipped = plan and Skipped(plan) or {}, result = result }
end

-- A confirmed apply that completed (or a no-op Done) answers the first-login
-- offer for good (#92): `onboarding.handled` is never cleared afterwards, by
-- a later stopped apply, a restore or a deleted setup. Save As doesn't set it.
local function Answered() ASS.char.onboarding = { handled = true } end

-- Apply the plan the player confirmed. `shown` is that plan; `abandon` is the
-- player's answer to "Abandon the incomplete load of X?".
function UISetup.Apply(entry, shown, abandon)
    local live = ASS.Catalog.Get(entry.id)
    if not live or live.deleted then return nil, "That UI setup was deleted since the preview." end
    local plan = UISetup.Plan(live)
    if plan.blocked then return nil, plan.blocked end
    if plan.fingerprint ~= shown.fingerprint then return nil, "Something changed since the preview: review it again." end
    local pinned = ASS.Backups.Operation()
    if pinned and not abandon then return nil, "incomplete" end
    local function abandonPinned()
        if pinned then ASS.Backups.Release(); ASS.char.interrupted = nil end
    end
    if plan.noop then
        abandonPinned()
        local result = { noop = true, changed = 0, created = {}, skips = plan.skips }
        Record(live, true, plan, result)
    Answered()
        return result
    end
    local snap = Snapshot(plan, "UI setup " .. tostring(live.name))
    if not snap then return nil, "Couldn't read the current setup for the backup; nothing was changed." end
    abandonPinned()
    -- The attempted entry is the save target from here on, with no usable
    -- comparison until the apply completes (docs/DESIGN.md "Preserve intent").
    Record(live, false, plan)
    local ok, err = ASS.Backups.Pin(snap, { kind = "ui", id = live.id, version = live.version,
                                            name = "UI setup " .. tostring(live.name) })
    if not ok then return nil, err end
    local result = Execute(plan, snap)
    result.skips = plan.skips
    if result.failed then
        ASS.char.interrupted = { id = live.id, version = live.version, why = result.failed, at = result.at }
        return result
    end
    ASS.char.interrupted = nil
    ASS.Backups.Release()
    Record(live, true, plan, result)
    Answered()
    return result
end

------------------------------------------------------------
-- Restore a UI backup exactly
------------------------------------------------------------

-- The damage meter, restored exactly. A window shown in the backup and now
-- gets its type, segment and lock back. A window that apply opened is first
-- put back to what Blizzard remembered for it (a reopened window), then
-- hidden, and only while it still holds what the apply left in it. Restore
-- never opens a window; a window shown now that the backup didn't list as
-- opened by the apply is kept and said.
local function PlanRestoreMeter(plan, sm, cant)
    local m, why = ReadMeter()
    if not m then
        cant("Damage meter", why)
        return
    end
    plan.meter.seen = MeterSeen(m)
    local opened = {}
    for _, r in ipairs(type(sm.opened) == "table" and sm.opened or {}) do
        if type(r) == "table" and type(r.index) == "number" then opened[r.index] = r end
    end
    local function note(s) plan.notes[#plan.notes + 1] = s end
    for i = 1, m.max do
        local was, now = sm.windows[i], m[i]
        local label = ("Damage meter window %d"):format(i)
        local o = opened[i]
        if type(was) == "table" and o and i > 1 and not was.data then
            -- Blizzard had nothing for this index: it made the window fresh
            -- (DamageMeter.lua GetDefaultWindowData). Put those values back so
            -- the next "Show new window" behaves as if the apply never ran.
            was = { shown = false, data = true, type = Enum.DamageMeterType.DamageDone,
                    session = Enum.DamageMeterSessionType.Overall, locked = false }
        end
        if type(was) ~= "table" then
            -- Not touched by the plan that took the backup: left alone.
        elseif o and i > 1 then
            local left = { type = o.type, session = o.session, sessionID = o.sessionID, locked = o.locked and true or false }
            if not now.shown then
                note(label .. " (opened by that apply) is hidden already; the game keeps its settings for the next new window.")
            elseif not SameValues(MeterValues(now), left) then
                note(label .. " (opened by that apply) changed since; kept. Hide it yourself if you don't want it.")
            else
                local op, after = { index = i, from = MeterValues(now) }, MeterValues(now)
                if was.data then
                    if KnownMeterType(was.type) and now.type ~= was.type then op.type, after.type = was.type, was.type end
                    if KnownSession(was.session) and (now.session ~= was.session or now.sessionID ~= nil) then
                        op.session, after.session, after.sessionID = was.session, was.session, nil
                    elseif not KnownSession(was.session) then
                        note(label .. ": its earlier segment was a single fight; not put back.")
                    end
                    local lock = was.locked and true or false
                    if now.locked ~= lock then op.locked, after.locked = lock, lock end
                    if op.type ~= nil or op.session ~= nil or op.locked ~= nil then
                        plan.meter.sets[#plan.meter.sets + 1] = op
                    end
                end
                plan.meter.hides[#plan.meter.hides + 1] = { index = i, from = after }
            end
        elseif was.shown and now.shown then
            local op = { index = i, from = MeterValues(now) }
            if not KnownMeterType(was.type) then
                cant(label, MeterTypeText(was.type) .. " is not a meter type on this client; left as is")
            elseif now.type ~= was.type then
                op.type = was.type
            end
            if not KnownSession(was.session) then
                if now.session ~= was.session or now.sessionID ~= was.sessionID then
                    cant(label, "showed a single fight; pick its segment yourself")
                end
            elseif now.session ~= was.session or now.sessionID ~= nil then
                op.session = was.session
            end
            local lock = was.locked and true or false
            if i > 1 and now.locked ~= lock then op.locked = lock end
            if op.type ~= nil or op.session ~= nil or op.locked ~= nil then
                plan.meter.sets[#plan.meter.sets + 1] = op
            end
        elseif was.shown and not now.shown then
            cant(label, "closed since the backup; left as is")
        elseif not was.shown and now.shown then
            note(label .. " was opened since the backup; kept. Hide it yourself if you don't want it.")
        end
    end
end

-- plan = { kind = "restore", which, layout, bars, cvars, chat = { add = {slot,name,groups,remove} },
--          kept = { names }, unavailable = { { what, reason } }, noop, blocked, fingerprint }
function UISetup.PlanRestore(which)
    local plan = { kind = "restore", which = which, cvars = {}, chat = { add = {}, create = {} }, meter = NewMeterPlan(),
                   skips = {}, unavailable = {}, kept = {}, notes = {} }
    local snap = ASS.Backups.Get(which)
    if not snap then plan.blocked = "No such backup." return Finish(plan) end
    if snap.kind ~= "ui" then plan.blocked = "Not a UI setup backup." return Finish(plan) end
    plan.blocked = UISetup.Blocked()
    if plan.blocked then return Finish(plan) end
    local function cant(what, reason) plan.unavailable[#plan.unavailable + 1] = { what = what, reason = reason } end

    if type(snap.layout) == "table" then
        local ls, why = Layouts()
        local cur = ls and ActiveLayout(ls)
        local target, whyNot
        if ls then target, whyNot = FindLayout(ls, snap.layout) end
        if not cur then
            cant("Layout " .. LayoutText(snap.layout), why or "couldn't tell which layout is active")
        elseif not target then
            cant("Layout " .. LayoutText(snap.layout), whyNot)
        elseif not SameLayout(cur, target) then
            plan.layout = { want = { type = target.type, index = target.index, name = target.name },
                            from = { type = cur.type, index = cur.index, name = cur.name } }
        end
    end

    if type(snap.bars) == "table" then
        local cur = ReadBars()
        if not cur then
            cant("Action bars", "couldn't read which are shown")
        else
            local differs = false
            for i = 2, 8 do if cur[i] ~= snap.bars[i] then differs = true end end
            if differs then plan.bars = { from = cur, to = Copy(snap.bars) } end
        end
    end

    for _, name in ipairs(Sorted(snap.cvars)) do
        local want = snap.cvars[name]
        local why, account = CVarBlocked(name, want)
        local cur = not why and ReadCVar(name)
        if why then
            cant(CVAR_LABEL[name] or name, why)
        elseif not cur then
            cant(CVAR_LABEL[name] or name, "couldn't read it")
        elseif cur ~= want then
            plan.cvars[#plan.cvars + 1] = { name = name, from = cur, to = want, account = account }
        end
    end

    local chat = snap.chat
    if type(chat) == "table" then
        local w = ReadChat()
        if not w then
            cant("Chat", "couldn't read the chat windows")
        else
            local function restore(slot, name, groups, label)
                local now = w[slot]
                if not now or (slot ~= 1 and now.name ~= name) then
                    cant(label, "changed since the backup, left as is")
                    return
                end
                local want, has = Set(groups), Set(now.groups)
                local add, remove = {}, {}
                for _, g in ipairs(groups) do if not has[g] then add[#add + 1] = g end end
                for _, g in ipairs(now.groups) do if not want[g] then remove[#remove + 1] = g end end
                -- Every group to add or remove must be one the client knows, so
                -- the write can reach the target and this restore's own backup
                -- could put the window back (Codex round 3). A type outside
                -- ChatTypeGroup that stays as it is is never written: General
                -- holds seven such on Forever (SYSTEM_NOMENU, BN_WHISPER_INFORM,
                -- ...; measured 2026-10-22), so requiring every type to be known
                -- made General impossible to restore.
                for _, g in ipairs(add) do
                    if not Known(g) then cant(label, g .. " is not a chat type on this client; left as is") return end
                end
                for _, g in ipairs(remove) do
                    if not Known(g) then cant(label, "it holds " .. g .. ", unknown to this client; left as is") return end
                end
                if #add + #remove > 0 then
                    plan.chat.add[#plan.chat.add + 1] = { slot = slot, name = now.name, groups = add, remove = remove,
                                                          from = Copy(now.groups), exact = Copy(groups) }
                end
            end
            if type(chat.primary) == "table" then restore(1, nil, chat.primary.groups or {}, "Main chat window") end
            for _, t in ipairs(chat.tabs or {}) do restore(t.slot, t.name, t.groups or {}, ('Tab "%s"'):format(tostring(t.name))) end
            for _, name in ipairs(chat.creating or {}) do
                if FindTab(w, name) then plan.kept[#plan.kept + 1] = name end
            end
        end
    end

    if type(snap.meter) == "table" and type(snap.meter.windows) == "table" then
        PlanRestoreMeter(plan, snap.meter, cant)
    end

    plan.noop = Empty(plan) or nil
    return Finish(plan)
end

function UISetup.Restore(which, shown)
    local plan = UISetup.PlanRestore(which)
    if plan.blocked then return nil, plan.blocked end
    if plan.fingerprint ~= shown.fingerprint then return nil, "Something changed since the preview: review it again." end
    local result
    if plan.noop then
        result = { noop = true, changed = 0, created = {} }
    else
        local snap = Snapshot(plan, "restore")
        if not snap then return nil, "Couldn't read the current setup for the backup; nothing was changed." end
        ASS.Backups.PushRing(snap, ASS.Backups.Get(which))
        result = Execute(plan, snap)
        -- The UI no longer holds what the last apply left: Save must not
        -- write the restored state into that entry (apply it again first).
        local rec = ASS.char.loaded and ASS.char.loaded.ui
        if rec then rec.restored = true end
    end
    result.unavailable, result.kept = plan.unavailable, plan.kept
    local complete = not result.failed and #plan.unavailable == 0
    result.partial = not complete or nil
    if which == "op" and complete then
        ASS.Backups.Release()
        ASS.char.interrupted = nil
    end
    return result
end

------------------------------------------------------------
-- Save and Save As
------------------------------------------------------------

-- Groups the client doesn't know stay in the entry (a newer client's types).
local function KeepUnknown(now, saved)
    local out, has = Copy(now), Set(now)
    for _, g in ipairs(saved or {}) do
        if not Known(g) and not has[g] then out[#out + 1] = g end
    end
    return out
end

-- Save's damage meter: each window of the entry, mapped as Apply maps it
-- (1 the primary, k the (k-1)th shown secondary), takes the live values. A
-- field or window the apply skipped, a single-fight segment, a recorded
-- position and unknown keys keep the entry's. Windows beyond the entry's
-- count aren't added (Save As includes them).
local function SaveMeter(p, old, new, skipped)
    local function note(s) p.notes[#p.notes + 1] = s end
    if skipped.all then note("Damage meter: skipped by the apply; kept as saved.") return end
    local m, why = ReadMeter()
    if not m then note("Damage meter: " .. tostring(why) .. "; kept as saved.") return end
    local live = ShownSecondaries(m)
    for k, w in ipairs(old.windows) do
        local sk = skipped[k] or {}
        local i = k == 1 and 1 or live[k - 1]
        local x = new.windows[k]
        local label = ("Damage meter window %d"):format(k)
        if sk.window then
            note(label .. ": skipped by the apply; kept as saved.")
        elseif not i then
            note(("Damage meter: no window here for the setup's window %d; kept as saved."):format(k))
        else
            local now = m[i]
            local function change(s) p.changes[#p.changes + 1] = label .. ": " .. s end
            if not sk.type and now.type ~= w.type then
                change(MeterTypeText(w.type) .. " -> " .. MeterTypeText(now.type))
                x.type = now.type
            end
            if not sk.session and KnownSession(now.session) and now.session ~= w.session then
                change(SessionText(w.session) .. " -> " .. SessionText(now.session))
                x.session = now.session
            end
            if k > 1 then
                if not sk.locked and now.locked ~= w.locked then
                    change(now.locked and "locked" or "unlocked")
                    x.locked = now.locked
                end
                -- The position isn't applied, so a window here sits where the
                -- game put it: Save keeps a recorded position (Save As records
                -- a new one) and only fills one in when the entry has none.
                if now.rect and w.rect == nil then
                    change("position and size recorded")
                    x.rect = now.rect
                end
            end
        end
    end
    if #live + 1 > #old.windows then
        note(("Damage meter: %d more window(s) shown here aren't in the setup; use Save As to include them.")
            :format(#live + 1 - #old.windows))
    end
end

-- Save over the entry this character applied. p = { entry, modules, changes,
-- notes, noop, blocked, fingerprint }.
function UISetup.PlanSave()
    local p = { changes = {}, notes = {} }
    local function done() local f = Copy(p); f.fingerprint = nil; p.fingerprint = Serialize(f); return p end
    p.blocked = UISetup.Blocked()
    if p.blocked then return done() end
    local rec = ASS.char.loaded and ASS.char.loaded.ui
    local e = rec and ASS.Catalog.Get(rec.id)
    if not rec then p.blocked = "Apply a UI setup first, or use Save As." return done() end
    if not e or e.deleted then p.blocked = "The UI setup you applied was deleted: use Save As." return done() end
    if e.version ~= rec.version then
        p.blocked = "That UI setup changed since you applied it: apply it again, or use Save As."
        return done()
    end
    if not rec.complete then p.blocked = "The last apply didn't finish: apply it again, or use Save As." return done() end
    if rec.restored then p.blocked = "A backup was restored since the apply: apply it again, or use Save As." return done() end
    p.id, p.version, p.name = e.id, e.version, e.name
    local cur, notes = UISetup.Capture()
    for _, n in ipairs(notes) do p.notes[#p.notes + 1] = n end
    local old, new = e.modules, Copy(e.modules)
    local skipped = rec.skipped or {}
    if old.layout and cur.layout and not skipped.layout and not SameLayout(cur.layout, old.layout) then
        new.layout = cur.layout
        p.changes[#p.changes + 1] = ("Layout: %s -> %s"):format(LayoutText(old.layout), LayoutText(cur.layout))
    end
    if old.bars and cur.bars and not skipped.bars then
        for i = 2, 8 do
            if cur.bars[i] ~= old.bars[i] then
                p.changes[#p.changes + 1] = ("%s: %s"):format(BAR_LABEL[i], cur.bars[i] and "shown" or "hidden")
            end
        end
        new.bars = cur.bars
    end
    if old.cvars then
        for _, name in ipairs(Sorted(old.cvars)) do
            local v = cur.cvars and cur.cvars[name]
            local skip = skipped.cvars and skipped.cvars[name]
            if CVARS[name] and v and not skip and v ~= old.cvars[name] then
                new.cvars[name] = v
                p.changes[#p.changes + 1] = ("%s: %s -> %s"):format(CVAR_LABEL[name], old.cvars[name], v)
            end
        end
    end
    if old.chat and cur.chat then
        local function diff(label, was, now)
            local a, b = Set(was), Set(now)
            for _, g in ipairs(now) do if not a[g] then p.changes[#p.changes + 1] = ("%s: + %s"):format(label, g) end end
            for _, g in ipairs(was) do if not b[g] then p.changes[#p.changes + 1] = ("%s: - %s"):format(label, g) end end
        end
        if old.chat.primary and cur.chat.primary then
            local now = KeepUnknown(cur.chat.primary, old.chat.primary)
            diff("Main chat window", old.chat.primary, now)
            new.chat.primary = now
        end
        local w = ReadChat()
        local tabs = {}
        for _, t in ipairs(old.chat.tabs or {}) do
            local slot = w and FindTab(w, t.name)
            local now = slot and KeepUnknown(w[slot].groups, t.groups)
            if #t.groups == 0 then
                -- An empty tab is never kept, whether or not this character
                -- still has it (Apply wouldn't create it).
                p.changes[#p.changes + 1] = ('Tab "%s": removed (it receives no message types)'):format(t.name)
            elseif not slot then
                p.notes[#p.notes + 1] = ('Chat: no single tab named "%s" here; kept as saved.'):format(t.name)
                tabs[#tabs + 1] = t
            elseif #now == 0 then
                -- Save As leaves such tabs out; Save drops one the entry has.
                p.changes[#p.changes + 1] = ('Tab "%s": removed (it receives no message types)'):format(t.name)
            else
                diff(('Tab "%s"'):format(t.name), t.groups, now)
                tabs[#tabs + 1] = { name = t.name, groups = now }
            end
        end
        new.chat.tabs = #tabs > 0 and tabs or nil
    end
    if type(old.meter) == "table" and type(old.meter.windows) == "table" then
        SaveMeter(p, old.meter, new.meter, skipped.meter or {})
    end
    p.modules = new
    p.noop = Serialize(new) == Serialize(old) or nil
    return done()
end

function UISetup.Save(shown)
    local p = UISetup.PlanSave()
    if p.blocked then return nil, p.blocked end
    if p.fingerprint ~= shown.fingerprint then return nil, "Something changed since the preview: review it again." end
    if p.noop then return { noop = true } end
    local e, err = ASS.Catalog.Replace(p.id, p.modules, p.version, Provenance())
    if not e then return nil, err end
    local rec = ASS.char.loaded.ui
    rec.version, rec.baseline = e.version, Copy(e.modules)
    return { entry = e, changes = #p.changes }
end

-- Save As: a fresh capture of all five parts. p = { modules, notes, fingerprint }.
function UISetup.PlanSaveAs()
    local p = { notes = {} }
    p.blocked = UISetup.Blocked()
    if not p.blocked then p.modules, p.notes = UISetup.Capture() end
    local f = Copy(p)
    p.fingerprint = Serialize(f)
    return p
end

function UISetup.SaveAs(shown, name)
    local p = UISetup.PlanSaveAs()
    if p.blocked then return nil, p.blocked end
    if p.fingerprint ~= shown.fingerprint then return nil, "Something changed since the preview: review it again." end
    local e, err = ASS.Catalog.Create("ui", { name = name, provenance = Provenance() }, p.modules)
    if not e then return nil, err end
    ASS.char.loaded = ASS.char.loaded or {}
    ASS.char.loaded.ui = { id = e.id, version = e.version, baseline = Copy(e.modules), complete = true, skipped = {} }
    return e
end

------------------------------------------------------------
-- Describing (pure; tested)
------------------------------------------------------------

local function OnOff(v, domain)
    if domain == "bool" then return v == "1" and "on" or "off" end
    return v
end

-- The saved contents of an entry, one line per part (the panel, /altsync ui).
function UISetup.Contents(modules)
    local lines = {}
    if type(modules) ~= "table" then return lines end
    if modules.layout then lines[#lines + 1] = "Layout: " .. LayoutText(modules.layout) end
    if modules.bars then
        local shown = {}
        for i = 2, 8 do if modules.bars[i] then shown[#shown + 1] = tostring(i) end end
        lines[#lines + 1] = "Action bars shown: " .. (#shown > 0 and table.concat(shown, ", ") or "none beyond bar 1")
    end
    for _, name in ipairs(Sorted(modules.cvars)) do
        lines[#lines + 1] = CVARS[name] and ("%s: %s"):format(CVAR_LABEL[name], OnOff(modules.cvars[name], CVARS[name]))
            or ("%s: %s (not supported on this build)"):format(name, tostring(modules.cvars[name]))
    end
    if modules.chat then
        if modules.chat.primary then
            lines[#lines + 1] = ("Main chat window: %d message types"):format(#modules.chat.primary)
        end
        for _, t in ipairs(modules.chat.tabs or {}) do
            lines[#lines + 1] = ('Chat tab "%s": %s'):format(t.name, table.concat(t.groups, ", "))
        end
    end
    if type(modules.meter) == "table" then
        for k, w in ipairs(modules.meter.windows or {}) do
            local bits = { MeterTypeText(w.type) }
            if w.session ~= nil then bits[#bits + 1] = SessionText(w.session) end
            if w.locked then bits[#bits + 1] = "locked" end
            lines[#lines + 1] = ("Damage meter window %d: %s"):format(k, table.concat(bits, ", "))
            if type(w.rect) == "table" then
                lines[#lines + 1] = ("  Position and size recorded (%sx%s at %s %s,%s); not applied: place it yourself.")
                    :format(tostring(w.rect.width), tostring(w.rect.height), tostring(w.rect.point),
                            tostring(w.rect.x), tostring(w.rect.y))
            end
        end
    end
    for _, k in ipairs(Sorted(modules)) do
        if not KNOWN[k] then lines[#lines + 1] = ("%s: not supported on this build"):format(tostring(k)) end
    end
    return lines
end

local function DescribeMeter(plan)
    local lines = {}
    local mp = plan.meter
    if not mp then return lines end
    local reopen = {}
    for _, o in ipairs(mp.opens) do reopen[o.index] = o.reopen end
    local seen = mp.seen or {}
    for _, op in ipairs(mp.sets) do
        local label = ("Damage meter window %d"):format(op.index)
        if op.open then
            local bits = {}
            if op.type ~= nil then bits[#bits + 1] = MeterTypeText(op.type) end
            if op.session ~= nil then bits[#bits + 1] = SessionText(op.session) end
            if op.locked ~= nil then bits[#bits + 1] = op.locked and "locked" or "unlocked" end
            lines[#lines + 1] = ("New damage meter window %d: %s"):format(op.index, table.concat(bits, ", "))
            if reopen[op.index] then
                lines[#lines + 1] = "  The game reopens a window you hid before, as you left it (click-through, minimized)."
            end
            lines[#lines + 1] = "  It opens where the game places it: move it yourself (a saved position isn't applied)."
        else
            local from = op.from or seen[op.index] or {}
            if op.type ~= nil then
                lines[#lines + 1] = ("%s: %s -> %s"):format(label, MeterTypeText(from.type), MeterTypeText(op.type))
            end
            if op.session ~= nil then
                lines[#lines + 1] = ("%s: %s -> %s"):format(label, SessionText(from.session), SessionText(op.session))
            end
            if op.locked ~= nil then lines[#lines + 1] = ("%s: %s"):format(label, op.locked and "lock" or "unlock") end
        end
    end
    -- Opened windows that wrote nothing still say they open.
    local listed = {}
    for _, op in ipairs(mp.sets) do if op.open then listed[op.index] = true end end
    for _, o in ipairs(mp.opens) do
        if not listed[o.index] then lines[#lines + 1] = ("New damage meter window %d"):format(o.index) end
    end
    for _, h in ipairs(mp.hides) do
        lines[#lines + 1] = ("Damage meter window %d: hide (opened by that apply)"):format(h.index)
    end
    return lines
end

-- The preview's lines for an apply or restore plan.
function UISetup.Describe(plan)
    local lines = {}
    if plan.blocked then return { plan.blocked } end
    local restore = plan.kind == "restore"
    if plan.layout then
        lines[#lines + 1] = ("Layout: %s -> %s"):format(LayoutText(plan.layout.from), LayoutText(plan.layout.want))
        if not restore and plan.layout.want.type == ACCOUNT then
            lines[#lines + 1] = "  Uses this account's layout of that name; the layout itself isn't changed."
        end
    end
    if plan.bars then
        for i = 2, 8 do
            if plan.bars.from[i] ~= plan.bars.to[i] then
                lines[#lines + 1] = ("%s: %s"):format(BAR_LABEL[i], plan.bars.to[i] and "show" or "hide")
            end
        end
        lines[#lines + 1] = "  Action bars change after a reload: you'll be asked to reload."
    end
    for _, op in ipairs(plan.cvars) do
        local d = CVARS[op.name]
        lines[#lines + 1] = ("%s: %s -> %s%s"):format(CVAR_LABEL[op.name] or op.name, OnOff(op.from, d), OnOff(op.to, d),
            op.account and " (affects this WoW account)" or "")
    end
    for _, op in ipairs(plan.chat.add) do
        local label = op.slot == 1 and "Main chat window" or ('Chat tab "%s"'):format(op.name)
        if #op.groups > 0 then lines[#lines + 1] = ("%s: add %s"):format(label, table.concat(op.groups, ", ")) end
        if op.remove and #op.remove > 0 then
            lines[#lines + 1] = ("%s: remove %s"):format(label, table.concat(op.remove, ", "))
        end
    end
    for _, c in ipairs(plan.chat.create) do
        lines[#lines + 1] = ('New chat tab "%s": %s'):format(c.name, table.concat(c.groups, ", "))
        lines[#lines + 1] = "  It opens docked beside your other tabs, and is selected."
    end
    for _, l in ipairs(DescribeMeter(plan)) do lines[#lines + 1] = l end
    if plan.noop then
        if #plan.skips + #(plan.unavailable or {}) == 0 then
            lines[#lines + 1] = "Already matches the selected settings."
        else
            lines[#lines + 1] = "Nothing to change."
        end
    end
    if #plan.skips > 0 then
        lines[#lines + 1] = "Skipped:"
        for _, s in ipairs(plan.skips) do lines[#lines + 1] = ("  %s: %s"):format(s.what, s.reason) end
    end
    if #(plan.unavailable or {}) > 0 then
        lines[#lines + 1] = "Can't be restored:"
        for _, u in ipairs(plan.unavailable) do lines[#lines + 1] = ("  %s: %s"):format(u.what, u.reason) end
    end
    for _, n in ipairs(plan.notes or {}) do lines[#lines + 1] = n end
    if #(plan.kept or {}) > 0 then
        for _, name in ipairs(plan.kept) do
            lines[#lines + 1] = ('Chat tab "%s" is kept (created by that apply, or by you): close it yourself if you don\'t want it.'):format(name)
        end
    end
    for _, k in ipairs(plan.unsupported or {}) do
        lines[#lines + 1] = ("%s: not supported on this build, not applied."):format(k)
    end
    if not plan.noop then
        lines[#lines + 1] = restore and "Restore exactly what the backup holds. A backup is taken first."
            or "A backup is taken first; restore it from Backups."
    end
    return lines
end

UISetup._test = { Layouts = Layouts, ReadChat = ReadChat, ReadBars = ReadBars, Snapshot = Snapshot,
                  ReadMeter = ReadMeter, PredictOpens = PredictOpens }
