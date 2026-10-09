------------------------------------------------------------
-- test_catalog.lua - the catalog of saved setups (#27)
--
-- Covers docs/ACCEPTANCE.md A01, A05, A06, A39, A44 and the catalog sync
-- receive rules (docs/DESIGN.md "Catalog sync"), including two-account
-- exchanges that must converge. The catalog is pure state: a tripwire fails
-- the run if anything here touches a game-state API.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")

-- Tripwire: every game-state writer the addon could ever call.
local touched = {}
for _, name in ipairs({ "PlaceAction", "PickupAction", "ClearCursor", "SetBinding", "SaveBindings",
                        "LoadBindings", "CreateMacro", "EditMacro", "DeleteMacro", "PickupMacro",
                        "SetCVar" }) do
    _G[name] = function() touched[#touched + 1] = name end
end
C_EditMode = setmetatable({}, { __index = function(_, k)
    return function() touched[#touched + 1] = "C_EditMode." .. k end
end })

local function boot()
    WoW.reset()
    assert(loadfile("Core.lua"))("AltStableSync", {})
    assert(loadfile("Categories.lua"))("AltStableSync", {})
    assert(loadfile("Catalog.lua"))("AltStableSync", {})
    WoW.fire("ADDON_LOADED", "AltStableSync")
    assert(AltStableSync.db, "init failed: " .. tostring(AltStableSync.disabled))
    return AltStableSync, AltStableSync.Catalog
end

local A, C = boot()
local function mods(tag) return { actions = { [1] = { spell = tag } }, bindings = {}, macros = {}, cover = { { 1, 12 } } } end
local function loadout(class, category, name, tag)
    return C.Create("loadout", { class = class, category = category, name = name,
                                 provenance = { sourceChar = "Karuzo-Elegia", build = "70245" } }, mods(tag))
end

------------------------------------------------------------
-- Categories
------------------------------------------------------------
do
    local Cat = A.Categories
    local keys = {}
    for _, c in ipairs(Cat.List("PRIEST")) do keys[#keys + 1] = c.key end
    eq("categories: priest", table.concat(keys, ","), "discipline,holy,shadow,general")
    eq("categories: druid has 4 + general", #Cat.List("DRUID"), 5)
    eq("categories: unknown class", Cat.List("DEATHKNIGHT"), nil)
    check("categories: valid", Cat.IsValid("PRIEST", "holy"))
    check("categories: other class's key invalid", not Cat.IsValid("PRIEST", "fury"))
    eq("categories: label", Cat.Label("DRUID", "feral_tank"), "Feral Tank")
    eq("categories: unknown key shown as itself", Cat.Label("PRIEST", "newthing"), "newthing")
    -- Every class's keys are unique.
    for _, class in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
        local seen, dup = {}, false
        for _, c in ipairs(Cat.List(class)) do dup = dup or seen[c.key]; seen[c.key] = true end
        check("categories: unique keys for " .. class, not dup)
    end
end

------------------------------------------------------------
-- Create / Save As (A05, A06)
------------------------------------------------------------
do
    local e = loadout("PRIEST", "discipline", "  Everyday  ", "smite")
    check("create: ok", e ~= nil)
    eq("create: name trimmed", e.name, "Everyday")
    check("create: id is kind-writer-seq", e.id == "loadout-" .. A.writer .. "-" .. A.seq, e.id)
    check("create: version is writer:seq", e.version == A.writer .. ":" .. A.seq, e.version)
    eq("create: no parent", e.parent, nil)
    eq("create: no ancestors", #e.ancestors, 0)
    eq("create: provenance kept", e.provenance.sourceChar, "Karuzo-Elegia")

    -- The stored modules are a copy: changing the caller's table changes nothing.
    local m = mods("heal")
    local e2 = C.Create("loadout", { class = "PRIEST", category = "holy", name = "Raid" }, m)
    m.actions[1].spell = "changed"
    eq("create: modules copied", e2.modules.actions[1].spell, "heal")

    -- A01: separate lists per category; listing writes nothing.
    eq("A01: discipline list", #C.List("loadout", "PRIEST", "discipline"), 1)
    eq("A01: holy list", #C.List("loadout", "PRIEST", "holy"), 1)
    eq("A01: shadow list empty", #C.List("loadout", "PRIEST", "shadow"), 0)
    eq("A01: other class empty", #C.List("loadout", "MAGE", "discipline"), 0)

    -- A06: names.
    local _, err = loadout("PRIEST", "discipline", "", "x");          eq("A06: empty", err, "name-empty")
    _, err = loadout("PRIEST", "discipline", "   ", "x");             eq("A06: whitespace", err, "name-empty")
    _, err = loadout("PRIEST", "discipline", "everyday", "x");        eq("A06: duplicate (case)", err, "name-duplicate")
    check("A06: same name in another category is fine", loadout("PRIEST", "shadow", "Everyday", "x") ~= nil)
    check("A06: same name in another class is fine", loadout("MAGE", "frost", "Everyday", "x") ~= nil)
    check("A06: code-like names are plain text", loadout("PRIEST", "shadow", "|cffff0000Red|r %s", "x") ~= nil)

    -- Validation.
    _, err = C.Create("weird", { name = "X" }, {});                              eq("create: bad kind", err, "bad-kind")
    _, err = C.Create("loadout", { class = "NOPE", category = "x", name = "X" }, {}); eq("create: bad class", err, "bad-class")
    _, err = C.Create("loadout", { class = "PRIEST", category = "fury", name = "X" }, {}); eq("create: bad category", err, "bad-category")
    _, err = C.Create("loadout", { class = "PRIEST", category = "holy", name = "X" }, "no"); eq("create: bad modules", err, "bad-modules")

    -- UI setups: one list, no class or category.
    local ui = C.Create("ui", { name = "My UI" }, { editmode = {} })
    check("ui: created", ui ~= nil and ui.class == nil and ui.category == nil)
    _, err = C.Create("ui", { name = "my ui" }, {});                              eq("ui: duplicate", err, "name-duplicate")
    check("ui: My UI - Druid", C.Create("ui", { name = "My UI - Druid" }, {}) ~= nil)
    eq("ui: list", #C.List("ui"), 2)

    -- A05: Save As from an entry is independent; the original is unchanged.
    local before = e.version
    local fork = loadout("PRIEST", "discipline", "Dungeon healing", "renew")
    check("A05: new id", fork.id ~= e.id)
    eq("A05: original untouched", e.version, before)
    eq("A05: original content untouched", e.modules.actions[1].spell, "smite")
end

------------------------------------------------------------
-- Save (Replace), version guard (A39), Undo (A44), Rename, Delete
------------------------------------------------------------
do
    A, C = boot()
    local e = loadout("PRIEST", "discipline", "Everyday", "v0")
    local v0 = e.version
    local created = e.created
    eq("timestamps: created = updated at birth", e.updated, created)
    WoW.now = WoW.now + 3600

    local r = C.Replace(e.id, mods("v1"), v0)
    eq("timestamps: updated moves on Save", r.updated, created + 3600)
    eq("timestamps: created stays", r.created, created)
    check("replace: ok", r ~= nil)
    eq("replace: parent", r.parent, v0)
    eq("replace: ancestors start with parent", r.ancestors[1], v0)
    eq("replace: previous.of is the new version", r.previous.of, r.version)
    eq("replace: previous holds old content", r.previous.modules.actions[1].spell, "v0")
    eq("replace: new content", r.modules.actions[1].spell, "v1")

    -- A39: a Save from a stale baseline is refused, and nothing changes.
    local v1 = r.version
    local _, err = C.Replace(e.id, mods("stale"), v0)
    eq("A39: stale refused", err, "stale")
    eq("A39: content unchanged", e.modules.actions[1].spell, "v1")
    eq("A39: version unchanged", e.version, v1)

    -- A44: undo my last Save, once.
    local u, uerr = C.UndoLastSave(e.id, v1)
    check("A44: undo ok", u ~= nil, tostring(uerr))
    eq("A44: content restored", e.modules.actions[1].spell, "v0")
    check("A44: undo is a new version", e.version ~= v1 and e.version ~= v0)
    eq("A44: undo descends from the bad save", e.ancestors[1], v1)
    eq("A44: not repeatable", select(2, C.UndoLastSave(e.id, e.version)), "no-undo")

    -- Rename: validated and versioned.
    loadout("PRIEST", "discipline", "Raid", "x")
    local before = e.version
    eq("rename: duplicate refused", select(2, C.Rename(e.id, "raid", e.version)), "name-duplicate")
    eq("rename: stale refused", select(2, C.Rename(e.id, "Solo", v0)), "stale")
    check("rename: ok", C.Rename(e.id, " Solo ", e.version) ~= nil)
    eq("rename: trimmed", e.name, "Solo")
    check("rename: new version", e.version ~= before)
    eq("rename: renaming to its own name is fine", C.Rename(e.id, "solo", e.version) ~= nil, true)

    -- Delete: a tombstone, hidden, guarded, final.
    local beforeDelete = e.version
    eq("delete: stale refused", select(2, C.Delete(e.id, v1)), "stale")
    local d = C.Delete(e.id, e.version)
    check("delete: ok", d ~= nil)
    check("delete: tombstone", e.deleted == true and e.modules == nil and e.previous == nil)
    eq("delete: descends", e.ancestors[1], beforeDelete)
    eq("delete: name kept", e.name, "solo")
    eq("delete: hidden from list", #C.List("loadout", "PRIEST", "discipline"), 1)
    eq("delete: can't save over", select(2, C.Replace(e.id, mods("x"), e.version)), "deleted")
    eq("delete: can't delete twice", select(2, C.Delete(e.id, e.version)), "deleted")
    eq("unknown id", select(2, C.Replace("nope", mods("x"), "v")), "unknown-id")
    eq("manifest lists the tombstone", C.Manifest()[e.id], e.version)

    -- Replace stores a copy too.
    local g = loadout("PRIEST", "holy", "Copy check", "a")
    local gm = mods("b")
    C.Replace(g.id, gm, g.version)
    gm.actions[1].spell = "changed"
    eq("replace: modules copied", g.modules.actions[1].spell, "b")

    -- Ancestors are capped.
    local f = loadout("PRIEST", "holy", "Long", "0")
    for i = 1, 30 do f = C.Replace(f.id, mods(tostring(i)), f.version) end
    eq("ancestors: capped at 20", #f.ancestors, 20)
    eq("ancestors: newest first", f.ancestors[1], f.parent)
end

------------------------------------------------------------
-- Two accounts. Each has its own DB and its own session writer; `use`
-- switches which one the catalog works on.
------------------------------------------------------------
local current
local function use(acc)
    if current then current.seq = A.seq end
    current = acc
    A.db, A.writer, A.seq = acc.db, acc.writer, acc.seq
end
local function account(name, writer, presets)
    return { name = name, writer = writer, seq = 0,
             db = { schema = 2, presets = presets or {}, backups = {} } }
end
-- Send every entry `from` holds to `to`, the way the Link addon would
-- (an envelope never carries `previous`).
local function send(from, to)
    local out = {}
    for _, e in pairs(from.db.presets) do
        local x = C.Copy(e); x.previous = nil; out[#out + 1] = x
    end
    use(to)
    for _, x in ipairs(out) do C.Upsert(x, from.name) end
end
local function sync(a, b) for _ = 1, 3 do send(a, b); send(b, a) end end
local function same(a, b)
    use(a); local ma = C.Manifest()
    use(b); local mb = C.Manifest()
    for id, v in pairs(ma) do if mb[id] ~= v then return false, id end end
    for id, v in pairs(mb) do if ma[id] ~= v then return false, id end end
    return true
end
local function liveConflicts(acc)
    use(acc); local n = 0
    for _, e in pairs(acc.db.presets) do if e.conflict and not e.deleted then n = n + 1 end end
    return n
end
local function root(acc, id) return acc.db.presets[id] end

-- Start both accounts from ONE copied catalog (the beta file copied to both).
local function pair()
    A, C = boot()
    local seed = account("seed", "000000000000")
    use(seed)
    local e = loadout("PRIEST", "discipline", "Everyday", "base")
    local a = account("Karuzo", "aaaaaaaaaaaa", C.Copy(seed.db.presets))
    local b = account("Kaleid", "bbbbbbbbbbbb", C.Copy(seed.db.presets))
    return a, b, e.id
end

-- Upsert basics.
do
    local a, b, id = pair()
    use(a)
    eq("upsert: bad entry", select(2, C.Upsert({ id = 1 }, "x")), "bad-entry")
    eq("upsert: bad entry (no modules)", select(2, C.Upsert({ id = "x", version = "w:1", kind = "ui" }, "x")), "bad-entry")
    local e = root(a, id)
    eq("upsert: same version ignored", C.Upsert(C.Copy(e), "Kaleid"), "ignore")
    -- An unknown id is stored, without the sender's `previous`.
    local x = { id = "ui-cccccccccccc-1", kind = "ui", name = "Theirs", version = "cccccccccccc:1",
                ancestors = {}, modules = {}, previous = { of = "cccccccccccc:1", modules = { secret = 1 } } }
    eq("upsert: unknown id stored", C.Upsert(x, "Kaleid"), "replace")
    eq("upsert: previous stripped", a.db.presets["ui-cccccccccccc-1"].previous, nil)
end

-- An older version arriving late (one we've moved past) is ignored, never a
-- conflict.
do
    local a, b, id = pair()
    use(b); local old = C.Copy(root(b, id))
    use(a); C.Replace(id, mods("A1"), root(a, id).version); C.Replace(id, mods("A2"), root(a, id).version)
    local before = 0
    for _ in pairs(a.db.presets) do before = before + 1 end
    eq("older version: ignored", C.Upsert(old, "Kaleid"), "ignore")
    local after = 0
    for _ in pairs(a.db.presets) do after = after + 1 end
    eq("older version: no conflict copy", after, before)
    eq("older version: content kept", root(a, id).modules.actions[1].spell, "A2")
end

-- A conflict copy id that already exists - live or retired - is never
-- re-created or overwritten by the same divergent version arriving again.
do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("A"), root(a, id).version)
    use(b); C.Replace(id, mods("B"), root(b, id).version)
    local theirs = C.Copy(root(b, id))
    use(a)
    eq("copy id: first receipt is a conflict", C.Upsert(C.Copy(theirs), "Kaleid"), "conflict")
    local cid = id .. "~" .. theirs.version
    a.db.presets[cid].deleted = true          -- as if it had been retired
    eq("copy id: again, ignored", C.Upsert(C.Copy(theirs), "Kaleid"), "ignore")
    check("copy id: retired copy stays retired", a.db.presets[cid].deleted == true)
end

-- Malformed metadata never crosses the receive boundary: the catalog is left
-- untouched, whether the id is unknown or the entry would fast-forward.
do
    local a, b, id = pair()
    use(a)
    local function count() local n = 0; for _ in pairs(a.db.presets) do n = n + 1 end; return n end
    local before, rootBefore = count(), root(a, id).version
    local function bad(label, x)
        local act, err = C.Upsert(x, "Kaleid")
        eq("malformed (" .. label .. "): rejected", err, "bad-entry")
        eq("malformed (" .. label .. "): nothing stored", count(), before)
        eq("malformed (" .. label .. "): root unchanged", root(a, id).version, rootBefore)
    end
    local base = { id = "ui-peer-1", version = "peer:1", kind = "ui", name = "Broken", modules = {} }
    local function with(k, v) local x = C.Copy(base); x[k] = v; return x end
    bad("conflict = true", with("conflict", true))
    bad("conflict without of", with("conflict", { from = "X" }))
    bad("conflict.of empty", with("conflict", { of = "" }))
    -- A valid "<of>~<version>" id, so only the deletion flag is wrong.
    bad("conflict.deletion a string", (function()
        local x = with("conflict", { of = id, deletion = "yes" }); x.id = id .. "~peer:1"; return x end)())
    bad("deleted a string", with("deleted", "false"))
    bad("name a table", with("name", {}))
    bad("modules a string", with("modules", "x"))
    bad("empty version", with("version", ""))
    local lo = { id = "loadout-peer-1", version = "peer:2", kind = "loadout", name = "Everyday",
                 modules = { cover = { { 1, 12 } } } }
    local function lwith(k, v) local x = C.Copy(lo); x[k] = v; return x end
    bad("loadout without class or category", C.Copy(lo))
    bad("loadout without category", lwith("class", "PRIEST"))
    bad("loadout with empty class", (function() local x = lwith("class", ""); x.category = "holy"; return x end)())
    -- A loadout without a valid cover (#5): every schema-2 sender stamps one.
    local nocover = lwith("class", "PRIEST"); nocover.category = "holy"; nocover.modules = {}
    bad("loadout without a cover", nocover)
    local badcover = lwith("class", "PRIEST"); badcover.category = "holy"; badcover.modules = { cover = { { 12, 1 } } }
    bad("loadout with a malformed cover", badcover)
    -- A category key this build doesn't know (a newer build's) is accepted.
    local newer = lwith("class", "PRIEST"); newer.category = "newcategory"
    eq("loadout with a newer category key: accepted", C.Upsert(newer, "Kaleid"), "replace")
    eq("loadout with a newer category key: listed under it", #C.List("loadout", "PRIEST", "newcategory"), 1)
    a.db.presets[newer.id] = nil
    -- A would-be fast-forward of a known id with a broken field.
    local ff = C.Copy(root(a, id))
    ff.version, ff.ancestors, ff.conflict = "peer:9", { rootBefore }, true
    bad("fast-forward with conflict = true", ff)
    -- A conflict that points at itself would retire itself on arrival.
    local selfref = C.Copy(root(a, id))
    selfref.version, selfref.ancestors, selfref.conflict = "peer:11", { rootBefore }, { of = id }
    bad("self-referencing conflict", selfref)
    bad("conflict id not <of>~<v>", with("conflict", { of = id }))
    local ff2 = C.Copy(root(a, id))
    ff2.version, ff2.ancestors, ff2.deleted = "peer:10", { rootBefore }, "true"
    bad("fast-forward with deleted a string", ff2)
end

-- Copied DB: the two accounts can't mint the same version (fresh writers).
do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("A"), root(a, id).version)
    use(b); C.Replace(id, mods("B"), root(b, id).version)
    check("copied DB: distinct versions", root(a, id).version ~= root(b, id).version)
end

-- Lag fast-forwards: A saves three times while B is away.
do
    local a, b, id = pair()
    use(a)
    for i = 1, 3 do C.Replace(id, mods("A" .. i), root(a, id).version) end
    sync(a, b)
    eq("lag: B fast-forwards", root(b, id).modules.actions[1].spell, "A3")
    eq("lag: no conflict copies", liveConflicts(a) + liveConflicts(b), 0)
    check("lag: manifests agree", same(a, b))
    -- A's own undo survives the trip; B never got A's `previous`.
    eq("lag: B has no previous", root(b, id).previous, nil)
end

-- Offline edits on both sides: conflict copies, then one resolution settles both.
do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("A"), root(a, id).version)
    use(b); C.Replace(id, mods("B"), root(b, id).version)
    sync(a, b)
    eq("conflict: A keeps its own", root(a, id).modules.actions[1].spell, "A")
    eq("conflict: B keeps its own", root(b, id).modules.actions[1].spell, "B")
    eq("conflict: one copy each side", liveConflicts(a) .. "/" .. liveConflicts(b), "1/1")
    local copyOnA
    for cid, e in pairs(a.db.presets) do if e.conflict and not e.deleted then copyOnA = cid end end
    eq("conflict: deterministic id", copyOnA, id .. "~" .. root(b, id).version)
    eq("conflict: named", a.db.presets[copyOnA].name, "Everyday (from Kaleid)")
    use(a); eq("conflict: copy listed", #C.List("loadout", "PRIEST", "discipline"), 2)
    -- Repeated exchange never creates a second copy.
    sync(a, b)
    eq("conflict: repeated exchange, still one copy", liveConflicts(a), 1)

    -- Resolve on A: keep theirs.
    use(a)
    local r = C.Resolve(copyOnA, "theirs", root(a, id).version)
    check("resolve: ok", r ~= nil)
    eq("resolve: theirs content", root(a, id).modules.actions[1].spell, "B")
    sync(a, b)
    eq("resolve: B converged", root(b, id).modules.actions[1].spell, "B")
    eq("resolve: no live copies left anywhere", liveConflicts(a) + liveConflicts(b), 0)
    check("resolve: manifests agree", same(a, b))
    -- Settled: another exchange changes nothing.
    use(a); local before = C.Manifest()
    sync(a, b)
    use(a)
    local changed = false
    for k, v in pairs(C.Manifest()) do changed = changed or before[k] ~= v end
    check("resolve: settled", not changed)
end

-- Deleting a conflict copy is "Keep mine", and converges too.
do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("A"), root(a, id).version)
    use(b); C.Replace(id, mods("B"), root(b, id).version)
    sync(a, b)
    use(b)
    local copyOnB = id .. "~" .. root(a, id).version
    check("delete copy: ok", C.DeleteConflictCopy(copyOnB, root(b, id).version) ~= nil)
    sync(a, b)
    eq("delete copy: B kept its own", root(b, id).modules.actions[1].spell, "B")
    eq("delete copy: A converged on B", root(a, id).modules.actions[1].spell, "B")
    eq("delete copy: no live copies", liveConflicts(a) + liveConflicts(b), 0)
    check("delete copy: manifests agree", same(a, b))
end

-- A stale live copy of a conflict entry arriving after its resolution does
-- not re-create it.
do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("A"), root(a, id).version)
    use(b); C.Replace(id, mods("B"), root(b, id).version)
    sync(a, b)
    use(b)
    local staleCopy = C.Copy(b.db.presets[id .. "~" .. root(a, id).version])   -- B's live copy, before resolving
    use(a)
    local copyOnA = id .. "~" .. root(b, id).version
    C.Resolve(copyOnA, "mine", root(a, id).version)
    eq("stale copy: arrives late, ignored or retired", (function()
        local act = C.Upsert(staleCopy, "Kaleid"); return act end)() ~= "conflict", true)
    eq("stale copy: still no live copy on A", liveConflicts(a), 0)
    sync(a, b)
    check("stale copy: converged", same(a, b))
    eq("stale copy: no live copies", liveConflicts(a) + liveConflicts(b), 0)
end

-- Both accounts delete offline: the tombstones converge.
do
    local a, b, id = pair()
    use(a); C.Delete(id, root(a, id).version)
    use(b); C.Delete(id, root(b, id).version)
    sync(a, b)
    check("double delete: still deleted", root(a, id).deleted and root(b, id).deleted)
    check("double delete: converged", same(a, b))
    eq("double delete: no copies", liveConflicts(a) + liveConflicts(b), 0)
end

-- Deleted here, edited there: keep their edit as a new entry; root stays deleted.
do
    local a, b, id = pair()
    use(a); C.Delete(id, root(a, id).version)
    use(b); C.Replace(id, mods("B-edit"), root(b, id).version)
    sync(a, b)
    use(a)
    local copyOnA = id .. "~" .. root(b, id).version
    check("del/edit: copy exists on A", a.db.presets[copyOnA] and not a.db.presets[copyOnA].deleted)
    local r, kept = C.Resolve(copyOnA, "theirs", root(a, id).version)
    check("del/edit: resolved", r ~= nil)
    check("del/edit: edit kept as a new entry", kept and kept.id ~= id and kept.modules.actions[1].spell == "B-edit")
    check("del/edit: root still deleted", root(a, id).deleted)
    sync(a, b)
    check("del/edit: B's root deleted too", root(b, id).deleted)
    check("del/edit: B has the kept entry", b.db.presets[kept.id] ~= nil and not b.db.presets[kept.id].deleted)
    check("del/edit: converged", same(a, b))
    eq("del/edit: no live copies", liveConflicts(a) + liveConflicts(b), 0)
end

-- Edited here, deleted there: "delete here too", and "keep mine".
for _, choice in ipairs({ "delete", "mine" }) do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("A-edit"), root(a, id).version)
    use(b); C.Delete(id, root(b, id).version)
    sync(a, b)
    use(a)
    local copyOnA = id .. "~" .. root(b, id).version
    check("edit/del " .. choice .. ": deletion copy", a.db.presets[copyOnA] and a.db.presets[copyOnA].conflict.deletion)
    check("edit/del " .. choice .. ": resolved", C.Resolve(copyOnA, choice, root(a, id).version) ~= nil)
    sync(a, b)
    if choice == "delete" then
        check("edit/del delete: both deleted", root(a, id).deleted and root(b, id).deleted)
    else
        check("edit/del mine: both live", not root(a, id).deleted and not root(b, id).deleted)
        eq("edit/del mine: B has A's edit", root(b, id).modules.actions[1].spell, "A-edit")
    end
    check("edit/del " .. choice .. ": converged", same(a, b))
    eq("edit/del " .. choice .. ": no live copies", liveConflicts(a) + liveConflicts(b), 0)
end

-- Undo travels as a successor, and lapses when a newer Save arrives.
do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("bad"), root(a, id).version)
    sync(a, b)
    use(a); C.UndoLastSave(id, root(a, id).version)
    sync(a, b)
    eq("undo: B got the undo", root(b, id).modules.actions[1].spell, "base")
    check("undo: converged", same(a, b))

    local a2, b2, id2 = pair()
    use(a2); C.Replace(id2, mods("mine"), root(a2, id2).version)
    sync(a2, b2)
    use(b2); C.Replace(id2, mods("theirs-newer"), root(b2, id2).version)
    sync(a2, b2)
    use(a2)
    eq("undo: lapses after a newer save arrived", select(2, C.UndoLastSave(id2, root(a2, id2).version)), "no-undo")
    eq("undo: newer save intact", root(a2, id2).modules.actions[1].spell, "theirs-newer")
end

-- "Keep this version" takes the chosen version whole: its rename too.
do
    local a, b, id = pair()
    use(a); C.Rename(id, "A-name", root(a, id).version)
    use(b); C.Rename(id, "B-name", root(b, id).version)
    root(b, id).provenance = { sourceChar = "Kaleid-Sumner", build = "70245" }
    sync(a, b)
    use(a)
    C.Resolve(id .. "~" .. root(b, id).version, "theirs", root(a, id).version)
    sync(a, b)
    eq("rename conflict: A took B's name", root(a, id).name, "B-name")
    eq("rename conflict: B kept its name", root(b, id).name, "B-name")
    eq("rename conflict: provenance taken too", root(a, id).provenance.sourceChar, "Kaleid-Sumner")
    check("rename conflict: converged", same(a, b))
end

-- Edited again after the conflict was detected, then resolved: the other
-- account's older mirror copy is retired too, and both settle.
do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("A1"), root(a, id).version)
    use(b); C.Replace(id, mods("B1"), root(b, id).version)
    sync(a, b)
    use(a)
    local copyOnA = id .. "~" .. root(b, id).version
    C.Replace(id, mods("A2"), root(a, id).version)
    C.Resolve(copyOnA, "mine", root(a, id).version)
    sync(a, b)
    eq("late edit: no live copies anywhere", liveConflicts(a) + liveConflicts(b), 0)
    eq("late edit: B has A2", root(b, id).modules.actions[1].spell, "A2")
    check("late edit: manifests agree", same(a, b))
end

-- A delayed older message from the branch that lost can't reopen a settled
-- conflict: the resolution keeps both branches' history.
do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("A1"), root(a, id).version)
    use(b); C.Replace(id, mods("B1"), root(b, id).version)
    local b1 = C.Copy(root(b, id)); b1.previous = nil
    C.Replace(id, mods("B2"), root(b, id).version)
    sync(a, b)
    use(a)
    C.Resolve(id .. "~" .. root(b, id).version, "theirs", root(a, id).version)
    sync(a, b)
    use(a); eq("delayed B1 on A: ignored", C.Upsert(C.Copy(b1), "Kaleid"), "ignore")
    use(b); eq("delayed B1 on B: ignored", C.Upsert(C.Copy(b1), "Kaleid"), "ignore")
    sync(a, b)
    eq("delayed B1: no live copies", liveConflicts(a) + liveConflicts(b), 0)
    check("delayed B1: manifests agree", same(a, b))
end

-- B saved twice while diverged, so A holds two conflict copies. Resolving the
-- newer one retires the older one too (its version is in the resolution's
-- history), and both accounts settle.
do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("A1"), root(a, id).version)
    use(b); C.Replace(id, mods("B1"), root(b, id).version)
    sync(a, b)
    use(b); C.Replace(id, mods("B2"), root(b, id).version)
    send(b, a)
    eq("two copies: A holds two live copies", liveConflicts(a), 2)
    use(a)
    C.Resolve(id .. "~" .. root(b, id).version, "theirs", root(a, id).version)
    eq("two copies: both retired on A", liveConflicts(a), 0)
    sync(a, b)
    eq("two copies: no live copies anywhere", liveConflicts(a) + liveConflicts(b), 0)
    eq("two copies: converged on B2", root(a, id).modules.actions[1].spell, "B2")
    check("two copies: manifests agree", same(a, b))
end

-- Edited here, deleted there, then deleted here too before resolving: the
-- deletion copy is still resolvable ("keep it deleted"), in both writer-token
-- orderings, and both accounts settle.
for _, editorIsA in ipairs({ true, false }) do
    local a, b, id = pair()
    local ed, del = a, b
    if not editorIsA then ed, del = b, a end
    local tag = editorIsA and "A edits" or "B edits"
    use(ed); C.Replace(id, mods("edit"), root(ed, id).version)
    use(del); C.Delete(id, root(del, id).version)
    send(del, ed)
    use(ed)
    local cid = id .. "~" .. root(del, id).version
    check("del twice (" .. tag .. "): deletion copy", ed.db.presets[cid] and ed.db.presets[cid].conflict.deletion)
    C.Delete(id, root(ed, id).version)
    sync(a, b)
    for _, acc in ipairs({ a, b }) do
        use(acc)
        for copyId, e in pairs(acc.db.presets) do
            if e.conflict and not e.deleted then
                check("del twice (" .. tag .. "): resolvable on " .. acc.name,
                      C.Resolve(copyId, "mine", root(acc, id).version) ~= nil)
            end
        end
    end
    sync(a, b)
    check("del twice (" .. tag .. "): both deleted", root(a, id).deleted and root(b, id).deleted)
    eq("del twice (" .. tag .. "): no live copies", liveConflicts(a) + liveConflicts(b), 0)
    check("del twice (" .. tag .. "): manifests agree", same(a, b))
end

-- Resolving against a root version that has moved on is refused, and
-- nothing changes.
do
    local a, b, id = pair()
    use(a); C.Replace(id, mods("A"), root(a, id).version)
    use(b); C.Replace(id, mods("B"), root(b, id).version)
    sync(a, b)
    use(a)
    local cid = id .. "~" .. root(b, id).version
    local seen = root(a, id).version
    C.Replace(id, mods("A2"), seen)
    local rootBefore, copyBefore = root(a, id).version, a.db.presets[cid].version
    eq("stale resolve: refused", select(2, C.Resolve(cid, "theirs", seen)), "stale")
    eq("stale resolve: root unchanged", root(a, id).version, rootBefore)
    eq("stale resolve: root content unchanged", root(a, id).modules.actions[1].spell, "A2")
    eq("stale resolve: copy unchanged", a.db.presets[cid].version, copyBefore)
    check("stale resolve: copy still live", not a.db.presets[cid].deleted)
end

-- Keeping their edit of an entry we deleted, when its name and the first
-- fallback are both taken: the next free name is used, or the caller's.
do
    for _, given in ipairs({ false, true }) do
        local a, b, id = pair()
        use(a); C.Delete(id, root(a, id).version)
        loadout("PRIEST", "discipline", "Everyday", "new1")
        loadout("PRIEST", "discipline", "Everyday (kept)", "new2")
        use(b); C.Replace(id, mods("B-edit"), root(b, id).version)
        send(b, a)
        use(a)
        local cid = id .. "~" .. root(b, id).version
        local r, kept
        if given then
            eq("kept name: caller's duplicate refused", select(2, C.Resolve(cid, "theirs", root(a, id).version, "everyday")), "name-duplicate")
            r, kept = C.Resolve(cid, "theirs", root(a, id).version, "Everyday from Kaleid")
        else
            r, kept = C.Resolve(cid, "theirs", root(a, id).version)
        end
        local tag = given and "given" or "auto"
        check("kept name (" .. tag .. "): resolved", r ~= nil and kept ~= nil)
        eq("kept name (" .. tag .. "): name", kept and kept.name, given and "Everyday from Kaleid" or "Everyday (kept 2)")
        eq("kept name (" .. tag .. "): content", type(kept) == "table" and kept.modules.actions[1].spell, "B-edit")
        check("kept name (" .. tag .. "): root still deleted", root(a, id).deleted)
        sync(a, b)
        eq("kept name (" .. tag .. "): no live copies", liveConflicts(a) + liveConflicts(b), 0)
        check("kept name (" .. tag .. "): converged", same(a, b))
    end
end

-- An entry in a category this build doesn't know (a newer build's) can be
-- kept like any other when we deleted it and the other account edited it.
do
    local a, b, id = pair()
    local newer = { id = "loadout-ffffffffffff-1", version = "ffffffffffff:1", kind = "loadout",
                    class = "PRIEST", category = "newcategory", name = "Future", ancestors = {},
                    modules = mods("future") }
    use(a); eq("unknown category: received", C.Upsert(C.Copy(newer), "Kaleid"), "replace")
    use(b); C.Upsert(C.Copy(newer), "Karuzo")
    use(a); C.Delete(newer.id, a.db.presets[newer.id].version)
    use(b); C.Replace(newer.id, mods("future-edit"), b.db.presets[newer.id].version)
    send(b, a)
    use(a)
    local cid = newer.id .. "~" .. b.db.presets[newer.id].version
    local r, kept = C.Resolve(cid, "theirs", a.db.presets[newer.id].version)
    check("unknown category: kept", r ~= nil and type(kept) == "table", tostring(kept))
    eq("unknown category: category preserved", type(kept) == "table" and kept.category, "newcategory")
    eq("unknown category: content", type(kept) == "table" and kept.modules.actions[1].spell, "future-edit")
    sync(a, b)
    eq("unknown category: no live copies", liveConflicts(a) + liveConflicts(b), 0)
    check("unknown category: converged", same(a, b))
    -- A fresh local Save As still only offers known categories.
    eq("unknown category: Save As still validates", select(2, loadout("PRIEST", "newcategory", "X", "x")), "bad-category")
end

-- A stale Delete can't destroy a newer version that arrived unreviewed.
do
    local a, b, id = pair()
    use(a); local seen = root(a, id).version
    use(b); C.Replace(id, mods("newer"), root(b, id).version)
    send(b, a)
    use(a)
    eq("stale delete: refused", select(2, C.Delete(id, seen)), "stale")
    eq("stale delete: newer kept", root(a, id).modules.actions[1].spell, "newer")
end

------------------------------------------------------------
-- Nothing above touched game state.
------------------------------------------------------------
eq("no game-state API was called", table.concat(touched, ","), "")

finish("test_catalog")
