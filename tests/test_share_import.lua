------------------------------------------------------------
-- test_share_import.lua - Share / Import a loadout as a text string (#71)
--
-- Share shows a loadout's string; Import validates a pasted one and saves
-- it as a NEW catalog entry after a preview. Neither reads nor writes game
-- state, and nothing is loaded. The promises, each checked:
--   * the string holds the five share fields only, and round-trips;
--   * a string is refused whole: damaged, too long, a sync message, another
--     schema, or any field outside the allowlist or its bounds;
--   * every string Share shows imports on this build;
--   * the confirm is one catalog write of what Review froze;
--   * imported text is shown literally (no markup renders);
--   * Escape closes only the top layer.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")
dofile("tests/wow_game.lua")

local G = WoW.game
local A, P, W, E, S

local function boot()
    WoW.reset()
    for _, f in ipairs({ "Core.lua", "Categories.lua", "Catalog.lua", "Envelope.lua", "Game.lua", "Pet.lua", "Backups.lua",
                         "Ready.lua", "Loadout.lua", "Share.lua", "Preview.lua", "Commands.lua", "Panel.lua" }) do
        assert(loadfile(f))("AltStableSync", {})
    end
    WoW.fire("ADDON_LOADED", "AltStableSync")
    A = AltStableSync
    P, W, E, S = A.Panel, A.Panel._W, A.Envelope, A.Share
    G.setup{
        class = "PRIEST", guid = "Player-70-MAIN",
        spells = { { id = 9472, name = "Flash Heal" }, { id = 2050, name = "Lesser Heal" } },
        items = { [5512] = 3 },
        macros = { { name = "Shield", body = "/cast Power Word: Shield", char = true },
                   { name = "Mount", body = "/cast Swift Horse" } },
        actions = { [1] = { spell = 9472 }, [2] = { spell = 2050 }, [3] = { item = 5512 }, [4] = { macro = "Shield" },
                    [5] = { macro = "Mount" } },
        keys = { ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2" },
    }
    WoW.fire("PLAYER_ENTERING_WORLD", true, false)
    WoW.clock = WoW.clock + 10
end

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
local function said(s) return table.concat(WoW.chat(), "\n"):find(s, 1, true) ~= nil end
local function capture() return assert(A.Loadout.Capture()) end
local function entry(name, modules, category)
    return assert(A.Catalog.Create("loadout", { class = "PRIEST", category = category or "holy", name = name,
        provenance = { sourceChar = "Main-Realm", build = "70338" } }, modules or capture()))
end
local function copy(v) return A.Catalog.Copy(v) end
local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
local function liveCount()
    local n = 0
    for _, e in pairs(AltStableSyncDB.presets) do if not e.deleted then n = n + 1 end end
    return n
end
local function shown() return A.Preview.Shown() end
local function previewText()
    local o = shown()
    return o and ((o.title or "") .. "\n" .. table.concat(o.lines or {}, "\n")) or ""
end

------------------------------------------------------------
-- The string
------------------------------------------------------------

-- Share -> Import: the five fields, equal; nothing of the entry's identity.
do
    boot()
    local e = entry("Raid Heals")
    local text = assert(S.Encode(e))
    local x = assert(S.Decode(text))
    eq("round trip: kind", x.kind, "loadout")
    eq("round trip: class", x.class, "PRIEST")
    eq("round trip: category", x.category, "holy")
    eq("round trip: name", x.name, "Raid Heals")
    eq("round trip: modules equal", ser(x.modules), ser(e.modules))
    local keys = {}
    for k in pairs(x) do keys[#keys + 1] = k end
    table.sort(keys)
    eq("round trip: exactly the five fields", table.concat(keys, ","), "category,class,kind,modules,name")
    local raw = C_EncodingUtil.DecompressString(C_EncodingUtil.DecodeBase64(text:match(":(%x+)$")))
    for _, word in ipairs({ "Main-Realm", "sourceChar", "provenance", "version", e.id }) do
        check("round trip: no " .. word .. " in the string", not raw:find(word, 1, true))
    end
    -- Whitespace and line breaks from a wrapped paste are fine.
    local wrapped = {}
    for i = 1, #text, 40 do wrapped[#wrapped + 1] = text:sub(i, i + 39) end
    check("wrapped paste decodes", S.Decode("  " .. table.concat(wrapped, "\r\n \t") .. "\n") ~= nil)
end

-- Refused whole, with a code.
do
    boot()
    local e = entry("Raid Heals")
    local text = assert(S.Encode(e))
    local x = assert(S.Decode(text))
    local function refused(name, t, code)
        local v, err = S.Decode(t)
        check(name .. ": refused", v == nil)
        eq(name .. ": code", err, code)
    end
    refused("garbage", "hello there", "bad-envelope")
    local sum = text:match("^ASE1:(%x+):")
    refused("bad checksum", text:gsub("^ASE1:%x+", "ASE1:" .. (sum:sub(1, 7) .. (sum:sub(8) == "0" and "1" or "0"))), "bad-checksum")
    refused("a sync message", assert(E.Encode(e)), "not-a-share")
    local both = assert(E.Pack({ s = E.SCHEMA, e = copy(e), share = x }))
    refused("both e and share", both, "not-a-share")
    local _, serr = E.Decode(both)
    eq("both e and share: sync refuses it too", serr, "bad-envelope")
    refused("newer schema", assert(E.Pack({ s = E.SCHEMA + 1, share = x })), "newer-schema")
    refused("older schema", assert(E.Pack({ s = E.SCHEMA - 1, share = x })), "older-schema")
    refused("raw over the limit", text .. (" "):rep(E.RAW_MAX - #text + 1), "too-long")
    refused("stripped over the limit", "ASE1:00000000:" .. ("a"):rep(E.SHARE_MAX), "too-long")
    check("at the raw limit: fine", S.Decode(text .. (" "):rep(E.RAW_MAX - #text)) ~= nil)
    -- Decompressed data over the limit is refused before it is parsed.
    local ds, parsed = C_EncodingUtil.DecompressString, false
    local des = C_EncodingUtil.DeserializeCBOR
    C_EncodingUtil.DecompressString = function() return ("x"):rep(E.CBOR_MAX + 1) end
    C_EncodingUtil.DeserializeCBOR = function(...) parsed = true return des(...) end
    refused("decompressed over the limit", text, "too-long")
    C_EncodingUtil.DecompressString, C_EncodingUtil.DeserializeCBOR = ds, des
    check("decompressed over the limit: never parsed", not parsed)
    check("the store never changed", liveCount() == 1)
end

------------------------------------------------------------
-- The validator: one broken field each
------------------------------------------------------------
do
    boot()
    local base = assert(S.Decode(assert(S.Encode(entry("Base")))))
    local function bad(name, mutate)
        local x = copy(base)
        mutate(x)
        local v, err = S.Decode(assert(E.EncodeShare(x)))
        check("damaged: " .. name, v == nil and err == "bad-share", tostring(err))
    end
    local function good(name, mutate)
        local x = copy(base)
        mutate(x)
        check("fine: " .. name, S.Decode(assert(E.EncodeShare(x))) ~= nil)
    end
    good("the base", function() end)
    bad("an extra top field", function(x) x.id = "loadout-x-1" end)
    bad("another kind", function(x) x.kind = "ui" end)
    bad("an extra module", function(x) x.modules.unavailable = {} end)
    bad("no cover", function(x) x.modules.cover = nil end)
    bad("a cover range with an extra field", function(x) x.modules.cover[1].x = { 1 } end)
    bad("an action with an extra field", function(x) x.modules.actions[1].extra = 1 end)
    bad("an unknown action kind", function(x) x.modules.actions[1] = { kind = "mount", id = 1 } end)
    bad("spell id 0", function(x) x.modules.actions[1].id = 0 end)
    bad("spell id 1.5", function(x) x.modules.actions[1].id = 1.5 end)
    bad("spell id 2^40", function(x) x.modules.actions[1].id = 2 ^ 40 end)
    bad("item id negative", function(x) x.modules.actions[3].id = -5 end)
    bad("a slot key over the cover limit", function(x) x.modules.actions[A.Cover.MAX + 1] = { kind = "item", id = 5 } end)
    bad("a slot key that isn't a number", function(x) x.modules.actions.one = { kind = "item", id = 5 } end)
    bad("a bad policy", function(x) x.modules.actions[1].policy = "lowest" end)
    bad("a char macro action without its definition", function(x) x.modules.macros.Shield = nil end)
    bad("a macro body padded with newlines", function(x) x.modules.macros.Shield.body = "/cast x" .. ("\n"):rep(300) end)
    bad("a macro body over 256 bytes", function(x) x.modules.macros.Shield.body = ("a"):rep(257) end)
    bad("a macro name over 16", function(x)
        x.modules.macros[("m"):rep(17)] = { body = "" }
    end)
    bad("a macro definition with an extra field", function(x) x.modules.macros.Shield.run = "x" end)
    bad("an account macro with another scope", function(x) x.modules.actions[5].scope = "global" end)
    bad("too many character macros", function(x)
        for i = 1, A.Game.MAX_CHAR_MACROS do x.modules.macros["M" .. i] = { body = "" } end
    end)
    bad("a binding to an unmanaged command", function(x) x.modules.bindings.JUMP = { "SPACE" } end)
    bad("a sparse binding list", function(x) x.modules.bindings.ACTIONBUTTON1 = { [1] = "1", [3] = "3" } end)
    bad("17 keys on one command", function(x)
        local k = {}
        for i = 1, 17 do k[i] = "K" .. i end
        x.modules.bindings.ACTIONBUTTON3 = k
    end)
    good("16 keys on one command", function(x)
        local k = {}
        for i = 1, 16 do k[i] = "K" .. i end
        x.modules.bindings.ACTIONBUTTON3 = k
    end)
    good("a 255-character macro plus the server's newline", function(x) x.modules.macros.Shield.body = ("a"):rep(255) .. "\n" end)
    local function pet(x)
        local slots = {}
        for i = 1, 10 do slots[i] = false end
        slots[1] = { kind = "token", token = "PET_ACTION_ATTACK" }
        slots[4] = { kind = "spell", id = 14916, name = "Growl" }
        x.modules.pet = { [4] = { family = "Bear", locale = "enUS", slots = slots } }
        return x.modules.pet[4]
    end
    good("a pet bar", pet)
    bad("a table-valued pet locale", function(x) pet(x).locale = { "enUS" } end)
    bad("an extra pet slot", function(x) pet(x).slots[11] = false end)
    bad("a pet slot with an extra field", function(x) pet(x).slots[4].autocast = true end)
    bad("a pet family key that isn't a whole number", function(x) local l = pet(x); x.modules.pet = { [4.5] = l } end)
    bad("a pet layout with an extra field", function(x) pet(x).unavailable = {} end)
    bad("a NUL in the name", function(x) x.name = "Raid\0Heals" end)
    bad("a line break in the name", function(x) x.name = "Raid\nHeals" end)
    bad("a name over 240 bytes", function(x) x.name = ("n"):rep(241) end)
    bad("a NUL in a macro body", function(x) x.modules.macros.Shield.body = "/cast\0x" end)
    bad("a name that isn't text", function(x) x.name = 5 end)
end

-- Share checks its own output: refused with the reason, no string shown.
do
    boot()
    local long = entry(("n"):rep(241))
    local t, err = S.Encode(long)
    check("share: a name over the limit refused", t == nil and err == "cant-share")
    local e = entry("Fine")
    local max = E.SHARE_MAX
    E.SHARE_MAX = 100
    t, err = S.Encode(e)
    E.SHARE_MAX = max
    check("share: too large refused", t == nil and err == "too-large", tostring(err))
    eq("share: too large said", S.Copy("too-large"), "This loadout is too large to share.")
end

------------------------------------------------------------
-- Import through the panel
------------------------------------------------------------

local function import() return P._Import() end
local function paste(text)
    local d = import()
    WoW.type(d.box, text)
    WoW.tick(0.4)
    return d
end

do
    boot()
    local e = entry("Raid Heals")
    local text = assert(S.Encode(e))
    P.Show()
    P.OpenImport()
    local d = import()
    check("import: shown", d:IsShown())
    check("import: Review off with nothing pasted", not d.review:IsEnabled())
    WoW.type(d.box, text)
    check("import: Review off until the decode", not d.review:IsEnabled())
    eq("import: checking", d.status:GetText(), "Checking...")
    WoW.tick(0.4)
    check("import: decoded", d.draft ~= nil)
    eq("import: the name prefilled", d.name:GetText(), "Raid Heals")
    eq("import: the category prefilled", d.category, "holy")
    check("import: the name is taken, so Review is off", not d.review:IsEnabled())
    WoW.type(d.name, "Raid Heals 2")
    check("import: Review on", d.review:IsEnabled())
    local before, writes = persisted(), 0
    A.Catalog.OnLocalWrite(function() writes = writes + 1 end)
    G.calls = {}
    local char = ser(AltStableSyncChar)
    d.review:Click()
    check("import: the dialog hides before the preview", not d:IsShown())
    check("import: previewed", shown() ~= nil)
    eq("import: nothing written before the confirm", persisted(), before)
    local pv = previewText()
    check("import: the preview names it", pv:find("Import Raid Heals 2?", 1, true) ~= nil)
    check("import: the character macro's full text", pv:find("Shield:", 1, true) and pv:find("/cast Power Word: Shield", 1, true), pv)
    check("import: the account macro's text", pv:find("Mount:", 1, true) and pv:find("/cast Swift Horse", 1, true), pv)
    check("import: nothing on this character changes", pv:find("Nothing on this character changes", 1, true) ~= nil)
    -- What Review froze is what is saved, whatever the dialog holds now.
    d.name:SetText("Changed")
    d.category = "shadow"
    local other = copy(d.draft or {}); other.modules = { cover = { { 1, 12 } } }
    d.draft = other
    _G.AltStableSyncPreview.confirm:Click()
    eq("import: one catalog write", writes, 1)
    eq("import: no game call", #G.calls, 0)
    eq("import: the character's record unchanged", ser(AltStableSyncChar), char)
    local new
    for _, x in pairs(AltStableSyncDB.presets) do if x.name == "Raid Heals 2" then new = x end end
    check("import: a new entry", new ~= nil and new.id ~= e.id)
    eq("import: its category", new and new.category, "holy")
    eq("import: its modules", new and ser(new.modules), ser(e.modules))
    eq("import: provenance is this character", new and new.provenance and new.provenance.sourceChar,
        A.Loadout.Provenance().sourceChar)
    eq("import: the panel browses it", P.sel.id, new and new.id)
    check("import: said", said("Imported \"Raid Heals 2\""))
    check("import: never loaded", not (AltStableSyncChar.loaded and AltStableSyncChar.loaded.loadout))
end

-- Cancel writes nothing; a name that arrived since the preview refuses.
do
    boot()
    local text = assert(S.Encode(entry("Raid Heals")))
    P.Show()
    P.OpenImport()
    local d = paste(text)
    WoW.type(d.name, "Copy")
    d.review:Click()
    local before = persisted()
    _G.AltStableSyncPreview.cancel:Click()
    eq("cancel: nothing written", persisted(), before)
    P.OpenImport()
    d = paste(text)
    WoW.type(d.name, "Copy")
    d.review:Click()
    entry("Copy")                     -- arrives (say, by sync) before the confirm
    local n = liveCount()
    WoW.chatLines = {}
    _G.AltStableSyncPreview.confirm:Click()
    eq("duplicate at confirm: nothing added", liveCount(), n)
    check("duplicate at confirm: said", said("Not imported"))
end

-- Another class, an unknown category, a typed name, the debounce.
do
    boot()
    local e = entry("Raid Heals")
    local x = assert(S.Decode(assert(S.Encode(e))))
    P.Show()
    P.OpenImport()
    local mage = copy(x); mage.class = "MAGE"
    local d = paste(assert(E.EncodeShare(mage)))
    check("another class: no draft", d.draft == nil)
    check("another class: said", d.status:GetText():find("This is a Mage loadout", 1, true) ~= nil, d.status:GetText())
    check("another class: Review off", not d.review:IsEnabled())
    local odd = copy(x); odd.category = "zzz"; odd.name = "Odd"
    d = paste(assert(E.EncodeShare(odd)))
    eq("unknown category: General", d.category, "general")
    eq("unknown category: name", d.name:GetText(), "Odd")
    WoW.type(d.name, "Mine")
    d = paste(assert(S.Encode(e)))
    eq("a typed name stays", d.name:GetText(), "Mine")
    -- A change drops the draft at once.
    check("debounce: a draft", d.draft ~= nil and d.review:IsEnabled())
    WoW.type(d.box, d.box:GetText() .. "x")
    check("debounce: the change drops it", d.draft == nil and not d.review:IsEnabled())
    -- Only the last change's timer decodes: an earlier one does nothing.
    local later = copy(x); later.name = "Later"
    WoW.type(d.box, assert(S.Encode(e)))
    WoW.tick(0.2)
    WoW.type(d.box, assert(E.EncodeShare(later)))
    WoW.tick(0.15)
    check("debounce: the earlier timer didn't decode", d.draft == nil)
    WoW.tick(0.2)
    check("debounce: the last one did", d.draft ~= nil and d.draft.name == "Later")
    -- A timer that fires after the dialog closed does nothing.
    WoW.type(d.box, assert(S.Encode(e)))
    local status = d.status:GetText()
    d:Hide()
    WoW.tick(0.4)
    check("debounce: closed, no decode", d.draft == nil and d.status:GetText() == status)
    P.OpenImport()
    -- A timer from before a close does nothing after reopening.
    WoW.type(d.box, assert(S.Encode(e)))
    d:Hide()
    P.OpenImport()
    WoW.tick(0.4)
    check("debounce: the old timer did nothing", d.draft == nil and d.box:GetText() == "")
    -- The box's limit: a valid string, whitespace to the limit, then
    -- garbage. The box cuts the garbage; what's left is over the raw limit.
    local t = assert(S.Encode(e))
    d = paste(t .. (" "):rep(E.BOX_MAX - #t) .. "garbage")
    eq("box limit: the box cut it", #d.box:GetText(), E.BOX_MAX)
    check("box limit: refused, not decoded", d.draft == nil and d.status:GetText():find("too long", 1, true) ~= nil, d.status:GetText())
end

-- Hostile markup is shown literally; the stored text is byte-identical.
do
    boot()
    local m = capture()
    local body = "|cffff0000red|r |Hitem:6948|h[Hearthstone]|h |T134400:0|t"
    m.macros.Shield.body = body
    local text = assert(S.Encode(entry("|cff00ff00Green|r", m)))
    P.Show()
    P.OpenImport()
    local d = paste(text)
    check("markup: the status is literal", d.status:GetText():find("||cff00ff00Green||r", 1, true) ~= nil, d.status:GetText())
    WoW.type(d.name, "Plain")
    d.review:Click()
    local pv = previewText()
    check("markup: the body is literal", pv:find("||cffff0000red||r ||Hitem:6948||h[Hearthstone]||h ||T134400:0||t", 1, true) ~= nil, pv)
    _G.AltStableSyncPreview.confirm:Click()
    local new
    for _, x in pairs(AltStableSyncDB.presets) do if x.name == "Plain" then new = x end end
    eq("markup: stored unchanged", new and new.modules.macros.Shield.body, body)
end

-- Refused schema: Import refuses before the preview, and at the confirm.
do
    boot()
    A.disabled = "test"
    WoW.chatLines = {}
    A.Commands.ImportEntry({ class = "PRIEST", category = "holy", name = "X", modules = capture() })
    check("disabled: refused", said("Not imported") and shown() == nil)
    A.disabled = nil
    A.Commands.ImportEntry({ class = "PRIEST", category = "holy", name = "X", modules = capture() })
    check("disabled at confirm: previewed", shown() ~= nil)
    A.disabled = "test"
    local n = liveCount()
    WoW.chatLines = {}
    _G.AltStableSyncPreview.confirm:Click()
    eq("disabled at confirm: nothing saved", liveCount(), n)
    check("disabled at confirm: said", said("Not imported"))
end

------------------------------------------------------------
-- Share through the panel
------------------------------------------------------------
do
    boot()
    local e = entry("Raid Heals")
    P.Show()
    P._ShowShare(e)
    local d = P._Share()
    local text = assert(S.Encode(e))
    check("share: shown", d:IsShown())
    eq("share: the string", d.box:GetText(), text)
    check("share: focused", d.box:HasFocus())
    WoW.type(d.box, "edited")
    eq("share: read-only", d.box:GetText(), text)
    check("share: the privacy note", d.note:GetText():find("Macro text may name people", 1, true) ~= nil)
    d:Hide()
    local long = entry(("n"):rep(241))
    P._ShowShare(long)
    check("share: a refusal shows no string", d.box:GetText() == "" and not d.holder:IsShown())
    check("share: says why", d.intro:GetText():find("can't carry", 1, true) ~= nil, d.intro:GetText())
    d:Hide()
    eq("share: nothing written", liveCount(), 2)
end

------------------------------------------------------------
-- Escape: only the top layer
------------------------------------------------------------
local function panelEscapes()
    for _, n in ipairs(UISpecialFrames) do if n == "AltStableSyncPanel" then return true end end
    return false
end
do
    boot()
    local text = assert(S.Encode(entry("Raid Heals")))
    P.Show()
    WoW.tick(0.2)
    check("escape: the panel alone is a target", panelEscapes())
    P.OpenImport()
    local d = import()
    check("escape: import open, panel isn't a target", not panelEscapes())
    d.box:SetFocus()
    d.box.scripts.OnEscapePressed(d.box)
    check("escape from the paste box: import closes", not d:IsShown())
    check("escape: the panel stays", P._Frame():IsShown())
    check("escape: same frame, panel not yet a target", not panelEscapes())
    WoW.tick(0.2)
    check("escape: a frame later, the panel is a target", panelEscapes())
    P.OpenImport()
    d.cat:Click()
    check("escape: picker open over import", W.menu:IsShown() and not panelEscapes())
    W.menu:Hide()
    d = paste(text)
    WoW.type(d.name, "Copy")
    d.review:Click()
    WoW.tick(0.2)
    check("escape: the preview over the panel", shown() ~= nil and not panelEscapes())
    _G.AltStableSyncPreview.cancel:Click()
    WoW.tick(0.2)
    check("escape: after cancel, the panel again", panelEscapes())
    P._ShowShare(A.Catalog.List("loadout", "PRIEST", "holy")[1])
    check("escape: share open, panel isn't a target", not panelEscapes())
    P._Share():Hide()
    WoW.tick(0.2)
    check("escape: share closed, the panel again", panelEscapes())
end

-- The Manage menu offers Share on a loadout, not on a conflict copy.
do
    boot()
    local e = entry("Raid Heals")
    P.Show()
    W.cat:Click()
    for _, b in ipairs(W.menu.items) do if b:IsShown() and b.value == "holy" then b:Click() break end end
    W.entry:Click()
    for _, b in ipairs(W.menu.items) do if b:IsShown() and b.value == e.id then b:Click() break end end
    W.manage:Click()
    local values = {}
    for _, b in ipairs(W.menu.items) do if b:IsShown() then values[#values + 1] = b.value end end
    eq("manage: Rename, Share, Delete", table.concat(values, ","), "rename,share,delete")
    for _, b in ipairs(W.menu.items) do if b:IsShown() and b.value == "share" then b:Click() break end end
    check("manage: Share opens the string", P._Share():IsShown() and P._Share().box:GetText() == S.Encode(e))
    P._Share():Hide()
    check("import button shown", W.importBtn:IsShown())
end

------------------------------------------------------------
-- Load: only the managed commands are ever bound
------------------------------------------------------------
do
    boot()
    local m = capture()
    m.bindings.JUMP = { "SPACE" }
    m.bindings.ACTIONBUTTON3 = { "3" }
    local e = entry("Keys", m)
    local plan = A.Loadout.Plan(e)
    check("plan keys: the managed command", plan.keys["3"] ~= nil and plan.keys["3"].to == "ACTIONBUTTON3")
    check("plan keys: never an unmanaged one", plan.keys.SPACE == nil)
end

finish("test_share_import")
