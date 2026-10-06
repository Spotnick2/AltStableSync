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
        /syncprobe macro           create the test character macro (restart test)
        /syncprobe bind            bind CTRL-SHIFT-F11 in the CHARACTER binding set (restart test)
        /syncprobe cvar            write a marker CVar (restart test)
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
local function Call(label, fn, ...)
    if type(fn) ~= "function" then
        Record(("%-44s ABSENT (%s)"):format(label, type(fn)))
        return
    end
    local function handle(ok, ...)
        if not ok then
            Record(("%-44s THREW: %s"):format(label, tostring((...))))
            return
        end
        local n = select("#", ...)
        if n == 0 then Record(("%-44s (no returns)"):format(label)); return end
        local parts = {}
        for i = 1, n do parts[#parts + 1] = "[" .. i .. "]=" .. ValStr((select(i, ...)), 2) end
        Record(("%-44s %d: %s"):format(label, n, table.concat(parts, "  ")))
    end
    handle(pcall(fn, ...))
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

function P.ranks()
    Section("ranks  (IsSpellBookItemLowRank / GetBaseSpell / FindBaseSpellByID)")
    local book = SpellBook()
    Record(("%-44s %d items"):format("player spellbook", #book))
    local byName, shown = {}, 0
    for _, e in ipairs(book) do
        local name = e.info.name
        if name then byName[name] = (byName[name] or 0) + 1 end
    end
    for _, e in ipairs(book) do
        local info = e.info
        local okL, low = pcall(C_SpellBook.IsSpellBookItemLowRank, e.index, BANK)
        local multi = info.name and byName[info.name] and byName[info.name] > 1
        if (multi or (okL and low)) and shown < 12 and info.spellID then
            shown = shown + 1
            Record(("%-44s id=%s sub=%s lowRank=%s passive=%s"):format(
                "#" .. e.index .. " " .. tostring(info.name), ValStr(info.spellID), ValStr(info.subName),
                okL and ValStr(low) or "THREW", ValStr(info.isPassive)))
            Call("  C_Spell.GetBaseSpell(id)", C_Spell.GetBaseSpell, info.spellID)
            Call("  FindBaseSpellByID(id)", FindBaseSpellByID, info.spellID)
            Call("  C_Spell.GetOverrideSpell(id)", C_Spell.GetOverrideSpell, info.spellID)
            Call("  C_SpellBook.FindSpellBookSlotForSpell(id)", C_SpellBook.FindSpellBookSlotForSpell, info.spellID)
            Call("  C_Spell.GetSpellSubtext(id)", C_Spell.GetSpellSubtext, info.spellID)
        end
    end
    if shown == 0 then Record("no multi-rank spells in this spellbook - try a character above level ~10") end
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

local function readiness()
    local okM, m1, m2 = pcall(GetNumMacros)
    local okA, a = pcall(GetActionInfo, 1)
    local okB, b = pcall(GetBindingKey, "MOVEFORWARD")
    return ("macros=%s/%s slot1=%s fwdKey=%s book=%d"):format(okM and tostring(m1) or "!", okM and tostring(m2) or "!",
        okA and tostring(a) or "!", okB and tostring(b) or "!", #SpellBook())
end

loginFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 ~= ADDON then return end
    local n = 0
    for _, l in ipairs(loginLog) do if l.event == event then n = n + 1 end end
    if n == 0 then
        loginLog[#loginLog + 1] = { event = event, ms = math.floor((debugprofilestop() - loginT0) + 0.5),
                                    arg = arg1 ~= nil and tostring(arg1) or nil, state = readiness() }
    elseif n == 1 then
        loginLog[#loginLog + 1] = { event = event .. " (again; later repeats not logged)",
                                    ms = math.floor((debugprofilestop() - loginT0) + 0.5) }
    end
    if event == "ADDON_LOADED" then
        local db, cdb = DB(), CharDB()
        db.loadCount = (db.loadCount or 0) + 1
        cdb.loadCount = (cdb.loadCount or 0) + 1
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- The log so far, kept for reading off disk (last 5 logins).
        C_Timer.After(5, function()
            local cdb = CharDB()
            cdb.logins = cdb.logins or {}
            table.insert(cdb.logins, { at = Stamp(), build = Build(), log = loginLog })
            while #cdb.logins > 5 do table.remove(cdb.logins, 1) end
        end)
    end
end)

function P.login()
    Section("login  (ms since this file loaded; first two of each event)")
    for _, l in ipairs(loginLog) do
        Record(("%7d ms  %-34s %s %s"):format(l.ms, l.event, l.arg and ("arg=" .. l.arg) or "", l.state or ""))
    end
    Record("now: " .. readiness())
    Record("(only meaningful after a fresh login or /reload)")
end

----------------------------------------------------------------------------
-- editmode: string round trip
----------------------------------------------------------------------------

function P.editmode()
    Section("editmode  (ConvertLayoutInfoToString round trip)")
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
    local okR, s2 = pcall(C_EditMode.ConvertLayoutInfoToString, back)
    Record(("%-44s %s"):format("re-encode identical", okR and tostring(s2 == s) or ("THREW " .. tostring(s2))))
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
    local okD, raw = pcall(E.DecodeBase64, b64)
    local okU, unz = okD and pcall(E.DecompressString, raw)
    local okX, back = okU and pcall(E.DeserializeCBOR, unz)
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
pcall(slotFrame.RegisterEvent, slotFrame, "ACTIONBAR_SLOT_CHANGED")
slotFrame:SetScript("OnEvent", function(_, _, slot) slotEvents[#slotEvents + 1] = slot end)

function P.place()
    Section("place  (write one EMPTY slot, read back, clear)")
    if InCombatLockdown() then Record("out of combat only"); return end
    if GetCursorInfo() then Record("cursor is not empty - put it down and rerun"); return end
    local slot
    for s = 1, 120 do
        local ok, a = pcall(GetActionInfo, s)
        if ok and a == nil then slot = s; break end
    end
    if not slot then Record("no empty slot in 1-120 - clear one and rerun"); return end
    -- The lowest known rank of a multi-rank, non-passive spell, so we also see
    -- whether a LOW rank stays low when placed.
    local pick, seen = nil, {}
    for _, e in ipairs(SpellBook()) do
        local i = e.info
        if i.spellID and not i.isPassive and i.name then
            if seen[i.name] and not pick then pick = seen[i.name] end
            seen[i.name] = seen[i.name] or i
        end
    end
    if not pick then
        for _, e in ipairs(SpellBook()) do
            if e.info.spellID and not e.info.isPassive then pick = e.info; break end
        end
    end
    if not pick then Record("no castable spell in the spellbook"); return end
    Record(("%-44s slot %d, spell %s %q %s"):format("target", slot, pick.spellID, pick.name, tostring(pick.subName)))
    local mark, ev0 = #blocked, #slotEvents
    Call("C_Spell.PickupSpell(id)", C_Spell.PickupSpell, pick.spellID)
    Call("GetCursorInfo() after pickup", GetCursorInfo)
    Call("PlaceAction(slot)", PlaceAction, slot)
    Call("GetCursorInfo() after place", GetCursorInfo)
    ClearCursor()
    Call("GetActionInfo(slot) after place", GetActionInfo, slot)
    Call("C_ActionBar.GetSpell(slot)", C_ActionBar and C_ActionBar.GetSpell, slot)
    -- Clear it again: pick up what we placed, drop it.
    Call("PickupAction(slot)", PickupAction, slot)
    ClearCursor()
    Call("GetActionInfo(slot) after clear", GetActionInfo, slot)
    C_Timer.After(0.5, function()
        local evs = {}
        for i = ev0 + 1, #slotEvents do evs[#evs + 1] = tostring(slotEvents[i]) end
        Record(("%-44s %s"):format("ACTIONBAR_SLOT_CHANGED payloads", #evs > 0 and table.concat(evs, ",") or "none"))
        Record(("%-44s %s"):format("ADDON_ACTION_BLOCKED/FORBIDDEN", TaintSince(mark)))
        Record("If the slot is not empty now, drag it off by hand. Then /reload and play a minute: any taint?")
    end)
end

----------------------------------------------------------------------------
-- Restart tests: macro, binding, CVar. Each writes a marker; /syncprobe
-- restart reads it after a FULL EXIT; /syncprobe clean undoes it.
----------------------------------------------------------------------------

local MACRO_NAME = "SyncProbe"
local MACRO_BODY = ("/run -- AltStableSyncProbe 256-char body test, safe to delete " .. ("x"):rep(256)):sub(1, 255)
local BIND_KEY, BIND_CMD = "CTRL-SHIFT-F11", "TOGGLEAUTORUN"
local CVAR = "cameraDistanceMaxZoomFactor"

local function FindProbeMacro()
    for i = 1, 200 do
        local ok, name, _, body = pcall(GetMacroInfo, i)
        if ok and name == MACRO_NAME and type(body) == "string" and body:find("AltStableSyncProbe", 1, true) then
            return i, body
        end
    end
end

function P.macro()
    Section("macro  (character macro, 255-char body)")
    if InCombatLockdown() then Record("out of combat only"); return end
    local idx = FindProbeMacro()
    if idx then Record("probe macro already exists at index " .. idx .. " - run /syncprobe restart after a full exit") return end
    local mark = #blocked
    Call("GetNumMacros() before", GetNumMacros)
    Call("CreateMacro(name, icon, body, true)", CreateMacro, MACRO_NAME, "INV_Misc_QuestionMark", MACRO_BODY, true)
    local i2, body = FindProbeMacro()
    Record(("%-44s index=%s bodyLen=%s"):format("read back", ValStr(i2), ValStr(body and #body)))
    Record(("%-44s %s"):format("taint", TaintSince(mark)))
    CharDB().macroMarkedAt = Stamp()
    Record("now EXIT THE GAME FULLY, relaunch, log this character in, /syncprobe restart")
end

function P.bind()
    Section("bind  (CHARACTER binding set only)")
    if InCombatLockdown() then Record("out of combat only"); return end
    local ok, set = pcall(GetCurrentBindingSet)
    Record(("%-44s %s"):format("GetCurrentBindingSet()", ok and ValStr(set) or "THREW"))
    if not (Enum and Enum.BindingSet and set == Enum.BindingSet.Character) then
        Record("This character uses ACCOUNT bindings. The probe will not switch modes for you.")
        Record("To test: Options > Keybindings > tick 'Character Specific Key Bindings', then rerun.")
        return
    end
    local okA, current = pcall(GetBindingAction, BIND_KEY)
    if okA and current and current ~= "" and current ~= BIND_CMD then
        Record(BIND_KEY .. " is already bound to " .. current .. " - not touching it")
        return
    end
    local mark = #blocked
    Call("SetBinding(key, cmd)", SetBinding, BIND_KEY, BIND_CMD)
    Call("SaveBindings(Enum.BindingSet.Character)", SaveBindings, Enum.BindingSet.Character)
    Call("GetBindingAction(key) after", GetBindingAction, BIND_KEY)
    Call("GetCurrentBindingSet() after", GetCurrentBindingSet)
    Record(("%-44s %s"):format("taint", TaintSince(mark)))
    CharDB().bindMarkedAt = Stamp()
    Record("now EXIT THE GAME FULLY, relaunch, log this character in, /syncprobe restart")
end

function P.cvar()
    Section("cvar  (marker for a full-exit restart test)")
    local ok, cur = pcall(C_CVar.GetCVar, CVAR)
    Call("C_CVar.GetCVarInfo(" .. CVAR .. ")", C_CVar.GetCVarInfo, CVAR)
    local db = CharDB()
    if db.cvarOriginal == nil then db.cvarOriginal = ok and cur or false end
    local marker = (cur == "1.5") and "1.6" or "1.5"
    Call("C_CVar.SetCVar(" .. CVAR .. ", " .. marker .. ")", C_CVar.SetCVar, CVAR, marker)
    db.cvarMarker, db.cvarMarkedAt = marker, Stamp()
    Record("now EXIT THE GAME FULLY, relaunch, log this character in, /syncprobe restart")
end

function P.restart()
    Section("restart  (run after a FULL EXIT, not /reload)")
    local db, cdb = DB(), CharDB()
    Record(("%-44s account %s, character %s"):format("probe SV loadCount", ValStr(db.loadCount), ValStr(cdb.loadCount)))
    if cdb.macroMarkedAt then
        local idx, body = FindProbeMacro()
        Record(("%-44s marked %s -> index=%s bodyLen=%s"):format("macro survived?", cdb.macroMarkedAt, ValStr(idx), ValStr(body and #body)))
    end
    if cdb.bindMarkedAt then
        local ok, act = pcall(GetBindingAction, BIND_KEY)
        local okS, set = pcall(GetCurrentBindingSet)
        Record(("%-44s marked %s -> %s=%s set=%s"):format("binding survived?", cdb.bindMarkedAt, BIND_KEY,
            ok and ValStr(act) or "THREW", okS and ValStr(set) or "THREW"))
    end
    if cdb.cvarMarkedAt then
        local ok, v = pcall(C_CVar.GetCVar, CVAR)
        Record(("%-44s marked %s -> %s=%s (marker %s)"):format("cvar survived?", cdb.cvarMarkedAt, CVAR,
            ok and ValStr(v) or "THREW", ValStr(cdb.cvarMarker)))
    end
    if not (cdb.macroMarkedAt or cdb.bindMarkedAt or cdb.cvarMarkedAt) then
        Record("no markers on this character - run /syncprobe macro | bind | cvar first")
    end
    Record("Proof needs a FULL EXIT: say so when you paste this, or it proves nothing.")
end

function P.clean()
    Section("clean")
    if InCombatLockdown() then Record("out of combat only"); return end
    local cdb = CharDB()
    local idx = FindProbeMacro()
    if idx then Call("DeleteMacro(" .. idx .. ")", DeleteMacro, idx) end
    local ok, act = pcall(GetBindingAction, BIND_KEY)
    if ok and act == BIND_CMD and Enum and Enum.BindingSet and GetCurrentBindingSet() == Enum.BindingSet.Character then
        Call("SetBinding(key, nil)", SetBinding, BIND_KEY)
        Call("SaveBindings(Character)", SaveBindings, Enum.BindingSet.Character)
    end
    if cdb.cvarOriginal ~= nil then
        if cdb.cvarOriginal ~= false then Call("C_CVar.SetCVar restore", C_CVar.SetCVar, CVAR, cdb.cvarOriginal) end
        cdb.cvarOriginal = nil
    end
    cdb.macroMarkedAt, cdb.bindMarkedAt, cdb.cvarMarkedAt, cdb.cvarMarker = nil, nil, nil, nil
    Record("done")
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

local READ_ONLY = { "client", "actions", "ranks", "login", "editmode", "encoding" }

local function Persist(label)
    local db = DB()
    db.runs = db.runs or {}
    db.runs[label] = { at = Stamp(), build = Build(), char = UnitName("player"), lines = lines }
end

SLASH_ALTSTABLESYNCPROBE1 = "/syncprobe"
SlashCmdList.ALTSTABLESYNCPROBE = function(msg)
    local cmd = ((msg or ""):match("^%s*(%S*)") or ""):lower()
    if cmd == "copy" then ShowCopy(); return end
    lines = {}
    if cmd == "" or cmd == "all" then
        for _, name in ipairs(READ_ONLY) do P[name]() end
        cmd = "all"
    elseif P[cmd] then
        P[cmd]()
    else
        Out("/syncprobe [client|actions|ranks|login|editmode|encoding] | place | macro | bind | cvar | restart | clean | copy")
        return
    end
    Persist(cmd)
    -- place reports half a second later; open the window after that.
    C_Timer.After(cmd == "place" and 0.7 or 0, ShowCopy)
end
