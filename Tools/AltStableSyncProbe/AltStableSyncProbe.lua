------------------------------------------------------------
-- AltStableSyncProbe - a ForeverProbe module (..\ForeverProbe, docs/GUIDE.md)
--
-- The launch rehearsal (#85, #13; docs/RUNBOOK.md "Stress test"): an
-- independent record of a character's bars, macros, keys and pet bar, read
-- straight from the client, so AltStableSync's own capture code can't hide
-- its own bug. The procedure `/fp steps sync stress` takes those records
-- around the owner's Loads, full exits and a Restore, and compares them (A43).
-- `/fp steps sync audit` (audit #95, docs/AUDIT.md section 5) does the same
-- for a UI setup and a loadout together, with the UI parts recorded too
-- (layout, bar toggles, CVars, chat windows, meter windows), two full exits,
-- and the short checks the stubs can't answer.
--
-- It only READS: every Load, Restore, Save As and Import is the owner's own
-- click. It never calls a mutating client function or an AltStableSync
-- write path, and writes only its own SavedVariables (AltStableSyncProbeDB).
-- Lines go to the /fp console and the saved log, never to chat.
--
-- The old /syncprobe (chat output) is kept, unloaded, in legacy/: port a
-- command from it when an issue next needs one. Its findings are in
-- docs/forever-api-notes.md.
------------------------------------------------------------

local ADDON, NS = ...
local MAX_LOG = 3000
local SHOWN_DIFFS = 60

local Probe = ForeverProbe:Module("AltStableSyncProbe", { api = 1, cmd = "sync" })
local function say(msg) Probe:Say(msg) end

-- Client APIs read through rawget: a missing one reads as nil, never throws
-- (the host's rule, and the tests' strict stubs).
local function api(name) return rawget(_G, name) end

local DB                             -- AltStableSyncProbeDB, from ADDON_LOADED

------------------------------------------------------------
-- What gets compared
------------------------------------------------------------

-- Action slots AltStableSync covers: 1-120 and 145-180 (Game.lua). Compared
-- whole, not only a loadout's cover: a slot outside it must stay unchanged.
-- 121-144 (skyriding/possess/override pages) are recorded as information.
local COMPARED, SPECIAL = {}, {}
for s = 1, 120 do COMPARED[#COMPARED + 1] = s end
for s = 145, 180 do COMPARED[#COMPARED + 1] = s end
for s = 121, 144 do SPECIAL[#SPECIAL + 1] = s end

-- Every key chord the client can bind, read by key with GetBindingAction:
-- the binding list (GetBinding) misses custom CLICK/MACRO/SPELL bindings.
-- The same inputs Game.lua checks, copied here on purpose (independent).
local KEY_BASES = { "SPACE", "TAB", "ESCAPE", "BACKSPACE", "ENTER", "INSERT", "DELETE", "HOME", "END",
    "PAGEUP", "PAGEDOWN", "UP", "DOWN", "LEFT", "RIGHT", "CAPSLOCK", "NUMLOCK", "SCROLLLOCK", "PAUSE",
    "PRINTSCREEN", "`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/",
    "MOUSEWHEELUP", "MOUSEWHEELDOWN",
    "NUMPADPLUS", "NUMPADMINUS", "NUMPADMULTIPLY", "NUMPADDIVIDE", "NUMPADDECIMAL", "NUMPADENTER",
    "PADDUP", "PADDRIGHT", "PADDDOWN", "PADDLEFT", "PADLSTICK", "PADRSTICK", "PADLSHOULDER",
    "PADRSHOULDER", "PADLTRIGGER", "PADRTRIGGER", "PADFORWARD", "PADBACK", "PADSYSTEM", "PADSOCIAL",
    "PADLSTICKUP", "PADLSTICKRIGHT", "PADLSTICKDOWN", "PADLSTICKLEFT",
    "PADRSTICKUP", "PADRSTICKRIGHT", "PADRSTICKDOWN", "PADRSTICKLEFT" }
for c = 65, 90 do KEY_BASES[#KEY_BASES + 1] = string.char(c) end
for i = 0, 9 do KEY_BASES[#KEY_BASES + 1] = tostring(i); KEY_BASES[#KEY_BASES + 1] = "NUMPAD" .. i end
for i = 1, 24 do KEY_BASES[#KEY_BASES + 1] = "F" .. i end
for i = 1, 31 do KEY_BASES[#KEY_BASES + 1] = "BUTTON" .. i end
for i = 1, 6 do KEY_BASES[#KEY_BASES + 1] = "PAD" .. i end
for i = 1, 4 do KEY_BASES[#KEY_BASES + 1] = "PADPADDLE" .. i end
local CHORDS = {}
for mask = 0, 15 do
    local m = ""
    if mask % 2 >= 1 then m = m .. "ALT-" end
    if mask % 4 >= 2 then m = m .. "CTRL-" end
    if mask % 8 >= 4 then m = m .. "SHIFT-" end
    if mask >= 8 then m = m .. "META-" end
    for _, k in ipairs(KEY_BASES) do CHORDS[#CHORDS + 1] = m .. k end
end

local CHARACTER_SET = 2              -- Enum.BindingSet.Character (measured)
local function characterSet()
    local e = api("Enum")
    return (e and e.BindingSet and e.BindingSet.Character) or CHARACTER_SET
end

------------------------------------------------------------
-- Reading the client
------------------------------------------------------------

local function secret(v)
    local f = api("issecretvalue")
    if not f then return false end
    local ok, s = pcall(f, v)
    return not ok or s == true
end

-- pcall a client function by name. Returns ok, results... ; a missing
-- function or a secret first return is not ok.
local function read(rec, label, name, ...)
    local fn = api(name)
    if type(fn) ~= "function" then
        rec.why[#rec.why + 1] = name .. " missing"
        return false
    end
    local p = { n = 0 }
    local function pack(...) p = { n = select("#", ...), ... } end
    pack(pcall(fn, ...))
    if not p[1] then
        rec.why[#rec.why + 1] = label .. ": " .. tostring(p[2])
        return false
    end
    for i = 2, p.n do
        if secret(p[i]) then rec.why[#rec.why + 1] = label .. ": a secret value"; return false end
    end
    return true, unpack(p, 2, p.n)
end

local function plain(v)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    return nil
end

-- Bodies compare without the server's trailing newline (measured).
local function body(s) return (tostring(s or ""):gsub("[\r\n]+$", "")) end

local function macroKey(m) return m.scope .. "|" .. m.name .. "|" .. m.body .. "|" .. tostring(m.icon) end

-- A dotted global path (C_EditMode.GetLayouts), each segment through rawget.
local function path(dotted)
    local v = _G
    for part in dotted:gmatch("[^.]+") do
        if type(v) ~= "table" then return nil end
        v = rawget(v, part)
    end
    return v
end

-- The UI parts a UI setup writes (audit #95): the active Edit Mode layout,
-- the seven bar toggles, AltStableSync's CVar allowlist, the chat windows
-- (and the selected tab), the damage-meter windows. Read into rec.ui with
-- its own `why`, so a client without a part leaves the record valid: the
-- stress rehearsal doesn't compare them, the audit procedure does.
local UI_CVARS = { "damageMeterEnabled", "damageMeterResetOnNewInstance", "raidFramesDisplayClassColor",
                   "raidFramesDisplayPowerBars", "raidFramesHealthBarColorBG" }
local function readUI(rec)
    local ui = { why = {}, cvars = {} }
    local function try(label, fn, ...)
        if type(fn) ~= "function" then ui.why[#ui.why + 1] = label .. " missing"; return false end
        local p = { n = 0 }
        local function pack(...) p = { n = select("#", ...), ... } end
        pack(pcall(fn, ...))
        if not p[1] then ui.why[#ui.why + 1] = label .. ": " .. tostring(p[2]); return false end
        for i = 2, p.n do
            if secret(p[i]) then ui.why[#ui.why + 1] = label .. ": a secret value"; return false end
        end
        return true, unpack(p, 2, p.n)
    end
    -- Layout: the active index counts the presets first (measured 70245).
    local okL, info = try("GetLayouts", path("C_EditMode.GetLayouts"))
    if okL and type(info) == "table" and type(info.activeLayout) == "number" and type(info.layouts) == "table" then
        local mgr = path("EditModePresetLayoutManager")
        local okP, presets = try("GetCopyOfPresetLayouts", type(mgr) == "table" and mgr.GetCopyOfPresetLayouts, mgr)
        local n = okP and type(presets) == "table" and #presets or nil
        ui.layout = { index = info.activeLayout }
        if n then
            local l = info.activeLayout > n and info.layouts[info.activeLayout - n] or presets[info.activeLayout]
            if type(l) == "table" then ui.layout.name, ui.layout.type = plain(l.layoutName), plain(l.layoutType) end
        end
    end
    local toggles = { try("GetActionBarToggles", api("GetActionBarToggles")) }
    if toggles[1] then
        local t = {}
        for i = 2, 8 do t[#t + 1] = toggles[i] and "1" or "0" end
        ui.bars = table.concat(t)
    end
    local getCVar = path("C_CVar.GetCVar")
    for _, name in ipairs(UI_CVARS) do
        local ok, v = try("GetCVar " .. name, getCVar, name)
        if ok then ui.cvars[name] = plain(v) end
    end
    local n = api("NUM_CHAT_WINDOWS")
    if type(n) == "number" then
        ui.chat = {}
        for i = 1, n do
            local okW, name = try("GetChatWindowInfo " .. i, api("GetChatWindowInfo"), i)
            local okA, active = try("FCF_IsChatWindowIndexActive " .. i, api("FCF_IsChatWindowIndexActive"), i)
            if okW and okA and active then
                local g = { try("GetChatWindowMessages " .. i, api("GetChatWindowMessages"), i) }
                if g[1] then
                    local groups = {}
                    for j = 2, #g do if type(g[j]) == "string" then groups[#groups + 1] = g[j] end end
                    table.sort(groups)
                    ui.chat[i] = { name = plain(name) or "", groups = table.concat(groups, ",") }
                end
            end
        end
        local sel = api("SELECTED_CHAT_FRAME")
        if type(sel) == "table" and type(sel.GetID) == "function" then
            local okS, id = pcall(sel.GetID, sel)
            if okS then ui.chatSelected = plain(id) end
        end
    end
    -- The meter: the primary window must exist and every field must read
    -- with its type, else the part is left out (and said in `why`), so the
    -- audit's comparison is unverified rather than equal on nothing (Codex
    -- on PR #96, follow-up). A fresh window's lock reads nil on Mainline,
    -- meaning unlocked (DamageMeter.lua Flag).
    local m = api("DamageMeter")
    if type(m) == "table" and type(m.GetSessionWindow) == "function" then
        local windows, complete = {}, true
        for i = 1, 3 do
            local okW, w = try("GetSessionWindow " .. i, m.GetSessionWindow, m, i)
            if okW and type(w) == "table" then
                local function get(name, kind)
                    local ok, v = try(name .. " " .. i, w[name], w)
                    if not ok then return nil, false end
                    v = plain(v)
                    if kind == "flag" then
                        if v == nil then v = false end
                        kind = "boolean"
                    end
                    if type(v) ~= kind then
                        ui.why[#ui.why + 1] = ("%s %d: %s, not a %s"):format(name, i, tostring(v), kind)
                        return nil, false
                    end
                    return v, true
                end
                local shown, okS = get("IsShown", "boolean")
                local mtype, okT = get("GetDamageMeterType", "number")
                local session, okN = get("GetSessionType", "number")
                local locked, okL2 = get("IsLocked", "flag")
                if not (okS and okT and okN and okL2) then complete = false; break end
                -- The rectangle is part of what the audit compares (window
                -- 2's position and size): unreadable or malformed, the part
                -- is left out like any other field (Codex, PR #96 round 3).
                local okR, x, y, wd, h = try("GetRect " .. i, w.GetRect, w)
                if not (okR and type(x) == "number" and type(y) == "number" and type(wd) == "number" and type(h) == "number") then
                    if okR then ui.why[#ui.why + 1] = ("GetRect %d: not four numbers"):format(i) end
                    complete = false
                    break
                end
                windows[i] = ("%s type %d session %d %s %d,%d %dx%d"):format(shown and "shown" or "hidden", mtype, session,
                    locked and "locked" or "unlocked", x, y, wd, h)
            elseif i == 1 then
                ui.why[#ui.why + 1] = "meter window 1 missing"
                complete = false
                break
            elseif not okW then
                complete = false
                break
            end
        end
        if complete then ui.meter = windows end
    end
    rec.ui = ui
end

-- The independent record: { valid, why, slots, raw, special, macros, keymap,
-- cmdkeys, set, pet, who, context, addon }. Only strings, numbers and
-- booleans go in it.
function NS.Record()
    local rec = { why = {}, slots = {}, raw = {}, special = {}, macros = {}, keymap = {}, cmdkeys = {} }
    local stamp = api("time")
    rec.at = stamp and stamp() or 0
    local ok, guid = read(rec, "player GUID", "UnitGUID", "player")
    rec.guid = ok and plain(guid) or nil
    local _, name, realm = read(rec, "player name", "UnitFullName", "player")
    local _, _, class = read(rec, "class", "UnitClass", "player")
    local _, race = read(rec, "race", "UnitRace", "player")
    local _, level = read(rec, "level", "UnitLevel", "player")
    rec.who = { name = plain(name), realm = plain(realm), class = plain(class), race = plain(race), level = plain(level) }
    local _, form = read(rec, "form", "GetShapeshiftForm")
    local _, bonus = read(rec, "bonus bar", "GetBonusBarOffset")
    rec.context = { form = plain(form), bonus = plain(bonus) }

    -- Macros first: macro slots resolve against them.
    local okN, nAcc, nChar = read(rec, "GetNumMacros", "GetNumMacros")
    local byName = {}
    if okN and type(nAcc) == "number" and type(nChar) == "number" then
        local function add(index, scope)
            local okM, mName, icon, text = read(rec, "macro " .. index, "GetMacroInfo", index)
            if not okM or type(mName) ~= "string" or mName == "" then
                rec.why[#rec.why + 1] = "macro " .. index .. " unreadable"
                return
            end
            if type(icon) ~= "number" then rec.why[#rec.why + 1] = "macro " .. mName .. ": icon is a " .. type(icon) end
            local m = { scope = scope, name = mName, body = body(text), icon = plain(icon) or tostring(icon), index = index }
            rec.macros[#rec.macros + 1] = m
            byName[mName] = (byName[mName] or 0) + 1
        end
        for i = 1, nAcc do add(i, "account") end
        for i = 1, nChar do add(120 + i, "character") end
    else
        rec.why[#rec.why + 1] = "macro counts unreadable"
    end
    local scopeOf = {}
    for _, m in ipairs(rec.macros) do scopeOf[m.name] = m.scope end

    local function slot(s)
        local okA, kind, id, sub = read(rec, "slot " .. s, "GetActionInfo", s)
        if not okA then return nil end
        local okT, text = read(rec, "slot " .. s .. " text", "GetActionText", s)
        if not okT then return nil end
        rec.raw[s] = kind and table.concat({ tostring(kind), tostring(id), tostring(sub), tostring(text) }, "|") or false
        if not kind then return false end
        if kind == "macro" then
            if type(text) ~= "string" or text == "" then return "macro?:(no name)" end
            -- The id is the spell the macro shows, or its index: never compared.
            if byName[text] == 1 then return "macro:" .. scopeOf[text] .. ":" .. text end
            return "macro?:" .. text
        end
        return tostring(kind) .. ":" .. tostring(id) .. ":" .. tostring(sub or "")
    end
    for _, s in ipairs(COMPARED) do
        local v = slot(s)
        if v == nil then rec.slots[s] = "unreadable" else rec.slots[s] = v end
    end
    for _, s in ipairs(SPECIAL) do
        local v = slot(s)
        rec.special[s] = v == nil and "unreadable" or v
    end

    -- Bindings: the set, every key chord, and the binding list.
    local okS, set = read(rec, "binding set", "GetCurrentBindingSet")
    rec.set = okS and plain(set) or nil
    for _, chord in ipairs(CHORDS) do
        local okK, action = read(rec, "key " .. chord, "GetBindingAction", chord)
        if not okK then break end
        if type(action) == "string" and action ~= "" then rec.keymap[chord] = action end
    end
    local okB, n = read(rec, "GetNumBindings", "GetNumBindings")
    if okB and type(n) == "number" then
        for i = 1, n do
            local p = { read(rec, "binding " .. i, "GetBinding", i) }
            if not p[1] then break end
            local command = p[2]
            if type(command) == "string" and command ~= "" then
                local keys = {}
                for j = 4, #p do if type(p[j]) == "string" and p[j] ~= "" then keys[#keys + 1] = p[j] end end
                if #keys > 0 then table.sort(keys); rec.cmdkeys[command] = table.concat(keys, ",") end
            end
        end
    end

    -- The pet bar: the pet that is out, by family and name (its GUID
    -- changes on every summon, so it is recorded, never compared).
    local okE, exists = read(rec, "pet", "UnitExists", "pet")
    local okH, hasBar = true, false
    if okE and exists then okH, hasBar = read(rec, "pet bar", "PetHasActionBar") end
    if okE and okH and exists and hasBar then
        local _, familyName, family = read(rec, "pet family", "UnitCreatureFamily", "pet")
        local _, petName = read(rec, "pet name", "UnitName", "pet")
        local _, petGuid = read(rec, "pet GUID", "UnitGUID", "pet")
        local pet = { family = plain(family), familyName = plain(familyName), name = plain(petName),
                      guid = plain(petGuid), slots = {}, autocast = {} }
        for i = 1, 10 do
            local okP, pName, _, isToken, _, _, autoOn, spellID = read(rec, "pet slot " .. i, "GetPetActionInfo", i)
            if not okP then pet.slots[i] = "unreadable"
            elseif pName == nil then pet.slots[i] = false
            elseif isToken then pet.slots[i] = "token:" .. tostring(pName)
            elseif type(spellID) == "number" then
                pet.slots[i] = "spell:" .. spellID
                pet.autocast[i] = autoOn and true or false
            else pet.slots[i] = "unreadable" end
            if pet.slots[i] == "unreadable" then rec.why[#rec.why + 1] = "pet slot " .. i .. " unreadable" end
        end
        rec.pet = pet
    end

    -- AltStableSync's own view, read-only, as supporting evidence.
    local A = rawget(_G, "AltStableSync")
    local C = rawget(_G, "AltStableSyncChar")
    rec.addon = {}
    if type(C) == "table" and type(C.loaded) == "table" and type(C.loaded.loadout) == "table" then
        local l = C.loaded.loadout
        rec.addon.loaded = { id = plain(l.id), version = plain(l.version),
                             at = type(l.result) == "table" and plain(l.result.at) or nil }
    end
    if type(A) == "table" and type(A.Backups) == "table" and type(A.Backups.List) == "function" then
        local okL, ring, op = pcall(A.Backups.List)
        if okL and type(ring) == "table" then
            local b = ring[1]
            rec.addon.ring = #ring
            rec.addon.pinned = op ~= nil
            if type(b) == "table" then
                local o = type(b.op) == "table" and b.op or {}
                rec.addon.newest = { at = plain(b.at), kind = plain(o.kind), id = plain(o.id), name = plain(o.name) }
            end
            -- Every ring entry by reason and time, so a restore step can name
            -- its backup (an index shifts with every restore). Never compared.
            rec.addon.backups = {}
            for i, s in ipairs(ring) do
                local o = type(s) == "table" and type(s.op) == "table" and s.op or {}
                rec.addon.backups[i] = { at = plain(type(s) == "table" and s.at), reason = plain(type(s) == "table" and s.reason),
                                         kind = plain(type(s) == "table" and s.kind), name = plain(o.name) }
            end
        end
    end

    readUI(rec)
    rec.valid = #rec.why == 0
    return rec
end

------------------------------------------------------------
-- Comparing two records
------------------------------------------------------------

local function multiset(list)
    local out = {}
    for _, m in ipairs(list or {}) do local k = macroKey(m); out[k] = (out[k] or 0) + 1 end
    return out
end

-- The macros in `b` that `a` doesn't have (as a multiset): what a Load
-- created or changed. Restore keeps created macros (it never deletes one).
function NS.Extras(a, b)
    local have, out = multiset(a and a.macros), {}
    for k, n in pairs(multiset(b and b.macros)) do
        local extra = n - (have[k] or 0)
        if extra > 0 then out[k] = extra end
    end
    return out
end

local function sortedKeys(...)
    local seen, out = {}, {}
    for i = 1, select("#", ...) do
        for k in pairs(select(i, ...) or {}) do
            if not seen[k] then seen[k] = true; out[#out + 1] = k end
        end
    end
    table.sort(out, function(x, y) return tostring(x) < tostring(y) end)
    return out
end

-- The UI parts of two records (audit #95). `ui.tabs`: chat tab names `b`
-- may hold beyond `a` (an apply created them; a restore keeps them, as it
-- keeps created macros). `ui.meter`: the meter windows may differ (on
-- Forever a restore can't hide the window the apply opened, so the whole
-- meter part stays as applied). The selected chat tab is information only.
-- A part missing on one side is unverified. One missing on both sides is
-- skipped, unless `ui.require[part]` names it: then it is unverified too, so
-- the audit can never report EQUAL for a part it never saw (Codex on PR #96).
local function compareUI(a, b, ui, out)
    local function diff(s) out.diffs[#out.diffs + 1] = s end
    local function unv(s) out.unverified[#out.unverified + 1] = s end
    local function info(s) out.info[#out.info + 1] = s end
    local x, y = a.ui, b.ui
    if type(x) ~= "table" or type(y) ~= "table" then unv("UI parts not recorded"); return end
    local required = ui.require or {}
    local function layout(l) return l and (tostring(l.name) .. " (type " .. tostring(l.type) .. ", index " .. tostring(l.index) .. ")") or nil end
    local function part(name, p, q, label)
        if p == nil and q == nil then
            if required[name] then unv((label or name) .. " not recorded on either side") end
            return
        end
        if p == nil or q == nil then unv((label or name) .. " unreadable on one side"); return end
        if p ~= q then diff(("%s: %s -> %s"):format(label or name, tostring(p), tostring(q))) end
    end
    part("layout", layout(x.layout), layout(y.layout))
    part("bars", x.bars, y.bars, "bar toggles 2-8")
    for _, name in ipairs(UI_CVARS) do part("cvars", (x.cvars or {})[name], (y.cvars or {})[name], "cvar " .. name) end
    if x.chat or y.chat then
        if not (x.chat and y.chat) then unv("chat windows unreadable on one side")
        else
            for i = 1, 10 do
                local p, q = x.chat[i], y.chat[i]
                if p or q then
                    local ps = p and (p.name .. ": " .. p.groups) or "none"
                    local qs = q and (q.name .. ": " .. q.groups) or "none"
                    if ps ~= qs then
                        if not p and q and ui.tabs and ui.tabs[q.name] then info("chat tab kept, as expected: " .. q.name)
                        else diff(("chat window %d: %s -> %s"):format(i, ps, qs)) end
                    end
                end
            end
            if x.chatSelected ~= y.chatSelected then
                info(("selected chat tab: %s -> %s"):format(tostring(x.chatSelected), tostring(y.chatSelected)))
            end
        end
    elseif required.chat then
        unv("chat windows not recorded on either side")
    end
    if x.meter or y.meter then
        if not (x.meter and y.meter) then unv("meter windows unreadable on one side")
        else
            for i = 1, 3 do
                local p, q = x.meter[i], y.meter[i]
                if (p or q) and p ~= q then
                    if ui.meter then info(("meter window %d as applied, as expected on this build: %s -> %s"):format(i, tostring(p), tostring(q)))
                    else diff(("meter window %d: %s -> %s"):format(i, tostring(p), tostring(q))) end
                end
            end
        end
    elseif required.meter then
        unv("meter windows not recorded on either side")
    end
end

-- { equal, diffs = {...}, unverified = {...}, info = {...} }. `equal` only
-- when both records exist, are valid, nothing is unverified and nothing
-- differs. `allow`: a multiset of macro keys `b` may hold beyond `a`. `ui`:
-- compare the UI parts too, with its exceptions (compareUI); nil leaves
-- them out, as the stress rehearsal does.
function NS.Compare(a, b, allow, ui)
    local out = { diffs = {}, unverified = {}, info = {} }
    local function diff(s) out.diffs[#out.diffs + 1] = s end
    local function unv(s) out.unverified[#out.unverified + 1] = s end
    if type(a) ~= "table" or type(b) ~= "table" then
        unv("a record is missing")
        out.equal = false
        return out
    end
    if not a.valid then unv("the first record is incomplete: " .. table.concat(a.why or {}, "; ")) end
    if not b.valid then unv("the second record is incomplete: " .. table.concat(b.why or {}, "; ")) end
    if a.guid ~= b.guid then unv("different characters") end
    if a.set ~= b.set then diff(("binding set %s -> %s"):format(tostring(a.set), tostring(b.set))) end
    for _, s in ipairs(COMPARED) do
        local x, y = a.slots[s], b.slots[s]
        if x == "unreadable" or y == "unreadable" then
            unv("slot " .. s .. " unreadable")
        elseif type(x) == "string" and x:find("^macro%?:") or type(y) == "string" and y:find("^macro%?:") then
            if x ~= y then diff(("slot %d: %s -> %s"):format(s, tostring(x), tostring(y)))
            else unv("slot " .. s .. ": " .. x .. " (macro name not unique)") end
        elseif x ~= y then
            diff(("slot %d: %s -> %s"):format(s, tostring(x or "empty"), tostring(y or "empty")))
        end
    end
    for _, s in ipairs(SPECIAL) do
        if a.special[s] ~= b.special[s] then
            out.info[#out.info + 1] = ("special slot %d: %s -> %s"):format(s, tostring(a.special[s]), tostring(b.special[s]))
        end
    end
    local ma, mb = multiset(a.macros), multiset(b.macros)
    local allowed = {}
    for k, n in pairs(allow or {}) do allowed[k] = n end
    for _, k in ipairs(sortedKeys(ma, mb)) do
        local x, y = ma[k] or 0, mb[k] or 0
        local name = k:match("^[^|]*|([^|]*)") or k
        if y < x then diff("macro gone or changed: " .. name)
        elseif y > x then
            local extra = y - x
            local ok = math.min(extra, allowed[k] or 0)
            if ok > 0 then out.info[#out.info + 1] = "macro kept, as expected: " .. name end
            if extra > ok then diff("macro added or changed: " .. name) end
        end
    end
    for _, k in ipairs(sortedKeys(a.keymap, b.keymap)) do
        if a.keymap[k] ~= b.keymap[k] then
            diff(("key %s: %s -> %s"):format(k, tostring(a.keymap[k] or "unbound"), tostring(b.keymap[k] or "unbound")))
        end
    end
    for _, c in ipairs(sortedKeys(a.cmdkeys, b.cmdkeys)) do
        if a.cmdkeys[c] ~= b.cmdkeys[c] then
            diff(("command %s: %s -> %s"):format(c, tostring(a.cmdkeys[c] or "no key"), tostring(b.cmdkeys[c] or "no key")))
        end
    end
    local pa, pb = a.pet, b.pet
    if pa or pb then
        if not (pa and pb) or pa.family ~= pb.family or pa.name ~= pb.name then
            unv("pet bar: not comparable (a different pet, or none, is out)")
        else
            for i = 1, 10 do
                if pa.slots[i] == "unreadable" or pb.slots[i] == "unreadable" then unv("pet slot " .. i .. " unreadable")
                elseif pa.slots[i] ~= pb.slots[i] then
                    diff(("pet slot %d: %s -> %s"):format(i, tostring(pa.slots[i] or "empty"), tostring(pb.slots[i] or "empty")))
                elseif pa.autocast[i] ~= pb.autocast[i] then
                    diff(("pet slot %d autocast: %s -> %s"):format(i, tostring(pa.autocast[i]), tostring(pb.autocast[i])))
                end
            end
        end
    end
    if ui then compareUI(a, b, ui, out) end
    out.equal = #out.diffs == 0 and #out.unverified == 0
    return out
end

-- The comparison as lines: verdict, then at most SHOWN_DIFFS differences.
local function report(title, c)
    say(("%s: %s (%d differences, %d unverified)"):format(title, c.equal and "EQUAL" or "NOT EQUAL", #c.diffs, #c.unverified))
    local shown = 0
    for _, group in ipairs({ { "  UNVERIFIED ", c.unverified }, { "  DIFF ", c.diffs }, { "  info ", c.info } }) do
        for _, line in ipairs(group[2]) do
            shown = shown + 1
            if shown <= SHOWN_DIFFS then say(group[1] .. line) end
        end
    end
    if shown > SHOWN_DIFFS then say(("  ... and %d more"):format(shown - SHOWN_DIFFS)) end
end

------------------------------------------------------------
-- The rehearsal: records bound to one run of the procedure
------------------------------------------------------------

local PROC = "stress"
local LABELS = { first = { before = true, afterLoad = true, afterExit = true, afterRestore = true, afterRestoreExit = true },
                 second = { before = true, afterLoad = true, afterExit = true } }

local function rehearsal()
    local R = DB and DB.rehearsal
    if type(R) ~= "table" or type(R.records) ~= "table" then
        error("no rehearsal: start the procedure from its first step", 0)
    end
    return R
end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local function catalog()
    local db = rawget(_G, "AltStableSyncDB")
    return type(db) == "table" and type(db.presets) == "table" and db.presets or {}
end

-- AltStableSync's state, as lines; returns loaded, not disabled.
function NS.State()
    local A = rawget(_G, "AltStableSync")
    if type(A) ~= "table" then say("AltStableSync: not loaded"); return false end
    local meta = api("C_AddOns")
    local version = meta and meta.GetAddOnMetadata and select(2, pcall(meta.GetAddOnMetadata, "AltStableSync", "Version"))
    local kinds = {}
    for _, e in pairs(catalog()) do
        if type(e) == "table" and not e.deleted then kinds[tostring(e.kind)] = (kinds[tostring(e.kind)] or 0) + 1 end
    end
    local parts = {}
    for k, n in pairs(kinds) do parts[#parts + 1] = k .. " " .. n end
    table.sort(parts)
    local link = type(A.Link) == "table" and A.Link or {}
    say(("AltStableSync %s, schema %s, disabled %s; catalog: %s; Link %s%s"):format(tostring(version),
        tostring(A.SCHEMA), tostring(A.disabled), #parts > 0 and table.concat(parts, ", ") or "empty",
        tostring(link.state), link.why and (" (" .. tostring(link.why) .. ")") or ""))
    return true, A.disabled == nil
end

-- Record `label` for `role` ("first" | "second") into the rehearsal. Refuses
-- (throws: the step stays) BEFORE reading anything when it's the wrong
-- character, the addon isn't ready, or, for a `before`, character
-- keybindings are off. Evidence is frozen once complete: when the label
-- already holds a complete record, Record keeps it, reads nothing, and the
-- step completes so its check runs again on that same evidence (after the
-- owner corrected an answer, say). Only a new rehearsal replaces it. An
-- incomplete record is taken again.
function NS.Capture(role, label)
    local R = rehearsal()
    assert(LABELS[role] and LABELS[role][label], "unknown record " .. tostring(role) .. " " .. tostring(label))
    local okG, guid = pcall(api("UnitGUID"), "player")
    if not okG or type(guid) ~= "string" then error("can't read this character's GUID", 0) end
    if role == "first" and guid ~= R.first then
        error("this isn't the first character of this rehearsal: log in that one", 0)
    elseif role == "second" then
        if guid == R.first then error("this is the first character: log in the second one", 0) end
        if R.second and guid ~= R.second then error("this isn't the second character of this rehearsal", 0) end
    end
    local mine = R.records[guid] or {}
    if mine[label] and mine[label].valid then
        local kept = ("%s %s: already recorded, kept (evidence is never replaced); checking it again"):format(role, label)
        say(kept)
        return kept
    end
    local A = rawget(_G, "AltStableSync")
    if type(A) ~= "table" or type(A.Ready) ~= "table" then error("AltStableSync isn't loaded", 0) end
    local okR, ready, why = pcall(A.Ready.IsReady)
    if not okR or not ready then error("not ready yet (" .. tostring(why) .. "): wait a moment, then Retry", 0) end
    if label == "before" then
        local okS, set = pcall(api("GetCurrentBindingSet"))
        if not okS or set ~= characterSet() then
            error("character keybindings are off: turn on Character Specific Keybindings, then Retry", 0)
        end
    end
    local r = NS.Record()
    if role == "second" then R.second = guid end
    R.records[guid] = mine
    mine[label] = r
    local summary = ("%s %s: %s, %d macros, %d keys%s"):format(role, label, r.valid and "complete" or "INCOMPLETE",
        #r.macros, count(r.keymap), r.pet and (", pet " .. tostring(r.pet.name)) or "")
    say(summary)
    if not r.valid then say("  incomplete (Back, then Record again): " .. table.concat(r.why, "; ")) end
    if r.addon.loaded then
        say(("  AltStableSync's last load: %s version %s"):format(tostring(r.addon.loaded.id), tostring(r.addon.loaded.version)))
    end
    if r.addon.newest then
        local fmt = api("date")
        local at = r.addon.newest.at
        say(("  AltStableSync's newest backup: %s (%s %s)"):format(fmt and type(at) == "number" and fmt("%H:%M:%S", at) or tostring(at),
            tostring(r.addon.newest.kind), tostring(r.addon.newest.name)))
    end
    return summary
end

local function rec(role, label)
    local R = DB and DB.rehearsal
    if type(R) ~= "table" then return nil end
    local guid = role == "first" and R.first or R.second
    return guid and R.records[guid] and R.records[guid][label]
end

------------------------------------------------------------
-- The procedure
------------------------------------------------------------

-- Steps by name, so a check can name the answers it relies on.
local STEPS, AT = { title = "Launch rehearsal: load, exit, restore, exit (A43)", rev = 1 }, {}
local function step(id, def)
    STEPS[#STEPS + 1] = def
    if id then AT[id] = #STEPS end
end

-- The owner's answer to step `id` in this run of the procedure: a check
-- passes only when every answer it relies on is Yes (No, Skip or no answer:
-- unverified). Read from the host's saved record, never changed.
local function yes(id)
    local fp = rawget(_G, "ForeverProbeDB")
    local recs = type(fp) == "table" and type(fp.steps) == "table" and type(fp.steps.records) == "table" and fp.steps.records
    local r = recs and recs["AltStableSyncProbe/" .. PROC]
    local res = type(r) == "table" and type(r.results) == "table" and r.results[AT[id]]
    return type(res) == "table" and res.status == "yes"
end

local QUESTION = {
    firstLoaded = "the first Load matched its preview", secondLoaded = "the second Load matched its preview",
    exit1 = "the first full exit", restored = "the Restore said it restored", exit2 = "the second full exit",
}
local function needs(...)
    for i = 1, select("#", ...) do
        local id = select(i, ...)
        if not yes(id) then return false, "unverified: no Yes for " .. QUESTION[id] .. " (step " .. AT[id] .. ")" end
    end
    return true
end

-- Equality is over the game state only (slots, macros, keys, the set, the
-- pet): times, run numbers and AltStableSync's own records are evidence,
-- never compared (NS.Compare).
local function same(role, a, b, allowFrom)
    local allow = allowFrom and NS.Extras(rec(role, "before"), rec(role, "afterLoad")) or nil
    local c = NS.Compare(rec(role, a), rec(role, b), allow)
    report(role .. " " .. a .. " vs " .. b, c)
    return c.equal, ("%d differences, %d unverified"):format(#c.diffs, #c.unverified)
end

local function differs(role)
    local c = NS.Compare(rec(role, "before"), rec(role, "afterLoad"))
    report(role .. " before vs afterLoad", c)
    if #c.unverified > 0 then return false, "unverified: " .. #c.unverified end
    if #c.diffs == 0 then return false, "nothing changed: pick a loadout that differs from this character" end
    return true, #c.diffs .. " changes"
end

local function gated(fn, ...)
    local ids = { ... }
    return function()
        local ok, why = needs(unpack(ids))
        local pass, detail = fn()
        if not ok then return false, why .. "; " .. tostring(detail) end
        return pass, detail
    end
end

local function restored(label)
    return function()
        local ok, detail = same("first", "before", label, true)
        if not ok then return false, detail end
        local moved = NS.Compare(rec("first", "afterLoad"), rec("first", label))
        if #moved.diffs == 0 then return false, "nothing was restored (it still matches afterLoad)" end
        return true, detail
    end
end

local function start()
    local loaded, enabled = NS.State()
    local okG, guid = pcall(api("UnitGUID"), "player")
    local stamp = api("time")
    DB.rehearsal = { id = stamp and stamp() or 0, first = okG and guid or nil, records = {} }
    say(("rehearsal %s started on %s"):format(tostring(DB.rehearsal.id), tostring(guid)))
    return loaded and enabled, "rehearsal " .. tostring(DB.rehearsal.id)
end

local function capture(role, label) return function() return NS.Capture(role, label) end end

step(nil, { text = "Start a new rehearsal on this (first) character. It reads AltStableSync's state.",
    button = "Start", run = start, check = function()
        local A = rawget(_G, "AltStableSync")
        return type(A) == "table" and A.disabled == nil, type(A) == "table" and "loaded" or "AltStableSync isn't loaded"
    end })
step(nil, { text = "Did anything on your bars, keys or macros change when you logged in?", ask = true })
step(nil, { text = "Turn on Character Specific Keybindings (Key Bindings) if they're off. Wait until /altsync says it's ready. Then press Next." })
step(nil, { text = "Record this character before any Load.", button = "Record", run = capture("first", "before"),
    screenshot = "first: before" })
step(nil, { text = "In /altsync, Load a loadout that differs from this character. Read its preview before you press Load. Then press Next." })
step("firstLoaded", { text = "Did the window say \"Loaded ...\", and do the bars, keys and macros now match what the preview listed?", ask = true })
step(nil, { text = "Record after the Load. The result notes AltStableSync's newest backup: the Restore later uses that one.",
    button = "Record", run = capture("first", "afterLoad"), check = gated(function() return differs("first") end, "firstLoaded"),
    screenshot = "first: after Load" })
step(nil, { text = "Log out, then log in a second character (a lower-level one if you can). Turn on its Character Specific Keybindings, wait for ready, then press Next." })
step(nil, { text = "Record the second character before its Load.", button = "Record", run = capture("second", "before") })
step(nil, { text = "Load a loadout on this character. Read its preview before you press Load. Then press Next." })
step("secondLoaded", { text = "Did the window say \"Loaded ...\", and do the bars, keys and macros now match what the preview listed?", ask = true })
step(nil, { text = "Record after the Load.", button = "Record", run = capture("second", "afterLoad"),
    check = gated(function() return differs("second") end, "secondLoaded"), screenshot = "second: after Load" })
step(nil, { text = "Exit the game FULLY (not /reload), relaunch, and log in this SECOND character again.", reload = "exit" })
step("exit1", { text = "Did you exit the game fully and relaunch it (not a /reload)?", ask = true })
step(nil, { text = "Wait until /altsync says it's ready, then record.", button = "Record", run = capture("second", "afterExit"),
    check = gated(function() return same("second", "afterLoad", "afterExit") end, "secondLoaded", "exit1") })
step(nil, { text = "Log out, then log in the FIRST character. Wait until /altsync says it's ready, then press Next." })
step(nil, { text = "Record the first character after the exit.", button = "Record", run = capture("first", "afterExit"),
    check = gated(function() return same("first", "afterLoad", "afterExit") end, "firstLoaded", "exit1") })
step(nil, { text = "Restore the backup the Load took (/altsync backups: the one step 7 noted, not a newer one). Then press Next." })
step("restored", { text = "Did the Restore's preview list changes, and did it then say it restored the backup?", ask = true })
step(nil, { text = "Record after the Restore.", button = "Record", run = capture("first", "afterRestore"),
    check = gated(restored("afterRestore"), "firstLoaded", "restored"), screenshot = "first: after Restore" })
step(nil, { text = "Exit the game FULLY (not /reload), relaunch, and log in this FIRST character again.", reload = "exit" })
step("exit2", { text = "Did you exit the game fully and relaunch it (not a /reload)?", ask = true })
step(nil, { text = "Wait until /altsync says it's ready, then record.", button = "Record", run = capture("first", "afterRestoreExit"),
    check = gated(restored("afterRestoreExit"), "firstLoaded", "restored", "exit2") })
step(nil, { text = "Type /reload (or press Reload now) so the results are written to disk.", reload = true })

Probe:Steps(PROC, STEPS)
NS.AT = AT
NS._checks = { differs = differs, restored = restored }

------------------------------------------------------------
-- The audit procedure (#95, docs/AUDIT.md section 5): one character, a UI
-- setup and a loadout applied before the first full exit, both restored by
-- their backup's name after it, a second full exit, then the short checks.
-- Records go to DB.audit, with the UI parts compared.
------------------------------------------------------------

local AUDIT = "audit"
local ALABELS = { before = true, afterUI = true, afterLoad = true, exit1 = true, afterRestoreL = true,
                  afterRestoreU = true, exit2 = true, accountBefore = true, accountAfter = true }

local function audit()
    local R = DB and DB.audit
    if type(R) ~= "table" or type(R.records) ~= "table" then error("no audit run: start it from its first step", 0) end
    return R
end

-- Like NS.Capture, for the audit's single character. Evidence is frozen
-- once complete.
function NS.AuditCapture(label)
    local R = audit()
    assert(ALABELS[label], "unknown audit record " .. tostring(label))
    local okG, guid = pcall(api("UnitGUID"), "player")
    if not okG or type(guid) ~= "string" then error("can't read this character's GUID", 0) end
    if guid ~= R.guid then error("this isn't the audit's character: log in that one", 0) end
    if R.records[label] and R.records[label].valid then
        local kept = label .. ": already recorded, kept (evidence is never replaced); checking it again"
        say(kept)
        return kept
    end
    local A = rawget(_G, "AltStableSync")
    if type(A) ~= "table" or type(A.Ready) ~= "table" then error("AltStableSync isn't loaded", 0) end
    local okR, ready, why = pcall(A.Ready.IsReady)
    if not okR or not ready then error("not ready yet (" .. tostring(why) .. "): wait a moment, then Retry", 0) end
    local r = NS.Record()
    R.records[label] = r
    local parts = {}
    for _, k in ipairs({ "layout", "bars", "chat", "meter" }) do if r.ui[k] ~= nil then parts[#parts + 1] = k end end
    local summary = ("%s: %s, %d macros, %d keys%s; UI parts read: %s%s"):format(label,
        r.valid and "complete" or "INCOMPLETE", #r.macros, count(r.keymap), r.pet and (", pet " .. tostring(r.pet.name)) or "",
        #parts > 0 and table.concat(parts, ", ") or "none", #r.ui.why > 0 and (" (not read: " .. table.concat(r.ui.why, "; ") .. ")") or "")
    say(summary)
    if not r.valid then say("  incomplete (Back, then Record again): " .. table.concat(r.why, "; ")) end
    local fmt = api("date")
    for i, b in ipairs(r.addon.backups or {}) do
        say(("  backup %d: %s (%s)"):format(i, tostring(b.reason or b.name), fmt and type(b.at) == "number" and fmt("%H:%M:%S", b.at) or tostring(b.at)))
    end
    return summary
end

local function arec(label) return DB and type(DB.audit) == "table" and DB.audit.records[label] end

-- Steps by name, as the stress procedure does.
local ASTEPS, AAT = { title = "Audit: apply a UI setup and a loadout, exit, restore both, exit (#95)", rev = 1 }, {}
local function astep(id, def)
    ASTEPS[#ASTEPS + 1] = def
    if id then AAT[id] = #ASTEPS end
end
local function ayes(id)
    local fp = rawget(_G, "ForeverProbeDB")
    local recs = type(fp) == "table" and type(fp.steps) == "table" and type(fp.steps.records) == "table" and fp.steps.records
    local r = recs and recs["AltStableSyncProbe/" .. AUDIT]
    local res = type(r) == "table" and type(r.results) == "table" and r.results[AAT[id]]
    return type(res) == "table" and res.status == "yes"
end
local AQUESTION = {
    applied = "the Apply matched its preview", loaded = "the Load matched its preview", exit1 = "the first full exit",
    restoredL = "the loadout's Restore said it restored", restoredU = "the UI setup's Restore said it restored",
    exit2 = "the second full exit",
}
local function aneeds(...)
    for i = 1, select("#", ...) do
        local id = select(i, ...)
        if not ayes(id) then return false, "unverified: no Yes for " .. AQUESTION[id] .. " (step " .. AAT[id] .. ")" end
    end
    return true
end
local function agated(fn, ...)
    local ids = { ... }
    return function()
        local ok, why = aneeds(unpack(ids))
        local pass, detail = fn()
        if not ok then return false, why .. "; " .. tostring(detail) end
        return pass, detail
    end
end

-- The chat tabs the apply created: in afterUI, not in before.
local function createdTabs()
    local a, b = arec("before"), arec("afterUI")
    local out = {}
    if not (a and b and a.ui and b.ui and a.ui.chat and b.ui.chat) then return out end
    local had = {}
    for _, w in pairs(a.ui.chat) do had[w.name] = true end
    for _, w in pairs(b.ui.chat) do if not had[w.name] then out[w.name] = true end end
    return out
end
-- Did the apply open meter window 2 (so a restore can't hide it on Forever)?
local function openedMeter()
    local a, b = arec("before"), arec("afterUI")
    local function shown(r) return r and r.ui and r.ui.meter and r.ui.meter[2] and r.ui.meter[2]:find("^shown") ~= nil end
    return not shown(a) and shown(b)
end
-- The audit's view of the UI parts: every part it claims to verify must have
-- been read on both sides, else the comparison is unverified (compareUI).
local UI_REQUIRED = { layout = true, bars = true, cvars = true, chat = true, meter = true }
local UI_FULL = { tabs = {}, meter = false, require = UI_REQUIRED }

local function acompare(title, x, y, allow, ui)
    local c = NS.Compare(arec(x), arec(y), allow, ui)
    report(title, c)
    return c
end
local function uiDiffs(c)
    local n = 0
    for _, d in ipairs(c.diffs) do
        if d:find("^layout") or d:find("^bar toggles") or d:find("^cvar ") or d:find("^chat window") or d:find("^meter window") then n = n + 1 end
    end
    return n
end
-- The UI setup changed UI parts and nothing else.
local function uiChanged()
    local c = acompare("before vs afterUI", "before", "afterUI", nil, UI_FULL)
    if #c.unverified > 0 then return false, "unverified: " .. #c.unverified end
    local n = uiDiffs(c)
    if n == 0 then return false, "no UI part changed: pick a setup that differs from this character" end
    if n < #c.diffs then return false, (#c.diffs - n) .. " non-UI differences: a UI setup must not touch bars, macros or keys" end
    return true, n .. " UI changes"
end
-- The loadout changed game state and no UI part.
local function gameChanged()
    local c = acompare("afterUI vs afterLoad", "afterUI", "afterLoad", nil, UI_FULL)
    if #c.unverified > 0 then return false, "unverified: " .. #c.unverified end
    local n = uiDiffs(c)
    if n > 0 then return false, n .. " UI parts changed by a loadout" end
    if #c.diffs == 0 then return false, "nothing changed: pick a loadout that differs from this character" end
    return true, #c.diffs .. " changes"
end
local function persisted(x, y)
    return function()
        local c = acompare(x .. " vs " .. y, x, y, nil, UI_FULL)
        return c.equal, ("%d differences, %d unverified"):format(#c.diffs, #c.unverified)
    end
end
-- D3: the key another addon set without saving is saved by our load.
local function otherKeySaved()
    local r = arec("exit1")
    if not r then return false, "no exit1 record" end
    local v = r.keymap["CTRL-F11"]
    return v == "TOGGLEAUTORUN", "CTRL-F11 after the exit: " .. tostring(v or "unbound") .. " (expected TOGGLEAUTORUN: our save persisted it, as the preview said)"
end
-- The loadout's restore: game state back to afterUI except the created
-- macros; UI parts unchanged.
local function restoredL()
    local allow = NS.Extras(arec("afterUI"), arec("afterLoad"))
    local c = acompare("afterUI vs afterRestoreL", "afterUI", "afterRestoreL", allow, UI_FULL)
    if not c.equal then return false, ("%d differences, %d unverified"):format(#c.diffs, #c.unverified) end
    local moved = NS.Compare(arec("afterLoad"), arec("afterRestoreL"))
    if #moved.diffs == 0 then return false, "nothing was restored (it still matches afterLoad)" end
    return true, "exact, except the kept macros"
end
-- The UI setup's restore: UI back to before except the created tabs and,
-- when the apply opened meter window 2, the meter part; game state as
-- after the loadout's restore.
local function restoredU()
    local ui = { tabs = createdTabs(), meter = openedMeter(), require = UI_REQUIRED }
    local c = acompare("before vs afterRestoreU (UI)", "before", "afterRestoreU", NS.Extras(arec("afterUI"), arec("afterLoad")), ui)
    if not c.equal then return false, ("%d differences, %d unverified"):format(#c.diffs, #c.unverified) end
    local same = NS.Compare(arec("afterRestoreL"), arec("afterRestoreU"))
    if #same.diffs > 0 then return false, "the UI restore changed bars, macros or keys: " .. #same.diffs end
    return true, ui.meter and "exact, except the kept tabs and the meter part (window 2 was opened)" or "exact, except the kept tabs"
end
-- Keys per command (H4): after the owner's third SetBinding on button 1.
local function keysOnButton1()
    local p = { pcall(api("GetBindingKey"), "ACTIONBUTTON1") }
    if not p[1] then return nil, "GetBindingKey failed" end
    local keys = {}
    for i = 2, #p do if type(p[i]) == "string" then keys[#keys + 1] = p[i] end end
    say("ACTIONBUTTON1 keys: " .. table.concat(keys, ", "))
    return #keys, table.concat(keys, ", ")
end
-- A restore under Account bindings: actions moved, keys identical.
local function accountRestore()
    local a, b = arec("accountBefore"), arec("accountAfter")
    if not (a and b) then return false, "records missing" end
    local c = NS.Compare(a, b)
    local keys = 0
    for _, d in ipairs(c.diffs) do if d:find("^key ") or d:find("^command ") then keys = keys + 1 end end
    if keys > 0 then return false, keys .. " key differences: a restore under Account bindings must not touch keys" end
    if #c.diffs == 0 then return false, "nothing restored" end
    return true, #c.diffs .. " changes, no key touched"
end

local function astart()
    local loaded, enabled = NS.State()
    local okG, guid = pcall(api("UnitGUID"), "player")
    local stamp = api("time")
    DB.audit = { id = stamp and stamp() or 0, guid = okG and guid or nil, records = {} }
    say(("audit %s started on %s"):format(tostring(DB.audit.id), tostring(guid)))
    return loaded and enabled, "audit " .. tostring(DB.audit.id)
end
local function acapture(label) return function() return NS.AuditCapture(label) end end

astep(nil, { text = "Start the audit on this character. It reads AltStableSync's state.", button = "Start", run = astart,
    check = function()
        local A = rawget(_G, "AltStableSync")
        return type(A) == "table" and A.disabled == nil, type(A) == "table" and "loaded" or "AltStableSync isn't loaded"
    end })
astep(nil, { text = "Set up: Character Specific Keybindings ON; a pet out if you have one; the damage meter's window 2 CLOSED (the setup should open it); no AltStableSync window open. Then press Next." })
astep(nil, { text = "Another addon's unsaved key: type  /run SetBinding(\"CTRL-F11\",\"TOGGLEAUTORUN\")  (no save). Then press Next." })
astep(nil, { text = "Record this character before anything.", button = "Record", run = acapture("before"), screenshot = "audit: before" })
astep(nil, { text = "Apply a UI setup U that differs (layout, bars, a setting, a chat tab, the meter with window 2). Read its preview. Click Later on the reload prompt. Then press Next." })
astep("applied", { text = "Did it say \"Applied ...\", and did the layout, settings, chat and meter change as the preview listed? (Bars show after a reload.)", ask = true })
astep(nil, { text = "Record after the UI setup.", button = "Record", run = acapture("afterUI"), check = agated(uiChanged, "applied"), screenshot = "audit: after UI" })
astep(nil, { text = "Load a loadout L that differs: a macro to create, one to update, keys, a pet bar if a pet is out. Read its preview: it should say your keybindings are saved. Then press Next." })
astep("loaded", { text = "Did it say \"Loaded ...\", and do the bars, keys, macros and pet bar match the preview?", ask = true })
astep(nil, { text = "Record after the Load. The result lists your backups by name and time: the two restores later use \"load L\" and \"UI setup U\".",
    button = "Record", run = acapture("afterLoad"), check = agated(gameChanged, "loaded"), screenshot = "audit: after Load" })
astep(nil, { text = "Exit the game FULLY (not /reload), relaunch, and log this character in again.", reload = "exit" })
astep("exit1", { text = "Did you exit the game fully and relaunch it (not a /reload)?", ask = true })
astep(nil, { text = "Wait until /altsync says it's ready, then record. Everything applied should have persisted, bars included.",
    button = "Record", run = acapture("exit1"), check = agated(persisted("afterLoad", "exit1"), "applied", "loaded", "exit1") })
astep(nil, { text = "Check: CTRL-F11 still bound after the exit (our save persisted the other addon's unsaved key, as the preview said).",
    button = "Check", run = otherKeySaved, check = agated(otherKeySaved, "exit1") })
astep(nil, { text = "Are Action Bars 2-8 shown on screen exactly as the UI setup says (the toggles and the layout agree)?", ask = true })
astep(nil, { text = "In Backups..., select the backup named \"load L\" (its time matches your Load) and Restore. Read the preview: it names the macros it keeps. Then press Next." })
astep("restoredL", { text = "Did it say \"Restored ...\" without \"Partial\"?", ask = true })
astep(nil, { text = "Record after the loadout's restore.", button = "Record", run = acapture("afterRestoreL"),
    check = agated(restoredL, "loaded", "restoredL"), screenshot = "audit: after Restore L" })
astep(nil, { text = "In Backups..., select the backup named \"UI setup U\" and Restore. Read the preview: the created tab is kept; on this build the meter may say it can't be restored. Click Later on the reload prompt. Then press Next." })
astep("restoredU", { text = "Did it say \"Restored ...\" (Partial is expected when the meter part was left)?", ask = true })
astep(nil, { text = "Record after the UI setup's restore.", button = "Record", run = acapture("afterRestoreU"),
    check = agated(restoredU, "applied", "restoredU"), screenshot = "audit: after Restore U" })
astep(nil, { text = "Exit the game FULLY (not /reload), relaunch, and log this character in again.", reload = "exit" })
astep("exit2", { text = "Did you exit the game fully and relaunch it (not a /reload)?", ask = true })
astep(nil, { text = "Wait until ready, then record. Both restores should have persisted.", button = "Record", run = acapture("exit2"),
    check = agated(persisted("afterRestoreU", "exit2"), "restoredL", "restoredU", "exit2") })
astep(nil, { text = "Are Action Bars 2-8 shown exactly as before the audit (the UI setup's bar changes undone)?", ask = true })
astep(nil, { text = "Keys per command: type  /run SetBinding(\"CTRL-F10\",\"ACTIONBUTTON1\")  as a THIRD key on button 1 (it needs two already). Then press Check.",
    button = "Check", run = keysOnButton1, check = function()
        local n, detail = keysOnButton1()
        return n ~= nil and n >= 3, tostring(n) .. " keys: " .. tostring(detail)
    end })
astep(nil, { text = "Type  /run SetBinding(\"CTRL-F10\")  and  /run SetBinding(\"CTRL-F11\")  to unbind the test keys (no save needed; a /reload drops unsaved keys). Then press Next." })
astep(nil, { text = "Restore under Account bindings: Load L again (Character bindings). Then untick Character Specific Keybindings in Settings (Blizzard deletes the set). Wait for ready, then press Record.",
    button = "Record", run = acapture("accountBefore") })
astep(nil, { text = "In Backups..., Restore the newest \"load L\". Its preview must say the bindings are not changed. Confirm. Then press Record.",
    button = "Record", run = acapture("accountAfter"), check = accountRestore })
astep(nil, { text = "Turn Character Specific Keybindings back on if you use them. Type /reload (or press Reload now) so the results are written to disk.", reload = true })

Probe:Steps(AUDIT, ASTEPS)
NS.AAT = AAT
NS._audit = { uiChanged = uiChanged, gameChanged = gameChanged, restoredL = restoredL, restoredU = restoredU,
              otherKeySaved = otherKeySaved, accountRestore = accountRestore, createdTabs = createdTabs, openedMeter = openedMeter,
              UI_REQUIRED = UI_REQUIRED }

------------------------------------------------------------
-- Commands (on-demand records go to DB.adhoc, never the rehearsal)
------------------------------------------------------------

Probe:Command("state", function() NS.State() end, "AltStableSync's version, schema, catalog and Link")

Probe:Command("record", function(args)
    local label = tostring(args or ""):match("^%s*(%S+)")
    if not label then say("/fp sync record <label>") return end
    local r = NS.Record()
    DB.adhoc[label] = r
    say(("adhoc %s: %s, %d macros, %d keys"):format(label, r.valid and "complete" or "INCOMPLETE", #r.macros, count(r.keymap)))
    if not r.valid then say("  incomplete: " .. table.concat(r.why, "; ")) end
end, "record this character now, as <label> (outside the rehearsal)")

Probe:Command("diff", function(args)
    local a, b, ui = tostring(args or ""):match("^%s*(%S+)%s+(%S+)%s*(%S*)")
    if not a then say("/fp sync diff <label> <label> [ui]") return end
    report("adhoc " .. a .. " vs " .. b, NS.Compare(DB.adhoc[a], DB.adhoc[b], nil, ui == "ui" and UI_FULL or nil))
end, "compare two on-demand records; add `ui` to compare the UI parts too")

Probe:Command("backups", function()
    local r = NS.Record()
    local fmt = api("date")
    if not r.addon.backups or #r.addon.backups == 0 then say("no backups in the ring") return end
    for i, b in ipairs(r.addon.backups) do
        say(("  %d: %s (%s)"):format(i, tostring(b.reason or b.name), fmt and type(b.at) == "number" and fmt("%H:%M:%S", b.at) or tostring(b.at)))
    end
end, "AltStableSync's backups by name and time (an index shifts with every restore)")

Probe:Command("clear", function() Probe:ClearLog(); say("log cleared") end, "empty the saved log")

------------------------------------------------------------
-- Load
------------------------------------------------------------

local boot = CreateFrame("Frame")
Probe:RegisterEvents(boot, { "ADDON_LOADED" })
boot:SetScript("OnEvent", function(_, _, name)
    if name ~= ADDON then return end
    Probe:Ready()
    if type(AltStableSyncProbeDB) ~= "table" then AltStableSyncProbeDB = {} end
    DB = AltStableSyncProbeDB
    -- The old /syncprobe kept other keys here too: left alone, never reset.
    if type(DB.log) ~= "table" then DB.log = {} end
    if type(DB.adhoc) ~= "table" then DB.adhoc = {} end
    Probe:UseLog(DB.log, MAX_LOG)
    DB.loads = (DB.loads or 0) + 1
    say("loaded (" .. DB.loads .. " loads). /fp steps sync stress, /fp steps sync audit, or /fp sync for the commands")
end)

NS._test = { Probe = Probe, DB = function() return DB end }
