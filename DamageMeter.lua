-- Mainline Blizzard_DamageMeter at b9be9379719047977fca4dba1bb1d9988e8840b3.
-- NOT measured on Forever. Only the manager writes its settings; never touch
-- Blizzard SavedVariables. Called solely by the confirmed UI setup transaction.
AltStableSync = AltStableSync or {}
local ASS = AltStableSync
local M = {}
ASS.DamageMeter = M
local UNSUPPORTED = "not supported on this build"
local function Copy(v) return ASS.Catalog.Copy(v) end
local function Same(a, b) return ASS.UISetup.Serialize(a) == ASS.UISetup.Serialize(b) end
local function Plain(v)
    if issecretvalue and issecretvalue(v) then error("secret meter value") end
    return v
end
local function Number(v)
    Plain(v)
    if type(v) ~= "number" or v ~= v or math.abs(v) == math.huge then error("invalid meter number") end
    return v
end
local function Flag(v)
    Plain(v)
    -- These Mainline fields are initially nil, meaning false. A thrown getter
    -- never reaches here, and missing methods remain errors.
    if v == nil then return false end
    if type(v) ~= "boolean" then error("invalid meter flag") end
    return v
end
local function Boolean(v)
    Plain(v)
    if type(v) ~= "boolean" then error("unreadable meter boolean") end
    return v
end
local function Call(o, name, ...)
    if not o or type(o[name]) ~= "function" then error(UNSUPPORTED) end
    return o[name](o, ...)
end
local function Known(t)
    if not (Enum and type(Enum.DamageMeterType) == "table") then return false end
    for _, v in pairs(Enum.DamageMeterType) do if v == t then return true end end
    return false
end
local METHODS = { "GetSessionWindow", "GetWindowDataList", "GetSessionWindowDamageMeterType",
    "SetSessionWindowDamageMeterType", "SetSessionWindowSessionID", "SetSessionWindowLocked",
    "ShowNewSecondarySessionWindow", "HideSessionWindow", "CanShowNewSecondarySessionWindow",
    "GetAvailableSecondarySessionWindowIndex", "GetAvailableSecondaryWindowDataIndex" }
local function Manager()
    local m = _G.DamageMeter
    for _, name in ipairs(METHODS) do
        if not m or type(m[name]) ~= "function" then error(UNSUPPORTED) end
    end
    return m
end
local ANCHOR = { BOTTOMLEFT = {0,0}, BOTTOM = {.5,0}, BOTTOMRIGHT = {1,0},
    LEFT = {0,.5}, CENTER = {.5,.5}, RIGHT = {1,.5},
    TOPLEFT = {0,1}, TOP = {.5,1}, TOPRIGHT = {1,1} }
local function GeometryIdle(w)
    -- Forever lacks these newer mixin getters (owner probe, 2026-10-22).
    -- A present getter throwing is still a failure, never an absent feature.
    if w.IsMinimized ~= nil and Flag(Call(w, "IsMinimized")) then error("meter is minimized") end
    if w.IsResizing ~= nil then
        if Flag(Call(w, "IsResizing")) then error("meter is resizing") end
    else
        if type(IsMouseButtonDown) ~= "function" or Boolean(IsMouseButtonDown("LeftButton")) then
            error("finish dragging or resizing the meter first")
        end
    end
end
local function Geometry(w)
    GeometryIdle(w)
    if Number(Call(w, "GetNumPoints")) ~= 1 then error("meter has multiple anchors") end
    local p, relative, rp = Call(w, "GetPoint", 1)
    Plain(p); Plain(relative); Plain(rp)
    if relative ~= UIParent or not ANCHOR[p] or not ANCHOR[rp] then error("meter anchor isn't UIParent") end
    -- Different effective scales are left alone, rather than guessing at a
    -- coordinate conversion or changing the player's scale.
    if Number(Call(w, "GetEffectiveScale")) ~= Number(Call(UIParent, "GetEffectiveScale")) then
        error("meter scale differs from UIParent")
    end
    local x, y, width, height = Call(w, "GetRect")
    x, y, width, height = Number(x), Number(y), Number(width), Number(height)
    local sw, sh = Number(Call(UIParent, "GetWidth")), Number(Call(UIParent, "GetHeight"))
    if width < 200 or width > 600 or height < 120 or height > 400 or x < 0 or y < 0
        or x + width > sw or y + height > sh then error("meter rectangle out of bounds") end
    for _, name in ipairs({"SetPoint", "SetSize"}) do
        if type(w[name]) ~= "function" then error(UNSUPPORTED) end
    end
    local g = { x = x, y = y, width = width, height = height }
    if w.IsUserPlaced ~= nil then
        if type(w.SetUserPlaced) ~= "function" then error(UNSUPPORTED) end
        g.userPlaced = Boolean(Call(w, "IsUserPlaced"))
    end
    return g
end
local function Window(m, i)
    local data = Call(m, "GetWindowDataList")
    if type(data) ~= "table" then error("meter data unreadable") end
    local w = Call(m, "GetSessionWindow", i)
    if not w then
        if data[i] ~= nil or i == 1 then error("meter window unreadable") end
        return { exists = false, shown = false }
    end
    if type(data[i]) ~= "table" then error("meter data unreadable") end
    local s = { exists = true, shown = Boolean(Call(w, "IsShown")),
        meterType = Number(Call(w, "GetDamageMeterType")),
        locked = Flag(Call(w, "IsLocked")) }
    if Number(Call(w, "GetSessionWindowIndex")) ~= i then error("wrong meter window") end
    local st, id = Call(w, "GetSessionType"), Call(w, "GetSessionID")
    Plain(st); Plain(id)
    if id ~= nil or (st ~= 0 and st ~= 1) then error("select Current or Overall first (specific encounters cannot be backed up)") end
    s.sessionType = st
    if not Known(s.meterType) then error(UNSUPPORTED) end
    if Number(Call(m, "GetSessionWindowDamageMeterType", w)) ~= s.meterType
        or Plain(data[i].sessionType) ~= st or Plain(data[i].sessionID) ~= nil
        or Flag(data[i].locked) ~= s.locked then error("meter manager and window disagree") end
    if i == 2 then
        local ok, g = pcall(Geometry, w)
        if ok then s.geometry = g end
    end
    return s
end
local function Allocator(m)
    if not Boolean(Call(m, "CanShowNewSecondarySessionWindow")) then return false end
    local i = Plain(Call(m, "GetAvailableSecondarySessionWindowIndex"))
    if i == nil then i = Plain(Call(m, "GetAvailableSecondaryWindowDataIndex")) end
    if i ~= nil then Number(i) end
    return i or false
end
function M.Read()
    local ok, state = pcall(function()
        local m = Manager()
        local s = { windows = { Window(m, 1), Window(m, 2) } }
        if not s.windows[2].shown then s.allocator = Allocator(m) end
        return s
    end)
    if not ok then
        -- Do not expose secret client values or arbitrary exception text.
        if type(state) == "string" and state:find("select Current or Overall", 1, true) then
            return nil, "select Current or Overall first; specific encounters cannot be backed up"
        end
        return nil, UNSUPPORTED .. " (meter state or API unreadable)"
    end
    return state
end
function M.Capture()
    local s, why = M.Read()
    if not s then return nil, why end
    local out = { windows = {} }
    for i = 1, 2 do
        local w = s.windows[i]
        if i == 2 and not w.shown then
            local healing = Enum.DamageMeterType.HealingDone
            if not Known(healing) then return nil, UNSUPPORTED end
            out.windows[i] = { meterType = healing, sessionType = 1, locked = false }
        else
            out.windows[i] = { meterType = w.meterType, sessionType = 1, locked = w.locked,
                geometry = Copy(w.geometry) }
        end
    end
    local note = "Both windows use Current Segment; a hidden/missing second window becomes Healing Done. Primary position/size follow Edit Mode."
    if not out.windows[2].geometry then note = note .. " Secondary position/size couldn't be captured safely; not saved." end
    if out.windows[2].geometry and out.windows[2].geometry.userPlaced == nil then
        note = note .. " Secondary position/size saved; this build's unreadable placement flag is left alone."
    end
    return out, note
end
local function Fit(g)
    local ok, fits = pcall(function()
        return g.x >= 0 and g.y >= 0 and g.x + g.width <= Number(Call(UIParent, "GetWidth"))
            and g.y + g.height <= Number(Call(UIParent, "GetHeight"))
    end)
    return ok and fits
end
local function PlacementFlagAPI()
    -- IsUserPlaced is a Frame API, not a secondary-window mixin. Before a
    -- new frame exists, inspect the existing primary of the same frame type.
    local ok, available = pcall(function()
        return type(Call(Manager(), "GetSessionWindow", 1).IsUserPlaced) == "function"
    end)
    return ok and available
end
-- Plans contain plain copied values only; never retain Blizzard frames/tables.
function M.Plan(part, restoring)
    local from, why = M.Read()
    if not from then return nil, why end
    if not from.windows[1].shown then return nil, "show the primary damage meter first" end
    local p = { from = from, to = {}, restore = restoring or nil }
    for i = 1, 2 do
        local want = part.windows and part.windows[i]
        local cur = from.windows[i]
        if want then
            local to = Copy(want)
            if not restoring then
                to = { exists = true, shown = true, meterType = want.meterType,
                    sessionType = 1, locked = want.locked, geometry = Copy(want.geometry) }
            end
            if to.exists then
                if not Known(to.meterType) or (to.sessionType ~= 0 and to.sessionType ~= 1)
                    or to.sessionID ~= nil then return nil, UNSUPPORTED end
            end
            if i == 1 then to.geometry = nil end
            if i == 2 and not cur.shown and to.shown then
                if from.allocator ~= 2 then return nil, "opening would affect another window; open window 2 manually first" end
                if cur.exists and not cur.geometry then return nil, "hidden window placement cannot be backed up safely" end
                if cur.exists and cur.geometry.userPlaced == nil then
                    return nil, "hidden window placement flag cannot be backed up; show window 2 manually first"
                end
            end
            if i == 2 and not to.shown and cur.shown and not (part.journal and part.journal.opened) then
                return nil, "backup does not prove this operation opened window 2; left shown"
            end
            if i == 2 and not to.shown and cur.shown and not cur.geometry then
                return nil, "current window placement cannot be backed up before hiding"
            end
            if i == 2 and not to.shown and cur.shown and cur.geometry.userPlaced == nil then
                return nil, "window placement flag cannot be backed up for undo; window 2 is left shown"
            end
            if restoring and part.journal and part.journal.uncertain then
                return nil, "window opening could not be verified; left unchanged"
            end
            local flagUnreadable = to.geometry and to.geometry.userPlaced ~= nil
                and ((cur.exists and (not cur.geometry or cur.geometry.userPlaced == nil))
                    or (not cur.exists and not PlacementFlagAPI()))
            if to.geometry and (not Fit(to.geometry) or (cur.exists and not cur.geometry) or flagUnreadable) then
                if restoring then return nil, "saved placement cannot be restored safely" end
                to.geometry = nil
                p.geometrySkipped = true
            end
            -- No geometry requested means leave the existing placement alone.
            local compare = Copy(cur)
            if not to.geometry then compare.geometry = nil end
            if compare.geometry and to.geometry and to.geometry.userPlaced == nil then compare.geometry.userPlaced = nil end
            if not to.exists then
                if cur.shown then p.to[i] = to end
            elseif not Same(compare, to) then p.to[i] = to end
        end
    end
    if not next(p.to) then return nil, nil, p.geometrySkipped end
    return p, nil, p.geometrySkipped
end
function M.Snapshot(p)
    local now = M.Read()
    if not now or not Same(now, p.from) then return nil end
    local s = { windows = {}, journal = {} }
    for i, to in pairs(p.to) do
        s.windows[i] = Copy(now.windows[i])
        if not to.geometry and to.shown == now.windows[i].shown then s.windows[i].geometry = nil end
        if s.windows[i].geometry and to.geometry and to.geometry.userPlaced == nil
            and to.shown == now.windows[i].shown then s.windows[i].geometry.userPlaced = nil end
    end
    return s
end
local function Near(a, b) return math.abs(a - b) < .05 end
local function SameGeometry(a, b)
    return a and b and (b.userPlaced == nil or a.userPlaced == b.userPlaced) and Near(a.x,b.x) and Near(a.y,b.y)
        and Near(a.width,b.width) and Near(a.height,b.height)
end
local function Execute(p, snap, guard)
    local now = M.Read()
    if not now or not Same(now, p.from) then return nil, "meter changed since the preview" end
    local m = _G.DamageMeter
    local function write(o, method, ...)
        local why = guard()
        if why then return nil, why end
        if method == "SetSize" or method == "SetPoint" or method == "SetUserPlaced" then
            local idle = pcall(GeometryIdle, o)
            if not idle then return nil, "meter interaction changed; finish dragging or resizing first" end
        end
        local ok = pcall(Call, o, method, ...)
        if not ok then return nil, method .. " failed" end
        return true
    end
    local function read(i)
        local ok, w = pcall(Window, m, i)
        if ok then return w end
    end
    for i = 1, 2 do
        local to = p.to[i]
        if to then
            local cur = read(i)
            if not cur then return nil, "meter unreadable" end
            if to.shown and not cur.shown then
                local okA, available = pcall(Allocator, m)
                if not okA or available ~= 2 then return nil, "meter allocator changed" end
                local why = guard()
                if why then return nil, why end
                snap.journal.uncertain = true
                local ok = pcall(Call, m, "ShowNewSecondarySessionWindow")
                -- Check visibility independently: even an exception after Show
                -- must record ownership, including in the first backup.
                local okS, shown = pcall(function() return Boolean(Call(Call(m,"GetSessionWindow",2),"IsShown")) end)
                if okS and shown then snap.journal.opened = true; snap.journal.uncertain = nil end
                if okS and not shown then snap.journal.uncertain = nil end
                if not ok or not okS or not shown then return nil, "opening meter window failed" end
                cur = read(i)
                if not cur then return nil, "new meter window unreadable" end
            end
            local w = Call(m, "GetSessionWindow", i)
            if to.exists then
                for _, field in ipairs({"meterType", "sessionType", "locked"}) do
                    if cur[field] ~= to[field] then
                        local method = ({meterType="SetSessionWindowDamageMeterType", sessionType="SetSessionWindowSessionID",
                            locked="SetSessionWindowLocked"})[field]
                        local ok, why = write(m, method, w, to[field])
                        if not ok then return nil, why end
                        cur = read(i)
                        if not cur or cur[field] ~= to[field] then return nil, "meter " .. field .. " read-back" end
                    end
                end
                if to.geometry and not SameGeometry(cur.geometry, to.geometry) then
                    local g = to.geometry
                    if not cur.geometry or not Fit(g) then return nil, "meter geometry unreadable" end
                    local ok, why = write(w, "SetSize", g.width, g.height)
                    if not ok then return nil, why end
                    local okR, rect = pcall(Geometry, w)
                    if not okR or not Near(rect.width,g.width) or not Near(rect.height,g.height) then return nil, "meter size read-back" end
                    local okP, point, _, relativePoint = pcall(Call, w, "GetPoint", 1)
                    if not okP or not ANCHOR[point] or not ANCHOR[relativePoint] then return nil, "meter anchor unreadable" end
                    local a, b = ANCHOR[point], ANCHOR[relativePoint]
                    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
                    ok, why = write(w, "SetPoint", point, UIParent, relativePoint,
                        g.x + a[1]*g.width - b[1]*sw, g.y + a[2]*g.height - b[2]*sh)
                    if not ok then return nil, why end
                    okR, rect = pcall(Geometry, w)
                    if not okR or not Near(rect.x,g.x) or not Near(rect.y,g.y) then return nil, "meter position read-back" end
                    if g.userPlaced ~= nil then
                        ok, why = write(w, "SetUserPlaced", g.userPlaced)
                        if not ok then return nil, why end
                    end
                    okR, rect = pcall(Geometry, w)
                    if not okR or not SameGeometry(rect,g) then return nil, "meter placement read-back" end
                end
            end
            if not to.shown and cur.shown then
                local ok, why = write(m, "HideSessionWindow", w)
                if not ok then return nil, why end
                cur = read(i)
                if not cur or cur.shown then return nil, "meter hide read-back" end
            end
            local why = guard()
            if why then return nil, why end
            cur = read(i)
            if not cur or cur.shown ~= to.shown then return nil, "meter visibility read-back" end
            if to.exists and (cur.meterType ~= to.meterType or cur.sessionType ~= to.sessionType
                or cur.locked ~= to.locked or (to.geometry and not SameGeometry(cur.geometry,to.geometry))) then
                return nil, "meter final read-back"
            end
        end
    end
    return true
end
function M.Execute(p, snap, guard)
    local ok, result, why = pcall(Execute, p, snap, guard)
    if not ok then return nil, "damage meter API failed; backup retained" end
    return result, why
end
function M.Merge(now, old)
    local out = Copy(old)
    for i = 1, 2 do
        local n, o = now.windows[i], out.windows[i]
        o.meterType, o.sessionType, o.locked = n.meterType, n.sessionType, n.locked
        if n.geometry then
            o.geometry = o.geometry or {}
            for k, v in pairs(n.geometry) do o.geometry[k] = v end
        end
    end
    return out
end
function M.Describe(part)
    local lines = {}
    for i = 1, 2 do
        local w = part.windows[i]
        if w and w.exists ~= false then
            local label = tostring(w.meterType)
            for k, v in pairs(Enum and Enum.DamageMeterType or {}) do
                if v == w.meterType then label = k:gsub("(%l)(%u)", "%1 %2") end
            end
            local placement = w.geometry and (", position %.0f, %.0f; size %.0f x %.0f")
                :format(w.geometry.x, w.geometry.y, w.geometry.width, w.geometry.height) or ""
            lines[#lines+1] = ("Damage meter %d: %s, %s, %s%s"):format(i, label,
                w.sessionType == 1 and "Current Segment" or "Overall", w.locked and "locked" or "unlocked",
                placement)
        end
    end
    return lines
end
