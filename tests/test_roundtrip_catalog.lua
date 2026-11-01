------------------------------------------------------------
-- test_roundtrip_catalog.lua - the three inputs #95 left out (#98)
--
-- Sync receipt, Share/Import and the Save merge each write the catalog from
-- something this character didn't capture. Each row states its outcome by
-- hand, never derived from the code under test (docs/AUDIT.md section 6):
--   * receipt: an entry keeps its identity; malformed modules, oversized
--     messages and malformed manifest parts change nothing; junk metadata is
--     dropped and the panel still shows the entry;
--   * the module validator: what A35 keeps from another build saves, syncs
--     and is refused only by a share string; a damaged loaded record or
--     `previous` is refused with the existing guidance, never a Lua error;
--   * Save previews: every key and every changed character macro is named,
--     and the saved entry differs from the loaded one in exactly those.
-- test_catalog and test_sync keep the ancestry and transport rules.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local A, C, S, E, L

local function boot()
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Envelope.lua", "Game.lua", "Pet.lua", "Share.lua",
                         "Backups.lua", "Ready.lua", "Loadout.lua", "Preview.lua", "Commands.lua", "Panel.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    assert(loadfile("Plugins/Link/Sync.lua"))("AltStableSyncLink", {})
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A = AltStableSync
    C, S, E, L = A.Catalog, A.Share, A.Envelope, A.Loadout
    G.setup{
        class = "PRIEST", guid = "Player-70-MAIN",
        spells = { { id = 2061, name = "Flash Heal" }, { id = 2050, name = "Lesser Heal" } },
        items = { [5512] = 3 },
        macros = { { name = "Heal", body = "/cast Flash Heal", char = true }, { name = "Acct", body = "/say hi" } },
        actions = { [1] = { spell = 2061 }, [2] = { macro = "Heal" }, [3] = { macro = "Acct" }, [4] = { item = 5512 } },
        keys = { ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2" },
    }
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

-- Sorted keys, so two equal tables serialize alike.
local function ser(v)
    if type(v) ~= "table" then return type(v):sub(1, 1) .. tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. ser(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
end
local function catalog() return ser(A.db.presets) end
local function said(s) return table.concat(WoW.chat(), "\n"):find(s, 1, true) ~= nil end
local function previewText()
    local o = A.Preview.Shown()
    return o and ((o.title or "") .. "\n" .. table.concat(o.lines or {}, "\n")) or ""
end
local function petSlots() local t = {} for i = 1, 10 do t[i] = false end return t end
local function loadout(name, modules)
    return assert(C.Create("loadout", { class = "PRIEST", category = "holy", name = name,
        provenance = { sourceChar = "Main-Realm", build = "70532" } }, modules))
end

-- Every leaf of a table as "path=value", so two versions of an entry can be
-- compared field by field.
local function flatten(t, prefix, out)
    out = out or {}
    for k, v in pairs(t) do
        local path = (prefix and (prefix .. ".") or "") .. tostring(k)
        if type(v) == "table" then flatten(v, path, out) else out[path] = tostring(v) end
    end
    return out
end
local function differences(a, b)
    local x, y, out = flatten(a), flatten(b), {}
    for k, v in pairs(x) do if y[k] ~= v then out[#out + 1] = k end end
    for k in pairs(y) do if x[k] == nil then out[#out + 1] = k end end
    table.sort(out)
    return table.concat(out, " ")
end

-- One Sync instance on this account and a scripted peer: the rows craft the
-- peer's messages by hand.
local PEER = { guid = "Player-1-PEER", name = "Peer", realm = "Realm" }
local function syncFor()
    local sent, reports = {}, {}
    local s = A.Sync.New({ catalog = C, envelope = E, now = function() return WoW.clock end,
        transport = {
            Send = function(m) sent[#sent + 1] = m return 1 end,
            SendTo = function(_, m) sent[#sent + 1] = m return 1 end,
            Peers = function() return { { guid = PEER.guid, name = PEER.name, realm = PEER.realm } } end,
        },
        report = function(t) reports[#reports + 1] = t end, maxPayload = 16384, gen = "g" })
    return s, sent, reports
end
local function man(c, n, p, l)
    return "MAN\n" .. assert(E.Pack({ s = E.SCHEMA, b = "peer-session", c = c, p = p, n = n, l = l }))
end
local function requests(sent, id)
    local n = 0
    for _, m in ipairs(sent) do
        if m:sub(1, 4) == "REQ\n" then
            local x = E.Unpack(m:sub(5))
            if x and x.i == id then n = n + 1 end
        end
    end
    return n
end

------------------------------------------------------------
-- Receipt: an entry keeps its identity (E5)
------------------------------------------------------------
do
    boot()
    local e = loadout("Raid", assert(L.Capture()))
    local before = catalog()
    local function successor(change)
        local x = C.Copy(e)
        x.previous, x.version, x.parent, x.ancestors = nil, "ffffffffffff:1", e.version, { e.version }
        change(x)
        return x
    end
    local function refused(label, x)
        local act, err = C.Upsert(x, "Other-Realm")
        eq(label .. ": refused", err, "bad-entry")
        eq(label .. ": no action", act, nil)
        eq(label .. ": catalog unchanged", catalog(), before)
    end
    refused("E5 kind", successor(function(x) x.kind, x.class, x.category, x.modules = "ui", nil, nil, {} end))
    refused("E5 class", successor(function(x) x.class = "MAGE" end))
    refused("E5 category", successor(function(x) x.category = "shadow" end))
    refused("E5 a tombstone in another category", successor(function(x) x.category, x.deleted, x.modules = "shadow", true, nil end))
    refused("E5 a mirror conflict copy of another class", successor(function(x)
        x.class, x.id, x.conflict = "MAGE", e.id .. "~" .. x.version, { of = e.id, from = "Other" }
    end))
    -- The control: the same successor, identity kept, fast-forwards.
    eq("E5 control: same identity fast-forwards", (C.Upsert(successor(function() end), "Other-Realm")), "replace")
    eq("E5: still listed under Holy", #C.List("loadout", "PRIEST", "holy"), 1)
end

------------------------------------------------------------
-- Receipt: malformed modules (E1)
------------------------------------------------------------
do
    boot()
    local before = catalog()
    local base = { id = "loadout-ffffffffffff-7", version = "ffffffffffff:7", ancestors = {}, kind = "loadout",
                   class = "PRIEST", category = "holy", name = "Crafted" }
    local function with(m) local x = C.Copy(base); x.modules = m; return x end
    local cover = { { 1, 12 } }
    local cases = {
        ["actions a string"] = { cover = cover, actions = "bad" },
        ["a numeric command key"] = { cover = cover, bindings = { [5] = { "1" } } },
        ["a key list a string"] = { cover = cover, bindings = { ACTIONBUTTON1 = "1" } },
        ["an out-of-set action without a kind"] = { cover = cover, actions = { [130] = { id = 7 } } },
        ["a character macro without its definition"] = { cover = cover,
            actions = { [2] = { kind = "macro", name = "Heal", body = "/x", scope = "char" } } },
        ["a macro action's icon (a record's field)"] = { cover = cover,
            actions = { [2] = { kind = "macro", name = "Heal", body = "/x", scope = "char", icon = 1 } },
            macros = { Heal = { body = "/x" } } },
        ["a pet layout's unfilled slots (a record's field)"] = { cover = cover,
            pet = { [4] = { family = "Bear", slots = petSlots(), unavailable = { [3] = "not learned" } } } },
        ["a macro name over 64 bytes"] = { cover = cover,
            actions = { [2] = { kind = "macro", name = ("m"):rep(65), body = "/x", scope = "char" } },
            macros = { [("m"):rep(65)] = { body = "/x" } } },
    }
    for label, m in pairs(cases) do
        local act, err = C.Upsert(with(m), "Other-Realm")
        eq("E1 receipt, " .. label .. ": refused", err, "bad-entry")
        eq("E1 receipt, " .. label .. ": no action", act, nil)
    end
    eq("E1 receipt: nothing stored", catalog(), before)
    -- Why: stored, such an entry makes Load's plan raise.
    local stored = with(cases["actions a string"])
    A.db.presets[stored.id] = stored
    check("E1: a stored malformed entry makes Load raise (why it is refused)", not pcall(L.Plan, stored))
    A.db.presets[stored.id] = nil
end

------------------------------------------------------------
-- Receipt: junk metadata (E3)
------------------------------------------------------------
do
    boot()
    local x = { id = "loadout-ffffffffffff-9", version = "ffffffffffff:9", ancestors = { "a:1", 5, "b:2" },
                kind = "loadout", class = "PRIEST", category = "holy", name = "Junk", modules = assert(L.Capture()),
                evil = { nested = true }, previous = { of = "ffffffffffff:9", modules = {} },
                created = 1e308, updated = {},
                provenance = { sourceChar = "Alt-Realm", build = "70532", extra = { 1 }, n = 5 } }
    eq("E3: stored", (C.Upsert(x, "Other-Realm")), "replace")
    local e = C.Get(x.id)
    local keys = {}
    for k in pairs(e) do keys[#keys + 1] = k end
    table.sort(keys)
    eq("E3: exactly the known fields", table.concat(keys, ","),
       "ancestors,category,class,id,kind,modules,name,provenance,version")
    eq("E3: provenance as text only", ser(e.provenance), ser({ sourceChar = "Alt-Realm", build = "70532" }))
    eq("E3: ancestors are versions only", table.concat(e.ancestors, ","), "a:1,b:2")
    -- NaN and a negative time: dropped too; a real time kept.
    local y = C.Copy(x)
    y.id, y.version, y.created, y.updated = "loadout-ffffffffffff-10", "ffffffffffff:10", 0 / 0, 1730000000
    C.Upsert(y, "Other-Realm")
    eq("E3: NaN dropped", C.Get(y.id).created, nil)
    eq("E3: a real time kept", C.Get(y.id).updated, 1730000000)
    -- The panel shows such an entry, and a stored time it can't show reads "?".
    e.updated = 1e308
    local ok, m = pcall(A.Panel.Model, { category = "holy", id = x.id })
    check("E3: the panel renders it", ok, tostring(m))
    eq("E3: an unshowable time reads ?", ok and m.selected and m.selected.saved, "Saved ? by Alt-Realm")
    e.updated = { "table" }
    ok, m = pcall(A.Panel.Model, { category = "holy", id = x.id })
    check("E3: a table for a time renders too", ok and m.selected and m.selected.saved == "Saved ? by Alt-Realm", tostring(m))
end

------------------------------------------------------------
-- Receipt: an oversized entry (E2). The cap refuses the parse of what the
-- decompressor returned; it can't bound the decompressor (docs/AUDIT.md).
------------------------------------------------------------
do
    boot()
    local s, sent, reports = syncFor()
    local x = { id = "loadout-ffffffffffff-3", version = "ffffffffffff:3", ancestors = {}, kind = "loadout",
                class = "PRIEST", category = "holy", name = "Big", modules = assert(L.Capture()) }
    s.Receive(man(1, 1, 1, { [x.id] = x.version }), PEER, 1)
    eq("E2: requested once", requests(sent, x.id), 1)
    local text = assert(E.Encode(x))
    -- A genuine envelope, checksum and all, whose data is over the cap: an
    -- unknown module key (which the lenient validator keeps) 256 KB long.
    local big = C.Copy(x)
    big.modules.addons = { blob = ("x"):rep(E.ENTRY_CBOR_MAX) }
    local bigText = assert(E.Pack({ s = E.SCHEMA, e = big }))
    local des = C_EncodingUtil.DeserializeCBOR
    local parsed = false
    C_EncodingUtil.DeserializeCBOR = function(...) parsed = true return des(...) end
    s.Receive("ENT\n" .. x.id .. "\n" .. x.version .. "\n" .. bigText, PEER, 2)
    C_EncodingUtil.DeserializeCBOR = des
    check("E2: never parsed", not parsed)
    eq("E2: not stored", C.Get(x.id), nil)
    local why = false
    for _, r in ipairs(reports) do if r:find("too-long", 1, true) then why = true end end
    check("E2: said once, with the reason", why)
    s.Receive(man(2, 1, 1, { [x.id] = x.version }), PEER, 3)
    WoW.clock = WoW.clock + 1
    s.Tick()
    eq("E2: that version isn't asked for again this session", requests(sent, x.id), 1)
    -- The control: the same entry at its real size arrives.
    local s2, sent2 = syncFor()
    s2.Receive(man(1, 1, 1, { [x.id] = x.version }), PEER, 1)
    s2.Receive("ENT\n" .. x.id .. "\n" .. x.version .. "\n" .. text, PEER, 2)
    check("E2 control: a real entry is stored", C.Get(x.id) ~= nil and #sent2 > 0)
end

------------------------------------------------------------
-- Receipt: malformed manifest parts (E4)
------------------------------------------------------------
do
    boot()
    local e = loadout("Mine", assert(L.Capture()))
    local s = syncFor()
    local function status() return s.EntryStatus(e) end
    s.Receive(man(1, 1, 2, { [e.id] = e.version }), PEER, 1)
    eq("E4 p > n: no manifest", status(), "pending")
    local l = { [e.id] = e.version }
    for i = 1, 100 do l["loadout-x-" .. i] = "x:" .. i end
    s.Receive(man(2, 1, 1, l), PEER, 2)
    eq("E4 101 ids in one part: no manifest", status(), "pending")
    s.Receive(man(3, 1.5, 1, { [e.id] = e.version }), PEER, 3)
    eq("E4 a fractional n: no manifest", status(), "pending")
    -- A two-part batch; a stray part claiming another n arrives in between.
    s.Receive(man(4, 2, 1, { [e.id] = e.version }), PEER, 4)
    s.Receive(man(4, 3, 2, { ["loadout-stray-1"] = "z:1" }), PEER, 5)
    eq("E4 another n: the batch isn't complete", status(), "pending")
    s.Receive(man(4, 2, 2, {}), PEER, 6)
    eq("E4: the batch's own parts complete it", status(), "confirmed")
end

------------------------------------------------------------
-- Receipt: a conflict copy before its root
------------------------------------------------------------
do
    boot()
    local root = { id = "loadout-eeeeeeeeeeee-1", version = "eeeeeeeeeeee:2", parent = "eeeeeeeeeeee:1",
                   ancestors = { "eeeeeeeeeeee:1" }, kind = "loadout", class = "PRIEST", category = "holy", name = "Late",
                   modules = assert(L.Capture()) }
    local copy = C.Copy(root)
    copy.version, copy.ancestors = "dddddddddddd:5", { "eeeeeeeeeeee:1" }
    copy.id, copy.conflict, copy.name = root.id .. "~" .. copy.version, { of = root.id, from = "Third", name = "Late" }, "Late (from Third)"
    eq("copy first: stored", (C.Upsert(copy, "Other-Realm")), "replace")
    eq("copy first: not resolvable yet", select(2, C.Resolve(copy.id, "mine", "x")), "unknown-id")
    eq("root later: stored", (C.Upsert(root, "Other-Realm")), "replace")
    check("then resolvable", C.Resolve(copy.id, "mine", root.version) ~= nil)
    check("the copy retired", C.Get(copy.id).deleted == true)
end

------------------------------------------------------------
-- The validator: what A35 keeps from another build saves and syncs, and
-- only a share string refuses it (E1, lenient vs strict)
------------------------------------------------------------
do
    boot()
    local LONG = "Heal of twenty bytes"                  -- 20 bytes: over a share string's 16
    local m = assert(L.Capture())
    m.cover = { { 1, 12 } }                              -- a legacy cover
    m.addons = { Bartender = { profile = "Main" } }      -- a newer build's part
    m.bindings.TOGGLEAUTORUN = { "CTRL-F11" }            -- a command this build doesn't manage
    m.bindings.ACTIONBUTTON3 = { [2] = "Q" }             -- keys by position, a hole first
    m.actions[130] = { kind = "summonmount", id = 5 }    -- a slot this build doesn't manage
    m.actions[5] = { kind = "macro", name = LONG, body = "/cast Lesser Heal", scope = "char" }
    m.macros[LONG] = { body = "/cast Lesser Heal" }
    for _, a in pairs(m.actions) do if a.kind == "spell" then a.class = nil end end   -- an older capture: no marks
    local e = loadout("Legacy", m)
    check("lenient: Create takes it", e ~= nil)
    eq("strict: Share refuses it", select(2, S.Encode(e)), "cant-share")
    -- Sync carries it to an account that doesn't have it.
    local x = assert(E.Decode(assert(E.Encode(e))))
    local mine = A.db.presets
    A.db.presets = {}
    eq("sync: the other account stores it", (C.Upsert(x, "Main-Realm")), "replace")
    A.db.presets = mine
    -- Load, change one slot, Save: what A35 keeps survives, and the merge's
    -- output passes the catalog's own check.
    local plan = L.Plan(e)
    local outside = false
    for _, sk in ipairs(plan.skips) do if sk.slot == 130 and sk.reason == "not supported on this build" then outside = true end end
    check("load: the unmanaged slot listed, never applied", outside)
    local r = L.Load(e, plan)
    check("load: done", r and not r.failed, r and tostring(r.failed))
    G.actions[1] = { kind = "spell", id = 2050 }
    local p, err = L.PlanSave()
    check("save: planned", p ~= nil, tostring(err))
    if p then
        check("save: the unknown part kept", p.modules.addons ~= nil and p.modules.addons.Bartender.profile == "Main")
        eq("save: the unmanaged command kept", ser(p.modules.bindings.TOGGLEAUTORUN), ser({ "CTRL-F11" }))
        eq("save: the unmanaged slot kept", ser(p.modules.actions[130]), ser({ kind = "summonmount", id = 5 }))
        eq("save: the long macro name kept", p.modules.macros[LONG] and p.modules.macros[LONG].body, "/cast Lesser Heal")
        check("save: the merge passes the catalog's check", S.GoodModules(p.modules, "lenient"))
        check("save: confirmed", L.Save(p) ~= nil)
        eq("after Save: still not shareable", select(2, S.Encode(C.Get(e.id))), "cant-share")
    end
    -- The control, on a fresh character (this one now holds the long macro):
    -- an entry without them round-trips through a share string.
    boot()
    local plain = loadout("Plain", assert(L.Capture()))
    local back = S.Decode(assert(S.Encode(plain)))
    eq("strict control: a captured loadout round-trips", back and ser(back.modules), ser(plain.modules))
end

------------------------------------------------------------
-- The loaded record: damaged parts get the existing guidance (E1,
-- comparison mode), never a Lua error or a write
------------------------------------------------------------
do
    boot()
    local e = loadout("Rec", assert(L.Capture()))
    local r = L.Load(e, L.Plan(e))
    check("record: loaded", r ~= nil)
    G.actions[1] = { kind = "spell", id = 2050 }
    check("control: a sound record plans a Save", L.PlanSave() ~= nil)
    local good = C.Copy(A.char.loaded.loadout)
    local function damaged(label, mutate)
        A.char.loaded.loadout = C.Copy(good)
        mutate(A.char.loaded.loadout)
        local before = catalog()
        local ok, m, err = pcall(L.PlanSave)
        check(label .. ": Save doesn't raise", ok, tostring(m))
        check(label .. ": Save refused with the damaged-record line",
            ok and m == nil and tostring(err):find("record of the loaded setup is damaged", 1, true) ~= nil, tostring(err))
        local ok2, p = pcall(L.PlanSaveAs)
        check(label .. ": Save As doesn't raise", ok2, tostring(p))
        check(label .. ": Save As warns and captures plainly",
            ok2 and p and p.lossy == true and tostring(p.why):find("damaged", 1, true) ~= nil)
        eq(label .. ": nothing written", catalog(), before)
    end
    damaged("baseline actions a string", function(rec) rec.baseline.actions = "bad" end)
    damaged("comparison with a numeric command", function(rec) rec.after.bindings[5] = { "1" } end)
    damaged("comparison with an out-of-set action without a kind", function(rec) rec.after.actions[130] = { id = 1 } end)
    damaged("unavailable a string", function(rec) rec.unavailable = "bad" end)
    damaged("unavailable with a number for a reason", function(rec) rec.unavailable = { [3] = 5 } end)
    -- The fields only a record carries pass.
    A.char.loaded.loadout = C.Copy(good)
    local rec = A.char.loaded.loadout
    for _, a in pairs(rec.after.actions) do if a.kind == "macro" and a.scope == "char" then a.icon = 134400 end end
    rec.after.pet = { [4] = { family = "Bear", slots = petSlots(), unavailable = { [3] = "not learned" } } }
    check("a comparison with a macro icon and a pet's unfilled slots: Save plans", L.PlanSave() ~= nil)
    local sa = L.PlanSaveAs()
    check("and Save As merges", sa and not sa.lossy)
    -- The same fields in a share string are damage.
    local share = { kind = "loadout", class = "PRIEST", category = "holy", name = "X",
                    modules = { cover = { { 1, 12 } }, macros = { Heal = { body = "/x" } },
                                actions = { [2] = { kind = "macro", name = "Heal", body = "/x", scope = "char", icon = 5 } } } }
    eq("share: a macro action's icon is damage", select(2, S.Decode(assert(E.EncodeShare(share)))), "bad-share")

    -- An older build's `previous`: a malformed known part refuses Undo; an
    -- unknown key alone is kept (A35).
    local cur = C.Get(e.id)
    cur.previous = { of = cur.version, modules = { cover = { { 1, 12 } }, actions = "bad" } }
    local before = catalog()
    eq("Undo of a malformed previous: refused", select(2, C.UndoLastSave(e.id, cur.version)), "bad-modules")
    eq("Undo refused: nothing written", catalog(), before)
    cur.previous = { of = cur.version, modules = { cover = { { 1, 12 } }, actions = {}, addons = { x = 1 } } }
    check("Undo of a previous with an unknown key: done", C.UndoLastSave(e.id, cur.version) ~= nil)
    check("its unknown key kept", C.Get(e.id).modules.addons ~= nil)
end

------------------------------------------------------------
-- The Save preview: every key and every changed macro, and the saved entry
-- differs from the loaded one in exactly those (E13, E15)
------------------------------------------------------------
do
    boot()
    local m = assert(L.Capture())
    m.bindings = { ACTIONBUTTON1 = { "1" }, ACTIONBUTTON2 = { "2" } }      -- keys for buttons 1-2 only
    local e = loadout("Keys", m)
    local r = L.Load(e, L.Plan(e))
    check("loaded", r ~= nil and not r.failed)
    for _, mm in ipairs(G.char) do if mm.name == "Heal" then mm.body = "/cast Flash Heal\n/say on my way" end end
    G.keys["3"] = "ACTIONBUTTON3"
    A.Commands.save("")
    local text = previewText()
    check("E13: the headline counts the added key", text:find('1 slot and 1 key change in "Keys".', 1, true) ~= nil, text)
    check("E13: the added key listed", text:find("Adds 1 key this loadout didn't have yet:", 1, true) ~= nil, text)
    check("E15: the changed macro named", text:find("  Heal: text changes", 1, true) ~= nil, text)
    check("E15: with its first differing line", text:find("    line 2: (no line) -> /say on my way", 1, true) ~= nil, text)
    local shown = A.Preview.Shown()
    if shown and shown.onConfirm then shown.onConfirm() end
    local saved = C.Get(e.id)
    eq("saved: exactly the listed changes", differences(m, saved.modules),
       "actions.2.body bindings.ACTIONBUTTON3.1 macros.Heal.body")
end

finish("test_roundtrip_catalog")
