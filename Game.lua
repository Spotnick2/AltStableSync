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

Game.SLOTS = { first = 1, last = 12 }                  -- the slice's target set
Game.COMMANDS = {}
for i = 1, 12 do Game.COMMANDS[i] = "ACTIONBUTTON" .. i end

local CHAR_FIRST = 121

-- Bodies compare after stripping the trailing CR/LF the server appends, and
-- nothing else.
function Game.Normalize(body)
    return (tostring(body or ""):gsub("[\r\n]+$", ""))
end

------------------------------------------------------------
-- Macros
------------------------------------------------------------

-- Every macro: { index, name, icon, body, scope = "account" | "char" }.
function Game.Macros()
    local out = {}
    local ok, nAccount, nChar = pcall(GetNumMacros)
    if not ok then return out end
    for i = 1, nAccount or 0 do
        local name, icon, body = GetMacroInfo(i)
        if name then out[#out + 1] = { index = i, name = name, icon = icon, body = body, scope = "account" } end
    end
    for i = CHAR_FIRST, CHAR_FIRST + (nChar or 0) - 1 do
        local name, icon, body = GetMacroInfo(i)
        if name then out[#out + 1] = { index = i, name = name, icon = icon, body = body, scope = "char" } end
    end
    return out
end

function Game.MacrosNamed(name)
    local out = {}
    for _, m in ipairs(Game.Macros()) do
        if m.name == name then out[#out + 1] = m end
    end
    return out
end

function Game.CharMacroCount()
    local ok, _, nChar = pcall(GetNumMacros)
    return ok and nChar or 0
end

Game.MAX_CHAR_MACROS = (Constants and Constants.MacroConsts and Constants.MacroConsts.MAX_CHARACTER_MACROS) or 30

------------------------------------------------------------
-- Spells
------------------------------------------------------------

local BANK = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0

-- The player's learned castable spells: { [id] = { name, low } }, and by name
-- the top known rank (the same-name Spell entry that is not low rank).
function Game.Spellbook()
    local byId, top = {}, {}
    local T = Enum and Enum.SpellBookItemType
    local okN, n = pcall(C_SpellBook.GetNumSpellBookSkillLines)
    for line = 1, (okN and n or 0) do
        local okL, li = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
        if okL and type(li) == "table" and li.itemIndexOffset and li.numSpellBookItems then
            for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                local okI, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, BANK)
                if okI and type(info) == "table" and info.spellID and info.name and not info.isPassive
                    and (not T or info.itemType == T.Spell) then
                    local okR, low = pcall(C_SpellBook.IsSpellBookItemLowRank, i, BANK)
                    low = okR and low == true
                    byId[info.spellID] = { name = info.name, low = low }
                    if not low then top[info.name] = info.spellID end
                end
            end
        end
    end
    return { byId = byId, top = top }
end

function Game.SpellKnown(id)
    local ok, known = pcall(C_SpellBook.IsSpellKnown, id, BANK)
    return ok and known == true
end

------------------------------------------------------------
-- Items, action slots
------------------------------------------------------------

function Game.ItemCount(id)
    local ok, n = pcall(C_Item.GetItemCount, id)
    return ok and type(n) == "number" and n or 0
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
function Game.Restorable(a)
    if a == nil then return true end
    if a.kind == "spell" then return Game.SpellKnown(a.id) end
    if a.kind == "item" then return Game.ItemCount(a.id) > 0 end
    if a.kind == "macro" then return #Game.MacrosNamed(a.name) == 1 end
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

-- Every key bound to `command` (GetBindingKey returns them all), as a list.
function Game.KeysFor(command)
    local r = { pcall(GetBindingKey, command) }
    if not r[1] then return {} end
    local keys = {}
    for i = 2, #r do if type(r[i]) == "string" and r[i] ~= "" then keys[#keys + 1] = r[i] end end
    return keys
end

-- The command a key runs, or false when unbound.
function Game.CommandOf(key)
    local ok, cmd = pcall(GetBindingAction, key)
    if not ok or cmd == nil or cmd == "" then return false end
    return cmd
end

function Game.CharacterBindings()
    local ok, set = pcall(GetCurrentBindingSet)
    return ok and Enum and Enum.BindingSet and set == Enum.BindingSet.Character
end

function Game.CursorEmpty()
    local ok, kind = pcall(GetCursorInfo)
    return ok and kind == nil
end

-- The cursor as a normalised action (macro by name, via its index), or nil.
function Game.Cursor()
    local ok, kind, a, b, c = pcall(GetCursorInfo)
    if not ok or kind == nil then return nil end
    if kind == "spell" then return { kind = "spell", id = c } end
    if kind == "item" then return { kind = "item", id = a } end
    if kind == "macro" then
        local name, icon, body = GetMacroInfo(a)
        return { kind = "macro", name = name, body = body, index = a,
                 scope = (type(a) == "number" and a >= CHAR_FIRST) and "char" or "account" }
    end
    return { kind = "unsupported", what = tostring(kind) }
end
