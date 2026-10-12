--[[
    AltStableSyncProbe - measures, on the live client, what AltStableSync's
    design depends on and no sibling probe has measured yet (issue #2).

    A throwaway diagnostic. It never ships (it lives under Tools/, which
    .pkgmeta ignores) and is deployed by Tools/deploy-probe.ps1.

    What siblings ALREADY measured is cited in issue #2 and is not re-probed
    here: one spec per class, ranks as separate spell IDs, macros start at
    121, Edit Mode layout order, SavedVariables persistence, ...

    Helpers (Record/Section/Call/ValStr, the copy window) are taken from
    ..\AltStable\Tools\AltStableProbe\Probe.lua; the CVar restart test follows
    ..\PortalRoulette\Tools\PortalRouletteProbe.

    Usage in game (out of combat):
        /syncprobe                 every read-only section
        /syncprobe <section>       client | actions | ranks | login | editmode | encoding
        /syncprobe place           place a known spell in an EMPTY slot, read it back, clear it
        /syncprobe bars [label]    #5: bar button -> action slot, slots 1-200, form/page state,
                                   action-bar binding commands (read-only); label = the state,
                                   e.g. "bear" or "page2" (each label is kept separately)
        /syncprobe bars write <n>  #5: write a test spell into slot n ONLY if it is empty, read it
                                   back, take it off again, verify slot and cursor are empty
        /syncprobe pet [label]     #47: pet family/name/GUID, pet bar 1-10, pet spellbook, autocast,
                                   BONUSACTIONBUTTON keys; compares with the last read of the same
                                   pet and the same family (dismiss/resummon, swap, full exit)
        /syncprobe pet swap <a> <b>  swap two filled pet slots by code, read back, swap back
        /syncprobe pet write <n> [book]  put a pet ability into EMPTY pet slot n, read back, remove it
        /syncprobe pet move <j> <i>  move filled slot j into EMPTY slot i (two calls), back, then
                                   pick j up and put it straight back
        /syncprobe pet readd <n>   take the ability in slot n off the bar and put it back from the
                                   pet spellbook; autocast before/after (run with autocast ON and OFF)
        /syncprobe pet autocast <n> [book]  toggle autocast on slot n, read it, toggle it back
                                   (book: through C_SpellBook.SetSpellBookItemAutoCastEnabled)
        /syncprobe macro           create the test character macro (restart test)
        /syncprobe macroedit [slot]  #6: put the test macro in an EMPTY action slot (default: the
                                   first empty of 1-72), EditMacro its body and icon, read back
                                   (restart test; clean deletes it and reads the slot after)
        /syncprobe macroedit combat  IN COMBAT: EditMacro to the same body; blocked or not?
        /syncprobe bind            bind CTRL-SHIFT-F11 in the CHARACTER binding set (restart test)
        /syncprobe cvar            write a marker CVar (restart test)
        /syncprobe layouts         #29/#58 (read-only): saved layouts with content sums, Blizzard's
                                   copy, this character's load records, bar toggles, damage meter
        /syncprobe layoutadd       add an ACCOUNT layout "SyncProbe" (a copy of the active one) with
                                   SaveLayouts + OnLayoutAdded; backup first (restart test). Log
                                   another character in BEFORE this, so its load record exists
        /syncprobe layoutupdate    replace SyncProbe's content in place (SaveLayouts only)
        /syncprobe layoutactivate  SetActiveLayout to SyncProbe, then back by name
        /syncprobe layoutclean     remove SyncProbe, compare every other layout with the backup
        /syncprobe bartoggle <n>   flip bar n's visibility (2-8), read back, flip it back
        /syncprobe restart         after a FULL EXIT: what survived (macro, bind, cvar, SVs)
        /syncprobe clean           undo macro, bind and cvar
        /syncprobe copy            reopen the copy window (Ctrl+A, Ctrl+C)

    Results also land in AltStableSyncProbeDB / AltStableSyncProbeCharDB:
        WTF\Account\<id>\SavedVariables\AltStableSyncProbe.lua
]]

local ADDON = ...

local lines = {}

local function Out(s)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[syncprobe]|r " .. tostring(s))
end

local function Record(s)
    lines[#lines + 1] = tostring(s)
    Out(s)
end

local function Section(name)
    Record(" ")
    Record("|cffffd100== " .. name .. " ==|r")
end

local function ValStr(v, depth)
    local t = type(v)
    if t == "nil" then return "nil" end
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "table" then
        if (depth or 0) <= 0 then return "{...}" end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        if #keys == 0 then return "{}" end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for i = 1, #keys do
            parts[#parts + 1] = tostring(keys[i]) .. "=" .. ValStr(v[keys[i]], (depth or 1) - 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return "<" .. t .. ">"
end

-- The return tuple with positions preserved, INCLUDING trailing nils.
-- Returns true, ... when the call ran; false when it was ABSENT or THREW.
local function Call(label, fn, ...)
    if type(fn) ~= "function" then
        Record(("%-44s ABSENT (%s)"):format(label, type(fn)))
        return false
    end
    local function handle(ok, ...)
        if not ok then
            Record(("%-44s THREW: %s"):format(label, tostring((...))))
            return false
        end
        local n = select("#", ...)
        if n == 0 then Record(("%-44s (no returns)"):format(label)); return true end
        local parts = {}
        for i = 1, n do parts[#parts + 1] = "[" .. i .. "]=" .. ValStr((select(i, ...)), 2) end
        Record(("%-44s %d: %s"):format(label, n, table.concat(parts, "  ")))
        return true, ...
    end
    return handle(pcall(fn, ...))
end

local function Stamp() return date("%Y-%m-%d %H:%M:%S") end

local function Build() return select(2, GetBuildInfo()) end

local function DB()
    AltStableSyncProbeDB = AltStableSyncProbeDB or {}
    return AltStableSyncProbeDB
end

local function CharDB()
    AltStableSyncProbeCharDB = AltStableSyncProbeCharDB or {}
    return AltStableSyncProbeCharDB
end

local BANK = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0

-- Every player spellbook item: { index, info } in book order.
local function SpellBook()
    local out = {}
    local ok, n = pcall(C_SpellBook.GetNumSpellBookSkillLines)
    if not ok or type(n) ~= "number" then return out end
    for line = 1, n do
        local okL, li = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
        if okL and type(li) == "table" and li.itemIndexOffset and li.numSpellBookItems then
            for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                local okI, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, BANK)
                if okI and type(info) == "table" then
                    out[#out + 1] = { index = i, info = info, line = li.name }
                end
            end
        end
    end
    return out
end

-- Taint watch: anything Blizzard blocks while a section runs is recorded.
local blocked = {}
local taintFrame = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    pcall(taintFrame.RegisterEvent, taintFrame, e)
end
taintFrame:SetScript("OnEvent", function(_, event, addon, fn)
    blocked[#blocked + 1] = ("%s %s %s"):format(event, tostring(addon), tostring(fn))
end)

local function TaintSince(mark)
    if #blocked == mark then return "none" end
    local t = {}
    for i = mark + 1, #blocked do t[#t + 1] = blocked[i] end
    return table.concat(t, " | ")
end

----------------------------------------------------------------------------
-- Edit Mode layouts (#29, #58): helpers for the layout sections, the login
-- record and restart. Indices count the presets first, as
-- C_EditMode.GetLayouts().activeLayout does (measured on 70245).
----------------------------------------------------------------------------

local LAYOUT_NAME = "SyncProbe"
local LT = (Enum and Enum.EditModeLayoutType) or { Preset = 0, Account = 1, Character = 2 }
local MAX_LAYOUTS = (Constants and Constants.EditModeConsts and Constants.EditModeConsts.EditModeMaxLayoutsPerType) or 5

-- Adler-32 of a layout string. Re-encoding is stable (70245), so equal sums
-- mean equal content.
local function Sum(s)
    if type(s) ~= "string" then return nil end
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return ("%04x%04x"):format(b, a)
end

local function Encode(layout)
    local ok, s = pcall(C_EditMode.ConvertLayoutInfoToString, layout)
    if ok and type(s) == "string" then return s end
end

-- A copy of Blizzard's preset layouts: the list SaveLayouts is given starts
-- with them, as EditModeManagerFrame passes it.
local function Presets()
    local ok, p = pcall(function() return EditModePresetLayoutManager:GetCopyOfPresetLayouts() end)
    if ok and type(p) == "table" then return p end
end

-- { active, activeName, presets, list = { { index, name, type, systems, str, sum } } },
-- plus the raw GetLayouts() result and the presets copy.
local function LayoutSnapshot()
    if not C_EditMode then return nil end
    local ok, info = pcall(C_EditMode.GetLayouts)
    if not ok or type(info) ~= "table" or type(info.layouts) ~= "table" then return nil end
    local presets = Presets()
    local np = presets and #presets
        or (Enum and Enum.EditModePresetLayoutsMeta and Enum.EditModePresetLayoutsMeta.NumValues) or 2
    local snap = { active = info.activeLayout, presets = np, list = {} }
    for i, l in ipairs(info.layouts) do
        local s = Encode(l)
        snap.list[i] = { index = np + i, name = l.layoutName, type = l.layoutType,
                         systems = type(l.systems) == "table" and #l.systems or -1, str = s, sum = Sum(s) }
    end
    local a = tonumber(info.activeLayout)
    if a and a > np then
        local e = snap.list[a - np]
        snap.activeName = e and e.name
    elseif a and presets and presets[a] then
        snap.activeName = "preset:" .. tostring(presets[a].layoutName)
    end
    return snap, info, presets
end

local function FindByName(snap, name)
    for _, e in ipairs(snap.list) do
        if e.name == name then return e end
    end
end

-- Blizzard's own copy of the layouts. Edit Mode saves THIS list, so if it
-- misses our write, its next save drops it.
local function BlizzardCopyLine(snap)
    local f = _G.EditModeManagerFrame
    local li = f and f.layoutInfo
    if type(li) ~= "table" or type(li.layouts) ~= "table" then return "none (EditModeManagerFrame.layoutInfo)" end
    local names, inStep = {}, li.activeLayout == snap.active and #li.layouts - snap.presets == #snap.list
    for i, l in ipairs(li.layouts) do
        names[#names + 1] = tostring(l.layoutName)
        if i > snap.presets then
            local e = snap.list[i - snap.presets]
            if not e or e.name ~= l.layoutName or e.sum ~= Sum(Encode(l)) then inStep = false end
        end
    end
    return ("%d layouts, active=%s, names+content in step: %s [%s]"):format(#li.layouts,
        tostring(li.activeLayout), tostring(inStep), table.concat(names, ", ")), inStep
end

-- EDIT_MODE_LAYOUTS_UPDATED: when the client tells Blizzard's copy to refresh.
local layoutEvents = {}
local layoutEventFrame = CreateFrame("Frame")
pcall(layoutEventFrame.RegisterEvent, layoutEventFrame, "EDIT_MODE_LAYOUTS_UPDATED")
layoutEventFrame:SetScript("OnEvent", function(_, _, info, reconcile)
    local okT = type(info) == "table"
    layoutEvents[#layoutEvents + 1] = ("t=%.1f saved=%s active=%s reconcile=%s"):format(GetTime(),
        okT and type(info.layouts) == "table" and #info.layouts or "?", okT and tostring(info.activeLayout) or "?",
        tostring(reconcile))
end)

local function EventsSince(mark)
    if #layoutEvents == mark then return "none" end
    local t = {}
    for i = mark + 1, #layoutEvents do t[#t + 1] = layoutEvents[i] end
    return table.concat(t, " | ")
end

-- Each character's active layout at every load, by index AND name: adding
-- an Account layout may move other characters (their active layout is an index).
local function RecordLoginLayout(isLogin)
    local snap = LayoutSnapshot()
    if not snap then return end
    local cdb = CharDB()
    cdb.layoutLogins = cdb.layoutLogins or {}
    table.insert(cdb.layoutLogins, { at = Stamp(), login = isLogin, active = snap.active, name = snap.activeName,
                                     saved = #snap.list })
    while #cdb.layoutLogins > 5 do table.remove(cdb.layoutLogins, 1) end
end

local function LoginRecordLines(cdb)
    local l = cdb.layoutLogins or {}
    for i = math.max(1, #l - 2), #l do
        Record(("%-44s %s %s active=%s (%s) saved=%s"):format("load record " .. i .. "/" .. #l, tostring(l[i].at),
            l[i].login == true and "login" or l[i].login == false and "/reload" or "?", ValStr(l[i].active),
            ValStr(l[i].name), ValStr(l[i].saved)))
    end
end

local P = {}

----------------------------------------------------------------------------
-- client: identity, sets, constants
----------------------------------------------------------------------------

function P.client()
    Section("client")
    Call("GetBuildInfo()", GetBuildInfo)
    Record(("%-44s %s"):format("WOW_PROJECT_ID", ValStr(WOW_PROJECT_ID)))
    Record(("%-44s %s"):format("WOW_PROJECT_MAINLINE", ValStr(WOW_PROJECT_MAINLINE)))
    Call("GetCurrentRegion()", GetCurrentRegion)
    Call("GetCurrentRegionName()", GetCurrentRegionName)
    Call("GetNumSpecGroups()", GetNumSpecGroups)
    Call("C_SpecializationInfo.GetActiveSpecGroup()", C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup)
    Call("GetCurrentBindingSet()", GetCurrentBindingSet)
    Record(("%-44s %s"):format("Enum.BindingSet", ValStr(Enum and Enum.BindingSet, 1)))
    Record(("%-44s %s"):format("Constants.MacroConsts", ValStr(Constants and Constants.MacroConsts, 1)))
    Call("GetNumMacros()", GetNumMacros)
    Call("GetNumBindings()", GetNumBindings)
    Record(("%-44s %s"):format("C_EncodingUtil", ValStr(C_EncodingUtil and "present" or nil)))
    local db, cdb = DB(), CharDB()
    Record(("%-44s account %s, character %s"):format("probe SV loadCount", ValStr(db.loadCount), ValStr(cdb.loadCount)))
end

----------------------------------------------------------------------------
-- actions: GetActionInfo shape per type
----------------------------------------------------------------------------

function P.actions()
    Section("actions  (GetActionInfo shapes, slots 1-200)")
    local seen, counts, firstEmpty = {}, {}, nil
    for slot = 1, 200 do
        local ok, a, b, c = pcall(GetActionInfo, slot)
        local kind = ok and (a or "empty") or "THREW"
        counts[kind] = (counts[kind] or 0) + 1
        if kind == "empty" and not firstEmpty then firstEmpty = slot end
        if not seen[kind] then
            seen[kind] = true
            Call(("GetActionInfo(%d)  [first %s]"):format(slot, kind), GetActionInfo, slot)
            if kind == "spell" then
                Call(("  C_ActionBar.GetSpell(%d)"):format(slot), C_ActionBar and C_ActionBar.GetSpell, slot)
                Call(("  GetActionText(%d)"):format(slot), GetActionText, slot)
            elseif kind == "macro" then
                Call(("  GetMacroInfo(%s)"):format(tostring(b)), GetMacroInfo, b)
                Call(("  GetActionText(%d)"):format(slot), GetActionText, slot)
            end
        end
    end
    local parts = {}
    for k, n in pairs(counts) do parts[#parts + 1] = k .. "=" .. n end
    table.sort(parts)
    Record(("%-44s %s"):format("counts", table.concat(parts, "  ")))
    Record(("%-44s %s"):format("first empty slot", ValStr(firstEmpty)))
end

----------------------------------------------------------------------------
-- ranks: low-rank flags and base-spell mapping
----------------------------------------------------------------------------

-- Castable player spells grouped by name, each group's entries carrying the
-- client's own low-rank flag. Book order is NOT assumed to be rank order.
local function IsLearnedSpell(info)
    local T = Enum and Enum.SpellBookItemType
    if T and T.Spell ~= nil and info.itemType ~= T.Spell then return false end
    return info.spellID ~= nil and info.name ~= nil and not info.isPassive
end

local function RankGroups()
    local groups, order = {}, {}
    for _, e in ipairs(SpellBook()) do
        local i = e.info
        if IsLearnedSpell(i) then
            local okL, low = pcall(C_SpellBook.IsSpellBookItemLowRank, e.index, BANK)
            local g = groups[i.name]
            if not g then g = {}; groups[i.name] = g; order[#order + 1] = i.name end
            local dup = false
            for _, x in ipairs(g) do if x.id == i.spellID then dup = true end end
            if not dup then
                g[#g + 1] = { id = i.spellID, index = e.index, sub = i.subName, low = okL and low or false, lowOk = okL,
                              itemType = i.itemType }
            end
        end
    end
    local multi = {}
    for _, name in ipairs(order) do
        if #groups[name] > 1 then multi[#multi + 1] = { name = name, ranks = groups[name] } end
    end
    return multi
end

function P.ranks()
    Section("ranks  (IsSpellBookItemLowRank / GetBaseSpell / FindBaseSpellByID)")
    local multi = RankGroups()
    Record(("%-44s %d"):format("castable spells with >1 rank in the book", #multi))
    for gi = 1, math.min(#multi, 6) do
        local g = multi[gi]
        Record("-- " .. g.name)
        for _, r in ipairs(g.ranks) do
            Record(("   id=%-7s sub=%-10s lowRank=%s itemType=%s"):format(tostring(r.id), ValStr(r.sub),
                r.lowOk and ValStr(r.low) or "THREW", ValStr(r.itemType)))
            Call("     C_Spell.GetBaseSpell(id)", C_Spell.GetBaseSpell, r.id)
            Call("     FindBaseSpellByID(id)", FindBaseSpellByID, r.id)
            Call("     C_Spell.GetOverrideSpell(id)", C_Spell.GetOverrideSpell, r.id)
            Call("     C_SpellBook.FindSpellBookSlotForSpell(id)", C_SpellBook.FindSpellBookSlotForSpell, r.id)
        end
    end
    if #multi == 0 then Record("no multi-rank spells in this spellbook - try a character above level ~10") end
end

----------------------------------------------------------------------------
-- login: event order, recorded from file load
----------------------------------------------------------------------------

local loginLog = {}
local loginT0 = debugprofilestop and debugprofilestop() or 0
local LOGIN_EVENTS = { "ADDON_LOADED", "SPELLS_CHANGED", "UPDATE_MACROS", "UPDATE_BINDINGS",
                       "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "ACTIONBAR_SLOT_CHANGED",
                       "EDIT_MODE_LAYOUTS_UPDATED" }
local loginFrame = CreateFrame("Frame")
for _, e in ipairs(LOGIN_EVENTS) do pcall(loginFrame.RegisterEvent, loginFrame, e) end

local function readinessRaw()
    local okM, m1, m2 = pcall(GetNumMacros)
    local okA, a = pcall(GetActionInfo, 1)
    local okB, b = pcall(GetBindingKey, "MOVEFORWARD")
    return ("macros=%s/%s slot1=%s fwdKey=%s book=%d"):format(okM and tostring(m1) or "!", okM and tostring(m2) or "!",
        okA and tostring(a) or "!", okB and tostring(b) or "!", #SpellBook())
end

local loginCounts, loginSaved = {}, false
-- PLAYER_ENTERING_WORLD's isInitialLogin for this addon load: true after a
-- login from the character list, false after /reload. restart reports it.
local initialLogin
local function readiness()
    local ok, r = pcall(readinessRaw)
    return ok and r or ("readiness THREW: " .. tostring(r))
end

local function NowMs()
    return debugprofilestop and math.floor(debugprofilestop() - loginT0 + 0.5) or -1
end

loginFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 ~= ADDON then return end
    local n = (loginCounts[event] or 0) + 1
    loginCounts[event] = n
    local ms = NowMs()
    if n == 1 then
        loginLog[#loginLog + 1] = { event = event, ms = ms, arg = arg1 ~= nil and tostring(arg1) or nil, state = readiness() }
    elseif n == 2 then
        loginLog[#loginLog + 1] = { event = event .. " #2 (later repeats only counted)", ms = ms, state = readiness() }
    end
    if event == "ADDON_LOADED" then
        local db, cdb = DB(), CharDB()
        db.loadCount = (db.loadCount or 0) + 1
        cdb.loadCount = (cdb.loadCount or 0) + 1
    elseif event == "PLAYER_ENTERING_WORLD" and not loginSaved then
        initialLogin = arg1
        -- One copy of the startup log per addon load, 5 s after entering the
        -- world, kept for reading off disk (last 5 loads).
        loginSaved = true
        C_Timer.After(5, function()
            local copy = {}
            for i, l in ipairs(loginLog) do copy[i] = l end
            local counts = {}
            for k, v in pairs(loginCounts) do counts[k] = v end
            local cdb = CharDB()
            cdb.logins = cdb.logins or {}
            table.insert(cdb.logins, { at = Stamp(), build = Build(), log = copy, counts = counts })
            while #cdb.logins > 5 do table.remove(cdb.logins, 1) end
            pcall(RecordLoginLayout, initialLogin)
        end)
    end
end)

function P.login()
    Section("login  (ms since this file loaded; first two of each event)")
    for _, l in ipairs(loginLog) do
        Record(("%7d ms  %-34s %s %s"):format(l.ms, l.event, l.arg and ("arg=" .. l.arg) or "", l.state or ""))
    end
    local parts = {}
    for k, v in pairs(loginCounts) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    Record("event counts: " .. table.concat(parts, "  "))
    Record("now: " .. readiness())
    Record("(only meaningful after a fresh login or /reload)")
end

----------------------------------------------------------------------------
-- editmode: string round trip
----------------------------------------------------------------------------

function P.editmode()
    -- Codec stability only: this does NOT prove SaveLayouts persists an
    -- imported layout (that is #15's job, not a read-only probe's).
    Section("editmode  (string codec round trip - codec only, no SaveLayouts)")
    if not C_EditMode then Record("C_EditMode ABSENT"); return end
    local ok, layouts = pcall(C_EditMode.GetLayouts)
    if not ok or type(layouts) ~= "table" then Record("GetLayouts THREW " .. tostring(layouts)); return end
    Record(("%-44s %d saved, activeLayout=%s"):format("GetLayouts()", #(layouts.layouts or {}), ValStr(layouts.activeLayout)))
    local info = layouts.layouts and layouts.layouts[1]
    if not info then
        Record("no saved layout - open Edit Mode, Save As a new Character layout, rerun")
        return
    end
    Record(("%-44s name=%s type=%s systems=%d"):format("layouts[1]", ValStr(info.layoutName), ValStr(info.layoutType), #(info.systems or {})))
    local okS, s = pcall(C_EditMode.ConvertLayoutInfoToString, info)
    if not okS or type(s) ~= "string" then Record("ConvertLayoutInfoToString THREW " .. tostring(s)); return end
    Record(("%-44s %d chars, starts %q"):format("ConvertLayoutInfoToString", #s, s:sub(1, 16)))
    local okB, back = pcall(C_EditMode.ConvertStringToLayoutInfo, s)
    if not okB or type(back) ~= "table" then Record("ConvertStringToLayoutInfo THREW " .. tostring(back)); return end
    Record(("%-44s name=%s type=%s systems=%d"):format("ConvertStringToLayoutInfo", ValStr(back.layoutName), ValStr(back.layoutType), #(back.systems or {})))
    Record(("%-44s name %s, type %s, systems %s"):format("decoded vs original",
        tostring(back.layoutName == info.layoutName), tostring(back.layoutType == info.layoutType),
        tostring(#(back.systems or {}) == #(info.systems or {}))))
    local okR, s2 = pcall(C_EditMode.ConvertLayoutInfoToString, back)
    Record(("%-44s %s"):format("re-encode identical", okR and tostring(s2 == s) or ("THREW " .. tostring(s2))))
end

----------------------------------------------------------------------------
-- layouts (#29, #58): read-only state, then the layout write tests
----------------------------------------------------------------------------

local function LayoutLines(snap)
    for _, e in ipairs(snap.list) do
        Record(("  [%d] %-22s type=%s systems=%d len=%s sum=%s"):format(e.index, ValStr(e.name), ValStr(e.type),
            e.systems, ValStr(e.str and #e.str), ValStr(e.sum)))
    end
    Record(("%-44s %s (%s)"):format("active", ValStr(snap.active), ValStr(snap.activeName)))
end

function P.layouts()
    Section("layouts  (#29/#58: saved layouts, Blizzard's copy, bars, damage meter - read-only)")
    if not C_EditMode then Record("C_EditMode ABSENT"); return end
    local snap = LayoutSnapshot()
    if not snap then Record("GetLayouts failed"); return end
    Record(("%-44s %d presets, %d saved, max %d per type"):format("layouts", snap.presets, #snap.list, MAX_LAYOUTS))
    LayoutLines(snap)
    Record(("%-44s %s"):format("Blizzard copy", BlizzardCopyLine(snap)))
    Record(("%-44s %s"):format("Edit Mode window shown",
        tostring(EditModeManagerFrame ~= nil and EditModeManagerFrame:IsShown())))
    LoginRecordLines(CharDB())
    -- The owner's new-character steps 2-4.
    Call("GetActionBarToggles()", GetActionBarToggles)
    Call("C_CVar.GetCVar(damageMeterEnabled)", C_CVar.GetCVar, "damageMeterEnabled")
    local okS, settings = pcall(C_EditMode.GetAccountSettings)
    if okS and type(settings) == "table" then
        local want = Enum and Enum.EditModeAccountSetting and Enum.EditModeAccountSetting.ShowDamageMeter
        for _, s in ipairs(settings) do
            if s.setting == want then Record(("%-44s %s"):format("account setting ShowDamageMeter", ValStr(s.value))) end
        end
        Record(("%-44s %d settings"):format("C_EditMode.GetAccountSettings()", #settings))
    else
        Record("GetAccountSettings THREW " .. tostring(settings))
    end
    -- "Current Segment" lives in Blizzard's own per-character SavedVariables: read only.
    local dm = _G.DamageMeterPerCharacterSettings
    local wl = type(dm) == "table" and dm.windowDataList
    if type(wl) == "table" then
        for i, w in pairs(wl) do
            Record(("%-44s meterType=%s sessionType=%s shown=%s"):format("damage meter window " .. tostring(i),
                ValStr(w.damageMeterType), ValStr(w.sessionType), ValStr(w.shown)))
        end
    else
        Record("DamageMeterPerCharacterSettings.windowDataList: " .. type(wl))
    end
    if Enum and Enum.DamageMeterSessionType then
        Record(("%-44s %s"):format("Enum.DamageMeterSessionType", ValStr(Enum.DamageMeterSessionType, 1)))
    end
end

local function LayoutWriteGate()
    if InCombatLockdown() then Record("out of combat only"); return false end
    if EditModeManagerFrame and EditModeManagerFrame:IsShown() then Record("close Edit Mode first"); return false end
    return true
end

-- The list SaveLayouts takes: the presets, then the saved layouts as the
-- client returned them. EditModeManagerFrame:SaveLayouts passes the same shape.
local function Combined(info, presets)
    local c = { activeLayout = info.activeLayout, layouts = {} }
    for _, p in ipairs(presets) do c.layouts[#c.layouts + 1] = p end
    for _, l in ipairs(info.layouts) do c.layouts[#c.layouts + 1] = l end
    return c
end

-- Was the backup taken on this character? Character layouts are per character,
-- so another character can only be compared on the Account layouts.
local function SameChar(t)
    local okG, guid = pcall(UnitGUID, "player")
    if t.guid then return okG and guid == t.guid end
    return t.char == UnitName("player")
end

-- Every layout of the backup except the probe's: still there, same type, same
-- content? Second return: true when all are. `accountOnly`: another character.
local function OthersLine(snap, before, accountOnly)
    local bad, n = {}, 0
    for _, b in ipairs(before.list) do
        if b.name ~= LAYOUT_NAME and not (accountOnly and b.type ~= LT.Account) then
            n = n + 1
            local e = FindByName(snap, b.name)
            if not e then bad[#bad + 1] = tostring(b.name) .. " MISSING"
            elseif e.sum ~= b.sum or e.type ~= b.type then bad[#bad + 1] = tostring(b.name) .. " CHANGED" end
        end
    end
    local what = accountOnly and "Account layouts" or "layouts"
    return #bad == 0 and ("all %d %s unchanged"):format(n, what) or table.concat(bad, ", "), #bad == 0
end

local function LayoutCheck(label, test, expect)
    local snap = LayoutSnapshot()
    if not snap then Record(label .. ": GetLayouts failed"); return end
    local e = FindByName(snap, LAYOUT_NAME)
    Record(("%-44s %s"):format(label .. ": probe layout", e and ("index %d type %s, content %s"):format(e.index,
        ValStr(e.type), expect and (e.sum == expect and "as written" or "DIFFERENT") or "-") or "absent"))
    Record(("%-44s %s"):format(label .. ": other layouts", (OthersLine(snap, test.before, not SameChar(test)))))
    Record(("%-44s %s (%s), before %s (%s)"):format(label .. ": active", ValStr(snap.active), ValStr(snap.activeName),
        ValStr(test.before.active), ValStr(test.before.activeName)))
    Record(("%-44s %s"):format(label .. ": Blizzard copy", BlizzardCopyLine(snap)))
    return snap, e
end

function P.layoutadd()
    Section("layoutadd  (#29/#58: add an ACCOUNT layout from a string, SaveLayouts + OnLayoutAdded)")
    if not LayoutWriteGate() then return end
    local db = DB()
    if db.layoutTest then
        Record("a layout test is armed (" .. tostring(db.layoutTest.state) .. ") - restart and/or layoutclean first")
        return
    end
    local snap, info, presets = LayoutSnapshot()
    if not snap then Record("GetLayouts failed"); return end
    if not presets then Record("no preset copy (EditModePresetLayoutManager) - not writing"); return end
    if FindByName(snap, LAYOUT_NAME) then Record("a layout named " .. LAYOUT_NAME .. " already exists - not touching it"); return end
    local nAcc = 0
    for _, e in ipairs(snap.list) do
        if e.type == LT.Account then nAcc = nAcc + 1 end
        if not e.str then Record("layout " .. tostring(e.name) .. " does not encode - not writing"); return end
    end
    if nAcc >= MAX_LAYOUTS then
        Record(("%d Account layouts already (max %d) - not adding"):format(nAcc, MAX_LAYOUTS))
        return
    end
    local okN, valid = pcall(C_EditMode.IsValidLayoutName, LAYOUT_NAME)
    Record(("%-44s %s"):format("IsValidLayoutName(" .. LAYOUT_NAME .. ")", okN and ValStr(valid) or "THREW"))
    if not (okN and valid) then return end
    -- The content: the active saved layout's, else the first saved one's.
    local a = tonumber(snap.active)
    local src = (a and a > snap.presets and snap.list[a - snap.presets]) or snap.list[1]
    if not src then Record("no saved layout to copy - Save As one in Edit Mode first"); return end
    local okD, newInfo = pcall(C_EditMode.ConvertStringToLayoutInfo, src.str)
    if not okD or type(newInfo) ~= "table" then Record("ConvertStringToLayoutInfo THREW " .. tostring(newInfo)); return end
    newInfo.layoutName, newInfo.layoutType = LAYOUT_NAME, LT.Account
    -- Where Blizzard's MakeNewLayout puts it: after the last Account layout.
    local combined = Combined(info, presets)
    local at = #presets + 1
    for i = #presets + 1, #combined.layouts do
        if combined.layouts[i].layoutType == LT.Account then at = i + 1 end
    end
    table.insert(combined.layouts, at, newInfo)
    -- The backup, before any write: restart and layoutclean compare against it.
    local okG, guid = pcall(UnitGUID, "player")
    local t = { state = "adding", at = Stamp(), char = UnitName("player"), guid = okG and guid or nil,
                before = snap, insertAt = at,
                source = src.name, expect = src.sum }
    db.layoutTest = t
    local mark, emark = #blocked, #layoutEvents
    Record(("%-44s %s at index %d, a copy of %s"):format("adding", LAYOUT_NAME, at, ValStr(src.name)))
    local okSave = Call("C_EditMode.SaveLayouts(presets+saved+new)", C_EditMode.SaveLayouts, combined)
    if okSave then Call("C_EditMode.OnLayoutAdded(at, false, true)", C_EditMode.OnLayoutAdded, at, false, true) end
    LayoutCheck("immediately", t, src.sum)
    C_Timer.After(1.5, function()
        local _, e = LayoutCheck("after 1.5 s", t, src.sum)
        Record(("%-44s %s"):format("EDIT_MODE_LAYOUTS_UPDATED", EventsSince(emark)))
        Record(("%-44s %s"):format("taint", TaintSince(mark)))
        if e and e.sum == src.sum then
            t.state = "added"
            Record("armed. Open Edit Mode: is " .. LAYOUT_NAME .. " in the layout list? Close it WITHOUT saving.")
            Record("Then EXIT THE GAME FULLY, relaunch, /syncprobe restart here AND on another character.")
        else
            Record("add NOT verified - run /syncprobe layoutclean")
        end
    end)
end

function P.layoutupdate()
    Section("layoutupdate  (#58: replace the probe layout's content in place, SaveLayouts only)")
    if not LayoutWriteGate() then return end
    local t = DB().layoutTest
    if not t or (t.state ~= "added" and t.state ~= "updated") then Record("run /syncprobe layoutadd first"); return end
    local snap, info, presets = LayoutSnapshot()
    if not (snap and presets) then Record("GetLayouts or the preset copy failed"); return end
    local e = FindByName(snap, LAYOUT_NAME)
    if not e or e.type ~= LT.Account then Record("probe layout not found"); return end
    -- New content: the first preset whose content differs from the probe layout's.
    local srcStr
    for _, p in ipairs(presets) do
        local s = Encode(p)
        if s and Sum(s) ~= e.sum then srcStr = s; break end
    end
    if not srcStr then Record("no different content to write"); return end
    local okD, newInfo = pcall(C_EditMode.ConvertStringToLayoutInfo, srcStr)
    if not okD or type(newInfo) ~= "table" then Record("ConvertStringToLayoutInfo THREW " .. tostring(newInfo)); return end
    newInfo.layoutName, newInfo.layoutType = LAYOUT_NAME, LT.Account
    local combined = Combined(info, presets)
    combined.layouts[e.index] = newInfo
    local expect = Sum(srcStr)
    t.state, t.expect = "updating", expect
    local mark, emark = #blocked, #layoutEvents
    Call("C_EditMode.SaveLayouts(probe replaced)", C_EditMode.SaveLayouts, combined)
    LayoutCheck("immediately", t, expect)
    C_Timer.After(1.5, function()
        local _, e2 = LayoutCheck("after 1.5 s", t, expect)
        Record(("%-44s %s"):format("EDIT_MODE_LAYOUTS_UPDATED", EventsSince(emark)))
        Record(("%-44s %s"):format("taint", TaintSince(mark)))
        if not (e2 and e2.sum == expect) then
            Record("update NOT verified - /syncprobe layouts, then layoutclean")
            return
        end
        t.state = "updated"
        local STALE = "Blizzard's copy is STALE: do NOT save in Edit Mode; /reload refreshes it, then /syncprobe layouts"
        -- Blizzard's copy is only refreshed by EDIT_MODE_LAYOUTS_UPDATED. Does
        -- re-selecting the active layout (same index) send it? Gated again:
        -- combat or Edit Mode may have started during the wait.
        if not LayoutWriteGate() then Record("re-select skipped. " .. STALE); return end
        local s2 = LayoutSnapshot()
        if not s2 then Record("GetLayouts failed. " .. STALE); return end
        local emark2 = #layoutEvents
        Call("C_EditMode.SetActiveLayout(same index)", C_EditMode.SetActiveLayout, s2.active)
        C_Timer.After(1.5, function()
            local s3 = LayoutSnapshot()
            local line, inStep = "-", false
            if s3 then line, inStep = BlizzardCopyLine(s3) end
            Record(("%-44s %s"):format("after re-select: EDIT_MODE_LAYOUTS_UPDATED", EventsSince(emark2)))
            Record(("%-44s %s"):format("after re-select: Blizzard copy", line))
            Record(("%-44s %s (%s)"):format("after re-select: active", ValStr(s3 and s3.active), ValStr(s3 and s3.activeName)))
            Record(("%-44s %s"):format("taint", TaintSince(mark)))
            if inStep and s3.active == s2.active then
                Record("updated, Blizzard's copy in step. EXIT THE GAME FULLY, relaunch, /syncprobe restart")
            else
                Record("updated, but " .. STALE)
            end
        end)
    end)
end

function P.layoutactivate()
    Section("layoutactivate  (#29: SetActiveLayout to the probe layout, then back by name)")
    if not LayoutWriteGate() then return end
    local t = DB().layoutTest
    if not t or (t.state ~= "added" and t.state ~= "updated") then Record("run /syncprobe layoutadd first"); return end
    local snap = LayoutSnapshot()
    if not snap then Record("GetLayouts failed"); return end
    local mark, emark = #blocked, #layoutEvents
    -- Switching back, by name and verified. Until it is, t.restoreActive keeps
    -- the layout to return to, and rerunning layoutactivate retries it.
    local function SwitchBack(backName, backIndex, s)
        if not LayoutWriteGate() then Record("can't switch back now - rerun /syncprobe layoutactivate to retry"); return end
        local back = backIndex
        if type(backName) == "string" and not backName:find("^preset:") then
            local b = FindByName(s, backName)
            back = b and b.index
        end
        if not back then Record("previous layout " .. tostring(backName) .. " not found - switch back by hand in Edit Mode"); return end
        Call("C_EditMode.SetActiveLayout(previous)", C_EditMode.SetActiveLayout, back)
        C_Timer.After(1.5, function()
            local s3 = LayoutSnapshot()
            local line, inStep = "-", false
            if s3 then line, inStep = BlizzardCopyLine(s3) end
            local backOk = s3 ~= nil and s3.activeName == backName
            Record(("%-44s %s (%s), back as before: %s"):format("active after restore", ValStr(s3 and s3.active),
                ValStr(s3 and s3.activeName), tostring(backOk)))
            Record(("%-44s %s"):format("Blizzard copy", line))
            Record(("%-44s %s"):format("EDIT_MODE_LAYOUTS_UPDATED", EventsSince(emark)))
            Record(("%-44s %s"):format("taint", TaintSince(mark)))
            if backOk and inStep then
                t.restoreActive = nil
                Record("back on " .. tostring(backName) .. ", verified")
            else
                Record("NOT verified - rerun /syncprobe layoutactivate to retry the switch back")
            end
        end)
    end
    if t.restoreActive then
        Record(("%-44s %s"):format("pending switch back to", ValStr(t.restoreActive.name)))
        return SwitchBack(t.restoreActive.name, t.restoreActive.index, snap)
    end
    local e = FindByName(snap, LAYOUT_NAME)
    if not e then Record("probe layout not found"); return end
    local backName, backIndex = snap.activeName, snap.active
    if backName == LAYOUT_NAME then Record("the probe layout is already active - pick another in Edit Mode first"); return end
    Record(("%-44s %s (%s)"):format("active before", ValStr(backIndex), ValStr(backName)))
    -- Recorded before the switch: whatever happens next, a rerun switches back.
    t.restoreActive = { name = backName, index = backIndex }
    Call("C_EditMode.SetActiveLayout(probe)", C_EditMode.SetActiveLayout, e.index)
    C_Timer.After(1.5, function()
        local s2 = LayoutSnapshot()
        if not s2 then Record("GetLayouts failed - rerun /syncprobe layoutactivate to switch back"); return end
        Record(("%-44s %s (%s)"):format("active after 1.5 s", ValStr(s2.active), ValStr(s2.activeName)))
        Record(("%-44s %s"):format("Blizzard copy", (BlizzardCopyLine(s2))))
        -- Back by NAME: a preset keeps its index, a saved layout is found again.
        SwitchBack(backName, backIndex, s2)
    end)
end

function P.layoutclean()
    Section("layoutclean  (remove the probe layout; compare the others with the backup)")
    if not LayoutWriteGate() then return end
    local db = DB()
    local t = db.layoutTest
    local snap, info, presets = LayoutSnapshot()
    if not (snap and presets) then Record("GetLayouts or the preset copy failed"); return end
    local e = FindByName(snap, LAYOUT_NAME)
    if not e then
        if not t then Record("no probe layout, no record - nothing to do"); return end
        local line, ok = OthersLine(snap, t.before, not SameChar(t))
        Record(("%-44s %s"):format("other layouts vs backup", line))
        if ok and SameChar(t) and not t.restoreActive then
            db.layoutTest = nil
            Record("no probe layout, the others match the backup - record cleared")
        else
            Record("no probe layout, but the backup record is KEPT (" .. (not ok and "layouts differ"
                or not SameChar(t) and ("taken on " .. tostring(t.char) .. ": clear it there")
                or "a switch back is pending: /syncprobe layoutactivate") .. ")")
        end
        return
    end
    if not t then
        Record("a layout named " .. LAYOUT_NAME .. " exists but the probe has no record of it - not touching it")
        return
    end
    if e.type ~= LT.Account then Record(LAYOUT_NAME .. " is not an Account layout - not the probe's, not touching it"); return end
    if snap.active == e.index then Record("the probe layout is active here - pick another layout in Edit Mode first"); return end
    local combined = Combined(info, presets)
    table.remove(combined.layouts, e.index)
    local mark, emark = #blocked, #layoutEvents
    local okSave = Call("C_EditMode.SaveLayouts(without probe)", C_EditMode.SaveLayouts, combined)
    if okSave then Call("C_EditMode.OnLayoutDeleted(index)", C_EditMode.OnLayoutDeleted, e.index) end
    local beforeName = snap.activeName
    C_Timer.After(1.5, function()
        local s2 = LayoutSnapshot()
        if not s2 then Record("GetLayouts failed - rerun layoutclean"); return end
        local gone = FindByName(s2, LAYOUT_NAME) == nil
        local same = SameChar(t)
        local others, ok = OthersLine(s2, t.before, not same)
        local line, inStep = BlizzardCopyLine(s2)
        local activeOk = s2.activeName == beforeName
        Record(("%-44s %s"):format("probe layout", gone and "removed" or "STILL THERE"))
        Record(("%-44s %s"):format("other layouts vs backup", others))
        Record(("%-44s %s (%s), before %s"):format("active", ValStr(s2.active), ValStr(s2.activeName), ValStr(beforeName)))
        Record(("%-44s %s"):format("Blizzard copy", line))
        Record(("%-44s %s"):format("EDIT_MODE_LAYOUTS_UPDATED", EventsSince(emark)))
        Record(("%-44s %s"):format("taint", TaintSince(mark)))
        -- The backup goes only when everything is verified on the character it
        -- was taken on; otherwise it stays for recovery.
        if gone and ok and activeOk and inStep and same and not t.restoreActive then
            db.layoutTest = nil
            Record("done - removed, the others match the backup, record cleared")
        else
            Record("backup record KEPT: " .. (not gone and "the probe layout is still there"
                or not ok and "layouts differ from the backup"
                or not activeOk and "the active layout changed"
                or not inStep and "Blizzard's copy is out of step (/reload, then /syncprobe layoutclean)"
                or not same and ("taken on " .. tostring(t.char) .. ": run layoutclean there to verify and clear it")
                or "a switch back is pending: /syncprobe layoutactivate"))
        end
    end)
end

----------------------------------------------------------------------------
-- bartoggle (step 2 of a new character: show action bars 2-8)
----------------------------------------------------------------------------

local function Pack(...) return { n = select("#", ...), ... } end

local function TogglesLine(label)
    local p = Pack(pcall(GetActionBarToggles))
    if not p[1] then Record(("%-44s THREW %s"):format(label, tostring(p[2]))); return end
    local parts = {}
    for i = 2, p.n do parts[#parts + 1] = ValStr(p[i]) end
    Record(("%-44s %s"):format(label, table.concat(parts, " ")))
    return p
end

function P.bartoggle(rest)
    Section("bartoggle  (flip one bar's visibility, read back, flip it back)")
    if InCombatLockdown() then Record("out of combat only"); return end
    local db = DB()
    if db.barToggle then Record("a bar toggle record exists - /syncprobe clean first"); return end
    local bar = tonumber(rest)
    if not bar or bar < 2 or bar > 8 then Record("usage: /syncprobe bartoggle <2-8>"); return end
    local p = TogglesLine("GetActionBarToggles() before")
    if not p then return end
    local count, idx = p.n - 1, bar - 1
    if idx > count then Record("only " .. count .. " toggles returned"); return end
    local orig, flipped = {}, {}
    for i = 1, count do orig[i] = p[i + 1]; flipped[i] = p[i + 1] end
    flipped[idx] = not orig[idx]
    db.barToggle = { orig = orig, count = count, at = Stamp() }
    local mark = #blocked
    Call("SetActionBarToggles(bar " .. bar .. " flipped)", SetActionBarToggles, unpack(flipped, 1, count))
    TogglesLine("immediately")
    C_Timer.After(1, function() TogglesLine("after 1 s") end)
    C_Timer.After(3, function()
        TogglesLine("after 3 s")
        Call("SetActionBarToggles(original)", SetActionBarToggles, unpack(orig, 1, count))
        C_Timer.After(2, function()
            local q = TogglesLine("after restore + 2 s")
            local same = q ~= nil
            for i = 1, count do
                if not q or q[i + 1] ~= orig[i] then same = false end
            end
            Record(("%-44s %s"):format("taint", TaintSince(mark)))
            if same then db.barToggle = nil; Record("restored and verified") else Record("NOT restored - /syncprobe clean") end
        end)
    end)
end

----------------------------------------------------------------------------
-- encoding: C_EncodingUtil on a realistic profile
----------------------------------------------------------------------------

local function DeepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not DeepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function P.encoding()
    Section("encoding  (CBOR -> Deflate -> Base64 and back)")
    local E = C_EncodingUtil
    if not E then Record("C_EncodingUtil ABSENT"); return end
    -- A worst-case-ish profile: 180 slots, 18 full macros, 150 bindings.
    local profile = { schema = 1, class = "PRIEST", name = "Holy", actions = {}, macros = {}, bindings = {} }
    for slot = 1, 180 do
        profile.actions[slot] = { type = "spell", id = 10000 + slot, name = "Spell Name " .. slot, family = "fam" .. slot % 40 }
    end
    for i = 1, 18 do
        profile.macros[i] = { name = "Macro" .. i, icon = 134400, scope = "char",
                              body = ("/cast [@mouseover,help,nodead][] Flash Heal\n"):rep(6):sub(1, 255) }
    end
    for i = 1, 150 do profile.bindings["CTRL-SHIFT-" .. i] = { "ACTIONBUTTON" .. (i % 12 + 1), "MULTIACTIONBAR1BUTTON" .. (i % 12 + 1) } end
    local t0 = debugprofilestop()
    local okC, cbor = pcall(E.SerializeCBOR, profile)
    if not okC then Record("SerializeCBOR THREW " .. tostring(cbor)); return end
    local okZ, z = pcall(E.CompressString, cbor)
    if not okZ then Record("CompressString THREW " .. tostring(z)); return end
    local okB, b64 = pcall(E.EncodeBase64, z)
    if not okB then Record("EncodeBase64 THREW " .. tostring(b64)); return end
    local t1 = debugprofilestop()
    Record(("%-44s cbor=%d deflate=%d base64=%d bytes, %.1f ms"):format("encode", #cbor, #z, #b64, t1 - t0))
    -- Explicit ifs: `ok and pcall(...)` keeps only pcall's FIRST result.
    local okD, raw = pcall(E.DecodeBase64, b64)
    local okU, unz, okX, back = false, nil, false, nil
    if okD then okU, unz = pcall(E.DecompressString, raw) end
    if okU then okX, back = pcall(E.DeserializeCBOR, unz) end
    Record(("%-44s decode=%s decompress=%s deserialize=%s"):format("decode", tostring(okD), tostring(okU), tostring(okX)))
    Record(("%-44s %s"):format("round trip deep-equal", tostring(okX and DeepEqual(profile, back))))
    if okX and type(back) == "table" and type(back.actions) == "table" then
        Record(("%-44s actions[1].id=%s (%s)  #actions=%d"):format("integer keys survive", ValStr(back.actions[1] and back.actions[1].id),
            type(back.actions[1] and back.actions[1].id), #back.actions))
    end
end

----------------------------------------------------------------------------
-- place: one non-destructive action-bar write
----------------------------------------------------------------------------

local slotEvents = {}
local slotFrame = CreateFrame("Frame")
slotFrame:SetScript("OnEvent", function(_, _, slot) slotEvents[#slotEvents + 1] = slot end)

local function SlotEmpty(slot)
    local ok, a = pcall(GetActionInfo, slot)
    return ok and a == nil
end

local function CursorSpell()
    local ok, kind, a, b, c = pcall(GetCursorInfo)
    if not ok then return nil end
    -- GetCursorInfo's spell tuple: "spell", spellIndex, bookType, spellID.
    return kind, a, b, c
end

function P.place()
    Section("place  (write one EMPTY slot, verify, remove only what we placed)")
    if InCombatLockdown() then Record("out of combat only"); return end
    if GetCursorInfo() then Record("cursor is not empty - put it down and rerun"); return end
    local slot
    for s = 1, 120 do
        if SlotEmpty(s) then slot = s; break end
    end
    if not slot then Record("no empty slot in 1-120 - clear one and rerun"); return end
    -- A spell the client itself flags as a LOW rank, so we also see whether a
    -- low rank stays low when placed. Falls back to any castable spell.
    local pick, top
    for _, g in ipairs(RankGroups()) do
        for _, r in ipairs(g.ranks) do
            if r.lowOk and r.low and not pick then pick = { id = r.id, name = g.name, sub = r.sub }; top = g.ranks end
        end
    end
    if not pick then
        for _, e in ipairs(SpellBook()) do
            if IsLearnedSpell(e.info) then
                pick = { id = e.info.spellID, name = e.info.name, sub = e.info.subName }; break
            end
        end
    end
    if not pick then Record("no castable spell in the spellbook"); return end
    Record(("%-44s slot %d, spell %s %q %s"):format("target", slot, pick.id, tostring(pick.name), tostring(pick.sub)))
    if top then
        local ids = {}
        for _, r in ipairs(top) do ids[#ids + 1] = r.id .. (r.low and "(low)" or "") end
        Record(("%-44s %s"):format("ranks of this spell in the book", table.concat(ids, " ")))
    end
    slotEvents = {}
    pcall(slotFrame.RegisterEvent, slotFrame, "ACTIONBAR_SLOT_CHANGED")
    local mark, ev0 = #blocked, 0

    Call("C_Spell.PickupSpell(id)", C_Spell.PickupSpell, pick.id)
    Call("GetCursorInfo() after pickup", GetCursorInfo)
    if CursorSpell() ~= "spell" then
        ClearCursor()
        slotFrame:UnregisterEvent("ACTIONBAR_SLOT_CHANGED")
        Record("pickup did not put a spell on the cursor - stopped, nothing written")
        return
    end
    if not SlotEmpty(slot) then
        ClearCursor()
        slotFrame:UnregisterEvent("ACTIONBAR_SLOT_CHANGED")
        Record("slot " .. slot .. " is no longer empty - stopped, nothing written")
        return
    end
    Call("PlaceAction(slot)", PlaceAction, slot)
    Call("GetCursorInfo() after place", GetCursorInfo)
    local leftover = GetCursorInfo()
    ClearCursor()
    Call("GetActionInfo(slot) after place", GetActionInfo, slot)
    Call("C_ActionBar.GetSpell(slot)", C_ActionBar and C_ActionBar.GetSpell, slot)

    -- Remove only if the slot holds exactly what we placed (a spell action).
    local okA, kind, placedID = pcall(GetActionInfo, slot)
    if okA and kind == "spell" and placedID == pick.id and not leftover then
        Call("PickupAction(slot)", PickupAction, slot)
        local ck = CursorSpell()
        ClearCursor()
        Record(("%-44s %s"):format("cursor after PickupAction", ValStr(ck)))
    else
        Record(("%-44s slot holds %s %s, cursor held %s - NOT removing"):format("removal skipped", ValStr(kind), ValStr(placedID), ValStr(leftover)))
    end
    local clean = SlotEmpty(slot)
    Record(("%-44s %s"):format("slot " .. slot .. " empty again", clean and "yes" or "NO - drag it off by hand"))

    C_Timer.After(0.5, function()
        pcall(slotFrame.UnregisterEvent, slotFrame, "ACTIONBAR_SLOT_CHANGED")
        local evs = {}
        for i = ev0 + 1, #slotEvents do evs[#evs + 1] = tostring(slotEvents[i]) end
        Record(("%-44s %s"):format("ACTIONBAR_SLOT_CHANGED payloads", #evs > 0 and table.concat(evs, ",") or "none"))
        Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
        Record("Then /reload and play a minute: any taint?")
    end)
end

----------------------------------------------------------------------------
-- bars (#5): which underlying slot each visible button shows, per state
----------------------------------------------------------------------------

-- Every Blizzard action button family the client might have (each name is
-- reported as present or absent; nothing is assumed).
local BUTTON_BARS = { "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton", "MultiBar5Button", "MultiBar6Button", "MultiBar7Button",
    "BonusActionButton", "OverrideActionBarButton" }

-- A button's current action slot, and which accessor gave it.
local function ButtonSlot(b)
    for _, m in ipairs({ "GetPagedID", "CalculateAction" }) do
        if type(b[m]) == "function" then
            local ok, v = pcall(b[m], b)
            if ok and type(v) == "number" then return v, m end
        end
    end
    if type(b.action) == "number" then return b.action, ".action" end
    return nil, "none"
end

-- "1-12=a 13-24=b": runs of equal values over 1..n.
local function Runs(n, valueOf)
    local out, start, cur = {}, 1, valueOf(1)
    for i = 2, n + 1 do
        local v = i <= n and valueOf(i) or {}
        if v ~= cur then
            out[#out + 1] = (start == i - 1 and tostring(start) or (start .. "-" .. (i - 1))) .. "=" .. tostring(cur)
            start, cur = i, v
        end
    end
    return table.concat(out, " ")
end

local function BarsMap(label)
    Section("bars map  (" .. label .. ")")
    -- State
    Call("GetShapeshiftForm()", GetShapeshiftForm)
    local okN, nForms = Call("GetNumShapeshiftForms()", GetNumShapeshiftForms)
    for i = 1, (okN and tonumber(nForms) or 0) do Call(("GetShapeshiftFormInfo(%d)"):format(i), GetShapeshiftFormInfo, i) end
    local AB = C_ActionBar or {}
    for _, f in ipairs({ "GetActionBarPage", "GetBonusBarOffset", "GetBonusBarIndex", "HasBonusActionBar",
                         "GetOverrideBarIndex", "GetVehicleBarIndex", "GetTempShapeshiftBarIndex",
                         "GetExtraBarIndex", "HasOverrideActionBar", "HasVehicleActionBar",
                         "HasTempShapeshiftActionBar" }) do
        Call("C_ActionBar." .. f .. "()", AB[f])
    end
    -- Buttons -> slots
    for _, bar in ipairs(BUTTON_BARS) do
        if not _G[bar .. "1"] then
            Record(("%-44s absent"):format(bar))
        else
            local parts, how, shown = {}, nil, 0
            for i = 1, 12 do
                local b = _G[bar .. i]
                if b then
                    local slot, m = ButtonSlot(b)
                    how = how or m
                    local okV, vis = pcall(b.IsVisible, b)
                    if okV and vis then shown = shown + 1 end
                    parts[#parts + 1] = i .. ">" .. tostring(slot)
                else
                    parts[#parts + 1] = i .. ">-"
                end
            end
            Record(("%-44s via %s, %d/12 visible: %s"):format(bar, tostring(how), shown, table.concat(parts, " ")))
        end
    end
    -- Slots 1-200: contents and bonus bar index
    local info = {}
    for slot = 1, 200 do
        local ok, kind, id = pcall(GetActionInfo, slot)
        info[slot] = not ok and "THREW" or kind and (kind .. ":" .. tostring(id)) or "empty"
    end
    local filled = {}
    for slot = 1, 200 do if info[slot] ~= "empty" then filled[#filled + 1] = slot .. "=" .. info[slot] end end
    Record(("%-44s %d: %s"):format("slots holding something", #filled, table.concat(filled, " ")))
    local bonusFn = AB.GetBonusBarIndexForSlot
    if type(bonusFn) == "function" then
        Record(("%-44s %s"):format("GetBonusBarIndexForSlot 1-200", Runs(200, function(i)
            local ok, v = pcall(bonusFn, i)
            return ok and tostring(v) or "THREW"
        end)))
    else
        Record("C_ActionBar.GetBonusBarIndexForSlot ABSENT")
    end
    Record(("%-44s %s"):format("GetActionInfo threw at", Runs(200, function(i) return info[i] == "THREW" and "threw" or "ok" end)))
    -- Binding commands for the bars (#7): enumerated, so unbound ones show too.
    local okB, n = pcall(GetNumBindings)
    if okB and type(n) == "number" then
        local cmds = {}
        for i = 1, n do
            local okI, cmd, _, k1, k2 = pcall(GetBinding, i)
            if okI and type(cmd) == "string" and (cmd:find("^ACTIONBUTTON") or cmd:find("^MULTIACTIONBAR")
                or cmd:find("^BONUSACTIONBUTTON") or cmd:find("^SHAPESHIFTBUTTON")) then
                cmds[#cmds + 1] = cmd .. ((k1 or k2) and ("[" .. tostring(k1 or "") .. (k2 and ("," .. k2) or "") .. "]") or "")
            end
        end
        Record(("%-44s %d: %s"):format("bar binding commands (GetBinding)", #cmds, table.concat(cmds, " ")))
    else
        Record("GetNumBindings unavailable")
    end
end

local function BarsWrite(slot)
    Section("bars write  (slot " .. tostring(slot) .. ", EMPTY only)")
    if not slot or slot < 1 or slot > 200 then Record("usage: /syncprobe bars write <slot 1-200>"); return end
    if InCombatLockdown() then Record("out of combat only"); return end
    if GetCursorInfo() then Record("cursor is not empty - put it down and rerun"); return end
    if not SlotEmpty(slot) then Record("slot " .. slot .. " is not empty - pick an empty slot; nothing written"); return end
    Call("GetShapeshiftForm()", GetShapeshiftForm)
    Call("C_ActionBar.GetBonusBarOffset()", C_ActionBar and C_ActionBar.GetBonusBarOffset)
    Call("C_ActionBar.GetBonusBarIndexForSlot(slot)", C_ActionBar and C_ActionBar.GetBonusBarIndexForSlot, slot)
    local pick
    for _, e in ipairs(SpellBook()) do
        if IsLearnedSpell(e.info) then pick = { id = e.info.spellID, name = e.info.name }; break end
    end
    if not pick then Record("no castable spell in the spellbook"); return end
    Record(("%-44s slot %d, spell %s %q"):format("target", slot, pick.id, tostring(pick.name)))
    local mark = #blocked
    local function done(msg)
        ClearCursor()
        Record(msg)
        Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
    end
    if not Call("C_Spell.PickupSpell(id)", C_Spell.PickupSpell, pick.id) or CursorSpell() ~= "spell" then
        return done("pickup did not put a spell on the cursor - stopped, nothing written")
    end
    if not SlotEmpty(slot) then return done("slot " .. slot .. " is no longer empty - stopped, nothing written") end
    Call("PlaceAction(slot)", PlaceAction, slot)
    local leftover = GetCursorInfo()
    Call("GetActionInfo(slot) after place", GetActionInfo, slot)
    local okA, kind, placed = pcall(GetActionInfo, slot)
    if leftover or not (okA and kind == "spell" and placed == pick.id) then
        return done(("placed read back %s %s, cursor held %s - NOT removing; check slot %d by hand")
            :format(ValStr(kind), ValStr(placed), ValStr(leftover), slot))
    end
    Call("PickupAction(slot)", PickupAction, slot)
    local ck, _, _, cid = CursorSpell()
    local same = ck == "spell" and (cid == pick.id or cid == nil)
    Record(("%-44s %s %s"):format("cursor after PickupAction", ValStr(ck), ValStr(cid)))
    ClearCursor()
    local clean = SlotEmpty(slot) and not GetCursorInfo()
    if same and clean then
        done(("OK - slot %d written, read back, and empty again; cursor empty"):format(slot))
    else
        done(("NOT clean - slot %d empty: %s, cursor empty: %s, picked up our spell: %s - check by hand")
            :format(slot, tostring(SlotEmpty(slot)), tostring(not GetCursorInfo()), tostring(same)))
    end
end

-- Returns the label this run is kept under.
function P.bars(rest)
    local sub, arg = (rest or ""):match("^%s*(%S*)%s*(.-)%s*$")
    if sub == "write" then
        BarsWrite(tonumber(arg))
        return "bars write " .. tostring(arg)
    end
    local label = (sub ~= "" and (sub .. (arg ~= "" and (" " .. arg) or "")))
    if not label then
        local okF, form = pcall(GetShapeshiftForm)
        local okP, page = pcall(C_ActionBar and C_ActionBar.GetActionBarPage or GetActionBarPage)
        label = ("form%s page%s"):format(tostring(okF and form), tostring(okP and page))
    end
    BarsMap(label)
    return "bars " .. label
end

----------------------------------------------------------------------------
-- Pet bar (#47): what identifies a pet and its abilities, whether the
-- server keeps the bar per pet, and whether code can move pet actions.
-- Read-only except "swap", "write" and "autocast", which undo themselves
-- and verify the undo.
----------------------------------------------------------------------------

local PET_BANK = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet
local PET_SLOTS = 10

local function PetSlot(i)
    local ok, name, texture, isToken, isActive, acAllowed, acEnabled, spellID = pcall(GetPetActionInfo, i)
    if not ok or name == nil then return nil end
    return { name = name, texture = texture, token = isToken and true or false, active = isActive,
             acAllowed = acAllowed and true or false, acEnabled = acEnabled and true or false,
             spellID = spellID }
end

local function SlotSig(s)
    if not s then return "-" end
    return ("%s|%s|%s|ac=%s"):format(tostring(s.name), tostring(s.token), tostring(s.spellID), tostring(s.acEnabled))
end

local function PetBar()
    local bar = {}
    for i = 1, PET_SLOTS do bar[i] = SlotSig(PetSlot(i)) end
    return bar
end

local function PetKey()
    local okF, fname, fid = pcall(UnitCreatureFamily, "pet")
    local okN, pname = pcall(UnitName, "pet")
    return okF and fid or nil, okF and fname or nil, okN and pname or nil
end

local function CursorPet()
    local ok, kind, a = pcall(GetCursorInfo)
    if not ok then return "THREW" end
    return kind, a
end

local function PetRead(label)
    Section("pet read  (" .. tostring(label) .. ")")
    Call("UnitExists(\"pet\")", UnitExists, "pet")
    Call("UnitName(\"pet\")", UnitName, "pet")
    Call("UnitCreatureFamily(\"pet\")", UnitCreatureFamily, "pet")
    Call("UnitCreatureType(\"pet\")", UnitCreatureType, "pet")
    Call("UnitGUID(\"pet\")", UnitGUID, "pet")
    Call("UnitLevel(\"pet\")", UnitLevel, "pet")
    Call("PetHasActionBar()", PetHasActionBar)
    Call("HasPetUI()", HasPetUI)
    Call("C_SpellBook.HasPetSpells()", C_SpellBook and C_SpellBook.HasPetSpells)
    Call("C_PetInfo.GetPetTalentTree()", C_PetInfo and C_PetInfo.GetPetTalentTree)
    Call("GetLocale()", GetLocale)

    Record(" ")
    Record("-- pet bar: GetPetActionInfo(i) = name, texture, isToken, isActive, acAllowed, acEnabled, spellID, ...")
    for i = 1, PET_SLOTS do
        Call(("GetPetActionInfo(%d)"):format(i), GetPetActionInfo, i)
        local s = PetSlot(i)
        if s and s.spellID then
            Call(("  FindBaseSpellByID(%s)"):format(s.spellID), FindBaseSpellByID, s.spellID)
            Call(("  C_Spell.GetSpellName(%s)"):format(s.spellID), C_Spell and C_Spell.GetSpellName, s.spellID)
            Call(("  C_Spell.GetSpellSubtext(%s)"):format(s.spellID), C_Spell and C_Spell.GetSpellSubtext, s.spellID)
        end
        Call(("  C_ActionBar.IsAutoCastPetAction(%d)"):format(i), C_ActionBar and C_ActionBar.IsAutoCastPetAction, i)
        Call(("  GetBindingKey(BONUSACTIONBUTTON%d)"):format(i), GetBindingKey, "BONUSACTIONBUTTON" .. i)
        local b = _G["PetActionButton" .. i]
        Record(("  %-42s %s"):format("PetActionButton" .. i, b and ("exists, action " .. ValStr(b.action or (b.GetID and b:GetID()))) or "ABSENT"))
    end

    Record(" ")
    Record("-- pet spellbook (bank " .. ValStr(PET_BANK) .. ")")
    local okN, n = pcall(C_SpellBook.HasPetSpells)
    if PET_BANK and okN and type(n) == "number" then
        for i = 1, n do
            local okI, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, PET_BANK)
            if okI and type(info) == "table" then
                Record(("  book %2d  %-24s sub=%-10s spell=%s action=%s type=%s passive=%s"):format(i,
                    tostring(info.name), ValStr(info.subName), tostring(info.spellID), tostring(info.actionID),
                    tostring(info.itemType), tostring(info.isPassive)))
                if info.actionID then
                    Call(("    C_PetInfo.GetSpellForPetAction(%s)"):format(info.actionID),
                        C_PetInfo and C_PetInfo.GetSpellForPetAction, info.actionID)
                end
                Call("    GetSpellBookItemAutoCast", C_SpellBook.GetSpellBookItemAutoCast, i, PET_BANK)
            else
                Record(("  book %2d  THREW/none: %s"):format(i, ValStr(info)))
            end
        end
    else
        Record("  no pet spells (HasPetSpells " .. ValStr(n) .. ")")
    end

    -- Persistence: compare with the last read of this same pet (by GUID-less key:
    -- family + pet name), and with the last read of the same family.
    local fid, fname, pname = PetKey()
    if fid or fname then
        local db = CharDB()
        db.pet = db.pet or { byPet = {}, byFamily = {} }
        local bar = PetBar()
        local petKey = tostring(fid or fname) .. ":" .. tostring(pname)
        local function compare(what, prev)
            if not prev then Record(("%-44s first read"):format(what)); return end
            local diffs = {}
            for i = 1, PET_SLOTS do
                if prev.bar[i] ~= bar[i] then diffs[#diffs + 1] = ("slot %d: %s -> %s"):format(i, prev.bar[i], bar[i]) end
            end
            Record(("%-44s %s (last read %s, pet %s, build %s)"):format(what,
                #diffs == 0 and "SAME" or (#diffs .. " slot(s) differ"), prev.at, tostring(prev.pet), tostring(prev.build)))
            for _, d in ipairs(diffs) do Record("    " .. d) end
        end
        Record(" ")
        compare("vs last read of THIS pet", db.pet.byPet[petKey])
        compare("vs last read of this FAMILY", db.pet.byFamily[tostring(fid or fname)])
        local snap = { at = Stamp(), build = Build(), pet = pname, family = fname, bar = bar }
        db.pet.byPet[petKey] = snap
        db.pet.byFamily[tostring(fid or fname)] = snap
    end
end

-- Swap two filled pet slots with PickupPetAction, read back, swap back.
local function PetSwap(a, b)
    Section(("pet swap  (slots %s and %s, then back)"):format(tostring(a), tostring(b)))
    if not (a and b and a ~= b and a >= 1 and b >= 1 and a <= PET_SLOTS and b <= PET_SLOTS) then
        Record("usage: /syncprobe pet swap <a> <b>   two different FILLED slots 1-10"); return
    end
    if InCombatLockdown() then Record("out of combat only"); return end
    if GetCursorInfo() then Record("cursor is not empty - put it down and rerun"); return end
    if not (PetSlot(a) and PetSlot(b)) then Record("both slots must be filled; nothing moved"); return end
    local before = PetBar()
    local mark = #blocked
    local function swap(step)
        Call(step .. " PickupPetAction(" .. a .. ")", PickupPetAction, a)
        Record(("  %-42s %s %s"):format("cursor", ValStr((CursorPet())), ValStr(select(2, CursorPet()))))
        Call(step .. " PickupPetAction(" .. b .. ")", PickupPetAction, b)
        Record(("  %-42s %s %s"):format("cursor", ValStr((CursorPet())), ValStr(select(2, CursorPet()))))
        Call(step .. " PickupPetAction(" .. a .. ")", PickupPetAction, a)
        return not GetCursorInfo()
    end
    local clean1 = swap("1.")
    local mid = PetBar()
    local swapped = mid[a] == before[b] and mid[b] == before[a]
    Record(("%-44s %s; cursor empty: %s"):format("after swap", swapped and "SWAPPED" or "NOT swapped", tostring(clean1)))
    for i = 1, PET_SLOTS do if mid[i] ~= before[i] then Record(("    slot %d: %s -> %s"):format(i, before[i], mid[i])) end end
    if not clean1 then
        Record("cursor still holds something - NOT continuing; drop it into the empty pet slot by hand")
        Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
        return
    end
    if swapped then
        local clean2 = swap("2.")
        local after = PetBar()
        local same = true
        for i = 1, PET_SLOTS do if after[i] ~= before[i] then same = false end end
        Record(("%-44s %s; cursor empty: %s"):format("after swap back", same and "OK - bar as before" or "DIFFERS - check by hand", tostring(clean2)))
    end
    Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
end

-- Place a pet spellbook ability into an EMPTY pet slot, read back, remove it.
local function PetWrite(slot, bookIndex)
    Section(("pet write  (slot %s, EMPTY only)"):format(tostring(slot)))
    if not (slot and slot >= 1 and slot <= PET_SLOTS) then
        Record("usage: /syncprobe pet write <empty slot 1-10> [pet book index]"); return
    end
    if InCombatLockdown() then Record("out of combat only"); return end
    if GetCursorInfo() then Record("cursor is not empty - put it down and rerun"); return end
    if PetSlot(slot) then Record("slot " .. slot .. " is not empty; nothing written"); return end
    if not PET_BANK then Record("Enum.SpellBookSpellBank.Pet absent"); return end
    local okN, n = pcall(C_SpellBook.HasPetSpells)
    if not okN or type(n) ~= "number" or n < 1 then Record("no pet spells"); return end
    local pick
    for i = 1, n do
        local okI, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, PET_BANK)
        if okI and type(info) == "table" and (bookIndex == nil or i == bookIndex) and not info.isPassive then
            pick = { index = i, name = info.name, spellID = info.spellID }; break
        end
    end
    if not pick then Record("no matching non-passive pet book entry"); return end
    Record(("%-44s book %d %q spell %s"):format("picking", pick.index, tostring(pick.name), tostring(pick.spellID)))
    local before = PetBar()
    local mark = #blocked
    Call("C_SpellBook.PickupSpellBookItem(i, Pet)", C_SpellBook.PickupSpellBookItem, pick.index, PET_BANK)
    Record(("  %-42s %s %s"):format("cursor", ValStr((CursorPet())), ValStr(select(2, CursorPet()))))
    if not GetCursorInfo() then
        Record("nothing on the cursor - stopped, nothing written")
        Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
        return
    end
    Call("PickupPetAction(slot) [place]", PickupPetAction, slot)
    local leftover = GetCursorInfo()
    local mid = PetBar()
    Record(("%-44s %s; cursor after place: %s"):format("slot now", mid[slot], ValStr(leftover)))
    for i = 1, PET_SLOTS do
        if i ~= slot and mid[i] ~= before[i] then Record(("    ALSO changed slot %d: %s -> %s"):format(i, before[i], mid[i])) end
    end
    if leftover then ClearCursor() end
    if PetSlot(slot) then
        Call("PickupPetAction(slot) [take off]", PickupPetAction, slot)
        Record(("  %-42s %s %s"):format("cursor", ValStr((CursorPet())), ValStr(select(2, CursorPet()))))
        ClearCursor()
    end
    local after = PetBar()
    local same = true
    for i = 1, PET_SLOTS do if after[i] ~= before[i] then same = false end end
    Record(("%-44s %s; cursor empty: %s"):format("after removal", same and "OK - bar as before" or "DIFFERS - check by hand",
        tostring(not GetCursorInfo())))
    Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
end

-- Move a filled slot into an EMPTY one with two calls, read back, move it back.
-- Then pick the same slot up and put it straight back (the recovery step).
local function PetMove(from, to)
    Section(("pet move  (slot %s into EMPTY slot %s, then back)"):format(tostring(from), tostring(to)))
    if not (from and to and from ~= to and from >= 1 and to >= 1 and from <= PET_SLOTS and to <= PET_SLOTS) then
        Record("usage: /syncprobe pet move <filled slot> <empty slot>"); return
    end
    if InCombatLockdown() then Record("out of combat only"); return end
    if GetCursorInfo() then Record("cursor is not empty - put it down and rerun"); return end
    if not PetSlot(from) then Record("slot " .. from .. " is empty; nothing moved"); return end
    if PetSlot(to) then Record("slot " .. to .. " is not empty; nothing moved"); return end
    local before = PetBar()
    local mark = #blocked
    local function cursor(label)
        Record(("  %-42s %s %s"):format("cursor " .. label, ValStr((CursorPet())), ValStr(select(2, CursorPet()))))
    end
    local function stop(msg)
        Record(msg .. " - stopped; if the cursor holds something, drop it into the empty pet slot by hand")
        Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
    end
    -- 1. The two-call move.
    Call("PickupPetAction(from)", PickupPetAction, from); cursor("after pickup")
    Call("PickupPetAction(to)", PickupPetAction, to); cursor("after drop")
    local mid = PetBar()
    local moved = mid[to] == before[from] and mid[from] == "-" and not GetCursorInfo()
    Record(("%-44s %s"):format("move into empty slot", moved and "MOVED (source empty, cursor empty)" or "NOT as expected"))
    for i = 1, PET_SLOTS do if mid[i] ~= before[i] then Record(("    slot %d: %s -> %s"):format(i, before[i], mid[i])) end end
    if GetCursorInfo() then return stop("cursor not empty after the move") end
    -- 2. Move it back the same way.
    if moved then
        Call("PickupPetAction(to) [back]", PickupPetAction, to); cursor("after pickup")
        Call("PickupPetAction(from) [back]", PickupPetAction, from); cursor("after drop")
        if GetCursorInfo() then return stop("cursor not empty after moving back") end
    end
    -- 3. Put back into its own slot: pick up `from`, drop on `from`.
    local mid2 = PetBar()
    Call("PickupPetAction(from) [lift]", PickupPetAction, from); cursor("after lift")
    Call("PickupPetAction(from) [put back]", PickupPetAction, from); cursor("after put back")
    local after = PetBar()
    local same = true
    for i = 1, PET_SLOTS do if after[i] ~= before[i] then same = false end end
    Record(("%-44s %s"):format("put back into its own slot", mid2[from] == after[from] and not GetCursorInfo() and "OK" or "NOT as expected"))
    Record(("%-44s %s; cursor empty: %s"):format("bar at the end", same and "OK - as before" or "DIFFERS - check by hand", tostring(not GetCursorInfo())))
    for i = 1, PET_SLOTS do if after[i] ~= before[i] then Record(("    slot %d: %s -> %s"):format(i, before[i], after[i])) end end
    Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
end

-- Remove an autocast ability from slot n and put it back from the pet
-- spellbook: does its autocast state survive? Run once with autocast ON and
-- once with it OFF (right-click the button to change it by hand first).
local function PetReadd(slot)
    Section(("pet readd  (slot %s: remove, put back from the book, autocast before/after)"):format(tostring(slot)))
    if not (slot and slot >= 1 and slot <= PET_SLOTS) then Record("usage: /syncprobe pet readd <slot 1-10>"); return end
    if InCombatLockdown() then Record("out of combat only"); return end
    if GetCursorInfo() then Record("cursor is not empty - put it down and rerun"); return end
    local s = PetSlot(slot)
    if not (s and s.spellID and s.acAllowed) then Record("slot " .. slot .. " needs an ability that can autocast"); return end
    local okN, n = pcall(C_SpellBook.HasPetSpells)
    local index
    for i = 1, (okN and type(n) == "number") and n or 0 do
        local okI, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, PET_BANK)
        if okI and type(info) == "table" and info.spellID == s.spellID then index = i end
    end
    if not index then Record("no pet book entry with spell " .. tostring(s.spellID) .. "; nothing removed"); return end
    local function book(label)
        local ok, allowed, enabled = pcall(C_SpellBook.GetSpellBookItemAutoCast, index, PET_BANK)
        Record(("%-44s allowed %s enabled %s"):format("book autocast " .. label, ValStr(ok and allowed), ValStr(ok and enabled)))
        return ok and enabled
    end
    local before = PetBar()
    local mark = #blocked
    Record(("%-44s %s, book %d, slot autocast %s"):format("ability", tostring(s.name), index, tostring(s.acEnabled)))
    local was = book("before")
    -- Each step is checked before the next write; a failure stops with the
    -- cursor as it is and says how to put the bar back.
    local function stop(msg)
        Record(msg)
        Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
        SlashCmdList.ALTSTABLESYNCPROBE("copy")
    end
    local function cursor()
        local kind, id = CursorPet()
        Record(("  %-42s %s %s"):format("cursor", ValStr(kind), ValStr(id)))
        return kind, id
    end
    -- 1. Remove: the slot must be empty and the cursor must hold this ability.
    Call("PickupPetAction(slot) [remove]", PickupPetAction, slot)
    local kind, id = cursor()
    Record(("%-44s %s"):format("slot after remove", PetBar()[slot]))
    if PetSlot(slot) or kind ~= "petaction" or id ~= s.spellID then
        return stop(("remove NOT as expected - stopped. If the cursor holds something, drop it into slot %d; "
            .. "if slot %d is empty, drag %s from the pet spellbook into it"):format(slot, slot, tostring(s.name)))
    end
    pcall(ClearCursor)
    if GetCursorInfo() then
        return stop(("cursor didn't clear - stopped; drop it into slot %d"):format(slot))
    end
    book("while off the bar")
    -- 2. Pick it up from the book.
    Call("C_SpellBook.PickupSpellBookItem(book, Pet)", C_SpellBook.PickupSpellBookItem, index, PET_BANK)
    kind = cursor()
    if kind ~= "petaction" then
        return stop(("book pickup NOT as expected - stopped. Slot %d is empty: drag %s from the pet spellbook "
            .. "into it%s"):format(slot, tostring(s.name), kind and ", after putting down what the cursor holds" or ""))
    end
    -- 3. Put it back: the slot must hold this ability and the cursor be empty.
    Call("PickupPetAction(slot) [put back]", PickupPetAction, slot)
    local back = PetSlot(slot)
    if GetCursorInfo() or not (back and back.spellID == s.spellID) then
        return stop(("put-back NOT as expected (slot %d: %s) - stopped. Drop what the cursor holds into slot %d, "
            .. "or drag %s from the pet spellbook into it"):format(slot, SlotSig(back), slot, tostring(s.name)))
    end
    Record(("%-44s %s"):format("slot right after", PetBar()[slot]))
    book("right after")
    C_Timer.After(1, function()
        local after = PetBar()
        local now = book("1 s after")
        Record(("%-44s %s"):format("slot 1 s after", after[slot]))
        local same = true
        for i = 1, PET_SLOTS do if after[i] ~= before[i] then same = false end end
        Record(("%-44s %s"):format("autocast survived", now == was and "YES" or "NO - check the button"))
        Record(("%-44s %s"):format("bar", same and "OK - as before" or "DIFFERS - check by hand"))
        Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
        SlashCmdList.ALTSTABLESYNCPROBE("copy")
    end)
end

-- Toggle autocast on one slot, read it now and a second later, toggle back.
-- "book": the same toggle through the pet spellbook entry with this slot's spell.
local function PetAutocast(slot, how)
    Section(("pet autocast  (slot %s, toggled and back)"):format(tostring(slot)))
    if not (slot and slot >= 1 and slot <= PET_SLOTS) then Record("usage: /syncprobe pet autocast <slot 1-10>"); return end
    if InCombatLockdown() then Record("out of combat only"); return end
    local s = PetSlot(slot)
    if not (s and s.acAllowed) then Record("slot " .. slot .. " has no autocast ability"); return end
    local was = s.acEnabled
    local mark = #blocked
    Record(("%-44s %s"):format("autocast before", tostring(was)))
    local toggle
    if how == "book" then
        local okN, n = pcall(C_SpellBook.HasPetSpells)
        local index
        for i = 1, (okN and type(n) == "number") and n or 0 do
            local okI, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, PET_BANK)
            if okI and type(info) == "table" and info.spellID == s.spellID then index = i end
        end
        if not index then Record("no pet book entry with spell " .. tostring(s.spellID)); return end
        Record(("%-44s book %d"):format("via C_SpellBook, entry", index))
        toggle = function(label)
            Call("SetSpellBookItemAutoCastEnabled" .. label, C_SpellBook.SetSpellBookItemAutoCastEnabled,
                index, PET_BANK, not (PetSlot(slot) or {}).acEnabled)
        end
    else
        toggle = function(label) Call("TogglePetAutocast(slot)" .. label, TogglePetAutocast, slot) end
    end
    toggle("")
    Record(("%-44s %s"):format("right after toggle", tostring((PetSlot(slot) or {}).acEnabled)))
    C_Timer.After(1, function()
        local now = (PetSlot(slot) or {}).acEnabled
        Record(("%-44s %s"):format("1 s after toggle", tostring(now)))
        if now ~= was then
            toggle(" [back]")
        end
        C_Timer.After(1, function()
            local back = (PetSlot(slot) or {}).acEnabled
            Record(("%-44s %s (%s)"):format("1 s after toggling back", tostring(back), back == was and "OK - as before" or "DIFFERS - check by hand"))
            Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
            SlashCmdList.ALTSTABLESYNCPROBE("copy")
        end)
    end)
end

-- Returns the label this run is kept under.
function P.pet(rest)
    local sub, a, b = (rest or ""):match("^%s*(%S*)%s*(%S*)%s*(%S*)")
    if sub == "swap" then PetSwap(tonumber(a), tonumber(b)); return "pet swap" end
    if sub == "write" then PetWrite(tonumber(a), tonumber(b)); return "pet write" end
    if sub == "move" then PetMove(tonumber(a), tonumber(b)); return "pet move" end
    if sub == "readd" then PetReadd(tonumber(a)); return "pet readd " .. tostring((PetSlot(tonumber(a) or 0) or {}).acEnabled) end
    if sub == "autocast" then PetAutocast(tonumber(a), b); return "pet autocast " .. tostring(b) end
    local label = sub ~= "" and sub or (select(3, PetKey()) or "nopet")
    PetRead(label)
    return "pet " .. label
end

----------------------------------------------------------------------------
-- Restart tests: macro, binding, CVar. Each records a marker ONLY after the
-- write is verified; /syncprobe restart reads it after a FULL EXIT;
-- /syncprobe clean undoes only what the probe recorded, verifies each undo,
-- and keeps the record of anything it could not undo.
----------------------------------------------------------------------------

local MACRO_NAME = "SyncProbe"
local MACRO_BODY = ("/run -- AltStableSyncProbe 256-char body test, safe to delete " .. ("x"):rep(256)):sub(1, 255)
local BIND_KEY, BIND_CMD = "CTRL-SHIFT-F11", "TOGGLEAUTORUN"
local CVAR = "cameraDistanceMaxZoomFactor"
local FIRST_CHAR_MACRO = 121   -- measured (Stakeout, 69977)

local function Norm(body) return (tostring(body or ""):gsub("[\r\n]+$", "")) end
local MARKER = "AltStableSyncProbe 256-char body test"
-- #6: the body /syncprobe macroedit writes (it keeps the marker, so clean
-- still recognises the macro), and a numeric icon fileID.
local EDIT_BODY = "/run -- " .. MARKER .. " (edited by macroedit), safe to delete"
local EDIT_ICON = 134414

-- Character-scope macros only, exact name AND body (trailing newlines
-- normalised: the server appends one, measured 70245).
local function FindProbeMacro()
    local ok, _, nChar = pcall(GetNumMacros)
    if not ok or type(nChar) ~= "number" then return nil end
    for i = FIRST_CHAR_MACRO, FIRST_CHAR_MACRO + nChar - 1 do
        local okI, name, _, body = pcall(GetMacroInfo, i)
        if okI and name == MACRO_NAME and (Norm(body) == Norm(MACRO_BODY) or Norm(body) == Norm(EDIT_BODY)) then
            return i, body
        end
    end
end

local function AnyMacroNamed(name)
    for i = 1, 200 do
        local ok, n = pcall(GetMacroInfo, i)
        if ok and n == name then return i end
    end
end

local function IsCharacterSet()
    local ok, set = pcall(GetCurrentBindingSet)
    return ok and Enum and Enum.BindingSet and set == Enum.BindingSet.Character
end

function P.macro()
    Section("macro  (character macro, 255-char body)")
    if InCombatLockdown() then Record("out of combat only"); return end
    local cdb = CharDB()
    if cdb.macroOwned then Record("probe macro already created - run /syncprobe restart after a full exit"); return end
    local clash = AnyMacroNamed(MACRO_NAME)
    if clash then Record("a macro named " .. MACRO_NAME .. " already exists (index " .. clash .. ") - not touching it"); return end
    local mark = #blocked
    Call("GetNumMacros() before", GetNumMacros)
    Call("CreateMacro(name, icon, body, true)", CreateMacro, MACRO_NAME, "INV_Misc_QuestionMark", MACRO_BODY, true)
    local idx, body = FindProbeMacro()
    Record(("%-44s index=%s bodyLen=%s"):format("read back (character scope)", ValStr(idx), ValStr(body and #body)))
    Record(("%-44s %s"):format("taint", TaintSince(mark)))
    if not idx then Record("create NOT verified - no marker recorded"); return end
    cdb.macroOwned, cdb.macroMarkedAt = true, Stamp()
    Record("armed. EXIT THE GAME FULLY, relaunch, log this character in, /syncprobe restart")
end

-- #6: what EditMacro does on Forever. The probe's own macro only (made by
-- /syncprobe macro). Read: the return, the index, body and icon after, and a
-- bar slot holding the macro before and after.
local function MacroLine(label, idx)
    local ok, name, icon, body = pcall(GetMacroInfo, idx)
    if not ok then Record(("%-44s THREW"):format(label)) return end
    Record(("%-44s index=%s name=%s icon=%s (%s) bodyLen=%s edited=%s"):format(label, ValStr(idx), ValStr(name),
        ValStr(icon), type(icon), ValStr(body and #body), tostring(Norm(body) == Norm(EDIT_BODY))))
end

local function SlotLine(label, slot)
    local okI, kind, id, sub = pcall(GetActionInfo, slot)
    local okT, text = pcall(GetActionText, slot)
    Record(("%-44s slot %d: %s %s %s text=%s"):format(label, slot, okI and ValStr(kind) or "THREW", ValStr(id),
        ValStr(sub), okT and ValStr(text) or "THREW"))
end

function P.macroedit(rest)
    local cdb = CharDB()
    local idx, body = FindProbeMacro()
    if rest == "combat" then
        Section("macroedit combat  (EditMacro in combat lockdown)")
        if not InCombatLockdown() then Record("enter combat first (attack a training dummy), then rerun"); return "macroedit combat" end
        -- Its own run label, so it never overwrites the out-of-combat run.
        if not idx then Record("no probe macro - run /syncprobe macro out of combat first (and before clean)"); return "macroedit combat" end
        local mark = #blocked
        Call("EditMacro(i, name, nil, same body)", EditMacro, idx, MACRO_NAME, nil, body)
        MacroLine("after", idx)
        Record(("%-44s %s"):format("blocked (ADDON_ACTION_BLOCKED/FORBIDDEN)", TaintSince(mark)))
        return "macroedit combat"
    end
    Section("macroedit  (#6: EditMacro on the probe's character macro)")
    if InCombatLockdown() then Record("out of combat only"); return end
    if cdb.macroEdit then
        Record("already armed (slot " .. tostring(cdb.macroEdit.slot) .. ") - /syncprobe restart after a full exit, then clean")
        return
    end
    if not cdb.macroOwned or not idx then Record("no probe macro - run /syncprobe macro first"); return end
    if Norm(body) ~= Norm(MACRO_BODY) then Record("the probe macro is already edited - /syncprobe clean, then macro"); return end
    local okC, ck = pcall(GetCursorInfo)
    if not okC or ck ~= nil then Record("empty the cursor first"); return end
    local slot = tonumber(rest)
    if slot then
        local ok, kind = pcall(GetActionInfo, slot)
        if not ok or kind ~= nil then Record("slot " .. slot .. " is not empty (or unreadable) - pick an empty one"); return end
    else
        for s = 1, 72 do
            local ok, kind = pcall(GetActionInfo, s)
            if ok and kind == nil then slot = s break end
        end
        if not slot then Record("no empty slot in 1-72 - give one: /syncprobe macroedit <slot>"); return end
    end
    local mark = #blocked
    Call("GetNumMacros() before", GetNumMacros)
    MacroLine("before", idx)
    Call("PickupMacro(i)", PickupMacro, idx)
    Call("PlaceAction(slot)", PlaceAction, slot)
    local okC2, ck2 = pcall(GetCursorInfo)
    if okC2 and ck2 ~= nil then pcall(ClearCursor) end
    SlotLine("placed", slot)
    local okT, text = pcall(GetActionText, slot)
    if not okT or text ~= MACRO_NAME then Record("the macro did not land in slot " .. slot .. " - stopping"); return end
    -- Recorded before the edit: whatever happens next, clean knows the slot.
    cdb.macroEdit = { slot = slot, at = Stamp() }
    Call("EditMacro(i, name, icon, body)", EditMacro, idx, MACRO_NAME, EDIT_ICON, EDIT_BODY)
    Call("GetNumMacros() after", GetNumMacros)
    MacroLine("same index after", idx)
    local idx2 = FindProbeMacro()
    Record(("%-44s %s"):format("found by name after (index)", ValStr(idx2)))
    SlotLine("slot after the edit", slot)
    Record(("%-44s %s"):format("taint", TaintSince(mark)))
    Record("armed. Look at slot " .. slot .. " (icon, tooltip). EXIT THE GAME FULLY, relaunch, /syncprobe restart")
end

function P.bind()
    Section("bind  (CHARACTER binding set only)")
    if InCombatLockdown() then Record("out of combat only"); return end
    local cdb = CharDB()
    Call("GetCurrentBindingSet()", GetCurrentBindingSet)
    if not IsCharacterSet() then
        Record("This character uses ACCOUNT bindings. The probe will not switch modes for you.")
        Record("To test: Options > Keybindings > tick 'Character Specific Key Bindings', then rerun.")
        return
    end
    if cdb.bindOwned then Record("probe binding already armed - run /syncprobe restart after a full exit"); return end
    local okA, current = pcall(GetBindingAction, BIND_KEY)
    if not okA then Record("GetBindingAction THREW - not touching bindings"); return end
    if current and current ~= "" then
        Record(BIND_KEY .. " is already bound to " .. current .. " - not touching it")
        return
    end
    local mark = #blocked
    -- Owned before the write: whatever happens next, clean knows to undo it.
    cdb.bindOwned, cdb.bindSavePending, cdb.bindMarkedAt = true, true, nil
    local okSet = Call("SetBinding(key, cmd)", SetBinding, BIND_KEY, BIND_CMD)
    local okSave = okSet and Call("SaveBindings(Enum.BindingSet.Character)", SaveBindings, Enum.BindingSet.Character)
    local okB, after = pcall(GetBindingAction, BIND_KEY)
    Record(("%-44s %s"):format("GetBindingAction(key) after", okB and ValStr(after) or "THREW"))
    Call("GetCurrentBindingSet() after", GetCurrentBindingSet)
    Record(("%-44s %s"):format("taint", TaintSince(mark)))
    if not okSet and okB and (after == nil or after == "") then
        cdb.bindOwned, cdb.bindSavePending = nil, nil   -- nothing changed
        Record("SetBinding failed and the key is unbound - nothing to undo, not armed")
        return
    end
    if not (okSave and okB and after == BIND_CMD) then
        Record("binding NOT verified (save " .. tostring(okSave) .. ") - not armed; run /syncprobe clean")
        return
    end
    cdb.bindSavePending, cdb.bindMarkedAt = nil, Stamp()
    Record("armed. EXIT THE GAME FULLY, relaunch, log this character in, /syncprobe restart")
end

-- A CVar can be account- or character-stored, so one test at a time,
-- recorded account-wide.
function P.cvar()
    Section("cvar  (marker for a full-exit restart test)")
    local db = DB()
    if db.cvarTest then
        Record("a CVar " .. tostring(db.cvarTest.state) .. " record exists (" .. tostring(db.cvarTest.char) .. ") - /syncprobe restart and/or clean first")
        return
    end
    Call("C_CVar.GetCVarInfo(" .. CVAR .. ")", C_CVar.GetCVarInfo, CVAR)
    local ok, cur = pcall(C_CVar.GetCVar, CVAR)
    if not ok or type(cur) ~= "string" then Record("cannot read the original value - not writing"); return end
    local marker = (cur == "1.5") and "1.6" or "1.5"
    db.cvarTest = { original = cur, marker = marker, at = Stamp(), char = UnitName("player"), state = "rollback" }
    Call("C_CVar.SetCVar(" .. CVAR .. ", " .. marker .. ")", C_CVar.SetCVar, CVAR, marker)
    local okR, now = pcall(C_CVar.GetCVar, CVAR)
    if not (okR and now == marker) then
        local okS, set = pcall(C_CVar.SetCVar, CVAR, cur)
        local okV, back = pcall(C_CVar.GetCVar, CVAR)
        if okS and set ~= false and okV and tonumber(back) == tonumber(cur) then
            db.cvarTest = nil
            Record("write NOT verified (read back " .. tostring(now) .. ") - original restored and verified, not armed")
        else
            Record("write NOT verified AND restore not verified (reads " .. tostring(back)
                .. ") - original " .. cur .. " kept; run /syncprobe clean")
        end
        return
    end
    db.cvarTest.state = "armed"
    Record("armed (original " .. cur .. "). EXIT THE GAME FULLY, relaunch, log in, /syncprobe restart")
end

function P.restart()
    Section("restart  (run after a FULL EXIT, not /reload)")
    local db, cdb = DB(), CharDB()
    Record(("%-44s account %s, character %s"):format("probe SV loadCount", ValStr(db.loadCount), ValStr(cdb.loadCount)))
    Record(("%-44s %s"):format("this load (PLAYER_ENTERING_WORLD)", initialLogin == true and "a login (relog or full exit)"
        or initialLogin == false and "a /reload - NOT a restart, results below prove nothing" or "unknown"))
    if cdb.macroOwned then
        local idx, body = FindProbeMacro()
        Record(("%-44s armed %s -> index=%s bodyLen=%s"):format("macro survived?", tostring(cdb.macroMarkedAt), ValStr(idx), ValStr(body and #body)))
    end
    if cdb.macroEdit then
        local idx = FindProbeMacro()
        if idx then MacroLine("edited macro survived? (armed " .. tostring(cdb.macroEdit.at) .. ")", idx)
        else Record("edited macro survived?                       NOT FOUND by name") end
        SlotLine("edited macro's slot after restart", cdb.macroEdit.slot)
    end
    if cdb.bindOwned and not cdb.bindSavePending then
        local ok, act = pcall(GetBindingAction, BIND_KEY)
        local okS, set = pcall(GetCurrentBindingSet)
        Record(("%-44s armed %s -> %s=%s set=%s"):format("binding survived?", tostring(cdb.bindMarkedAt), BIND_KEY,
            ok and ValStr(act) or "THREW", okS and ValStr(set) or "THREW"))
    end
    if db.cvarTest and db.cvarTest.state ~= "rollback" then
        local ok, v = pcall(C_CVar.GetCVar, CVAR)
        Record(("%-44s armed %s by %s -> %s=%s (marker %s, original %s)"):format("cvar survived?", db.cvarTest.at,
            tostring(db.cvarTest.char), CVAR, ok and ValStr(v) or "THREW", db.cvarTest.marker, db.cvarTest.original))
    end
    if db.layoutTest then
        local t = db.layoutTest
        local snap = LayoutSnapshot()
        if snap then
            local e = FindByName(snap, LAYOUT_NAME)
            Record(("%-44s armed %s by %s (%s) -> %s"):format("probe layout survived?", tostring(t.at), tostring(t.char),
                tostring(t.state), e and ("index %d, content %s"):format(e.index, e.sum == t.expect and "as written"
                or "DIFFERENT") or "ABSENT"))
            Record(("%-44s %s"):format("other layouts vs backup", (OthersLine(snap, t.before, not SameChar(t)))))
            Record(("%-44s %s (%s)"):format("active layout now", ValStr(snap.active), ValStr(snap.activeName)))
            Record(("%-44s %s"):format("Blizzard copy", BlizzardCopyLine(snap)))
        else
            Record("probe layout survived?                       GetLayouts failed")
        end
    end
    -- This character's active layout at each load: did adding a layout move it?
    LoginRecordLines(cdb)
    if not (cdb.macroOwned or cdb.bindOwned or db.cvarTest or db.layoutTest) then
        Record("nothing armed - run /syncprobe macro | bind | cvar | layoutadd first")
    end
    Record("The loadCount goes up on /reload too - it cannot prove a full exit. Only you can:")
    Record("say 'full exit' when you paste this, or it proves nothing.")
end

function P.clean()
    Section("clean  (undo only what the probe recorded; verify each)")
    if InCombatLockdown() then Record("out of combat only"); return end
    local db, cdb = DB(), CharDB()
    local left = {}

    -- Ours if recorded, or if a character macro carries our exact name and
    -- the probe's marker (a record an older probe build dropped).
    local orphan = false
    if not cdb.macroOwned then
        local idx, body = FindProbeMacro()
        orphan = idx ~= nil and tostring(body):find(MARKER, 1, true) ~= nil
    end
    if cdb.macroOwned or orphan then
        local idx = FindProbeMacro()
        if cdb.macroEdit then
            SlotLine("macroedit slot before DeleteMacro", cdb.macroEdit.slot)
            Call("GetNumMacros() before DeleteMacro", GetNumMacros)
        end
        if idx then Call("DeleteMacro(" .. idx .. ")", DeleteMacro, idx) end
        if FindProbeMacro() then left[#left + 1] = "macro (still present)"
        else cdb.macroOwned, cdb.macroMarkedAt = nil, nil end
    end
    -- #6: what a deleted macro leaves in its slot; the slot is then emptied
    -- only if it still shows our macro's name.
    if cdb.macroEdit and not cdb.macroOwned then
        local slot = cdb.macroEdit.slot
        SlotLine("macroedit slot after DeleteMacro", slot)
        local okT, text = pcall(GetActionText, slot)
        if okT and text == MACRO_NAME then
            Call("PickupAction(slot)", PickupAction, slot)
            pcall(ClearCursor)
        end
        local okI, kind = pcall(GetActionInfo, slot)
        local okT2, text2 = pcall(GetActionText, slot)
        if okT2 and text2 == MACRO_NAME then
            left[#left + 1] = "macroedit slot " .. slot .. " (still holds the macro)"
        else
            if okI and kind ~= nil then Record("slot " .. slot .. " holds something else now - left alone") end
            cdb.macroEdit = nil
        end
    end

    if cdb.bindOwned then
        local ok, act = pcall(GetBindingAction, BIND_KEY)
        if not ok then
            left[#left + 1] = "binding (GetBindingAction threw - record kept)"
        elseif not IsCharacterSet() then
            left[#left + 1] = "binding (character set not active - re-enable it, then clean)"
        elseif act == BIND_CMD or act == nil or act == "" then
            if act == BIND_CMD then
                cdb.bindSavePending = true
                Call("SetBinding(key, nil)", SetBinding, BIND_KEY)
            end
            local okSave = Call("SaveBindings(Character)", SaveBindings, Enum.BindingSet.Character)
            local ok2, act2 = pcall(GetBindingAction, BIND_KEY)
            if okSave and ok2 and (act2 == nil or act2 == "") then
                cdb.bindOwned, cdb.bindSavePending, cdb.bindMarkedAt = nil, nil, nil
            else
                left[#left + 1] = "binding (save " .. tostring(okSave) .. ", key reads " .. tostring(act2) .. " - rerun clean)"
            end
        else
            -- Not ours any more (the player rebound it): forget, don't touch.
            Record(BIND_KEY .. " now holds " .. tostring(act) .. " - left alone")
            cdb.bindOwned, cdb.bindMarkedAt = nil, nil
        end
    end

    if db.cvarTest then
        local okC, cur = pcall(C_CVar.GetCVar, CVAR)
        if not okC then
            left[#left + 1] = "cvar (GetCVar threw - record kept)"
        elseif db.cvarTest.state ~= "rollback" and tonumber(cur) ~= tonumber(db.cvarTest.marker) then
            -- The player changed it since: theirs now, leave it.
            Record(CVAR .. " now " .. tostring(cur) .. ", not our marker - left alone")
            db.cvarTest = nil
        else
            local okS, set = Call("C_CVar.SetCVar restore", C_CVar.SetCVar, CVAR, db.cvarTest.original)
            local ok, v = pcall(C_CVar.GetCVar, CVAR)
            if okS and set ~= false and ok and tonumber(v) == tonumber(db.cvarTest.original) then db.cvarTest = nil
            else left[#left + 1] = "cvar (reads " .. tostring(v) .. ", original " .. db.cvarTest.original .. ")" end
        end
    end

    if db.barToggle then
        local o = db.barToggle
        Call("SetActionBarToggles(original)", SetActionBarToggles, unpack(o.orig, 1, o.count))
        local q = TogglesLine("GetActionBarToggles() after")
        local same = q ~= nil
        for i = 1, o.count do
            if not q or q[i + 1] ~= o.orig[i] then same = false end
        end
        if same then db.barToggle = nil
        else left[#left + 1] = "bar toggles (not back to the original - record kept, rerun clean)" end
    end
    if db.layoutTest then left[#left + 1] = "layout test (run /syncprobe layoutclean)" end

    Record(#left == 0 and "done - everything undone" or ("NOT done: " .. table.concat(left, "; ")))
end

----------------------------------------------------------------------------
-- Copy window (from AltStableProbe): chat is not selectable.
----------------------------------------------------------------------------

local copyFrame, copyEdit

local function StripColors(s)
    return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""))
end

local function ShowCopy()
    if not copyFrame then
        local ok, f = pcall(CreateFrame, "Frame", "AltStableSyncProbeCopy", UIParent, "BackdropTemplate")
        if not ok or not f then f = CreateFrame("Frame", "AltStableSyncProbeCopy", UIParent) end
        f:SetSize(780, 520); f:SetPoint("CENTER"); f:SetFrameStrata("DIALOG")
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                            tile = true, tileSize = 32, edgeSize = 32,
                            insets = { left = 11, right = 12, top = 12, bottom = 11 } })
        end
        tinsert(UISpecialFrames, "AltStableSyncProbeCopy")
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 16, -16)
        title:SetText("AltStableSync probe - click the text, Ctrl+A, Ctrl+C, Escape")
        local sc = CreateFrame("ScrollFrame", nil, f)
        sc:SetPoint("TOPLEFT", 18, -40); sc:SetPoint("BOTTOMRIGHT", -20, 18)
        local eb = CreateFrame("EditBox", nil, sc)
        eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetMaxLetters(0)
        eb:SetFontObject(ChatFontNormal); eb:SetWidth(740)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); f:Hide() end)
        sc:SetScrollChild(eb)
        sc:EnableMouseWheel(true)
        sc:SetScript("OnMouseWheel", function(self, d)
            local v = math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - d * 45))
            self:SetVerticalScroll(v)
        end)
        copyFrame, copyEdit = f, eb
    end
    local buf = {}
    for i = 1, #lines do buf[i] = StripColors(lines[i]) end
    copyEdit:SetText(#buf > 0 and table.concat(buf, "\n") or "(no output yet - run /syncprobe)")
    copyEdit:SetCursorPosition(0)
    copyFrame:Show()
end

----------------------------------------------------------------------------
-- Slash command
----------------------------------------------------------------------------

local READ_ONLY = { "client", "actions", "ranks", "login", "editmode", "encoding", "layouts" }

-- Sections that report later: the copy window opens after them.
local REPORT_DELAY = { place = 0.7, layoutadd = 2, layoutupdate = 3.5, layoutclean = 2, layoutactivate = 3.5,
                       bartoggle = 5.5 }

local function Persist(label)
    local db = DB()
    db.runs = db.runs or {}
    -- A repeated label keeps the run before it.
    if db.runs[label] then db.runs[label .. " (previous)"] = db.runs[label] end
    db.runs[label] = { at = Stamp(), build = Build(), char = UnitName("player"), lines = lines }
end

SLASH_ALTSTABLESYNCPROBE1 = "/syncprobe"
SlashCmdList.ALTSTABLESYNCPROBE = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "copy" then ShowCopy(); return end
    lines = {}
    -- Each section protected: one error must not lose the rest of the run.
    local label
    local function Run(name)
        local ok, err = pcall(P[name], rest)
        if not ok then Record("|cffff5555SECTION " .. name .. " ERRORED:|r " .. tostring(err))
        elseif type(err) == "string" then label = err end
    end
    if cmd == "" or cmd == "all" then
        for _, name in ipairs(READ_ONLY) do Run(name) end
        cmd = "all"
    elseif P[cmd] then
        Run(cmd)
    else
        Out("/syncprobe [client|actions|ranks|login|editmode|encoding|layouts] | place | bars [label|write <n>] | pet [swap a b|move j i|write n|readd n|autocast n] | macro | bind | cvar | layoutadd | layoutupdate | layoutactivate | layoutclean | bartoggle <n> | restart | clean | copy")
        return
    end
    Persist(label or cmd)
    C_Timer.After(REPORT_DELAY[cmd] or 0, ShowCopy)
end
