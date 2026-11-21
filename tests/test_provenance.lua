------------------------------------------------------------
-- test_provenance.lua - which character a setup was saved by (#117). The
-- realm is hidden since the 2026-11-20 server hotfix, and UnitFullName's
-- second value is the surname: a character is its full name.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
dofile("tests/wow_game.lua")

WoW.reset()
assert(loadfile("Core.lua"))("AltStableSync", {})
for _, f in ipairs({ "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Share.lua", "Backups.lua",
                     "Ready.lua", "Loadout.lua" }) do
    assert(loadfile(f))("AltStableSync", {})
end
WoW.fire("ADDON_LOADED", "AltStableSync")
local A = AltStableSync

-- The full name, from UnitName's two values.
eq("full name: first, space, surname", (A.PlayerName()), "Karuzo Sumner")
eq("first name alongside", select(2, A.PlayerName()), "Karuzo")
eq("a save names the full name", A.Loadout.Provenance().sourceChar, "Karuzo Sumner")

local realUnitName = UnitName
UnitName = function() return "Karuzo", "" end
eq("no surname: the first name", (A.PlayerName()), "Karuzo")
UnitName = function() return "Karuzo" end
eq("no second value: the first name", (A.PlayerName()), "Karuzo")
UnitName = function() return "Karuzo Sumner", "Sumner" end
eq("a name with a space already: as is", (A.PlayerName()), "Karuzo Sumner")
UnitName = realUnitName

-- This character, in every form a save has held.
check("me: the full name", A.IsMe("Karuzo Sumner"))
check("me: before the hotfix, <first>-<realm>", A.IsMe("Karuzo-Elegia"))
check("me: a realm with a hyphen", A.IsMe("Karuzo-Azjol-Nerub"))
check("me: since the hotfix, <first>-<surname>", A.IsMe("Karuzo-Sumner"))
check("not me: another first name", not A.IsMe("Kaleid-Elegia"))
check("not me: a longer name", not A.IsMe("Karuzon-Elegia"))
check("not me: another surname", not A.IsMe("Karuzo Other"))
check("not me: the first name alone, with a surname here", not A.IsMe("Karuzo"))
check("not me: no provenance", not A.IsMe(nil) and not A.IsMe(false))

-- Shown as the character's name; the old form loses the realm.
eq("shown: old form, the first name", A.SourceName("Karuzo-Elegia"), "Karuzo")
eq("shown: since the hotfix, the first name", A.SourceName("Karuzo-Sumner"), "Karuzo")
eq("shown: the full name as is", A.SourceName("Kaleid Sumner"), "Kaleid Sumner")
eq("shown: a name alone as is", A.SourceName("Kaleid"), "Kaleid")

finish("test_provenance")
