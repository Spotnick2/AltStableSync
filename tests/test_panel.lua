------------------------------------------------------------
-- test_panel.lua - the #9 window: a view and a launcher, never a writer
--
-- Runs the real Panel.lua, Commands.lua and Preview.lua handlers against the
-- widget stub (tests/wow_stubs.lua) and the game model (tests/wow_game.lua).
-- The plan's promises, each checked:
--   * nothing is written until a preview's confirm runs (SavedVariables and
--     WoW.game.calls, the log of every mutating game call);
--   * browsing (Category, Saved loadout) and the save target are separate:
--     Load acts on the browsed entry, Save on the target, and browsing,
--     previews and cancels never move the target;
--   * a confirm uses what its preview captured, whatever the panel shows by
--     then; a redraw never touches an open preview;
--   * the model is pure, including over a backup record without a ring;
--   * the tick shows changes no event announces (readiness, the cursor, a
--     peer's manifest).
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local A, P, W

local SPELLS = {
    { id = 2061, name = "Flash Heal", low = true }, { id = 9472, name = "Flash Heal" },
    { id = 2050, name = "Lesser Heal" }, { id = 2060, name = "Greater Heal" },
}

local function boot()
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Game.lua", "Pet.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "Preview.lua", "Commands.lua", "Panel.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A = AltStableSync
    P, W = A.Panel, A.Panel._W
end

local function main(opts)
    opts = opts or {}
    G.setup{
        class = "PRIEST", guid = "Player-70-MAIN", bindingSet = opts.bindingSet,
        spells = SPELLS, items = { [5512] = 3 },
        macros = { { name = "Shield", body = "/cast Power Word: Shield", char = true } },
        actions = { [1] = { spell = 9472 }, [2] = { spell = 2050 }, [3] = { item = 5512 }, [4] = { macro = "Shield" } },
        keys = { ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2" },
    }
end

local function ready()
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

-- A deterministic text form, to compare SavedVariables before and after.
local function ser(v, seen)
    if type(v) ~= "table" then return type(v):sub(1, 1) .. tostring(v) end
    seen = seen or {}
    if seen[v] then return "<cycle>" end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. ser(v[k], seen) end
    seen[v] = nil
    return "{" .. table.concat(out, ",") .. "}"
end
local function persisted() return ser(AltStableSyncDB) .. "|" .. ser(AltStableSyncChar) end

local function capture() return assert(A.Loadout.Capture()) end
local function create(name, category, modules)
    return assert(A.Catalog.Create("loadout", { class = "PRIEST", category = category or "general", name = name },
        modules or capture()))
end

-- One model tick (1 s); tick(5.1) also runs the save status's slow poll.
local function tick(dt) P._Frame().scripts.OnUpdate(P._Frame(), dt or 1.1) end
local function shown() return A.Preview.Shown() end
local function previewFrame() return _G.AltStableSyncPreview end
local function confirm() return previewFrame().confirm:Click() end
local function cancel() return previewFrame().cancel:Click() end
local function dialog() return P._Dialog() end

-- Open a picker or menu and click the item with this value.
local function pick(owner, value)
    owner:Click()
    for _, b in ipairs(W.menu.items) do
        if b:IsShown() and b.value == value then return b:Click() end
    end
    error("no menu item " .. tostring(value))
end
local function browse(e)
    pick(W.cat, e.category)
    pick(W.entry, e.id)
end
local function itemText(id)
    for _, it in ipairs(W.entry.items or {}) do if it.value == id then return it.text end end
end
local function backupRow(snap)
    for _, r in ipairs(W.brows) do if r.snap == snap and r:IsShown() then return r end end
end
local function linesOf(o) return o and table.concat(o.lines or {}, "\n") or "" end
local function target() return A.char.loaded and A.char.loaded.loadout and A.char.loaded.loadout.id end

------------------------------------------------------------
-- The model
------------------------------------------------------------

do
    boot(); main(); ready()
    local a = create("Everyday")
    local b = create("Holy raid", "holy")
    -- A loadout from a newer build, in a category this build doesn't know.
    A.Catalog.Upsert({ id = "loadout-ffffffffffff-1", version = "ffffffffffff:1", ancestors = {}, kind = "loadout",
        class = "PRIEST", category = "chaplain", name = "Future", modules = { actions = {}, cover = { { 1, 12 } } } }, "Other")
    local before = persisted()
    local m = P.Model({ id = b.id })
    eq("model: wrote nothing", persisted(), before)
    local cats = {}
    for _, c in ipairs(m.categories) do cats[#cats + 1] = c.key .. ":" .. c.count end
    eq("model: class categories in order, then unknown keys", table.concat(cats, ","),
        "discipline:0,holy:1,shadow:0,general:1,chaplain:1")
    eq("model: the browsed category follows the entry", m.category, "holy")
    eq("model: browsed", m.selected and m.selected.name, "Holy raid")
    eq("model: contents, actions", m.selected and m.selected.contents[1].value, "4 saved actions")
    eq("model: contents, keys", m.selected and m.selected.contents[2].value, "2 saved keys")
    eq("model: contents, destination", m.selected and m.selected.contents[2].sub, "Destination: Character")
    eq("model: contents, macros", m.selected and m.selected.contents[3].value, "1 character macro")
    check("model: short saved line", m.selected and m.selected.saved:find("^Saved %a%a%a %d%d, %d%d:%d%d") ~= nil, m.selected and m.selected.saved)
    eq("model: no save target", m.target, nil)

    -- The save target: shown with its category; markers never hide each other.
    A.char.loaded = { loadout = { id = a.id, version = a.version } }
    m = P.Model({})
    eq("model: opens on the target's category", m.category, "general")
    eq("model: opens on the target", m.selectedId, a.id)
    eq("model: target", m.target and (m.target.name .. "|" .. m.target.category), "Everyday|General / Leveling")
    m = P.Model({ id = b.id })
    check("model: browsing another says the target stays", m.targetDiffers == true)
    eq("model: target unchanged by browsing", m.target and m.target.id, a.id)
    A.Catalog.Upsert({ id = a.id, version = "ffffffffffff:2", parent = a.version, ancestors = { a.version },
        kind = "loadout", class = "PRIEST", category = "general", name = "Everyday",
        modules = { actions = {}, cover = { { 1, 12 } } } }, "Other")
    A.Link = { EntryStatus = function(e) return e.id == a.id and "pending" or nil end }
    m = P.Model({})
    eq("model: markers together", table.concat(m.entries[1].marks, ","), "save target, older version,pending")
    check("model: target older", m.target.older == true)
    A.Link = nil
    -- A browsed entry that disappears: said, not replaced.
    m = P.Model({ id = "loadout-gone-1" })
    check("model: gone selection said", m.selectionGone == true and m.selectedId == nil)
    -- An empty category stays browsable.
    m = P.Model({ category = "shadow" })
    check("model: empty category", m.emptyCategory == true and m.selectedId == nil and m.category == "shadow")
    -- Refused or uninitialised: nothing listed.
    A.disabled = "schema 99 is newer"
    m = P.Model({})
    check("model: refused schema blocks", m.blocked and m.blocked:find("Unsupported version", 1, true) ~= nil)
    eq("model: refused schema, no entries", #m.entries, 0)
    A.disabled = nil
end

-- No loadouts at all.
do
    boot(); main(); ready()
    local m = P.Model({})
    check("model: no loadouts", m.noLoadouts == true and m.selectedId == nil)
    P.Show()
    check("no loadouts: said", W.boxNote:GetText():find("No saved loadouts for this class yet", 1, true) ~= nil, W.boxNote:GetText())
    check("no loadouts: Save As on", W.saveAs:IsEnabled())
    check("no loadouts: Save off, with a reason", not W.save:IsEnabled() and W.save.why ~= nil)
    check("no loadouts: no target", W.target:GetText():find("none yet", 1, true) ~= nil)
    P.Hide()
end

-- A backup record with a pin and a first backup but no ring: both show, both
-- restore, and reading changes nothing.
do
    boot(); main(); ready()
    local snapOp = { at = 100, actions = {}, reason = "load" }
    local snapFirst = { at = 50, actions = {} }
    A.db.backups["Player-70-MAIN"] = { operation = { snapshot = snapOp, op = { name = "Everyday" } }, firstSeen = snapFirst }
    local before = persisted()
    local m = P.Model({ snap = snapFirst })
    eq("no ring: wrote nothing", persisted(), before)
    eq("no ring: two rows", #m.backups, 2)
    check("no ring: the pin first", m.backups[1].snap == snapOp and m.backups[1].text:find("Incomplete load of Everyday", 1, true) ~= nil)
    check("no ring: the first backup", m.backups[2].snap == snapFirst and m.backupSelected)
    eq("no ring: pinned", m.pinned, "Everyday")
    eq("no ring: slot of the pin", P.SlotOf(snapOp), "op")
    eq("no ring: slot of first", P.SlotOf(snapFirst), "first")
    eq("no ring: Get op", A.Backups.Get("op"), snapOp)
    eq("no ring: Get 1", A.Backups.Get("1"), nil)
    eq("no ring: still no ring after reading", A.db.backups["Player-70-MAIN"].ring, nil)
end

------------------------------------------------------------
-- Nothing is written before a confirm
------------------------------------------------------------

do
    boot(); main(); ready()
    local a = create("Everyday")
    local b = create("Other", "holy")
    G.actions[9] = { kind = "spell", id = 2060 }
    A.Loadout.Load(a, A.Loadout.Plan(a))                     -- empties slot 9: a backup and a save target
    G.actions[9] = { kind = "spell", id = 2060 }             -- an unsaved change
    G.calls = {}
    local before = persisted()
    P.Show()
    tick(); tick()
    eq("open: shows the target's entry at once", W.entry.label:GetText(), "Everyday")
    check("open: its contents at once", W.boxTitle:GetText():find("EVERYDAY", 1, true) ~= nil)
    browse(b)
    W.tabs.ui:Click(); W.backupsLink:Click(); W.backupsLink:Click(); W.tabs.loadouts:Click()
    local function each(what, click)
        click()
        check(what .. ": a preview opened", shown() ~= nil)
        eq(what .. ": nothing saved", persisted(), before)
        eq(what .. ": nothing written to the game", #G.calls, 0)
        cancel()
        eq(what .. ": closed by Cancel", shown(), nil)
        eq(what .. ": Cancel wrote nothing", persisted(), before)
    end
    each("Load", function() W.load:Click() end)
    each("Delete", function() pick(W.manage, "delete") end)
    each("Rename", function() pick(W.manage, "rename"); dialog().name:SetText("Renamed"); dialog().review:Click() end)
    each("Save As", function() W.saveAs:Click(); dialog().name:SetText("Draft"); dialog().review:Click() end)
    each("Save", function() W.save:Click() end)
    W.backupsLink:Click()
    backupRow(A.Backups.Get("1")):Click()
    each("Restore", function() W.restore:Click() end)
    -- Escape (hiding the preview) is a cancel too; so is closing a dialog.
    W.backupsLink:Click()
    W.load:Click()
    previewFrame():Hide()
    W.saveAs:Click()
    dialog().name:SetText("Not this")
    dialog().cancel:Click()
    eq("Escape and dialog Cancel: nothing saved", persisted(), before)
    eq("Escape and dialog Cancel: nothing written", #G.calls, 0)
    eq("browsing never moved the save target", target(), a.id)
    P.Hide()
end

------------------------------------------------------------
-- Load acts on the browsed entry, Save on the target
------------------------------------------------------------

do
    boot(); main(); ready()
    local raid = create("Raid Healing", "holy")
    local quest = create("Questing", "shadow")
    G.actions[9] = { kind = "spell", id = 2060 }
    A.Loadout.Load(raid, A.Loadout.Plan(raid))               -- the save target: Raid Healing
    P.Show()
    eq("target: named with its category", W.target:GetText(), "|cffffd100Save target:|r Raid Healing - Holy")
    eq("target: opens on it", W.entry.label:GetText(), "Raid Healing")
    browse(quest)
    eq("browse: Questing shown", W.entry.label:GetText(), "Questing")
    check("browse: the target note", W.targetNote:GetText():find("doesn't change this target", 1, true) ~= nil)
    eq("browse: target unchanged", target(), raid.id)
    W.load:Click()
    eq("Load names the browsed entry", shown() and shown().title, "Load Questing?")
    cancel()
    eq("cancelled Load: target unchanged", target(), raid.id)
    G.actions[10] = { kind = "spell", id = 2060 }
    tick(5.1)
    W.save:Click()
    eq("Save names the target, not the browsed entry", shown() and shown().title, "Update Raid Healing?")
    cancel()
    eq("cancelled Save: target unchanged", target(), raid.id)
    -- Save As defaults to the target's category, never the browsed one.
    W.saveAs:Click()
    eq("Save As: the target's category", dialog().category, "holy")
    dialog().cancel:Click()
    -- A Load that fails partway (docs/DESIGN.md "No usable comparison"): the
    -- bars are partly Questing now, so the old target must not take a Save
    -- of them. The record names Questing with no comparison: Save refused.
    G.actions[9] = { kind = "spell", id = 2060 }             -- a real change, so a write to interrupt
    G.combatAfter = 1
    W.load:Click()
    confirm()
    G.combat, G.combatAfter = false, nil
    check("failed Load: it did fail", A.char.loaded.loadout.after == nil)
    eq("failed Load: the record names the partly loaded entry", target(), quest.id)
    tick(5.1)
    check("failed Load: Save refused, with the reason", not W.save:IsEnabled()
        and (W.save.why or ""):find("No usable comparison", 1, true) ~= nil, W.save.why)
    eq("failed Load: Raid Healing untouched", A.Catalog.Get(raid.id).version, raid.version)
    P.Hide()
end

------------------------------------------------------------
-- A confirm uses what its preview captured
------------------------------------------------------------

do
    boot(); main(); ready()
    local a = create("Alpha")
    local b = create("Beta")
    P.Show()
    browse(a)
    W.load:Click()
    local o = shown()
    eq("ownership: Load preview for A", o and o.title, "Load Alpha?")
    browse(b)
    tick(); tick(); P.Refresh()
    eq("ownership: the preview is untouched by redraws", shown(), o)
    confirm()
    eq("ownership: A was loaded", target(), a.id)

    -- Save As: the name and category as they were at Review.
    W.saveAs:Click()
    local d = dialog()
    pick(d.cat, "holy")
    d.name:SetText("Holy set")
    d.review:Click()
    eq("Save As: preview", shown() and shown().title, "Save As Holy set?")
    check("Save As: the dialog closed", not d:IsShown())
    d.name:SetText("Changed my mind")
    d.category = "shadow"
    confirm()
    local found
    for _, e in ipairs(A.Catalog.List("loadout", "PRIEST", "holy")) do if e.name == "Holy set" then found = e end end
    check("Save As: saved with the captured name and category", found ~= nil)
    eq("Save As: nothing under the later choice", #A.Catalog.List("loadout", "PRIEST", "shadow"), 0)
    tick(0.01)
    eq("Save As: the new entry is the target", W.target:GetText(), "|cffffd100Save target:|r Holy set - Holy")

    -- Sync replaces A between its preview and the confirm: refused as stale.
    browse(a)
    W.load:Click()
    A.Catalog.Upsert({ id = a.id, version = "ffffffffffff:9", parent = a.version, ancestors = { a.version },
        kind = "loadout", class = "PRIEST", category = "general", name = "Alpha",
        modules = { actions = {}, cover = { { 1, 12 } } } }, "Other")
    G.calls = {}
    WoW.chatLines = {}
    confirm()
    eq("stale: nothing written", #G.calls, 0)
    check("stale: said so", table.concat(WoW.chat(), " "):find("review it again", 1, true) ~= nil, table.concat(WoW.chat(), " | "))
    tick(0.01)
    check("stale: the footer repeats it", W.status:GetText():find("review it again", 1, true) ~= nil, W.status:GetText())

    -- Sync deletes the browsed entry: said, not quietly replaced.
    browse(b)
    A.Catalog.Upsert({ id = b.id, version = "ffffffffffff:10", parent = b.version, ancestors = { b.version },
        kind = "loadout", class = "PRIEST", category = "general", name = "Beta", deleted = true }, "Other")
    tick()
    check("deleted by sync: said", W.boxNote:GetText():find("removed", 1, true) ~= nil, W.boxNote:GetText())
    check("deleted by sync: no Load", not W.load:IsShown())
    tick()
    check("deleted by sync: still said on the next tick", W.boxNote:GetText():find("removed", 1, true) ~= nil)
    P.Hide()
end

-- The save target deleted or changed elsewhere: never redirected.
do
    boot(); main(); ready()
    local a = create("Everyday")
    local b = create("Other")
    G.actions[9] = { kind = "spell", id = 2060 }
    A.Loadout.Load(a, A.Loadout.Plan(a))
    P.Show()
    browse(b)
    A.Catalog.Upsert({ id = a.id, version = "ffffffffffff:11", parent = a.version, ancestors = { a.version },
        kind = "loadout", class = "PRIEST", category = "general", name = "Everyday",
        modules = { actions = {}, cover = { { 1, 12 } } } }, "Other")
    tick(5.1)
    check("target changed: said", W.target:GetText():find("changed since you loaded it", 1, true) ~= nil, W.target:GetText())
    check("target changed: Save off, with the reason", not W.save:IsEnabled() and (W.save.why or ""):find("changed since you loaded", 1, true) ~= nil)
    A.Catalog.Upsert({ id = a.id, version = "ffffffffffff:12", parent = "ffffffffffff:11", ancestors = { a.version, "ffffffffffff:11" },
        kind = "loadout", class = "PRIEST", category = "general", name = "Everyday", deleted = true }, "Other")
    tick(5.1)
    check("target deleted: said", W.target:GetText():find("(removed)", 1, true) ~= nil, W.target:GetText())
    check("target deleted: Save off", not W.save:IsEnabled())
    check("target deleted: Save As on", W.saveAs:IsEnabled())
    W.save:Click()
    eq("target deleted: no preview from a disabled Save", shown(), nil)
    eq("target deleted: never redirected to the browsed entry", A.Catalog.Get(b.id).version, b.version)
    P.Hide()
end

------------------------------------------------------------
-- The flows check their own arguments
------------------------------------------------------------

do
    boot(); main(); ready()
    local mine = create("Mine")
    A.Catalog.Upsert({ id = "loadout-ffffffffffff-3", version = "ffffffffffff:3", ancestors = {},
        kind = "loadout", class = "WARRIOR", category = "arms", name = "Smash",
        modules = { actions = {}, cover = { { 1, 12 } } } }, "Other")
    local warrior = A.Catalog.Get("loadout-ffffffffffff-3")
    A.Catalog.Upsert({ id = "loadout-ffffffffffff-4", version = "ffffffffffff:4", ancestors = {}, kind = "loadout",
        class = "PRIEST", category = "chaplain", name = "Future", modules = { actions = {}, cover = { { 1, 12 } } } }, "Other")
    local future = A.Catalog.Get("loadout-ffffffffffff-4")
    A.Commands.RenameEntry(warrior.id, "Mine now")
    eq("another class: no rename preview", shown(), nil)
    A.Commands.DeleteEntry(warrior.id)
    eq("another class: no delete preview", shown(), nil)
    -- Unknown category: browsable, renamed and deleted from the panel.
    P.Show()
    browse(future)
    eq("unknown category: shown by its key", W.cat.label:GetText(), "chaplain")
    pick(W.manage, "rename")
    dialog().name:SetText("Future 2")
    dialog().review:Click()
    confirm()
    eq("unknown category: renamed", A.Catalog.Get(future.id).name, "Future 2")
    eq("unknown category: kept", A.Catalog.Get(future.id).category, "chaplain")
    pick(W.manage, "delete")
    confirm()
    check("unknown category: deleted", A.Catalog.Get(future.id).deleted == true)
    -- A conflict copy: no Load; Resolve settles it.
    A.Catalog.Upsert({ id = mine.id, version = "ffffffffffff:5", ancestors = {}, kind = "loadout", class = "PRIEST",
        category = "general", name = "Mine", modules = { actions = {}, cover = { { 1, 12 } } } }, "Other")
    local copy = A.Catalog.Conflicts()[1]
    check("conflict: a copy exists", copy ~= nil)
    A.Commands.RenameEntry(copy.id, "x")
    eq("conflict copy: no rename", shown(), nil)
    browse(copy)
    check("conflict copy: Load hidden", not W.load:IsShown())
    eq("conflict copy: Resolve", W.manage:GetText(), "Resolve...")
    pick(W.manage, "theirs")
    eq("conflict copy: the existing resolve preview", shown() and shown().title, "Resolve Mine?")
    confirm()
    eq("conflict: settled", #A.Catalog.Conflicts(), 0)
    P.Hide()
end

------------------------------------------------------------
-- Backups: Restore follows the selected snapshot, not its old position
------------------------------------------------------------

do
    boot(); main(); ready()
    local a = create("Everyday")
    G.actions[9] = { kind = "spell", id = 2060 }
    A.Loadout.Load(a, A.Loadout.Plan(a))                     -- a real change: backup 1
    P.Show()
    W.backupsLink:Click()
    local snap = A.Backups.Get("1")
    check("backups: Restore off until one is selected", not W.restore:IsEnabled())
    backupRow(snap):Click()
    G.actions[9] = { kind = "spell", id = 2060 }
    A.Loadout.Load(a, A.Loadout.Plan(a))                     -- a newer backup shifts the ring
    tick()
    eq("ring shift: the snapshot is now 2", P.SlotOf(snap), "2")
    W.restore:Click()
    eq("ring shift: Restore opens backup 2", shown() and shown().title, "Restore backup 2?")
    cancel()
    P.Hide()
end

-- An interrupted load: the footer says so, and nothing releases the pin but a confirm.
do
    boot(); main(); ready()
    local a = create("Everyday")
    G.actions[2] = nil
    G.combatAfter = 1
    local r = A.Loadout.Load(a, A.Loadout.Plan(a))
    G.combat, G.combatAfter = false, nil
    check("pin: the load failed", r and r.failed)
    check("pin: pinned", A.Backups.Operation() ~= nil)
    P.Show()
    tick()
    check("pin: footer", W.status:GetText():find("interrupted", 1, true) ~= nil, W.status:GetText())
    W.undo:Click()
    eq("pin: Undo opens the restore preview", shown() and shown().title, "Restore backup op?")
    cancel()
    W.load:Click()
    check("pin: Load offers to abandon it", linesOf(shown()):find("Abandon the incomplete load", 1, true) ~= nil)
    cancel()
    check("pin: still pinned after both cancels", A.Backups.Operation() ~= nil)
    P.Hide()
end

------------------------------------------------------------
-- The tick: what no event announces
------------------------------------------------------------

do
    boot(); main()
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    local a = create("Everyday")
    P.Show()
    check("not ready: Load off, with the reason", not W.load:IsEnabled() and (W.load.why or ""):find("Waiting for character data", 1, true) ~= nil, W.load.why)
    check("not ready: said", W.status:GetText():find("Waiting for character data", 1, true) ~= nil, W.status:GetText())
    WoW.clock = WoW.clock + 10                               -- ready by the quiet time alone
    tick()
    check("ready with no event: Load on", W.load:IsEnabled())

    G.actions[9] = { kind = "spell", id = 2060 }
    A.Loadout.Load(a, A.Loadout.Plan(a))
    tick(5.1)
    eq("save status: no changes", W.saveStatus:GetText(), "No unsaved changes.")
    G.cursor = { kind = "item", id = 5512 }
    tick(5.1)
    check("cursor: Save refused, said", W.saveStatus:GetText():find("cursor", 1, true) ~= nil, W.saveStatus:GetText())
    check("cursor: Save off", not W.save:IsEnabled())
    G.cursor = nil                                           -- nothing else changes
    tick(5.1)
    eq("cursor cleared: back", W.saveStatus:GetText(), "No unsaved changes.")
    check("no changes: Save off, says why", not W.save:IsEnabled() and W.save.why == "No unsaved changes.")
    check("no changes: Save As stays on", W.saveAs:IsEnabled())
    G.actions[10] = { kind = "spell", id = 2060 }
    tick(5.1)
    check("a change: Save on", W.save:IsEnabled())
    check("a change: said", W.saveStatus:GetText():find("Unsaved: 1 slot", 1, true) ~= nil, W.saveStatus:GetText())

    -- A peer's manifest alone turns pending into confirmed.
    local status = "pending"
    A.Link = { EntryStatus = function() return status end }
    tick()
    check("sync: pending shown", (itemText(a.id) or ""):find("pending", 1, true) ~= nil)
    status = "confirmed"
    tick()
    check("sync: confirmed shown", (itemText(a.id) or ""):find("confirmed", 1, true) ~= nil)
    A.Link = nil

    -- A sync receipt redraws, writes no game state, and leaves the target.
    local loaded = ser(A.char.loaded)
    G.calls = {}
    A.Catalog.Upsert({ id = "loadout-ffffffffffff-7", version = "ffffffffffff:7", ancestors = {}, kind = "loadout",
        class = "PRIEST", category = "general", name = "Arrived", modules = { actions = {}, cover = { { 1, 12 } } } }, "Other")
    tick()
    check("receipt: listed", itemText("loadout-ffffffffffff-7") ~= nil)
    eq("receipt: nothing written to the game", #G.calls, 0)
    eq("receipt: target unchanged", ser(A.char.loaded), loaded)

    -- Combat: writes wait; managing the list doesn't.
    G.combat = true
    tick(5.1)
    check("combat: Load off", not W.load:IsEnabled())
    check("combat: Save off", not W.save:IsEnabled())
    check("combat: Save As off", not W.saveAs:IsEnabled())
    check("combat: Manage on", W.manage:IsEnabled())
    G.combat = false
    P.Hide()
end

-- The Save As dialog: no red text before typing; the name checked per category.
do
    boot(); main(); ready()
    create("Everyday")
    P.Show()
    W.saveAs:Click()
    local d = dialog()
    check("dialog: open", d:IsShown())
    eq("dialog: General by default (no target)", d.category, "general")
    eq("dialog: no red text before typing", d.hint:GetText(), "")
    check("dialog: Review off when empty", not d.review:IsEnabled())
    d.name:SetText("   ")
    eq("dialog: blank is just off", d.hint:GetText(), "")
    d.name:SetText("everyday")
    check("dialog: duplicate said", d.hint:GetText():find("already has", 1, true) ~= nil)
    check("dialog: duplicate, Review off", not d.review:IsEnabled())
    pick(d.cat, "holy")
    eq("dialog: same name in another category is fine", d.hint:GetText(), "")
    check("dialog: Review on", d.review:IsEnabled())
    -- Enter reviews (opens the preview), never confirms.
    local n = #A.Catalog.List("loadout", "PRIEST", "holy")
    d.name.scripts.OnEnterPressed(d.name)
    eq("dialog: Enter opens the preview", shown() and shown().title, "Save As everyday?")
    eq("dialog: Enter saved nothing", #A.Catalog.List("loadout", "PRIEST", "holy"), n)
    cancel()
    -- An empty category: still browsable, Save As offered.
    pick(W.cat, "shadow")
    check("empty category: said", W.boxNote:GetText():find("No loadouts in Shadow yet", 1, true) ~= nil, W.boxNote:GetText())
    check("empty category: picker usable", W.cat:IsEnabled())
    check("empty category: Save As on", W.saveAs:IsEnabled())
    P.Hide()
end

-- A refused schema: the panel opens on the blocked view, reads nothing, writes nothing.
do
    boot(); main(); ready()
    A.disabled = "schema 99 is newer than this version"
    local before = persisted()
    P.Show()
    tick(5.1)
    check("refused: says so", W.blocked:IsShown() and W.blocked:GetText():find("Unsupported version", 1, true) ~= nil)
    check("refused: no view", not W.views.loadouts:IsShown())
    eq("refused: nothing written", persisted(), before)
    P.Hide()
end

-- The slash command opens and closes it.
do
    boot(); main(); ready()
    A.SlashHandler("")
    check("slash: opens", P._Frame() and P._Frame():IsShown())
    A.SlashHandler("")
    check("slash: closes", not P._Frame():IsShown())
    WoW.chatLines = {}
    A.SlashHandler("status")
    check("slash: status still prints", table.concat(WoW.chat(), " "):find("schema", 1, true) ~= nil)
end

-- #7 through the panel: step 1 only switches the binding set, and only on its OK.
do
    boot(); main({ bindingSet = 1 }); ready()
    local a = create("Everyday")
    P.Show()
    browse(a)
    G.calls = {}
    local before = persisted()
    W.load:Click()
    eq("#7: step 1 shown", shown() and shown().title, "Load Everyday: step 1 of 2")
    eq("#7: nothing before OK", #G.calls, 0)
    eq("#7: nothing saved before OK", persisted(), before)
    cancel()
    eq("#7: still account keybindings", G.bindingSet, 1)
    P.Hide()
end

------------------------------------------------------------
-- Code review on #60
------------------------------------------------------------

-- The unsaved line counts everything Merge counts, never "0 slots and 0 keys".
do
    boot(); main(); ready()
    local a = create("Everyday")
    A.char.loaded = { loadout = { id = a.id, version = a.version } }
    local plan = A.Loadout.PlanSave
    A.Loadout.PlanSave = function() return { noop = false, changed = {}, keysChanged = {}, keysAdded = { "X" } } end
    eq("unsaved: an added key counts", P.SaveStatus().text, "Unsaved: 1 key changed.")
    A.Loadout.PlanSave = function() return { noop = false, changed = {}, keysChanged = {}, pet = { changed = { 1 } } } end
    eq("unsaved: the pet bar counts", P.SaveStatus().text, "Unsaved: the pet bar changed.")
    A.Loadout.PlanSave = function() return { noop = false, changed = {}, keysChanged = {} } end
    eq("unsaved: nothing countable still says so", P.SaveStatus().text, "Unsaved changes: Save shows them.")
    check("unsaved: Save on", P.SaveStatus().ok)
    A.Loadout.PlanSave = plan
end

-- The Backups view keeps its own height, whatever the contents box last was.
do
    boot(); main(); ready()
    create("Everyday")
    P.Show()
    pick(W.cat, "shadow")                                    -- an empty category: a short box
    local short = P._Frame():GetHeight()
    W.backupsLink:Click()
    local backups = P._Frame():GetHeight()
    check("backups height: not the short Loadouts height", backups > short, short .. " / " .. tostring(backups))
    W.backupsLink:Click()
    P.Hide()
end

-- Escape closes only the topmost: the panel leaves UISpecialFrames while a
-- preview, the dialog or a list is open.
do
    boot(); main(); ready()
    local a = create("Everyday")
    local function special()
        for _, n in ipairs(UISpecialFrames) do if n == "AltStableSyncPanel" then return true end end
        return false
    end
    P.Show()
    WoW.tick(0.1)                                            -- rejoining waits a frame
    check("escape: the panel alone is a target", special())
    W.load:Click()
    check("escape: not while a preview is open", not special())
    cancel()
    check("escape: not in the same frame as the closing Escape", not special())
    WoW.tick(0.1)
    check("escape: back a frame later", special())
    W.saveAs:Click()
    check("escape: not while the dialog is open", not special())
    dialog().cancel:Click()
    WoW.tick(0.1)
    check("escape: back after the dialog", special())
    W.cat:Click()
    check("escape: not while a list is open", not special())
    W.cat:Click()
    WoW.tick(0.1)
    check("escape: back after the list", special())
    P.Hide()
end

-- /altsync opens the blocked view on a refused schema.
do
    boot(); main(); ready()
    A.disabled = "schema 99 is newer than this version"
    A.SlashHandler("")
    check("refused: /altsync opens the panel", P._Frame() and P._Frame():IsShown())
    check("refused: it says why", W.blocked:IsShown() and W.blocked:GetText():find("Unsupported version", 1, true) ~= nil)
    A.SlashHandler("")
    A.disabled = nil
end

-- Each opening starts on the save target.
do
    boot(); main(); ready()
    local a = create("Everyday")
    local b = create("Holy raid", "holy")
    A.char.loaded = { loadout = { id = a.id, version = a.version } }
    P.Show()
    browse(b)
    W.backupsLink:Click()
    P.Hide()
    P.Show()
    eq("reopen: on the save target", W.entry.label:GetText(), "Everyday")
    check("reopen: on Loadouts", W.views.loadouts:IsShown() and not W.views.backups:IsShown())
    P.Hide()
end

-- Something on the cursor: the write buttons are off and say why, as the flows would.
do
    boot(); main(); ready()
    local a = create("Everyday")
    P.Show()
    G.cursor = { kind = "item", id = 5512 }
    tick()
    check("cursor: Load off", not W.load:IsEnabled())
    check("cursor: says why", (W.load.why or ""):find("cursor", 1, true) ~= nil, W.load.why)
    check("cursor: Save As off", not W.saveAs:IsEnabled())
    G.cursor = nil
    tick()
    check("cursor: back on", W.load:IsEnabled())
    P.Hide()
end

-- A conflict copy with no sender: never "from nil".
do
    boot(); main(); ready()
    local mine = create("Mine")
    A.Catalog.Upsert({ id = mine.id, version = "ffffffffffff:5", ancestors = {}, kind = "loadout", class = "PRIEST",
        category = "general", name = "Mine", modules = { actions = {}, cover = { { 1, 12 } } } }, "Other")
    local copy = A.Catalog.Conflicts()[1]
    copy.conflict.from = nil
    P.Show()
    browse(copy)
    W.manage:Click()
    local texts = {}
    for _, b in ipairs(W.menu.items) do if b:IsShown() then texts[#texts + 1] = b.text:GetText() end end
    check("no sender: no nil", not table.concat(texts, "|"):find("nil", 1, true), table.concat(texts, "|"))
    check("no sender: your other account", table.concat(texts, "|"):find("your other account", 1, true) ~= nil)
    W.manage:Click()
    P.Hide()
end

-- The save status follows events, not only the slow poll.
do
    boot(); main(); ready()
    local a = create("Everyday")
    G.actions[9] = { kind = "spell", id = 2060 }
    A.Loadout.Load(a, A.Loadout.Plan(a))
    P.Show()
    tick(0.01)
    eq("events: no changes", W.saveStatus:GetText(), "No unsaved changes.")
    G.actions[10] = { kind = "spell", id = 2060 }
    tick(1.1)
    eq("events: no event, no poll yet: unchanged", W.saveStatus:GetText(), "No unsaved changes.")
    WoW.fire("ACTIONBAR_SLOT_CHANGED", 10)
    tick(0.01)
    check("events: a slot change shows at once", W.saveStatus:GetText():find("Unsaved: 1 slot", 1, true) ~= nil, W.saveStatus:GetText())
    P.Hide()
    check("events: hidden, no longer registered", not P._Frame().events.ACTIONBAR_SLOT_CHANGED)
end

finish("test_panel")
