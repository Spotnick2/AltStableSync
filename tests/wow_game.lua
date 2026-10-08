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
--   WoW.relaunch()             -- a full exit: macro bodies gain the server newline
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
    G.combat = false
    G.combatAfter = nil
    G.calls = {}
    G.cursor = nil
    G.bindingSet = opts.bindingSet or 2      -- Enum.BindingSet.Character
    G.keys = copy(opts.keys or {})           -- [key] = command
    G.savedKeys = copy(G.keys)
    G.saveFails = false
    -- macros: { name, icon, body, char = bool, shows = spellID }
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

local function mutate(name)
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
function UnitGUID() return G.guid end
function UnitFullName() return "Karuzo", "Elegia" end
function UnitName() return "Karuzo", "Elegia" end
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

C_Spell = {
    GetSpellName = function(id) local s = spellById(id); return s and s.name end,
    PickupSpell = function(id)
        mutate("C_Spell.PickupSpell")
        local s, i = spellById(id)
        if isKnown(s) then G.cursor = { kind = "spell", id = id, book = i } end
    end,
}

C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 1 end,
    GetSpellBookSkillLineInfo = function() return { name = "General", itemIndexOffset = 0, numSpellBookItems = #G.spells } end,
    GetSpellBookItemInfo = function(i)
        local s = G.spells[i]
        if not s then return nil end
        return { spellID = s.id, name = s.name, subName = s.sub or "", actionID = s.id, isPassive = s.passive or false,
                 itemType = isKnown(s) and Enum.SpellBookItemType.Spell or Enum.SpellBookItemType.FutureSpell }
    end,
    IsSpellBookItemLowRank = function(i) local s = G.spells[i]; return s and s.low or false end,
    IsSpellKnown = function(id) return isKnown((spellById(id))) end,
}

------------------------------------------------------------
-- Items
------------------------------------------------------------

C_Item = {
    GetItemCount = function(id) return G.items[id] or 0 end,
    PickupItem = function(id)
        mutate("C_Item.PickupItem")
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
    mutate("PlaceAction")
    if not G.cursor then return end
    local old = G.actions[slot]
    G.actions[slot] = cursorAsAction()
    G.cursor = old and actionAsCursor(old) or nil
end

function PickupAction(slot)
    mutate("PickupAction")
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
-- Macros
------------------------------------------------------------

function GetNumMacros() return #G.account, #G.char end

function GetMacroInfo(index)
    local m = type(index) == "number" and macroAt(index)
    if not m then return nil end
    return m.name, m.icon, m.body
end

function CreateMacro(name, icon, body, perCharacter)
    mutate("CreateMacro")
    local list = perCharacter and G.char or G.account
    local cap = perCharacter and 30 or 120
    if #list >= cap then error("too many macros", 2) end
    local m = { name = name, icon = icon, body = body }
    table.insert(list, m)
    G.sortMacros()
    return G.indexOf(m)
end

function EditMacro() mutate("EditMacro"); error("EditMacro must never be called by AltStableSync in these tests", 2) end
function DeleteMacro() mutate("DeleteMacro"); error("DeleteMacro must never be called by AltStableSync in these tests", 2) end

function PickupMacro(index)
    mutate("PickupMacro")
    local m = type(index) == "number" and macroAt(index)
    if m then G.cursor = { kind = "macro", ref = m } end
end

------------------------------------------------------------
-- Bindings
------------------------------------------------------------

function GetCurrentBindingSet() return G.bindingSet end

function GetBindingKey(command)
    local keys = {}
    for k, c in pairs(G.keys) do if c == command then keys[#keys + 1] = k end end
    table.sort(keys)
    return unpack(keys)
end

function GetBindingAction(key) return G.keys[key] or "" end

function SetBinding(key, command)
    mutate("SetBinding")
    G.keys[key] = command
    return true
end

function SaveBindings(set)
    mutate("SaveBindings")
    if G.saveFails then error("SaveBindings failed", 2) end
    if set == G.bindingSet then G.savedKeys = copy(G.keys) end
end

function LoadBindings() mutate("LoadBindings"); error("LoadBindings must never be called (no set switching)", 2) end

G.setup()
