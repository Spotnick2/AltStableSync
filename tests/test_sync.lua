------------------------------------------------------------
-- test_sync.lua - the catalog exchange between WoW accounts (#18)
--
-- Two (or three) accounts, each with its own catalog and its own Sync
-- instance, on a fake network that delays every message one second, can drop
-- a share of them, and refuses a stream when the sender already has 4 open
-- to that receiver (LibAccountSync r5's messages-mode cap per sender + tag).
-- The catalog's ancestry rules are test_catalog's; this file proves the
-- transport recovery, the dispatch, the status and the safety boundary:
-- nothing received ever reaches game state (A40).
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")

-- Tripwire: every game-state writer the addon could ever call.
local touched = {}
for _, name in ipairs({ "PlaceAction", "PickupAction", "ClearCursor", "SetBinding", "SaveBindings",
                        "LoadBindings", "CreateMacro", "EditMacro", "DeleteMacro", "PickupMacro",
                        "SetCVar", "PickupSpell", "PickupItem" }) do
    _G[name] = function() touched[#touched + 1] = name end
end

WoW.reset()
assert(loadfile("Core.lua"))("AltStableSync", {})
assert(loadfile("Categories.lua"))("AltStableSync", {})
assert(loadfile("Catalog.lua"))("AltStableSync", {})
assert(loadfile("Envelope.lua"))("AltStableSync", {})
assert(loadfile("Plugins/Link/Sync.lua"))("AltStableSyncLink", {})
WoW.fire("ADDON_LOADED", "AltStableSync")
local A, C, Env, S = AltStableSync, AltStableSync.Catalog, AltStableSync.Envelope, AltStableSync.Sync
assert(A.db, "init failed")

------------------------------------------------------------
-- Accounts, clock, network
------------------------------------------------------------
local T = 0
local current
local function use(acc)
    if current then current.seq = A.seq end
    current = acc
    A.db, A.writer, A.seq = acc.db, acc.writer, acc.seq
end
C.OnLocalWrite(function() if current and current.sync then current.sync.LocalWrite() end end)

local net = { queue = {}, drop = 0, rng = 0, refused = 0, sent = {} }
local accounts = {}

-- A deterministic "random" in [0,1).
local function rand()
    net.rng = (net.rng * 1103515245 + 12345) % 2147483648
    return net.rng / 2147483648
end

local function inFlight(from, to)
    local n = 0
    for _, m in ipairs(net.queue) do if m.from == from and m.to == to then n = n + 1 end end
    return n
end

local function enqueue(from, to, msg)
    local kind = msg:sub(1, 3)
    net.sent[#net.sent + 1] = { from = from.name, to = to.name, kind = kind, msg = msg, at = T }
    if net.instant then
        -- Delivered before the sender's call returns (LibAccountSync may report
        -- results synchronously; this is the worst case for bookkeeping order).
        local was = current
        use(to)
        to.sync.Receive(msg, { guid = from.guid, name = from.name, realm = from.realm })
        use(was)
        return
    end
    if inFlight(from, to) >= 4 then net.refused = net.refused + 1 return end
    if rand() < net.drop then return end
    from.sid = from.sid + 1
    net.queue[#net.queue + 1] = { from = from, to = to, msg = msg, sid = from.sid }
end

local function account(name, writer, realm)
    local acc = { name = name, writer = writer, seq = 0, online = true, guid = "Player-1-" .. name, sid = 0,
                  realm = realm == nil and "Elegia" or realm or nil, reports = {},
                  db = { schema = 2, presets = {}, backups = {} } }
    local transport = {
        Send = function(msg)
            local n = 0
            for _, o in ipairs(accounts) do
                if o ~= acc and o.online and acc.online then enqueue(acc, o, msg); n = n + 1 end
            end
            return n
        end,
        SendTo = function(guid, msg)
            for _, o in ipairs(accounts) do
                if o.guid == guid and o.online and acc.online then enqueue(acc, o, msg) return 1 end
            end
            return 0
        end,
        Peers = function()
            local out = {}
            if not acc.online then return out end
            for _, o in ipairs(accounts) do
                if o ~= acc and o.online then out[#out + 1] = { guid = o.guid, name = o.name, realm = o.realm } end
            end
            return out
        end,
    }
    acc.transport = transport
    acc.sync = S.New({ catalog = C, envelope = Env, transport = transport, now = function() return T end,
                       report = function(text) acc.reports[#acc.reports + 1] = text end,
                       maxPayload = acc.maxPayload or 16384, gen = writer })
    accounts[#accounts + 1] = acc
    return acc
end

-- One second: every account ticks, then every message queued before this
-- second is delivered (replies go out next second).
local function step()
    T = T + 1
    for _, acc in ipairs(accounts) do use(acc); acc.sync.Tick() end
    local batch = net.queue
    net.queue = {}
    for _, m in ipairs(batch) do
        if m.to.online then
            use(m.to)
            m.to.sync.Receive(m.msg, { guid = m.from.guid, name = m.from.name, realm = m.from.realm }, m.sid)
        end
    end
end
local function run(seconds) for _ = 1, seconds do step() end end

local function same(a, b)
    use(a); local ma = C.Manifest()
    use(b); local mb = C.Manifest()
    for id, v in pairs(ma) do if mb[id] ~= v then return false, id end end
    for id, v in pairs(mb) do if ma[id] ~= v then return false, id end end
    return true
end
local function liveConflicts(acc)
    local n = 0
    for _, e in pairs(acc.db.presets) do if type(e) == "table" and e.conflict and not e.deleted then n = n + 1 end end
    return n
end
local function mods(tag) return { actions = { [1] = { kind = "spell", id = tag } }, bindings = {}, macros = {}, cover = { { 1, 12 } } } end
local function save(acc, name, tag, category)
    use(acc)
    return C.Create("loadout", { class = "PRIEST", category = category or "holy", name = name,
                                 provenance = { sourceChar = acc.name .. "-Elegia", build = "70245" } }, mods(tag or 1))
end
local function count(kind, from, since)
    local n = 0
    for _, s in ipairs(net.sent) do
        if s.kind == kind and (not from or s.from == from) and s.at >= (since or 0) then n = n + 1 end
    end
    return n
end
local function reqs(from, id, since)
    local n = 0
    for _, s in ipairs(net.sent) do
        if s.kind == "REQ" and s.from == from and s.at >= (since or 0) then
            local m = Env.Unpack(s.msg:sub(5))
            if m and (id == nil or m.i == id) then n = n + 1 end
        end
    end
    return n
end
local function reset()
    accounts, net.queue, net.sent, net.drop, net.refused, net.rng, net.instant = {}, {}, {}, 0, 0, 7, nil
    current = nil
end

------------------------------------------------------------
-- Save on one account, it appears on the other, pending -> confirmed
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    run(12)                                        -- both see the other: an exchange each
    local e = save(a, "Raid", 2050)
    use(a)
    eq("basic: pending before the peer has it", a.sync.EntryStatus(e), "pending")
    run(6)
    check("basic: arrived on the other account", b.db.presets[e.id] ~= nil)
    eq("basic: same version", b.db.presets[e.id] and b.db.presets[e.id].version, e.version)
    eq("basic: still pending (the peer hasn't listed it yet)", a.sync.EntryStatus(e), "pending")
    run(S.INTERVAL + 2)                            -- the peer's next exchange lists it
    eq("basic: confirmed", a.sync.EntryStatus(e), "confirmed")
    check("basic: both catalogs equal", (same(a, b)))
    eq("basic: no game state touched", #touched, 0)
    -- No peer: no status.
    a.online, b.online = false, false
    run(S.INTERVAL + 12)
    eq("basic: no listed peer, no status", a.sync.EntryStatus(e), nil)
end

------------------------------------------------------------
-- #5: a peer on the older wire schema pauses sync; nothing it sends is
-- imported or cached as handled, so once it updates (same session, same
-- entry version) the entry is fetched and the pause clears.
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local e = save(a, "Raid", 2050)
    local from = { guid = a.guid, name = "Alpha", realm = "Elegia" }
    use(b)
    -- The previous wire (2, a #5 build) is older too (#46/#48).
    local function old(t) t.s = Env.SCHEMA - 1; return Env.Pack(t) end
    b.sync.Receive("MAN\n" .. old({ b = "aaa", c = 1, p = 1, n = 1, l = { [e.id] = e.version } }), from)
    b.sync.Receive("REQ\n" .. old({ i = e.id }), from)
    b.sync.Receive("ENT\n" .. e.id .. "\n" .. e.version .. "\n" .. old({ e = C.Copy(a.db.presets[e.id]) }), from)
    eq("old peer: nothing imported", b.db.presets[e.id], nil)
    local n = 0
    for _, r in ipairs(b.reports) do if r:find("older AltStableSync", 1, true) then n = n + 1 end end
    eq("old peer: one notice", n, 1)
    local function schemaOf(acc, guid)
        for _, p in ipairs(acc.sync.Peers()) do if p.guid == guid then return p.schema end end
        return "no peer"
    end
    eq("old peer: paused", schemaOf(b, a.guid), "older-schema")
    eq("old peer: no request sent", reqs("Beta", e.id), 0)
    -- Per entry it reads paused, not pending (#44 review).
    local mine = save(b, "Mine", 2052)
    eq("old peer: entry status says paused", b.sync.EntryStatus(b.db.presets[mine.id]), "sync paused")
    -- Its first schema-2 manifest clears the pause on its own.
    b.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA, b = "aaa2", c = 1, p = 1, n = 1, l = {} }), from)
    eq("updated peer: a manifest clears the pause", schemaOf(b, a.guid), nil)
    -- And the other way round: a peer on a newer wire pauses too.
    b.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA + 1, b = "new", c = 1, p = 1, n = 1, l = {} }), from)
    eq("newer peer: paused", schemaOf(b, a.guid), "newer-schema")
    b.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA, b = "aaa3", c = 1, p = 1, n = 1, l = {} }), from)
    eq("newer peer back on our wire: cleared", schemaOf(b, a.guid), nil)
    b.sync.Receive("MAN\n" .. old({ b = "aaa", c = 2, p = 1, n = 1, l = {} }), from)
    eq("old peer again: paused", schemaOf(b, a.guid), "older-schema")
    -- A corrupt entry proves nothing: the pause stays.
    b.sync.Receive("ENT\nloadout-x-1\nx:1\nASE1:00000000:zz", from)
    eq("old peer: a corrupt entry keeps the pause", schemaOf(b, a.guid), "older-schema")
    run(S.INTERVAL + 15)                                    -- the peer now speaks schema 2
    eq("updated peer: entry fetched", b.db.presets[e.id] and b.db.presets[e.id].version, e.version)
    eq("updated peer: pause cleared", schemaOf(b, a.guid), nil)
end

-- A peer found incompatible mid-exchange gets no more requests: what was
-- queued or outstanding for it is dropped until it speaks our schema.
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local e, f = save(a, "Raid", 2050), save(a, "Pvp", 2051)
    local from = { guid = a.guid, name = "Alpha", realm = "Elegia" }
    use(b)
    b.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA, b = "pre", c = 1, p = 1, n = 1,
                                         l = { [e.id] = e.version, [f.id] = f.version } }), from)
    check("paused peer: two requests out", (b.sync.Outstanding(a.guid)) == 2)
    b.sync.Receive("ENT\n" .. e.id .. "\n" .. e.version .. "\n" .. Env.Pack({ s = 1, e = C.Copy(a.db.presets[e.id]) }), from)
    local o, q = b.sync.Outstanding(a.guid)
    eq("paused peer: nothing outstanding or queued", o + q, 0)
end

------------------------------------------------------------
-- 100 differing entries converge through loss and stream refusals, never
-- more than MAX_OUT outstanding requests, one id per request
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    for i = 1, 60 do save(a, "A" .. i, i) end
    for i = 1, 40 do save(b, "B" .. i, i) end
    net.drop = 0.3
    local maxOut = 0
    for _ = 1, 1500 do
        step()
        for _, acc in ipairs({ a, b }) do
            local other = acc == a and b or a
            local out = acc.sync.Outstanding(other.guid)
            if out > maxOut then maxOut = out end
        end
        if (same(a, b)) then break end
    end
    check("100 entries: converged", (same(a, b)))
    check("100 entries: some messages were lost or refused", net.refused > 0 or net.drop > 0)
    check("100 entries: outstanding requests never above " .. S.MAX_OUT, maxOut <= S.MAX_OUT, "max " .. maxOut)
    local oneId = true
    for _, s in ipairs(net.sent) do
        if s.kind == "REQ" then
            local m = Env.Unpack(s.msg:sub(5))
            if not (m and type(m.i) == "string") then oneId = false end
        end
    end
    check("100 entries: every request names one id", oneId)
    net.drop = 0
    run(2 * S.INTERVAL + 5)
    local allConfirmed = true
    use(a)
    for _, e in pairs(a.db.presets) do
        if a.sync.EntryStatus(e) ~= "confirmed" then allConfirmed = false end
    end
    check("100 entries: all confirmed on A once the loss stops", allConfirmed)
    eq("100 entries: no game state touched", #touched, 0)
end

------------------------------------------------------------
-- Divergence: one conflict copy each, repeated exchange adds none,
-- resolving on one account settles both
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local e = save(a, "Raid", 1)
    run(10)
    check("diverge: shared first", b.db.presets[e.id] ~= nil)
    -- Both links off; each renames the same entry.
    a.online, b.online = false, false
    use(a); local ra = C.Rename(e.id, "Raid A", a.db.presets[e.id].version)
    use(b); local rb = C.Rename(e.id, "Raid B", b.db.presets[e.id].version)
    check("diverge: renamed on both", ra ~= nil and rb ~= nil)
    a.online, b.online = true, true
    run(20)
    eq("diverge: one conflict copy on A", liveConflicts(a), 1)
    eq("diverge: one conflict copy on B", liveConflicts(b), 1)
    local found = false
    for _, r in ipairs(a.reports) do if r:find("changed on both accounts", 1, true) then found = true end end
    check("diverge: a one-line notice", found)
    run(3 * S.INTERVAL)
    eq("diverge: repeated exchange adds no copy (A)", liveConflicts(a), 1)
    eq("diverge: repeated exchange adds no copy (B)", liveConflicts(b), 1)
    local t0 = T
    run(3 * S.INTERVAL)
    eq("diverge: settled, nothing more is requested (A)", reqs("Alpha", nil, t0), 0)
    eq("diverge: settled, nothing more is requested (B)", reqs("Beta", nil, t0), 0)
    -- A reload on A (fresh session memory, same catalog): the kept copy means
    -- the root's other version is not fetched again.
    a.sync = S.New({ catalog = C, envelope = Env, transport = a.transport, now = function() return T end,
                     report = function(text) a.reports[#a.reports + 1] = text end, gen = "aaaaaaaaaaaa-2" })
    local t1 = T
    run(S.INTERVAL + 15)
    eq("diverge: after a reload the root isn't refetched", reqs("Alpha", e.id, t1), 0)
    -- Resolve on A: keep theirs.
    use(a)
    local copyId
    for id, x in pairs(a.db.presets) do if x.conflict and not x.deleted then copyId = id end end
    local tr = T
    local root = C.Resolve(copyId, "theirs", a.db.presets[e.id].version)
    check("diverge: resolved on A", root ~= nil)
    run(4)
    check("diverge: resolving announces at once", count("MAN", "Alpha", tr) >= 1)
    run(2 * S.INTERVAL + 10)
    eq("diverge: settled on A", liveConflicts(a), 0)
    eq("diverge: settled on B", liveConflicts(b), 0)
    check("diverge: catalogs equal", (same(a, b)))
    eq("diverge: B took the resolution", b.db.presets[e.id].name, "Raid B")
    use(a)
    eq("diverge: root confirmed", a.sync.EntryStatus(a.db.presets[e.id]), "confirmed")
    eq("diverge: no game state touched", #touched, 0)
end

------------------------------------------------------------
-- Tombstones travel; a stale live copy arriving later stays deleted
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local e = save(a, "Old", 1)
    run(10)
    use(a)
    local stale = Env.Encode(a.db.presets[e.id])
    local staleV = a.db.presets[e.id].version
    C.Delete(e.id, a.db.presets[e.id].version)
    run(10)
    check("tombstone: deleted on B", b.db.presets[e.id] and b.db.presets[e.id].deleted == true)
    use(b)
    b.sync.Receive("ENT\n" .. e.id .. "\n" .. staleV .. "\n" .. stale, { guid = a.guid, name = "Alpha", realm = "Elegia" })
    check("tombstone: stale copy doesn't resurrect", b.db.presets[e.id].deleted == true)
    eq("tombstone: no conflict copy", liveConflicts(b), 0)
end

------------------------------------------------------------
-- `previous` never travels; receipts keep the local one
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local e = save(a, "Raid", 1)
    use(a); C.Replace(e.id, mods(2), a.db.presets[e.id].version)
    check("previous: A has one", a.db.presets[e.id].previous ~= nil)
    run(10)
    local leaked = false
    for _, s in ipairs(net.sent) do
        if s.kind == "ENT" then
            local x = Env.Decode(s.msg:match("^ENT\n[^\n]+\n[^\n]+\n(.*)$"))
            check("previous: entry message decodes", x ~= nil)
            if x and x.previous ~= nil then leaked = true end
            if s.msg:find("previous", 1, true) then leaked = true end
        end
    end
    check("previous: never on the wire", not leaked)
    eq("previous: not stored on B", b.db.presets[e.id].previous, nil)
    -- B saves over it (its own previous), then A saves again: B fast-forwards, keeps its previous.
    use(b); C.Replace(e.id, mods(3), b.db.presets[e.id].version)
    local bPrev = b.db.presets[e.id].previous
    run(10)
    use(a); C.Replace(e.id, mods(4), a.db.presets[e.id].version)
    run(10)
    eq("previous: B fast-forwarded", b.db.presets[e.id].version, a.db.presets[e.id].version)
    eq("previous: B's own previous untouched", b.db.presets[e.id].previous, bPrev)
end

------------------------------------------------------------
-- Refused input leaves the catalog untouched; a missing realm is fine
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    use(b)
    local before = C.Copy(b.db.presets)
    local cbor = C_EncodingUtil.SerializeCBOR({ s = 3, e = { id = "loadout-zzz-1", version = "zzz:1" } })
    local newer = "ASE1:" .. Env.Adler32(cbor) .. ":" .. C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(cbor))
    b.sync.Receive("ENT\nloadout-zzz-1\nzzz:1\n" .. newer, { guid = a.guid, name = "Alpha", realm = "Elegia" })
    b.sync.Receive("ENT\nloadout-zzz-1\nzzz:1\nASE1:00000000:00", { guid = a.guid, name = "Alpha" })
    b.sync.Receive("MAN\ngarbage", { guid = a.guid, name = "Alpha" })
    b.sync.Receive("XYZ\n" .. newer, { guid = a.guid, name = "Alpha" })
    b.sync.Receive("ENT\n" .. newer, { name = "no guid" })
    b.sync.Receive(42, { guid = a.guid })
    local n = 0
    for _ in pairs(b.db.presets) do n = n + 1 end
    eq("refused: catalog untouched", n, 0)
    check("refused: said so once", #b.reports >= 1 and b.reports[1]:find("can't read", 1, true) ~= nil)
    -- A bad entry (fails the catalog's receive boundary).
    local bad = Env.Pack({ s = Env.SCHEMA, e = { id = "x", version = "v", kind = "weird" } })
    b.sync.Receive("ENT\nx\nv\n" .. bad, { guid = a.guid, name = "Alpha" })
    eq("refused: bad entry not stored", b.db.presets.x, nil)

    -- A valid entry from a sender with no realm.
    local c = account("Gamma", "cccccccccccc", false)
    local e = save(c, "Solo", 9)
    use(c)
    local text = Env.Encode(c.db.presets[e.id])
    use(b)
    b.sync.Receive("ENT\n" .. e.id .. "\n" .. c.db.presets[e.id].version .. "\n" .. text, { guid = c.guid, name = "Gamma", realm = nil })
    check("no realm: upserted", b.db.presets[e.id] ~= nil)
    eq("label: name only without a realm", S.Label({ name = "Gamma" }), "Gamma")
    eq("label: name-realm", S.Label({ name = "Gamma", realm = "Elegia" }), "Gamma-Elegia")
    eq("label: empty realm", S.Label({ name = "Gamma", realm = "" }), "Gamma")
end

------------------------------------------------------------
-- Exchange triggers: local writes coalesce, receipts never trigger one
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    run(15)                                       -- peer sightings done
    local t0 = T + 1
    save(a, "One", 1); save(a, "Two", 2); save(a, "Three", 3)
    run(1)
    save(a, "Four", 4)                            -- still inside the 2 s window
    run(5)
    eq("coalesce: one exchange for four local writes", count("MAN", "Alpha", t0), 1)
    local bBefore = count("MAN", "Beta", t0)
    run(20)
    check("coalesce: B received them", b.db.presets[next(a.db.presets)] ~= nil)
    eq("receipts never trigger an exchange", count("MAN", "Beta", t0), bBefore)
    -- Refresh always sends.
    local r0 = count("MAN", "Beta")
    use(b); b.sync.Refresh()
    eq("refresh: sends at once", count("MAN", "Beta"), r0 + 1)
end

------------------------------------------------------------
-- Manifest batches: 100 ids per message, shrinking until each fits
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    for i = 1, 250 do save(a, "E" .. i, i) end
    local t0 = T + 1
    use(a); a.sync.Exchange()
    eq("batches: 250 ids in 3 messages", count("MAN", "Alpha", t0 - 1), 3)
    local fits = true
    for _, s in ipairs(net.sent) do if #s.msg > 16384 then fits = false end end
    check("batches: every message under 16384 bytes", fits)
    run(400)
    check("batches: converged", (same(a, b)))

    -- A small payload cap: batches shrink to fit; an entry too large stays local.
    reset()
    local small = { maxPayload = 3000 }
    local x = account("Alpha", "aaaaaaaaaaaa")
    x.sync = S.New({ catalog = C, envelope = Env, transport = x.transport, now = function() return T end,
                     report = function(t) x.reports[#x.reports + 1] = t end, maxPayload = small.maxPayload, gen = "x" })
    local y = account("Beta", "bbbbbbbbbbbb")
    for i = 1, 60 do save(x, "S" .. i, i) end
    local big = save(x, "Huge", 1)
    x.db.presets[big.id].modules.macros = { M = { body = string.rep("/say hi\n", 400) } }
    local t1 = T + 1
    use(x); x.sync.Exchange()
    check("shrink: more than one batch", count("MAN", "Alpha", t1 - 1) > 1)
    local fit = true
    for _, s in ipairs(net.sent) do if s.from == "Alpha" and #s.msg > small.maxPayload then fit = false end end
    check("shrink: every message fits the cap", fit)
    run(300)
    eq("too large: stays on its account", y.db.presets[big.id], nil)
    use(x)
    eq("too large: status says so", x.sync.EntryStatus(x.db.presets[big.id]), "too large")
    local said = 0
    for _, r in ipairs(x.reports) do if r:find("too large to sync", 1, true) then said = said + 1 end end
    eq("too large: reported once", said, 1)
end

------------------------------------------------------------
-- Ids the peer never answers can't starve the request slots
------------------------------------------------------------
do
    reset()
    local x = account("Alpha", "aaaaaaaaaaaa")
    x.sync = S.New({ catalog = C, envelope = Env, transport = x.transport, now = function() return T end,
                     report = function() end, maxPayload = 3000, gen = "x2" })
    local y = account("Beta", "bbbbbbbbbbbb")
    for i = 1, 4 do
        local big = save(x, "Huge" .. i, i)
        x.db.presets[big.id].modules.macros = { M = { body = string.rep("/say hi " .. i .. " ", 400) } }
    end
    run(S.INTERVAL + 20)
    local fine = save(x, "Fine", 7)
    run(S.INTERVAL + 20)
    check("starvation: a normal entry still arrives", y.db.presets[fine.id] ~= nil)
    -- Never answered: at most MAX_OUT requests per REQ_TIMEOUT.
    local t0 = T
    run(3 * S.INTERVAL)
    local bound = S.MAX_OUT * math.ceil(3 * S.INTERVAL / S.REQ_TIMEOUT + 1)
    check("retries: bounded for ids never answered", reqs("Beta", nil, t0) <= bound,
          reqs("Beta", nil, t0) .. " > " .. bound)
end

------------------------------------------------------------
-- Requests never ask for what we already hold or have moved past
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local e = save(a, "Raid", 1)
    run(10)
    a.online = false
    use(b); C.Rename(e.id, "Raid B", b.db.presets[e.id].version)      -- B moves past A's version
    -- B reloads: its session memory is empty, only the catalog's ancestry says
    -- that A's version is older.
    b.sync = S.New({ catalog = C, envelope = Env, transport = b.transport, now = function() return T end,
                     report = function() end, gen = "bbbbbbbbbbbb-2" })
    a.online = true
    local t0 = T
    use(b)
    b.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA, b = "aaa", c = 9, p = 1, n = 1, l = { [e.id] = a.db.presets[e.id].version } }),
                   { guid = a.guid, name = "Alpha", realm = "Elegia" })
    run(S.INTERVAL + 15)
    eq("older: B never asks for A's older version", reqs("Beta", e.id, t0), 0)
    eq("older: A fast-forwarded", a.db.presets[e.id].name, "Raid B")

    -- Two listings arrive while a request is out: one request, not two.
    local f = save(a, "Fresh", 5)
    local t1 = T
    use(a); a.sync.Refresh(); a.sync.Refresh()
    run(5)
    eq("one request per id while it is out", reqs("Beta", f.id, t1), 1)
end

------------------------------------------------------------
-- Bookkeeping comes before the send: an answer delivered synchronously still
-- frees its slot
------------------------------------------------------------
do
    reset()
    net.instant = true
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    for i = 1, 5 do save(a, "S" .. i, i) end
    run(15)
    check("instant: all arrived", (same(a, b)))
    eq("instant: no slot left held", (b.sync.Outstanding(a.guid)), 0)
end

------------------------------------------------------------
-- Confirmed needs the peer's WHOLE manifest, listing our exact version
------------------------------------------------------------
do
    reset()
    local a = account("Alpha", "aaaaaaaaaaaa")
    local b = account("Beta", "bbbbbbbbbbbb")
    b.online = false                              -- B only "speaks" through the hand-made messages below
    local e = save(a, "Raid", 1)
    local old = e.version
    use(a); C.Rename(e.id, "Raid 2", e.version)
    b.online = true
    use(a); a.sync.Tick()                         -- A sees B listed
    local function man(p, n, l, c)
        a.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA, b = "bbb", c = c or 1, p = p, n = n, l = l }),
                       { guid = b.guid, name = "Beta", realm = "Elegia" })
    end
    local cur = a.db.presets[e.id]
    man(1, 2, { [e.id] = cur.version })
    eq("confirm: half a manifest is not confirmation", a.sync.EntryStatus(cur), "pending")
    man(2, 2, {})
    eq("confirm: the whole manifest confirms", a.sync.EntryStatus(cur), "confirmed")
    -- Manifests are ordered: an older one arriving late changes nothing.
    man(1, 1, { [e.id] = old }, 0)
    eq("order: a late older manifest is ignored", a.sync.EntryStatus(cur), "confirmed")
    -- A newer two-part manifest with a stray older (but not yet held) part in
    -- between still completes.
    man(1, 1, { [e.id] = old }, 2)
    eq("order: back to pending on a newer manifest listing the old version", a.sync.EntryStatus(cur), "pending")
    man(1, 2, { [e.id] = cur.version }, 5)
    man(2, 2, {}, 3)
    man(2, 2, {}, 5)
    eq("order: a stray older part doesn't reset a newer one", a.sync.EntryStatus(cur), "confirmed")
    man(1, 1, { [e.id] = old }, 6)
    eq("confirm: an older version listed is pending", a.sync.EntryStatus(cur), "pending")
    -- A new session of the peer (it reloaded) replaces the old one for good.
    a.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA, b = "bbb2", c = 1, p = 1, n = 1, l = { [e.id] = cur.version } }),
                   { guid = b.guid, name = "Beta", realm = "Elegia" })
    eq("session: the new session counts", a.sync.EntryStatus(cur), "confirmed")
    man(1, 1, { [e.id] = old }, 99)
    eq("session: the replaced session is ignored", a.sync.EntryStatus(cur), "confirmed")
end

------------------------------------------------------------
-- An online account WITHOUT the Link addon never blocks "confirmed"
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local silent = { guid = "Player-1-Silent", name = "Silent", realm = "Elegia" }
    for _, acc in ipairs({ a, b }) do
        local peersOf = acc.transport.Peers
        acc.transport.Peers = function() local l = peersOf(); l[#l + 1] = silent; return l end
    end
    local e = save(a, "Raid", 1)
    run(10)
    use(b); b.sync.Refresh()
    run(5)
    eq("silent account: still confirmed", a.sync.EntryStatus(a.db.presets[e.id]), "confirmed")
    local heard = {}
    for _, p in ipairs(a.sync.Peers()) do heard[p.label] = p.heard end
    eq("silent account: listed but not heard", heard["Silent-Elegia"], false)
    eq("silent account: the Link peer is heard", heard["Beta-Elegia"], true)
end

------------------------------------------------------------
-- A manifest nobody took (peer mid-handshake) is sent again within seconds
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    for _, acc in ipairs({ a, b }) do
        local send, refusals = acc.transport.Send, 2
        acc.transport.Send = function(msg)
            if refusals > 0 then refusals = refusals - 1; return 0 end     -- "not-ready"
            return send(msg)
        end
    end
    local e = save(a, "Raid", 1)
    run(S.RETRY * 3 + 5)
    check("not ready: the entry arrives within seconds, not at the next 120 s exchange", b.db.presets[e.id] ~= nil)
end

------------------------------------------------------------
-- A retry never downgrades the queued version; an older answer re-asks
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local e = save(a, "Raid", 1)
    use(a)
    local v1Text = Env.Encode(a.db.presets[e.id])
    local v1 = a.db.presets[e.id].version
    C.Rename(e.id, "Raid 2", v1)
    local v2 = a.db.presets[e.id].version
    a.online = false                               -- B is driven by hand below
    use(b); b.sync.Tick()
    local function man(c, v)
        b.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA, b = "aaa", c = c, p = 1, n = 1, l = { [e.id] = v } }),
                       { guid = a.guid, name = "Alpha", realm = "Elegia" })
    end
    local peersOf = b.transport.Peers
    b.transport.Peers = function() return { { guid = a.guid, name = "Alpha", realm = "Elegia" } } end
    man(1, v1)                                     -- asks for v1
    man(2, v2)                                     -- v2 queued while v1 is out
    T = T + S.REQ_TIMEOUT + 1
    use(b); b.sync.Tick()                          -- v1 expires; v2 is asked
    b.sync.Receive("ENT\n" .. e.id .. "\n" .. v1 .. "\n" .. v1Text, { guid = a.guid, name = "Alpha", realm = "Elegia" })
    eq("late v1: stored", b.db.presets[e.id].version, v1)
    local out, queued = b.sync.Outstanding(a.guid)
    check("late v1: v2 is still wanted", out + queued >= 1)
    b.transport.Peers = peersOf
end

------------------------------------------------------------
-- A refused entry frees its request and isn't asked for again; an encode
-- failure isn't called "too large"
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local realSendTo = a.transport.SendTo
    a.transport.SendTo = function(guid, msg)
        if msg:sub(1, 4) == "ENT\n" then
            msg = msg:gsub("ASE1:%x+:", "ASE1:00000000:")                -- corrupt every entry
        end
        return realSendTo(guid, msg)
    end
    local e = save(a, "Raid", 1)
    run(15)
    eq("refused entry: not stored", b.db.presets[e.id], nil)
    eq("refused entry: slot freed", (b.sync.Outstanding(a.guid)), 0)
    local t0 = T
    run(3 * S.INTERVAL)
    eq("refused entry: not asked again this session", reqs("Beta", e.id, t0), 0)

    reset()
    local x, y = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local failing = setmetatable({ Encode = function() return nil, "encode-failed" end }, { __index = Env })
    x.sync = S.New({ catalog = C, envelope = failing, transport = x.transport, now = function() return T end,
                     report = function(t) x.reports[#x.reports + 1] = t end, gen = "x3" })
    local f = save(x, "Raid", 1)
    run(15)
    use(x)
    check("encode failure: not called too large", x.sync.EntryStatus(x.db.presets[f.id]) ~= "too large")
    local said = false
    for _, r in ipairs(x.reports) do if r:find("Couldn't encode", 1, true) then said = true end end
    check("encode failure: said so", said)
end

------------------------------------------------------------
-- A peer that leaves takes its queue and requests with it
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    for i = 1, 20 do save(a, "E" .. i, i) end
    net.drop = 1                                   -- nothing gets through: B's queue builds up
    run(12)
    net.drop = 0
    use(a); a.sync.Refresh()
    run(2)
    local out, queued = b.sync.Outstanding(a.guid)
    check("leaving: B had a backlog", out + queued > 0)
    a.online = false
    run(12)
    out, queued = b.sync.Outstanding(a.guid)
    eq("leaving: its requests are dropped", out + queued, 0)
end

------------------------------------------------------------
-- Codex: a late manifest from the peer's OLD session, arriving after its new
-- session's, doesn't push the new session aside
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    b.online = false                               -- B is driven by hand
    use(a); a.sync.Tick()
    local sender = { guid = b.guid, name = "Beta", realm = "Elegia" }
    local function man(session, c, l, sid)
        use(a)
        a.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA, b = session, c = c, p = 1, n = 1, l = l }), sender, sid)
    end
    -- B's own entries, so A has something to fetch from each manifest.
    use(b)
    local x = C.Create("loadout", { class = "PRIEST", category = "holy", name = "X" }, mods(1))
    local y = C.Create("loadout", { class = "PRIEST", category = "holy", name = "Y" }, mods(2))
    man("new", 1, { [x.id] = x.version }, 20)      -- the new session first
    man("old", 7, {}, 11)                          -- then a delayed one from before the reload
    local out, queued = a.sync.Outstanding(b.guid)
    check("old session: X still wanted", out + queued >= 1)
    man("new", 2, { [x.id] = x.version, [y.id] = y.version }, 21)
    out, queued = a.sync.Outstanding(b.guid)
    check("old session late: the new session's later manifests still count", out + queued >= 2)
end

------------------------------------------------------------
-- Codex: a refused LATE answer for v1 never suppresses v2
------------------------------------------------------------
do
    reset()
    local a, b = account("Alpha", "aaaaaaaaaaaa"), account("Beta", "bbbbbbbbbbbb")
    local e = save(a, "Raid", 1)
    use(a)
    local v1 = a.db.presets[e.id].version
    C.Rename(e.id, "Raid 2", v1)
    local v2 = a.db.presets[e.id].version
    a.online = false
    local peersOf = b.transport.Peers
    b.transport.Peers = function() return { { guid = a.guid, name = "Alpha", realm = "Elegia" } } end
    use(b); b.sync.Tick()
    local sender = { guid = a.guid, name = "Alpha", realm = "Elegia" }
    local function man(c, v) use(b); b.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA, b = "aaa", c = c, p = 1, n = 1, l = { [e.id] = v } }), sender) end
    man(1, v1)                                     -- asks for v1
    man(2, v2)                                     -- v2 queued while v1 is out
    T = T + S.REQ_TIMEOUT + 1
    use(b); b.sync.Tick()                          -- v1 expires; v2 is asked
    -- The late v1 answer arrives, unreadable.
    b.sync.Receive("ENT\n" .. e.id .. "\n" .. v1 .. "\nASE1:00000000:00", sender)
    local out = b.sync.Outstanding(a.guid)
    eq("refused late v1: v2's request is still out", out, 1)
    -- v2's answer is lost; after the timeout v2 is asked again and arrives.
    T = T + S.REQ_TIMEOUT + 1
    use(b); b.sync.Tick()
    use(a)
    local v2Text = Env.Encode(a.db.presets[e.id])
    use(b)
    b.sync.Receive("ENT\n" .. e.id .. "\n" .. v2 .. "\n" .. v2Text, sender)
    eq("refused late v1: v2 still arrives", b.db.presets[e.id] and b.db.presets[e.id].version, v2)
    -- The peer answers with a NEWER version than it listed (it saved in
    -- between): what we asked for is covered, so the request is done.
    use(a)
    local g = save(a, "Fresh", 4)
    local g1 = a.db.presets[g.id].version
    C.Rename(g.id, "Fresh 2", g1)
    local gText, g2 = Env.Encode(a.db.presets[g.id]), a.db.presets[g.id].version
    use(b)
    b.sync.Receive("MAN\n" .. Env.Pack({ s = Env.SCHEMA, b = "aaa", c = 4, p = 1, n = 1, l = { [g.id] = g1, [e.id] = v2 } }), sender)
    b.sync.Receive("ENT\n" .. g.id .. "\n" .. g2 .. "\n" .. gText, sender)
    eq("newer answer: stored", b.db.presets[g.id] and b.db.presets[g.id].version, g2)
    eq("newer answer: the request is done", (b.sync.Outstanding(a.guid)), 0)
    -- An answer whose outer version doesn't match its content is refused.
    use(a)
    local f = save(a, "Other", 3)
    use(a); local fText = Env.Encode(a.db.presets[f.id])
    use(b)
    b.sync.Receive("ENT\n" .. f.id .. "\nwrong:1\n" .. fText, sender)
    eq("mismatched outer version: refused", b.db.presets[f.id], nil)
    b.transport.Peers = peersOf
end

eq("never touched game state", #touched, 0)

------------------------------------------------------------
-- Link.lua: starts only on a usable DB with messages mode
------------------------------------------------------------
do
    local function fakeLib(messages)
        local inst = { messages = messages, enabled = true, sent = {} }
        inst.Send = function(msg) inst.sent[#inst.sent + 1] = msg; return 1 end
        inst.SendTo = function(guid, msg) inst.sent[#inst.sent + 1] = msg; return 1 end
        inst.Peers = function() return {} end
        inst.IsEnabled = function() return inst.enabled end
        inst.SetEnabled = function(on) inst.enabled = on end
        inst.OnMessage = function(fn) inst.handler = fn end
        inst.Diagnostics = function() return function() end end
        local lib = { New = function(_, o) inst.opts = o; return inst end }
        return lib, inst
    end
    local function bootLink(messages, disabledCore)
        WoW.reset()
        local lib, inst = fakeLib(messages)
        LibStub = function(name, silent) if name == "LibAccountSync-1.0" then return lib end end
        if disabledCore then AltStableSyncDB = { schema = 99 } end
        for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Envelope.lua", "Game.lua", "Backups.lua",
                             "Ready.lua", "Loadout.lua", "Preview.lua", "Commands.lua" }) do
            assert(loadfile(f))("AltStableSync", {})
        end
        WoW.fire("ADDON_LOADED", "AltStableSync")
        assert(loadfile("Plugins/Link/Sync.lua"))("AltStableSyncLink", {})
        assert(loadfile("Plugins/Link/Link.lua"))("AltStableSyncLink", {})
        WoW.fire("ADDON_LOADED", "AltStableSyncLink")
        return AltStableSync, inst
    end

    local L, inst = bootLink(true)
    eq("link: on", L.Link.state, "on")
    eq("link: tag", inst.opts.addon, "AltStableSync")
    eq("link: messages mode asked", inst.opts.messages, true)
    eq("link: 16 KB cap", inst.opts.maxPayload, 16384)
    check("link: store is the account-wide LAS table", inst.opts.store() == AltStableSyncLAS and type(AltStableSyncLAS) == "table")
    check("link: OnMessage registered", type(inst.handler) == "function")
    check("link: /altsync link registered", type(L.Commands.link) == "function")
    -- A local write schedules an exchange.
    WoW.clock = 2000
    L.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Raid" }, mods(1))
    WoW.clock = 2003
    L.Link.Tick()
    check("link: local write -> exchange", #inst.sent >= 1 and inst.sent[#inst.sent]:sub(1, 4) == "MAN\n")
    -- Off: no exchange, no status.
    local n = #inst.sent
    L.Commands.link("off")
    L.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Other" }, mods(2))
    WoW.clock = 2010
    L.Link.Tick()
    eq("link off: nothing sent", #inst.sent, n)
    eq("link off: no status", L.Link.EntryStatus(L.Catalog.ListAll("loadout", "PRIEST")[1]), nil)
    inst.Peers = function() return { { guid = "Player-1-0000BBBB", name = "Beta", realm = "Elegia" } } end
    WoW.clock = 2100
    L.Link.Tick()
    eq("link off: a listed peer starts nothing", #inst.sent, n)
    inst.Peers = function() return {} end
    L.Commands.link("on")
    check("link on: refreshes", #inst.sent > n)

    -- Commands: ids, ambiguity, previews, resolve choices.
    do
        UnitClass = function() return "Priest", "PRIEST" end
        local shown
        L.Preview.Show = function(o) shown = o end
        local function lines() local t = {}; for i = #WoW.chatLines - 5, #WoW.chatLines do t[#t + 1] = tostring(WoW.chatLines[i]) end; return table.concat(t, " | ") end
        local raid = L.Catalog.ListAll("loadout", "PRIEST")[1]
        local twin = L.Catalog.Create("loadout", { class = "PRIEST", category = "shadow", name = "Twin" }, mods(3))
        -- A received entry with the same name (names from sync are never rejected).
        L.Catalog.Upsert({ id = "loadout-ffffffffffff-1", version = "ffffffffffff:1", kind = "loadout",
                           class = "PRIEST", category = "general", name = "Twin", modules = mods(4) }, "Other")
        L.Commands.list()
        check("list: every category, with ids", lines():find(twin.id, 1, true) ~= nil
            and lines():find("loadout-ffffffffffff-1", 1, true) ~= nil)
        shown = nil
        L.Commands.delete("Twin")
        eq("ambiguous name: no preview", shown, nil)
        check("ambiguous name: candidates listed", lines():find("use the id", 1, true) ~= nil)
        L.Commands.delete(twin.id)
        check("delete by id: previewed", shown and shown.confirm == "Delete")
        eq("delete: nothing before confirm", L.Catalog.Get(twin.id).deleted, nil)
        -- The other account changes it before the confirm: refused as stale.
        L.Catalog.Rename(twin.id, "Twin 2", twin.version)
        shown.onConfirm()
        eq("delete: stale refused", L.Catalog.Get(twin.id).deleted, nil)
        L.Commands.delete(twin.id); shown.onConfirm()
        eq("delete: confirmed", L.Catalog.Get(twin.id).deleted, true)
        shown = nil
        L.Commands.rename("Twin")
        eq("rename: needs an id and a name", shown, nil)
        L.Commands.rename("loadout-ffffffffffff-1 New Twin Name")
        check("rename: previewed", shown and shown.confirm == "Rename")
        shown.onConfirm()
        eq("rename: multiword name", L.Catalog.Get("loadout-ffffffffffff-1").name, "New Twin Name")
        -- A deletion conflict: "theirs" deletes here too.
        local root = L.Catalog.Get(raid.id)
        L.Catalog.Upsert({ id = raid.id, version = "eeeeeeeeeeee:9", kind = "loadout", class = "PRIEST",
                           category = "holy", name = "Raid", deleted = true, ancestors = {} }, "Other-Elegia")
        local copyId = raid.id .. "~eeeeeeeeeeee:9"
        check("deletion conflict: copy kept", L.Catalog.Get(copyId) ~= nil)
        L.Commands.conflicts()
        check("conflicts: listed", lines():find(copyId, 1, true) ~= nil)
        shown = nil
        L.Commands.load(copyId)
        eq("load: a deletion copy has nothing to load", shown, nil)
        L.Commands.resolve(tostring(raid.name) .. " mine")
        check("resolve by the root's name: its one copy", shown and shown.confirm == "Resolve"
            and shown.lines[1]:find("comes back", 1, true) ~= nil)
        L.Commands.resolve(copyId .. " theirs")
        check("resolve: previewed", shown and shown.confirm == "Resolve")
        check("resolve: says delete", shown.lines[1]:find("Delete", 1, true) ~= nil)
        shown.onConfirm()
        eq("resolve theirs on a deletion: deleted here too", L.Catalog.Get(raid.id).deleted, true)
        eq("resolve: copy retired", L.Catalog.Get(copyId).deleted, true)
        -- Deleted here too after the deletion copy arrived: the preview says it stays deleted.
        local r2 = L.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Gone" }, mods(5))
        L.Catalog.Upsert({ id = r2.id, version = "dddddddddddd:3", kind = "loadout", class = "PRIEST",
                           category = "holy", name = "Gone", deleted = true, ancestors = {} }, "Other-Elegia")
        L.Catalog.Delete(r2.id, r2.version)
        L.Commands.resolve(r2.id .. "~dddddddddddd:3 mine")
        check("resolve: both deleted -> stays deleted", shown.lines[1]:find("stays deleted", 1, true) ~= nil)
        -- Rename: an empty or duplicate name is refused before the preview.
        shown = nil
        L.Commands.rename("loadout-ffffffffffff-1 ")
        eq("rename: empty name, no preview", shown, nil)
        check("rename: empty name names the rename command", lines():find("/altsync rename", 1, true) ~= nil)
        L.Commands.resolve("nothing maybe")
        check("resolve: usage on a bad choice", lines():find("Usage", 1, true) ~= nil)

        -- #39: a change made while Link is off says the other account won't see it.
        local OFF = "Link is off"
        local function said(fn) local n0 = #WoW.chatLines; fn()
            local t = {}; for i = n0 + 1, #WoW.chatLines do t[#t + 1] = tostring(WoW.chatLines[i]) end
            return table.concat(t, " | ") end
        L.Commands.link("off")
        local named = L.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Offline" }, mods(6))
        L.Commands.rename(named.id .. " Offline 2")
        local out = said(shown.onConfirm)
        check("off: rename notes it", out:find("Renamed", 1, true) and out:find(OFF, 1, true), out)
        check("off: note after the result", (out:find(OFF, 1, true) or 0) > (out:find("Renamed", 1, true) or 1e9), out)
        L.Commands.delete(named.id)
        out = said(shown.onConfirm)
        check("off: delete notes it", out:find(OFF, 1, true) ~= nil, out)
        local fixed = L.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Fixed" }, mods(10))
        L.Catalog.Upsert({ id = fixed.id, version = "cccccccccccc:2", parent = "q:1", ancestors = { "q:1" }, kind = "loadout",
                           class = "PRIEST", category = "holy", name = "Fixed B", modules = mods(11) }, "Other")
        L.Commands.resolve(fixed.id .. "~cccccccccccc:2 mine")
        out = said(shown.onConfirm)
        check("off: resolve notes it", out:find("Resolved", 1, true) and out:find(OFF, 1, true), out)
        out = said(function() L.Commands.rename(named.id .. " ") end)   -- refused: no note
        check("off: a refusal carries no note", out ~= "" and not out:find(OFF, 1, true), out)
        -- Refused at the confirm (stale: changed after the preview): no note either.
        local stale = L.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Stale" }, mods(12))
        L.Commands.rename(stale.id .. " Stale 2")
        L.Catalog.Rename(stale.id, "Moved", stale.version)
        out = said(shown.onConfirm)
        check("off: a stale rename carries no note", out:find("Not renamed", 1, true) and not out:find(OFF, 1, true), out)
        L.Commands.delete(stale.id)
        L.Catalog.Rename(stale.id, "Moved 2", L.Catalog.Get(stale.id).version)
        out = said(shown.onConfirm)
        check("off: a stale delete carries no note", out:find("Not deleted", 1, true) and not out:find(OFF, 1, true), out)
        L.Commands.link("on")
        local back = L.Catalog.Create("loadout", { class = "PRIEST", category = "holy", name = "Online" }, mods(7))
        L.Commands.rename(back.id .. " Online 2")
        out = said(shown.onConfirm)
        check("on: no note", out:find("Renamed", 1, true) and not out:find(OFF, 1, true), out)

        -- #39: conflicts on other classes' loadouts are counted, never hidden.
        L.Catalog.Upsert({ id = "loadout-aaaaaaaaaaaa-1", version = "aaaaaaaaaaaa:1", kind = "loadout",
                           class = "HUNTER", category = "general", name = "Hx", modules = mods(8) }, "Other")
        L.Catalog.Upsert({ id = "loadout-aaaaaaaaaaaa-1", version = "aaaaaaaaaaaa:2", parent = "zzz:1", ancestors = { "zzz:1" },
                           kind = "loadout", class = "HUNTER", category = "general", name = "Hy", modules = mods(9) }, "Other")
        check("other class: a hunter conflict exists", L.Catalog.Get("loadout-aaaaaaaaaaaa-1~aaaaaaaaaaaa:2") ~= nil)
        out = said(L.Commands.conflicts)
        check("other class: counted with its class", out:find("1 more not listed here: HUNTER (1)", 1, true) ~= nil, out)
        -- A UI setup conflict is counted too (Link's status counts it).
        L.Catalog.Upsert({ id = "ui-bbbbbbbbbbbb-1", version = "bbbbbbbbbbbb:1", kind = "ui", name = "U", modules = {} }, "Other")
        L.Catalog.Upsert({ id = "ui-bbbbbbbbbbbb-1", version = "bbbbbbbbbbbb:2", parent = "y:1", ancestors = { "y:1" },
                           kind = "ui", name = "U2", modules = {} }, "Other")
        out = said(L.Commands.conflicts)
        check("ui conflict: counted", out:find("2 more not listed here: HUNTER (1), UI setups (1)", 1, true) ~= nil, out)
        -- The class not known yet: nothing is called "elsewhere".
        UnitClass = function() return nil, nil end
        out = said(L.Commands.conflicts)
        check("no class: no other-class line", not out:find("not listed here", 1, true), out)
        UnitClass = function() return "Hunter", "HUNTER" end
        out = said(L.Commands.conflicts)
        check("other class: listed on that class", out:find("loadout-aaaaaaaaaaaa-1~aaaaaaaaaaaa:2", 1, true) ~= nil, out)
        check("other class: own copies not counted as elsewhere", not out:find("HUNTER (", 1, true), out)
        UnitClass = function() return "Priest", "PRIEST" end
    end
    -- /altsync link status: an online account that never replies is named as
    -- such; once one replies, counts cover what the player sees (no
    -- tombstones), with conflicts on their own line.
    do
        local function lines() return table.concat(WoW.chatLines, " | ") end
        local peer = { guid = "Player-1-0000CCCC", name = "Gamma", realm = "Elegia" }
        inst.Peers = function() return { peer } end
        WoW.clock = WoW.clock + 20
        L.Link.Tick()
        L.Commands.link("")
        check("status: silent peer named", lines():find("no reply yet", 1, true) ~= nil)
        local list = {}
        for id, e in pairs(L.db.presets) do list[id] = e.version end
        inst.handler("MAN\n" .. L.Envelope.Pack({ s = L.Envelope.SCHEMA, b = "ccc", c = 1, p = 1, n = 1, l = list }), peer)
        L.Commands.link("")
        local live = 0
        for _, e in pairs(L.db.presets) do if not e.deleted and not e.conflict then live = live + 1 end end
        check("status: confirmed counts only live entries",
              lines():find(("Gamma-Elegia: %d confirmed, 0 pending"):format(live), 1, true) ~= nil, lines())
        -- #5: an older peer's message pauses it; status says so instead of counts.
        inst.handler("MAN\n" .. L.Envelope.Pack({ s = 1, b = "ccc", c = 2, p = 1, n = 1, l = list }), peer)
        WoW.chatLines = {}
        L.Commands.link("")
        check("status: paused peer", lines():find("Gamma-Elegia: sync paused - that account runs an older AltStableSync; update it.", 1, true) ~= nil, lines())
        check("status: no counts for a paused peer", lines():find("confirmed", 1, true) == nil, lines())
        inst.Peers = function() return {} end
    end
    eq("commands: no game state touched", #touched, 0)

    local L2 = bootLink(false)
    eq("link: older library -> disabled", L2.Link.state, "disabled")
    check("link: says why", tostring(L2.Link.why):find("messages mode", 1, true) ~= nil)
    check("link failed: a change still says it won't sync",
          tostring(L2.Link.OffNote()):find("isn't running (", 1, true) ~= nil, tostring(L2.Link.OffNote()))

    local L3, inst3 = bootLink(true, true)
    eq("link: refused core schema -> disabled", L3.Link.state, "disabled")
    eq("link: library never started", inst3.opts, nil)
    check("link: says the core is disabled", tostring(L3.Link.why):find("disabled", 1, true) ~= nil)
    check("link: LAS store not created", AltStableSyncLAS == nil)
end

finish("test_sync")
