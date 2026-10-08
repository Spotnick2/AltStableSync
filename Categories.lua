------------------------------------------------------------
-- Categories.lua - the per-class loadout categories
--
-- Forever has one spec per class (measured on 70245), so a loadout's
-- "specialization" is a category the PLAYER picks: a stable key plus display
-- text, never a Blizzard spec ID. Choosing one never changes talents.
-- `general` ("General / Leveling") is offered to every class.
--
-- Keys are permanent: they are stored in saved entries and sent between
-- accounts. Rename the label freely; never change or reuse a key.
------------------------------------------------------------

AltStableSync = AltStableSync or {}
local ASS = AltStableSync

local GENERAL = { key = "general", label = "General / Leveling" }

local BY_CLASS = {
    WARRIOR = { { "arms", "Arms" }, { "fury", "Fury" }, { "protection", "Protection" } },
    PALADIN = { { "holy", "Holy" }, { "protection", "Protection" }, { "retribution", "Retribution" } },
    HUNTER  = { { "beast_mastery", "Beast Mastery" }, { "marksmanship", "Marksmanship" }, { "survival", "Survival" } },
    ROGUE   = { { "assassination", "Assassination" }, { "combat", "Combat" }, { "subtlety", "Subtlety" } },
    PRIEST  = { { "discipline", "Discipline" }, { "holy", "Holy" }, { "shadow", "Shadow" } },
    SHAMAN  = { { "elemental", "Elemental" }, { "enhancement", "Enhancement" }, { "restoration", "Restoration" } },
    MAGE    = { { "arcane", "Arcane" }, { "fire", "Fire" }, { "frost", "Frost" } },
    WARLOCK = { { "affliction", "Affliction" }, { "demonology", "Demonology" }, { "destruction", "Destruction" } },
    DRUID   = { { "balance", "Balance" }, { "feral_tank", "Feral Tank" }, { "feral_dps", "Feral DPS" }, { "restoration", "Restoration" } },
}

local Categories = {}
ASS.Categories = Categories

-- The class's categories in display order, `general` last:
-- { { key = "discipline", label = "Discipline" }, ... }. Nil for an unknown class.
function Categories.List(class)
    local list = BY_CLASS[class]
    if not list then return nil end
    local out = {}
    for i, c in ipairs(list) do out[i] = { key = c[1], label = c[2] } end
    out[#out + 1] = { key = GENERAL.key, label = GENERAL.label }
    return out
end

function Categories.IsValid(class, key)
    for _, c in ipairs(Categories.List(class) or {}) do
        if c.key == key then return true end
    end
    return false
end

-- Display text; an unknown key (say, one a newer build sent) shows as itself.
function Categories.Label(class, key)
    for _, c in ipairs(Categories.List(class) or {}) do
        if c.key == key then return c.label end
    end
    return tostring(key)
end
