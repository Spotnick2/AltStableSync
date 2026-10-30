------------------------------------------------------------
-- wow_game.lua - a Forever-shaped model of the game state AltStableSync writes
--
-- Loaded after wow_stubs.lua by tests that need action bars, the cursor,
-- macros, bindings, the spellbook and combat. Shapes follow the MEASURED
-- client (docs/forever-api-notes.md, 70245), not Classic:
--   - GetActionInfo on a macro slot returns the spell the macro SHOWS, not the
--     macro index ("macro", 75, "spell"); GetActionText(slot) is the name.
--   - C_Spell.PickupSpell puts "spell", bookIndex, "spell", spellID, nil on the
--     cursor; PickupMacro gives "macro", index; items "item", itemID, link.
--   - PlaceAction onto an occupied slot leaves the old action on the cursor.
--   - Character macros start at 121 (30 max), account 1-120. Within each scope
--     macros are kept SORTED BY NAME, so creating one shifts the indices of
--     those after it: code must never rely on a macro index staying put.
--   - The server appends a trailing newline to macro bodies: WoW.relaunch().
--   - Ranks are separate spell IDs; IsSpellBookItemLowRank marks lower ranks.
--
-- Driven through WoW.game:
--   WoW.game.setup{ spells = {...}, actions = {...}, macros = {...}, keys = {...}, items = {...} }
--   WoW.game.combatAfter = n   -- InCombatLockdown() turns true after n more mutating calls
--   WoW.game.calls             -- every mutating call, in order (for "wrote nothing" checks)
--   WoW.game.blocked           -- protected calls attempted IN COMBAT (each also raises, like
--                                 the client's ADDON_ACTION_BLOCKED); must stay empty
--   WoW.relaunch()             -- a full exit: macro bodies gain the server newline
--   WoW.game.macroFault = "error" | "noop" | "wrong"  -- the next EditMacro raises, does
--                                 nothing, or writes another body (#6)
--   WoW.game.createFault = "error" | "wrong"  -- the next CreateMacro raises, or creates the
--                                 macro with another body (audit D10)
--   WoW.game.onEditMacro = function(index)  -- runs before each EditMacro (e.g. combat starts)
--
-- The pet (#47, measured on 70338): setup{ pet = { family = 4, familyName = "Bear",
-- name, guid, bar = { [i] = { token = "PET_ACTION_ATTACK" } | { spell = id } },
-- book = { { id, name } | { name } (a stance, no id) } } }. GetPetActionInfo
-- gives name, texture, isToken, ..., spellID; PickupPetAction lifts, drops
-- and swaps like PickupAction; the cursor reads "petaction", <spell id> (2
-- for a command or stance); the pet book is bank 1. Faults:
--   WoW.game.petFault = function(name, n) -> "error" | "noop" | "after-error"
--     for the n-th pet call (PickupPetAction / PickupSpellBookItem)
--   WoW.game.onPetCall = function(name, n)  -- e.g. a resummon between calls
--   WoW.game.afterPetCall = function(n)       -- after the n-th call acted (a client that misplaces)
-- An ability taken off the bar keeps its autocast in the pet's spellbook and
-- gets it back when placed again (measured 2026-10-11): G.pet.autocastMemory.
------------------------------------------------------------

local G = {}
WoW.game = G

local function copy(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = copy(x) end
    return o
end

-- spells: { { id, name, sub, low = bool, known = bool (default true), passive } }
function G.setup(opts)
    opts = opts or {}
    G.class = opts.class or "PRIEST"
    G.guid = opts.guid or "Player-70-0000AAAA"
    G.spells = opts.spells or {}
    G.items = opts.items or {}               -- [itemID] = count
    G.extra = opts.extra or {}               -- [spellID] = name: known, not in the book
    G.combat = false
    G.combatAfter = nil
    G.calls = {}
    G.blocked = {}
    G.cursor = nil
    G.bindingSet = opts.bindingSet or 2      -- Enum.BindingSet.Character
    G.keys = copy(opts.keys or {})           -- [key] = command
    G.savedKeys = copy(G.keys)
    G.saveFails = false
    G.accountKeys = G.bindingSet == 1 and copy(G.keys) or nil
    G.charStore = opts.charStore and copy(opts.charStore) or (G.bindingSet == 2 and copy(G.keys) or nil)
    G.unbound = { "TOGGLEAUTORUN", "JUMP" }
    G.numBindings, G.bindingFails, G.bindFault, G.keyFails, G.emptyCommand = nil, nil, nil, nil, nil
    G.actionFails = nil
    G.timers = {}
    G.locale = opts.locale or "enUS"
    G.pet = nil
    if opts.pet then
        local o = opts.pet
        G.pet = { family = o.family or 4, familyName = o.familyName or "Bear", name = o.name or "Tarthosuk",
                  guid = o.guid or "Pet-0-1", hasBar = o.hasBar ~= false, bar = {}, book = copy(o.book or {}) }
        for i, a in pairs(o.bar or {}) do
            G.pet.bar[i] = a.token and { token = a.token } or { spell = a.spell, autocast = a.autocast }
        end
    end
    G.petCalls, G.petFault, G.onPetCall, G.afterPetCall, G.petReadFails, G.petBookFails = 0, nil, nil, nil, nil, nil
    -- macros: { name, icon, body, char = bool, shows = spellID }
    G.macroFault, G.onEditMacro, G.createFault = nil, nil, nil
    G.account, G.char = {}, {}
    for _, m in ipairs(opts.macros or {}) do
        local t = { name = m.name, icon = m.icon or 134400, body = m.body, shows = m.shows }
        table.insert(m.char and G.char or G.account, t)
    end
    G.sortMacros()
    -- actions: [slot] = { spell = id } | { item = id } | { macro = name } | { flyout = id }
    G.actions = {}
    for slot, a in pairs(opts.actions or {}) do
        if a.spell then G.actions[slot] = { kind = "spell", id = a.spell }
        elseif a.item then G.actions[slot] = { kind = "item", id = a.item }
        elseif a.flyout then G.actions[slot] = { kind = "flyout", id = a.flyout }
        elseif a.macro then
            local ref
            for _, m in ipairs(G.char) do if m.name == a.macro then ref = m end end
            for _, m in ipairs(G.account) do if m.name == a.macro then ref = ref or m end end
            assert(ref, "setup: no macro " .. a.macro)
            G.actions[slot] = { kind = "macro", ref = ref }
        end
    end
end

function G.sortMacros()
    local function byName(a, b) return a.name < b.name end
    table.sort(G.account, byName)
    table.sort(G.char, byName)
end

-- Index of a macro table, or nil (deleted).
function G.indexOf(ref)
    for i, m in ipairs(G.account) do if m == ref then return i end end
    for i, m in ipairs(G.char) do if m == ref then return 120 + i end end
end

local function macroAt(index)
    if index >= 121 then return G.char[index - 120] end
    return G.account[index]
end

-- A mutating call. `protected`: refused in combat (the client blocks action
-- bar, macro and binding writes in combat lockdown). ClearCursor is not.
local function mutate(name, protected)
    if protected and G.combat then
        G.blocked[#G.blocked + 1] = name
        error("ADDON_ACTION_BLOCKED: " .. name, 3)
    end
    G.calls[#G.calls + 1] = name
    if G.combatAfter then
        G.combatAfter = G.combatAfter - 1
        if G.combatAfter <= 0 then G.combat, G.combatAfter = true, nil end
    end
end

function WoW.relaunch()
    for _, list in ipairs({ G.account, G.char }) do
        for _, m in ipairs(list) do
            if m.body:sub(-1) ~= "\n" then m.body = m.body .. "\n" end
        end
    end
    G.keys = copy(G.savedKeys)
    G.cursor, G.combat = nil, false
end

------------------------------------------------------------
-- Unit, combat, enums
------------------------------------------------------------

local CLASS_NAMES = { PRIEST = "Priest", DRUID = "Druid", MAGE = "Mage", WARRIOR = "Warrior", HUNTER = "Hunter" }
function UnitClass() return CLASS_NAMES[G.class] or G.class, G.class, 5 end
function UnitGUID(unit)
    if unit == "pet" then return G.pet and G.pet.guid end
    return G.guid
end
function UnitFullName() return "Karuzo", "Elegia" end
function UnitName(unit)
    if unit == "pet" then return G.pet and G.pet.name end
    return "Karuzo", "Elegia"
end
function UnitExists(unit)
    if unit == "pet" then return G.pet ~= nil end
    return true
end
function UnitCreatureFamily(unit)
    if unit == "pet" and G.pet then return G.pet.familyName, G.pet.family end
end
function PetHasActionBar() return G.pet ~= nil and G.pet.hasBar end
function GetLocale() return G.locale end
function InCombatLockdown() return G.combat end

Enum = Enum or {}
Enum.BindingSet = { Default = 0, Account = 1, Character = 2, Current = 3 }
Enum.SpellBookSpellBank = { Player = 0, Pet = 1 }
Enum.SpellBookItemType = { None = 0, Spell = 1, FutureSpell = 2, PetAction = 3, Flyout = 4 }
Constants = Constants or {}
Constants.MacroConsts = { MAX_ACCOUNT_MACROS = 120, MAX_CHARACTER_MACROS = 30 }

------------------------------------------------------------
-- Spellbook
------------------------------------------------------------

local function spellById(id)
    for i, s in ipairs(G.spells) do if s.id == id then return s, i end end
end
local function isKnown(s) return s and s.known ~= false end
-- Known by id: in the book, or one of G.extra (known but not in the class
-- skill lines, like a profession).
local function knownId(id)
    if (G.extra or {})[id] then return true end
    return isKnown((spellById(id))) and true or false
end

C_Spell = {
    GetSpellName = function(id)
        local s = spellById(id)
        return (s and s.name) or (G.extra or {})[id]
    end,
    -- "Rank 2" for a ranked spell, "" otherwise (declared on 70532).
    GetSpellSubtext = function(id)
        local s = spellById(id)
        return s and s.sub or ""
    end,
    PickupSpell = function(id)
        mutate("C_Spell.PickupSpell", true)
        local s, i = spellById(id)
        if isKnown(s) or (G.extra or {})[id] then G.cursor = { kind = "spell", id = id, book = i } end
    end,
}
function IsPlayerSpell(id) return knownId(id) end

C_SpellBook = {
    -- Line 1 "General" holds the leading spells marked `general` (racials,
    -- Attack...); line 2 the class tab with the rest (measured layout, 70291).
    GetNumSpellBookSkillLines = function() return 2 end,
    GetSpellBookSkillLineInfo = function(line)
        local nGeneral = 0
        while G.spells[nGeneral + 1] and G.spells[nGeneral + 1].general do nGeneral = nGeneral + 1 end
        if line == 1 then return { name = "General", itemIndexOffset = 0, numSpellBookItems = nGeneral } end
        if line == 2 then return { name = "Class", itemIndexOffset = nGeneral, numSpellBookItems = #G.spells - nGeneral } end
    end,
    GetSpellBookItemInfo = function(i, bank)
        if bank == Enum.SpellBookSpellBank.Pet then
            if G.petBookFails then error("pet book read failed", 2) end
            local b = G.pet and G.pet.book[i]
            if not b then return nil end
            return { spellID = b.id, name = b.name, isPassive = b.passive or false, itemType = Enum.SpellBookItemType.PetAction }
        end
        local s = G.spells[i]
        if not s then return nil end
        return { spellID = s.id, name = s.name, subName = s.sub or "", actionID = s.id, isPassive = s.passive or false,
                 itemType = isKnown(s) and Enum.SpellBookItemType.Spell or Enum.SpellBookItemType.FutureSpell }
    end,
    IsSpellBookItemLowRank = function(i) local s = G.spells[i]; return s and s.low or false end,
    IsSpellKnown = function(id) return knownId(id) end,
    HasPetSpells = function()
        if not G.pet then return nil end
        return #G.pet.book, "PET"
    end,
    PickupSpellBookItem = function(i, bank)
        if G.petCallFault("PickupSpellBookItem") then return end
        local b = bank == Enum.SpellBookSpellBank.Pet and G.pet and G.pet.book[i]
        if b and b.id then
            G.cursor = { kind = "petaction", item = { spell = b.id, autocast = (G.pet.autocastMemory or {})[b.id] } }
        end
        G.petCallAfter()
    end,
}

------------------------------------------------------------
-- Items
------------------------------------------------------------

C_Item = {
    GetItemCount = function(id) return G.items[id] or 0 end,
    PickupItem = function(id)
        mutate("C_Item.PickupItem", true)
        if (G.items[id] or 0) > 0 then G.cursor = { kind = "item", id = id } end
    end,
}

------------------------------------------------------------
-- Cursor and action slots
------------------------------------------------------------

function GetCursorInfo()
    local c = G.cursor
    if not c then return nil end
    if c.kind == "spell" then return "spell", c.book or 0, "spell", c.id, nil end
    if c.kind == "item" then return "item", c.id, "|cffffffff|Hitem:" .. c.id .. "|h[item]|h|r" end
    if c.kind == "macro" then return "macro", G.indexOf(c.ref) end
    if c.kind == "flyout" then return "flyout", c.id end
    if c.kind == "petaction" then return "petaction", c.item.spell or 2 end
end

function ClearCursor() mutate("ClearCursor"); G.cursor = nil end

function GetActionInfo(slot)
    local a = G.actions[slot]
    if not a then return nil end
    if a.kind == "spell" then return "spell", a.id, "spell" end
    if a.kind == "item" then return "item", a.id end
    if a.kind == "flyout" then return "flyout", a.id end
    if a.kind == "macro" then
        -- Measured: the shown spell's id, not the macro index.
        return "macro", a.ref.shows or 0, a.ref.shows and "spell" or ""
    end
end

function GetActionText(slot)
    local a = G.actions[slot]
    if a and a.kind == "macro" then return a.ref.name end
    return nil
end

function HasAction(slot) return G.actions[slot] ~= nil end

local function cursorAsAction()
    local c = G.cursor
    if c.kind == "macro" then return { kind = "macro", ref = c.ref } end
    return { kind = c.kind, id = c.id }
end

local function actionAsCursor(a)
    if a.kind == "macro" then return { kind = "macro", ref = a.ref } end
    if a.kind == "spell" then local _, i = spellById(a.id); return { kind = "spell", id = a.id, book = i } end
    return { kind = a.kind, id = a.id }
end

function PlaceAction(slot)
    mutate("PlaceAction", true)
    if not G.cursor then return end
    local old = G.actions[slot]
    G.actions[slot] = cursorAsAction()
    G.cursor = old and actionAsCursor(old) or nil
end

function PickupAction(slot)
    mutate("PickupAction", true)
    local a = G.actions[slot]
    if G.cursor then
        local new = cursorAsAction()
        G.actions[slot] = new
        G.cursor = a and actionAsCursor(a) or nil
    elseif a then
        G.actions[slot] = nil
        G.cursor = actionAsCursor(a)
    end
end

------------------------------------------------------------
-- The pet bar (#47)
------------------------------------------------------------

local function petSpellName(id)
    for _, b in ipairs(G.pet and G.pet.book or {}) do if b.id == id then return b.name end end
    return "Spell " .. tostring(id)
end

function GetPetActionInfo(i)
    if G.petReadFails then error("GetPetActionInfo failed", 2) end
    local a = G.pet and G.pet.bar[i]
    if not a then return nil end
    if a.token then return a.token, 1, true, false, false, false, nil end
    return petSpellName(a.spell), 1, false, false, true, a.autocast or false, a.spell
end

-- A pet call: counted, maybe faulted. Returns true when the call does nothing.
local pending
function G.petCallFault(name)
    mutate(name, true)
    G.petCalls = G.petCalls + 1
    if G.onPetCall then G.onPetCall(name, G.petCalls) end
    local f = G.petFault and G.petFault(name, G.petCalls)
    if f == "error" then error(name .. " failed", 3) end
    pending = f == "after-error" and name or nil
    return f == "noop"
end
function G.petCallAfter()
    if G.afterPetCall then G.afterPetCall(G.petCalls) end
    if pending then local n = pending; pending = nil; error(n .. " failed after acting", 3) end
end

function PickupPetAction(i)
    if G.petCallFault("PickupPetAction") then return end
    local bar = G.pet and G.pet.bar
    if not bar then return end
    local a = bar[i]
    if G.cursor and G.cursor.kind == "petaction" then
        bar[i] = copy(G.cursor.item)
        G.cursor = a and { kind = "petaction", item = a } or nil
    elseif not G.cursor and a then
        bar[i] = nil
        G.cursor = { kind = "petaction", item = a }
        if a.spell then
            G.pet.autocastMemory = G.pet.autocastMemory or {}
            G.pet.autocastMemory[a.spell] = a.autocast
        end
    end
    G.petCallAfter()
end

------------------------------------------------------------
-- Macros
------------------------------------------------------------

function GetNumMacros() return #G.account, #G.char end

function GetMacroInfo(index)
    local m = type(index) == "number" and macroAt(index)
    if not m then return nil end
    return m.name, m.icon, m.body
end

function CreateMacro(name, icon, body, perCharacter)
    mutate("CreateMacro", true)
    local list = perCharacter and G.char or G.account
    local cap = perCharacter and 30 or 120
    if #list >= cap then error("too many macros", 2) end
    local fault = G.createFault
    G.createFault = nil
    if fault == "error" then error("CreateMacro failed", 2) end
    local m = { name = name, icon = icon, body = fault == "wrong" and (body .. " -- something else") or body }
    table.insert(list, m)
    G.sortMacros()
    return G.indexOf(m)
end

-- EditMacro(index, name, icon, body) -> index. Character macros only: an
-- account index raises, as AltStableSync must never write one (#6). The
-- name sorts again, so indices may shift (none of ours rename).
function EditMacro(index, name, icon, body)
    if G.onEditMacro then G.onEditMacro(index) end
    mutate("EditMacro", true)
    if type(index) ~= "number" or index < 121 then error("EditMacro on an account macro: never allowed", 2) end
    local m = macroAt(index)
    if not m then error("EditMacro: no macro " .. tostring(index), 2) end
    local fault = G.macroFault
    G.macroFault = nil
    if fault == "error" then error("EditMacro failed", 2) end
    if fault == "noop" then return index end
    if name then m.name = name end
    if icon then m.icon = icon end
    if body then m.body = fault == "wrong" and (body .. " -- something else") or body end
    G.sortMacros()
    return G.indexOf(m)
end
function DeleteMacro() mutate("DeleteMacro"); error("DeleteMacro must never be called by AltStableSync in these tests", 2) end

function PickupMacro(index)
    mutate("PickupMacro", true)
    local m = type(index) == "number" and macroAt(index)
    if m then G.cursor = { kind = "macro", ref = m } end
end

------------------------------------------------------------
-- Bindings
------------------------------------------------------------

function GetCurrentBindingSet() return G.bindingSet end

function GetBindingKey(command)
    if G.keyFails then error("GetBindingKey failed", 2) end
    local keys = {}
    for k, c in pairs(G.keys) do if c == command then keys[#keys + 1] = k end end
    table.sort(keys)
    return unpack(keys)
end

function GetBindingAction(key)
    if G.actionFails then error("GetBindingAction failed", 2) end
    return G.keys[key] or ""
end

function SetBinding(key, command)
    mutate("SetBinding", true)
    G.keys[key] = command
    return true
end

-- The binding list: every command that has a key now, plus G.unbound (always
-- listed, like the client's 333 entries), sorted. GetBinding(i) returns
-- command, category, then its keys.
local function bindingList()
    local seen, list = {}, {}
    -- Keys bound by SetBindingClick and the like ("CLICK Bar:LeftButton")
    -- are not in the client's binding list.
    for _, c in pairs(G.keys) do
        if not seen[c] and not c:find(" ", 1, true) then seen[c] = true; list[#list + 1] = c end
    end
    for _, c in ipairs(G.unbound) do if not seen[c] then seen[c] = true; list[#list + 1] = c end end
    table.sort(list)
    return list
end
function GetNumBindings()
    if G.numBindings ~= nil then return G.numBindings end
    return #bindingList()
end
function GetBinding(i)
    if G.bindingFails then error("GetBinding failed", 2) end
    if G.emptyCommand then return "" end
    local c = bindingList()[i]
    if not c then return nil end
    local keys = {}
    for k, cmd in pairs(G.keys) do if cmd == c then keys[#keys + 1] = k end end
    table.sort(keys)
    return c, "category", unpack(keys)
end

-- Saved per-set stores (#7). Measured on 70291 for a character with no
-- Character store: LoadBindings(Character) leaves the keys as they are,
-- the active set reads Account until SaveBindings(Character), and
-- UPDATE_BINDINGS fires inside LoadBindings. A Character store that differs
-- (G.charStore) is an INJECTED fault, not a measured case.
-- G.bindFault[name .. set] = "error" | "false" | "change-error" | "change-false":
-- the call fails, after changing a key first for the "change-" ones.
local function fault(name, set)
    local f = G.bindFault and G.bindFault[name .. tostring(set)]
    if not f then return nil end
    if f:find("^change") then G.keys["F12"] = "FAULT_COMMAND" end
    if f:find("error$") then error(name .. " failed", 3) end
    return false
end

function SaveBindings(set)
    mutate("SaveBindings", true)
    if G.saveFails then error("SaveBindings failed", 2) end
    if fault("SaveBindings", set) == false then return false end
    if set == Enum.BindingSet.Account then G.accountKeys = copy(G.keys) end
    if set == Enum.BindingSet.Character then G.charStore, G.bindingSet = copy(G.keys), set end
    if set == G.bindingSet then G.savedKeys = copy(G.keys) end
end

-- Only the #7 switch may call it: the tests wrap Loadout.UseCharacterBindings
-- to set G.switching, so any other path (Restore, Save, an event) fails loudly.
function LoadBindings(set)
    if not G.switching then error("LoadBindings outside the #7 switch", 2) end
    mutate("LoadBindings")
    if fault("LoadBindings", set) == false then return false end
    if set == Enum.BindingSet.Character and G.charStore then G.keys = copy(G.charStore) end
    if set == Enum.BindingSet.Account and G.accountKeys then G.keys = copy(G.accountKeys) end
    WoW.fire("UPDATE_BINDINGS")
end

-- C_Timer.After on the test clock: WoW.tick(seconds) advances it in 0.1 s
-- steps and runs what is due.
C_Timer = C_Timer or {}
function C_Timer.After(delay, fn) G.timers[#G.timers + 1] = { at = WoW.clock + delay, fn = fn } end
function WoW.tick(seconds)
    local stop = WoW.clock + seconds
    while WoW.clock < stop - 1e-9 do
        WoW.clock = WoW.clock + 0.1
        local due, rest = {}, {}
        for _, t in ipairs(G.timers) do
            if t.at <= WoW.clock + 1e-9 then due[#due + 1] = t else rest[#rest + 1] = t end
        end
        G.timers = rest
        for _, t in ipairs(due) do t.fn() end
    end
end

G.setup()
