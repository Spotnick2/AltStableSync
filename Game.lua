------------------------------------------------------------
-- Game.lua - normalised reads of the game state a loadout covers (#4)
--
-- Every client shape quirk lives here, measured on 70245
-- (docs/forever-api-notes.md):
--   - a macro action slot reports the spell the macro SHOWS, never the macro
--     index; the macro is identified by GetActionText(slot) (its name);
--   - the server appends a trailing newline to macro bodies;
--   - character macros are 121..120+n, account macros 1..n;
--   - spell ranks are separate ids linked only by name; the top known rank is
--     the same-name Spell entry that is not IsSpellBookItemLowRank.
-- Reads only: nothing here writes game state.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local Game = {}
ASS.Game = Game

-- The action slots a loadout covers (#5; measured on 70291 with
-- /syncprobe bars, docs/forever-api-notes.md "Action bars"): 1-120 (Action
-- Bar 1 pages 1-2, Action Bars 2-5, and the four stance/form pages, written
-- by slot id whatever form is active) and 145-180 (Action Bars 6-8). Never
-- 121-144 (skyriding/possess/override pages) or 181+ (no button shows them).
Game.SLOT_RANGES = { { 1, 120 }, { 145, 180 } }
Game.IS_SLOT = ASS.Cover.AddTo({}, Game.SLOT_RANGES)
Game.SLOT_LIST = {}
for slot in pairs(Game.IS_SLOT) do Game.SLOT_LIST[#Game.SLOT_LIST + 1] = slot end
table.sort(Game.SLOT_LIST)

-- Action Bar 1's two pages and the four stance/form pages take turns on the
-- same twelve buttons; every other bar shows alongside whichever is up. The
-- page index of a slot, or nil for a bar that is always beside it.
local MAIN_PAGES = { 1, 13, 73, 85, 97, 109 }
function Game.MainPage(slot)
    for i, first in ipairs(MAIN_PAGES) do
        if slot >= first and slot < first + 12 then return i end
    end
    return nil
end

-- Bars as the game's settings name them, by first slot (measured button ->
-- slot map). The stance/form pages are numbered: which form uses which page
-- isn't measured yet.
local BARS = {
    { 1, "Action Bar 1" }, { 13, "Action Bar 1, page 2" }, { 25, "Action Bar 4" }, { 37, "Action Bar 5" },
    { 49, "Action Bar 3" }, { 61, "Action Bar 2" }, { 73, "Stance/form page 1" }, { 85, "Stance/form page 2" },
    { 97, "Stance/form page 3" }, { 109, "Stance/form page 4" }, { 145, "Action Bar 6" },
    { 157, "Action Bar 7" }, { 169, "Action Bar 8" },
}

-- The bar's name and the button (1-12) for a slot; "Slot N" for any other.
function Game.SlotLabel(slot)
    for i = #BARS, 1, -1 do
        local first = BARS[i][1]
        if slot >= first and slot < first + 12 then return BARS[i][2], slot - first + 1 end
    end
    return "Slot " .. tostring(slot), nil
end

-- The commands a loadout carries keys for: the main bar's twelve buttons
-- and the pet bar's ten (#47).
Game.COMMANDS = {}
for i = 1, 12 do Game.COMMANDS[i] = "ACTIONBUTTON" .. i end
for i = 1, 10 do Game.COMMANDS[12 + i] = "BONUSACTIONBUTTON" .. i end

-- A command as a preview names it.
function Game.CommandLabel(cmd)
    local n = type(cmd) == "string" and cmd:match("^BONUSACTIONBUTTON(%d+)$")
    if n then return "Pet bar button " .. n end
    return tostring(cmd)
end

local CHAR_FIRST = 121

-- Bodies compare after stripping the trailing CR/LF the server appends, and
-- nothing else.
function Game.Normalize(body)
    return (tostring(body or ""):gsub("[\r\n]+$", ""))
end

------------------------------------------------------------
-- Macros
------------------------------------------------------------

Game.MAX_CHAR_MACROS = (Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_CHARACTER_MACROS) or 30
local MAX_ACCOUNT_MACROS = (Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_ACCOUNT_MACROS) or 120

local function Count(n, max)
    return type(n) == "number" and n >= 0 and n <= max and n == math.floor(n)
end

-- Every macro and the two counts: { list = {{ index, name, icon, body,
-- scope = "account" | "char" }}, nAccount, nChar }, or nil when anything
-- can't be read: a failed call, a count out of range, or a counted index
-- with no name (unreadable is never "no macros", #46).
function Game.MacroInventory()
    local out = {}
    local ok, nAccount, nChar = pcall(GetNumMacros)
    if not ok or not Count(nAccount, MAX_ACCOUNT_MACROS) or not Count(nChar, Game.MAX_CHAR_MACROS) then return nil end
    local function read(i, scope)
        local okI, name, icon, body = pcall(GetMacroInfo, i)
        if not okI or type(name) ~= "string" then return false end
        out[#out + 1] = { index = i, name = name, icon = icon, body = body, scope = scope }
        return true
    end
    for i = 1, nAccount do
        if not read(i, "account") then return nil end
    end
    for i = CHAR_FIRST, CHAR_FIRST + nChar - 1 do
        if not read(i, "char") then return nil end
    end
    return { list = out, nAccount = nAccount, nChar = nChar }
end

function Game.Macros()
    local inv = Game.MacroInventory()
    return inv and inv.list
end

-- The macros named `name`, or nil when the macro list can't be read.
function Game.MacrosNamed(name)
    local all = Game.Macros()
    if not all then return nil end
    local out = {}
    for _, m in ipairs(all) do
        if m.name == name then out[#out + 1] = m end
    end
    return out
end

-- This character's macro count, or nil when it can't be read.
function Game.CharMacroCount()
    local inv = Game.MacroInventory()
    return inv and inv.nChar
end

------------------------------------------------------------
-- Spells
------------------------------------------------------------

local BANK = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0

-- The player's learned castable spells: { [id] = { name, low, order, line } }
-- (`line`: the skill line; 1 is "General", racials and shared spells,
-- measured 70291, and the class tabs come after it)
-- (`order`: the book index; ranks are ascending book items), and by name
-- the top known rank (the same-name Spell entry that is not low rank).
-- `complete` is false when any read failed: then a spell missing from it is
-- not proof that it isn't learned (#46), and one whose rank read failed is
-- known but never taken as a top rank.
function Game.Spellbook()
    local byId, top, complete = {}, {}, true
    local T = Enum and Enum.SpellBookItemType
    local okN, n = pcall(C_SpellBook.GetNumSpellBookSkillLines)
    if not okN or type(n) ~= "number" then n, complete = 0, false end
    for line = 1, n do
        local okL, li = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
        if okL and type(li) == "table" and type(li.itemIndexOffset) == "number" and type(li.numSpellBookItems) == "number" then
            for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                local okI, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, BANK)
                if not okI or type(info) ~= "table" then
                    complete = false
                elseif (not T or info.itemType == T.Spell) and not (info.spellID and info.name) then
                    complete = false        -- spell data not loaded yet: not proof of absence
                elseif info.spellID and info.name and not info.isPassive
                    and (not T or info.itemType == T.Spell) then
                    local okR, low = pcall(C_SpellBook.IsSpellBookItemLowRank, i, BANK)
                    local rankRead = okR and type(low) == "boolean"
                    if not rankRead then complete = false end
                    low = rankRead and low
                    -- `order`: ranks are separate, ascending book items (measured).
                    byId[info.spellID] = { name = info.name, low = low, order = i, line = line }
                    if rankRead and not low then top[info.name] = info.spellID end
                end
            end
        else
            complete = false
        end
    end
    return { byId = byId, top = top, complete = complete }
end

-- Known by id, outside the book scan: true when the client says so, false
-- when every answer is a plain "no", nil when it can't be read. For spells
-- the class skill lines may not hold (professions, #48 review).
function Game.SpellKnownById(id)
    local answered, known = false, false
    for _, fn in ipairs({ C_SpellBook and C_SpellBook.IsSpellKnown or false, IsPlayerSpell or false }) do
        if fn then
            local ok, v = pcall(fn, id)
            if not ok or type(v) ~= "boolean" then return nil end
            answered, known = true, known or v
        end
    end
    if known then return true end
    if answered then return false end
    return nil
end

-- Known = in the spellbook scan (measured, 70245), low ranks included, or
-- known by id (a spell outside the class skill lines).
function Game.SpellKnown(id, book)
    book = book or Game.Spellbook()
    return book.byId[id] ~= nil or Game.SpellKnownById(id) == true
end

------------------------------------------------------------
-- Items, action slots
------------------------------------------------------------

function Game.ItemCount(id)
    return Game.ItemCountRead(id) or 0
end

-- The bag count, or nil when it can't be read (never "none", #46).
function Game.ItemCountRead(id)
    local ok, n = pcall(C_Item.GetItemCount, id)
    if ok and type(n) == "number" and n >= 0 then return n end
    return nil
end

-- The slot's content, normalised:
--   nil (empty) | { kind = "spell", id } | { kind = "item", id }
--   | { kind = "macro", name, body, scope, index } (an unambiguous macro)
--   | { kind = "unsupported", what } (anything this slice can't capture and
--     restore exactly: flyouts, companions, ambiguous macro names, ...).
function Game.ActionAt(slot)
    local ok, kind, id = pcall(GetActionInfo, slot)
    if not ok then return { kind = "unsupported", what = "unreadable" } end
    if kind == nil then return nil end
    if kind == "spell" and type(id) == "number" then return { kind = "spell", id = id } end
    if kind == "item" and type(id) == "number" then return { kind = "item", id = id } end
    if kind == "macro" then
        local okT, name = pcall(GetActionText, slot)
        if not okT or type(name) ~= "string" or name == "" then
            return { kind = "unsupported", what = "macro without a name" }
        end
        local matches = Game.MacrosNamed(name)
        if not matches then return { kind = "unsupported", what = "macros unreadable" } end
        if #matches ~= 1 then
            return { kind = "unsupported", what = "duplicate macro name", name = name }
        end
        local m = matches[1]
        return { kind = "macro", name = m.name, body = m.body, scope = m.scope, index = m.index, icon = m.icon }
    end
    return { kind = "unsupported", what = tostring(kind) }
end

-- Do two normalised actions hold the same thing?
-- Can the slot content `a` be captured and put back exactly by this slice?
-- Empty, a known spell, an item still in the bags, an unambiguous macro.
function Game.Restorable(a, book)
    if a == nil then return true end
    if a.kind == "spell" then return Game.SpellKnown(a.id, book) end
    if a.kind == "item" then return Game.ItemCount(a.id) > 0 end
    if a.kind == "macro" then
        local m = Game.MacrosNamed(a.name)
        return m ~= nil and #m == 1
    end
    return false
end

function Game.SameAction(a, b)
    if a == nil or b == nil then return a == b end
    if a.kind ~= b.kind then return false end
    if a.kind == "macro" then
        return a.name == b.name and a.scope == b.scope and Game.Normalize(a.body) == Game.Normalize(b.body)
    end
    return a.id == b.id
end

------------------------------------------------------------
-- Bindings, cursor
------------------------------------------------------------

-- Every key bound to `command` (GetBindingKey returns them all), as a list;
-- nil when the client call fails (unreadable is not "no keys").
function Game.KeysFor(command)
    -- select("#") keeps the exact return count: a nil in the middle of the
    -- tuple can't make #r stop early and hide the keys after it.
    local function pack(...) return select("#", ...), { ... } end
    local n, r = pack(pcall(GetBindingKey, command))
    if not r[1] then return nil end
    local keys = {}
    for i = 2, n do if type(r[i]) == "string" and r[i] ~= "" then keys[#keys + 1] = r[i] end end
    return keys
end

-- The command a key runs, false when unbound, nil when unreadable (a failed
-- read must never be recorded as "unbound": restoring that would wipe a key).
function Game.CommandOf(key)
    local ok, cmd = pcall(GetBindingAction, key)
    if not ok then return nil end
    if cmd == nil or cmd == "" then return false end
    return cmd
end

function Game.CharacterBindings()
    local ok, set = pcall(GetCurrentBindingSet)
    return ok and Enum and Enum.BindingSet and set == Enum.BindingSet.Character
end

-- The active binding set, or nil when unreadable.
function Game.BindingSet()
    local ok, set = pcall(GetCurrentBindingSet)
    if ok and type(set) == "number" then return set end
    return nil
end

-- Keys checked by what they do (#7): the binding list (GetBinding) holds
-- only the commands from Bindings.xml, not keys an addon bound with
-- SetBindingClick/Macro/Spell/Item ("CLICK ...", "MACRO ..."), which bar
-- addons use. Every modifier chord of these inputs is read by key: the
-- keyboard, mouse buttons 1-31 and the wheel (Blizzard's BindingUtil range),
-- and the gamepad. Each custom command found that way is then read by
-- command too, so its keys outside this list are compared as well.
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
-- Every chord of ALT, CTRL, SHIFT, META, in the client's order.
local MODIFIERS = {}
for mask = 0, 15 do
    local m = ""
    if mask % 2 >= 1 then m = m .. "ALT-" end
    if mask % 4 >= 2 then m = m .. "CTRL-" end
    if mask % 8 >= 4 then m = m .. "SHIFT-" end
    if mask >= 8 then m = m .. "META-" end
    MODIFIERS[#MODIFIERS + 1] = m
end
local KEYS = {}
for _, m in ipairs(MODIFIERS) do for _, k in ipairs(KEY_BASES) do KEYS[#KEYS + 1] = m .. k end end
Game.KEYS = KEYS

-- Every bound command with all its keys (command -> list), plus what each
-- of those keys and of Game.KEYS does ("@" .. key -> action) (#7). nil when
-- any read fails: an incomplete map can't prove the keys were kept. A custom
-- binding only on an input outside Game.KEYS stays out of reach: no client
-- call lists bound keys.
function Game.BindingMap()
    local ok, n = pcall(GetNumBindings)
    if not ok or type(n) ~= "number" or n < 1 or n ~= math.floor(n) then return nil end
    -- `queue`: keys still to read by key; `seen`: queued once each.
    local map, queue, seen, listed = {}, {}, {}, {}
    local function enqueue(k)
        if not seen[k] then seen[k] = true; queue[#queue + 1] = k end
    end
    local function addCommand(command)
        local list = Game.KeysFor(command)
        if not list then return false end
        if #list > 0 then map[command] = list end
        for _, k in ipairs(list) do enqueue(k) end
        return true
    end
    for i = 1, n do
        local okB, command = pcall(GetBinding, i)
        if not okB or type(command) ~= "string" or command == "" then return nil end
        listed[command] = true
        if not addCommand(command) then return nil end
    end
    for _, k in ipairs(KEYS) do enqueue(k) end
    -- A custom command found by key adds its other keys to the queue.
    local i = 1
    while queue[i] do
        local k = queue[i]
        i = i + 1
        local action = Game.CommandOf(k)
        if action == nil then return nil end
        if action then
            map["@" .. k] = action
            if not listed[action] then
                listed[action] = true
                if not addCommand(action) then return nil end
            end
        end
    end
    return map
end

function Game.CursorEmpty()
    local ok, kind = pcall(GetCursorInfo)
    return ok and kind == nil
end

-- The cursor as a normalised action (macro by name, via its index), nil when
-- empty, or { kind = "unreadable" } when the read fails (never "empty").
function Game.Cursor()
    local ok, kind, a, b, c = pcall(GetCursorInfo)
    if not ok then return { kind = "unreadable" } end
    if kind == nil then return nil end
    if kind == "spell" then return { kind = "spell", id = c } end
    if kind == "item" then return { kind = "item", id = a } end
    if kind == "macro" then
        local okM, name, icon, body = pcall(GetMacroInfo, a)
        if not okM then return { kind = "unreadable" } end
        return { kind = "macro", name = name, body = body, index = a,
                 scope = (type(a) == "number" and a >= CHAR_FIRST) and "char" or "account" }
    end
    return { kind = "unsupported", what = tostring(kind) }
end

------------------------------------------------------------
-- The pet bar (#47, measured on 70338, docs/forever-api-notes.md "Pet bar")
------------------------------------------------------------

Game.PET_SLOTS = 10
local PET_BANK = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet) or 1
Game.PET_BANK = PET_BANK

-- The pet that is out with a pet bar: { guid, family = id, familyName, name };
-- nil when there is none, false when one is out but can't be read. The family
-- id is the key (the name is localised); the GUID changes on every summon.
function Game.Pet()
    local ok, exists = pcall(UnitExists, "pet")
    if not ok then return false end
    if not exists then return nil end
    local okB, hasBar = pcall(PetHasActionBar)
    if not okB then return false end
    if not hasBar then return nil end
    local okF, familyName, family = pcall(UnitCreatureFamily, "pet")
    local okG, guid = pcall(UnitGUID, "pet")
    local okN, name = pcall(UnitName, "pet")
    if not (okF and okG and okN) or type(family) ~= "number" or type(guid) ~= "string" or guid == ""
        or type(name) ~= "string" or name == "" then
        return false
    end
    return { guid = guid, family = family, familyName = tostring(familyName or family), name = name }
end

-- One pet slot: nil (empty) | { kind = "token", token } (a command or stance)
-- | { kind = "spell", id, name } | { kind = "unreadable" }.
function Game.PetSlot(i)
    local ok, name, _, isToken, _, _, _, spellID = pcall(GetPetActionInfo, i)
    if not ok then return { kind = "unreadable" } end
    if name == nil then return nil end
    if type(name) ~= "string" or name == "" then return { kind = "unreadable" } end
    if isToken then return { kind = "token", token = name } end
    if type(spellID) == "number" and spellID > 0 then return { kind = "spell", id = spellID, name = name } end
    return { kind = "unreadable" }
end

-- The ten slots (false for an empty one), or nil when any slot can't be read.
function Game.PetBar()
    local bar = {}
    for i = 1, Game.PET_SLOTS do
        local s = Game.PetSlot(i)
        if s and s.kind == "unreadable" then return nil end
        bar[i] = s or false
    end
    return bar
end

-- Two pet slots hold the same thing: commands by token, abilities by id.
function Game.SamePetSlot(a, b)
    if not a or not b then return not a and not b end
    if a.kind ~= b.kind then return false end
    if a.kind == "token" then return a.token == b.token end
    return a.id == b.id
end

-- The pet's abilities: { byId = { [id] = { index, name } }, byName = { [name]
-- = { {id, index}, ... } }, complete }. One rank per ability (the pet's own);
-- stances and passives aren't placeable abilities. `complete` is false when
-- any read failed: then a missing ability isn't proof of absence.
function Game.PetBook()
    local book = { byId = {}, byName = {}, complete = true }
    local ok, n = pcall(C_SpellBook.HasPetSpells)
    if not ok or type(n) ~= "number" then book.complete = false return book end
    for i = 1, n do
        local okI, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, PET_BANK)
        if not okI or type(info) ~= "table" then
            book.complete = false
        elseif type(info.spellID) == "number" and type(info.name) == "string" and not info.isPassive then
            book.byId[info.spellID] = { index = i, name = info.name }
            local list = book.byName[info.name] or {}
            list[#list + 1] = { id = info.spellID, index = i }
            book.byName[info.name] = list
        end
    end
    return book
end

-- What the cursor holds, raw: kind and first value; "unreadable" when the
-- read fails. A pet action reads "petaction", <spell id> (a small number for
-- a command or stance, measured), so only the kind identifies it.
function Game.CursorRaw()
    local ok, kind, a = pcall(GetCursorInfo)
    if not ok then return "unreadable" end
    return kind, a
end
