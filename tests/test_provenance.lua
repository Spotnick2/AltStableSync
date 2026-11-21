------------------------------------------------------------
-- test_provenance.lua - which character a setup was saved by (#117). A
-- character is its full name; two characters can share a first name.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
dofile("tests/wow_game.lua")

WoW.reset()
for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Share.lua", "Backups.lua",
                     "Ready.lua", "Loadout.lua" }) do
    assert(loadfile(f))("AltStableSync", {})
end
WoW.fire("ADDON_LOADED", "AltStableSync")
local A = AltStableSync

-- The full name, from UnitName's two values.
eq("full name: first, space, surname", A.PlayerName(), "Karuzo Sumner")
eq("a save names the full name", A.Loadout.Provenance().sourceChar, "Karuzo Sumner")

local realUnitName = UnitName
UnitName = function() return "Karuzo", "" end
eq("no surname: the first name", A.PlayerName(), "Karuzo")
UnitName = function() return "Karuzo" end
eq("no second value: the first name", A.PlayerName(), "Karuzo")
UnitName = function() return "Karuzo Sumner", nil end
eq("early beta, the full name in one value: as is", A.PlayerName(), "Karuzo Sumner")
UnitName = realUnitName

-- This character, in every form a save has held.
check("me: the full name", A.IsMe("Karuzo Sumner"))
check("me: before #117, <first>-<surname>", A.IsMe("Karuzo-Sumner"))
check("me: early beta, <first> <surname>-<realm>", A.IsMe("Karuzo Sumner-ClassicBetaPvE"))
check("me: early beta, a realm with a hyphen", A.IsMe("Karuzo Sumner-Azjol-Nerub"))

-- Never another character, however close the name.
check("not me: same first name, another surname", not A.IsMe("Karuzo-Mistwalker"))
check("not me: same first name, another surname, full", not A.IsMe("Karuzo Mistwalker"))
check("not me: same first name, another surname, early beta", not A.IsMe("Karuzo Other-ClassicBetaPvE"))
check("not me: another first name, same surname", not A.IsMe("Kaleid-Sumner"))
check("not me: a longer name", not A.IsMe("Karuzon-Sumner"))
check("not me: the first name alone", not A.IsMe("Karuzo"))
check("not me: a first name and a realm", not A.IsMe("Karuzo-Elegia"))
check("not me: no provenance", not A.IsMe(nil) and not A.IsMe(false))

-- A character with no surname is still matched by its own saves.
UnitName = function() return "Karuzo" end
check("no surname: me by the name", A.IsMe("Karuzo"))
check("no surname: not a surnamed Karuzo", not A.IsMe("Karuzo-Sumner"))
UnitName = realUnitName

-- Shown as the full name.
eq("shown: <first>-<surname>", A.SourceName("Karuzo-Mistwalker"), "Karuzo Mistwalker")
eq("shown: early beta, the realm dropped", A.SourceName("Karuzo Sumner-ClassicBetaPvE"), "Karuzo Sumner")
eq("shown: the full name as is", A.SourceName("Kaleid Sumner"), "Kaleid Sumner")
eq("shown: a name alone as is", A.SourceName("Kaleid"), "Kaleid")

finish("test_provenance")
