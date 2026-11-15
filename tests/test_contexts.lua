------------------------------------------------------------
-- test_contexts.lua - #106: key bindings name their context
--
-- A command lives in one binding context: most in None, Blizzard_Gamepad's
-- (loaded on Forever) in GamepadModeInGameCore. AltStableSync reads and
-- writes loadout keys in None, explicitly, as Blizzard's key-binding
-- settings pass a context. The binding-set switch's guard also covers the
-- other contexts' bindings. Backups carry `keysNone = true`; an older
-- one's key reverts (read without a context) are left as they are. The mock
-- answers a call WITHOUT a context with the gamepad context's answer, so a
-- forgotten context fails here; what the client does then is not measured.
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local A, L
local NONE, PAD = Enum.BindingContext.None, Enum.BindingContext.GamepadModeInGameCore

local function boot()
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Share.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "Commands.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A = AltStableSync
    L = A.Loadout
    A.Preview = { Show = function(o) A._shown = o end, Hide = function() A._shown = nil end,
                  Shown = function() return A._shown end }
    local switch = L.UseCharacterBindings
    L.UseCharacterBindings = function(...)
        G.switching = true
        local r = { pcall(switch, ...) }
        G.switching = false
        assert(r[1], r[2])
        return unpack(r, 2, table.maxn(r))
    end
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

-- This character: key 1 on button 2 (None), and the same key 1 on the
-- gamepad's first button (its own context), plus a pad button.
local function char(opts)
    opts = opts or {}
    G.setup{
        class = "PRIEST", guid = "Player-70-PAD", bindingSet = opts.bindingSet,
        spells = { { id = 2061, name = "Flash Heal" } }, macros = {}, actions = {},
        keys = opts.keys or { ["1"] = "ACTIONBUTTON2" },
        padKeys = opts.padKeys or { ["1"] = "GAMEPADACTIONBUTTON1", ["PAD1"] = "GAMEPADACTIONBUTTON2" },
        cmdContext = opts.cmdContext,
    }
end

local function loadout(bindings)
    return assert(A.Catalog.Create("loadout", { class = "PRIEST", category = "general",
        name = "L" .. tostring(math.random(1, 1e9)) },
        { actions = {}, bindings = bindings or { ACTIONBUTTON1 = { "1" } }, cover = { { 1, 12 } } }))
end
local function text(lines) return table.concat(lines, "\n") end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

------------------------------------------------------------
-- A load: read and written in None; the gamepad's key 1 untouched
------------------------------------------------------------
do
    boot(); char()
    local e = loadout()
    local plan = L.Plan(e)
    eq("load: key 1 planned", plan.keys["1"] and plan.keys["1"].to, "ACTIONBUTTON1")
    eq("load: from None's button 2, not the gamepad's", plan.keys["1"] and plan.keys["1"].from, "ACTIONBUTTON2")
    local r = L.Load(e, plan)
    check("load: done", r and not r.failed, r and r.failed)
    eq("load: key 1 in None", G.keys["1"], "ACTIONBUTTON1")
    eq("load: the gamepad's key 1 untouched", G.padKeys["1"], "GAMEPADACTIONBUTTON1")
    check("load: some keys written", #G.setBindings > 0)
    for i, c in ipairs(G.setBindings) do eq("load: write " .. i .. " names None", c.ctx, NONE) end
    local snap = A.Backups.Get("1")
    eq("load: the backup is marked", snap and snap.keysNone, true)
    eq("load: it holds None's button 2", snap and snap.keys["1"], "ACTIONBUTTON2")
    -- Restored in None too.
    G.setBindings = {}
    local rp = L.PlanRestore("1")
    local rr = L.Restore("1", rp)
    check("restore: done", rr and not rr.failed and not rr.partial, rr and (rr.failed or "partial"))
    eq("restore: key 1 back on button 2", G.keys["1"], "ACTIONBUTTON2")
    eq("restore: the gamepad's key 1 untouched", G.padKeys["1"], "GAMEPADACTIONBUTTON1")
    for i, c in ipairs(G.setBindings) do eq("restore: write " .. i .. " names None", c.ctx, NONE) end
    -- A rollback after a refused save names None as well.
    boot(); char()
    e = loadout()
    plan = L.Plan(e)
    local realSave = SaveBindings
    SaveBindings = function() return false end
    r = L.Load(e, plan)
    SaveBindings = realSave
    check("rollback: the load failed", r and r.failed ~= nil)
    eq("rollback: key 1 back in None", G.keys["1"], "ACTIONBUTTON2")
    for i, c in ipairs(G.setBindings) do eq("rollback: write " .. i .. " names None", c.ctx, NONE) end
end

------------------------------------------------------------
-- The context lookup
------------------------------------------------------------
do
    -- A loadout command in another context: its keys aren't set.
    boot(); char({ cmdContext = { ACTIONBUTTON1 = PAD } })
    local plan = L.Plan(loadout())
    check("other context: keys blocked", plan.keysBlocked and has(plan.keysBlocked, "another binding context"), plan.keysBlocked)
    eq("other context: no key planned", next(plan.keys), nil)

    boot(); char()
    G.ctxLookup = "error"
    plan = L.Plan(loadout())
    eq("lookup fails: blocked", plan.blocked, "Couldn't read the key bindings; try again.")
    G.ctxLookup = "nil"
    plan = L.Plan(loadout())
    eq("lookup returns nothing: None", plan.keys["1"] and plan.keys["1"].to, "ACTIONBUTTON1")
    G.ctxLookup = nil

    local saved = Enum.BindingContext
    Enum.BindingContext = nil
    eq("no Enum.BindingContext: a key is unreadable", A.Game.CommandOf("1"), nil)
    eq("no Enum.BindingContext: no binding map", A.Game.BindingMap(), nil)
    plan = L.Plan(loadout())
    eq("no Enum.BindingContext: blocked", plan.blocked, "Couldn't read the key bindings; try again.")
    Enum.BindingContext = saved
end

------------------------------------------------------------
-- Restoring: an older build's keys; a command of another context
------------------------------------------------------------
do
    boot(); char()
    local e = loadout()
    local r = L.Load(e, L.Plan(e))
    check("old backup: loaded", r and not r.failed)
    local snap = A.Backups.Get("1")
    snap.keysNone = nil                          -- as an older build wrote it
    snap.keys["Q"] = false                       -- "unbound", read without a context
    G.keys["Q"] = "JUMP"
    local rp = L.PlanRestore("1")
    eq("old backup: no key planned", next(rp.keys), nil)
    local listed = {}
    for _, u in ipairs(rp.unavailable) do if u.key then listed[u.key] = u.reason end end
    check("old backup: key 1 listed", listed["1"] and has(listed["1"], "older version"), listed["1"])
    check("old backup: an unbound key listed too", listed["Q"] ~= nil)
    local t = text(A.Commands.Describe(rp))
    check("old backup: the preview names the key", has(t, "  key 1: left as is: this backup was taken by an older version"), t)
    local rr = L.Restore("1", rp)
    check("old backup: partial", rr and rr.partial, rr and rr.failed)
    eq("old backup: key 1 left as is", G.keys["1"], "ACTIONBUTTON1")
    eq("old backup: Q left as is", G.keys["Q"], "JUMP")
    check("old backup: kept to restore", A.Backups.Get("1") ~= nil)

    -- A new backup whose recorded command lives in another context: never
    -- replayed into None.
    boot(); char()
    e = loadout()
    r = L.Load(e, L.Plan(e))
    snap = A.Backups.Get("1")
    snap.keys["1"] = "GAMEPADACTIONBUTTON1"
    rp = L.PlanRestore("1")
    eq("other context: not replayed", rp.keys["1"], nil)
    local why
    for _, u in ipairs(rp.unavailable) do if u.key == "1" then why = u.reason end end
    check("other context: listed", why and has(why, "another binding context"), why)
end

------------------------------------------------------------
-- The binding map and the switch's guard
------------------------------------------------------------
do
    boot(); char()
    local map = A.Game.BindingMap()
    eq("map: its format", map["!format"], 2)
    eq("map: None's key 1", map["@1"], "ACTIONBUTTON2")
    eq("map: None's command", map.ACTIONBUTTON2 and map.ACTIONBUTTON2[1], "1")
    eq("map: the gamepad's command, by context", map["#" .. PAD .. ":GAMEPADACTIONBUTTON1"]
        and map["#" .. PAD .. ":GAMEPADACTIONBUTTON1"][1], "1")
    eq("map: the gamepad's key 1, by context", map["@" .. PAD .. ":1"], "GAMEPADACTIONBUTTON1")
    eq("map: the pad button", map["@" .. PAD .. ":PAD1"], "GAMEPADACTIONBUTTON2")
    eq("map: no gamepad command read as None", map.GAMEPADACTIONBUTTON1, nil)
    G.padKeys["PAD1"] = "GAMEPADACTIONBUTTON3"
    local after = A.Game.BindingMap()
    check("map: a gamepad-only change is a difference",
        A.Catalog.Copy and after["@" .. PAD .. ":PAD1"] ~= map["@" .. PAD .. ":PAD1"])

    -- The switch: LoadBindings(Character) changes only a gamepad key.
    boot(); char({ bindingSet = 1 })
    G.charPadStore = { ["1"] = "GAMEPADACTIONBUTTON1", ["PAD1"] = "GAMEPADACTIONBUTTON4" }
    G.calls = {}
    local ok, why = L.UseCharacterBindings()
    check("switch: stopped", not ok and has(tostring(why), "the keys changed"), why)
    check("switch: names the gamepad key", has(tostring(why), "key PAD1 (GamepadModeInGameCore)"), why)
    local saves = 0
    for _, c in ipairs(G.calls) do if c == "SaveBindings" then saves = saves + 1 end end
    eq("switch: Character never saved", saves, 1)
    check("switch: guard kept", A.char.bindingSwitch ~= nil)
    -- Retry with the gamepad's keys as they were: it goes through.
    G.padKeys = { ["1"] = "GAMEPADACTIONBUTTON1", ["PAD1"] = "GAMEPADACTIONBUTTON2" }
    G.charPadStore = nil
    WoW.clock = WoW.clock + 10                       -- the stopped switch fired UPDATE_BINDINGS
    ok, why = L.UseCharacterBindings()
    check("switch: retry done", ok, why)
    eq("switch: guard cleared", A.char.bindingSwitch, nil)

    -- A guard an older version left (no format): never equal, so the
    -- player is asked and the accepted keys are the new map.
    boot(); char({ bindingSet = 1 })
    local old = A.Game.BindingMap()
    old["!format"] = nil
    for k in pairs(old) do if k:find("^[#@]%d+:") then old[k] = nil end end
    A.char.bindingSwitch = { before = old }
    local differ, live = L.SwitchGuard()
    check("old guard: differs", type(differ) == "string" and has(differ, "how they were recorded (an older version)"), differ)
    ok, why = L.UseCharacterBindings()
    eq("old guard: asks first", why, L.SWITCH_GUARDED)
    ok, why = L.UseCharacterBindings(live)
    check("old guard: accepted, done", ok, why)
end

------------------------------------------------------------
-- The duplicate check tells an older backup apart
------------------------------------------------------------
do
    boot(); char()
    local p = L.PlanBackup()
    check("backup: stored", p and L.Backup(p) ~= nil)
    A.Backups.Get("1").keysNone = nil
    p = L.PlanBackup()
    eq("backup: an older newest backup is not the same", p.matches, false)
    check("backup: stored again", L.Backup(p) ~= nil)
    eq("backup: now it is", L.PlanBackup().matches, true)
end

finish("test_contexts")
