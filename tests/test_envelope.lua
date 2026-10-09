------------------------------------------------------------
-- test_envelope.lua - the catalog's wire format (#17, M1 part)
--
-- C_EncodingUtil is the stand-in in wow_stubs.lua: these checks prove our
-- framing, checksum, schema refusal and `previous` stripping, not the codec.
------------------------------------------------------------

dofile("tests/harness.lua")
dofile("tests/wow_stubs.lua")

local function boot()
    WoW.reset()
    assert(loadfile("Core.lua"))("AltStableSync", {})
    assert(loadfile("Categories.lua"))("AltStableSync", {})
    assert(loadfile("Catalog.lua"))("AltStableSync", {})
    assert(loadfile("Envelope.lua"))("AltStableSync", {})
    WoW.fire("ADDON_LOADED", "AltStableSync")
    return AltStableSync, AltStableSync.Catalog, AltStableSync.Envelope
end

local A, C, E = boot()

local function deepEq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local entry = C.Create("loadout", { class = "PRIEST", category = "holy", name = "Raid",
    provenance = { sourceChar = "Karuzo-Elegia", build = "70245" } },
    { actions = { [1] = { kind = "spell", id = 2050 }, [12] = { kind = "macro", name = "Heal", scope = "char" } },
      bindings = { ACTIONBUTTON1 = { "1", "SHIFT-1" } },
      macros = { Heal = { body = "/cast Heal", icon = 135915 } }, cover = { { 1, 120 }, { 145, 180 } } })
entry = C.Replace(entry.id, entry.modules, entry.version)   -- now it has a `previous`
check("fixture has a previous", entry.previous ~= nil)

-- Round trip.
do
    local text = E.Encode(entry)
    check("encode: a string", type(text) == "string")
    check("encode: prefix and checksum", text:match("^ASE1:%x%x%x%x%x%x%x%x:") ~= nil)
    local back, why = E.Decode(text)
    check("decode: ok", back ~= nil, why)
    local want = C.Copy(entry); want.previous = nil
    check("round trip: deep-equal minus previous", deepEq(back, want))
    eq("round trip: integer slot keys stay numbers", back.modules.actions[12].name, "Heal")
    eq("never carries previous", back.previous, nil)
    eq("encoding the entry left it intact", entry.previous ~= nil, true)
    check("previous not in the text at all", not text:find(E.Adler32("previous"), 1, true)
        and not C_EncodingUtil.DecompressString(C_EncodingUtil.DecodeBase64(text:match(":(%x+)$"))):find("previous", 1, true))
end

-- Refusals: each leaves nothing decoded.
do
    local text = E.Encode(entry)
    local body = text:match("^ASE1:%x+:(.+)$")
    local function refused(label, t, want)
        local v, why = E.Decode(t)
        eq(label .. ": refused", v, nil)
        eq(label .. ": why", why, want)
    end
    refused("not a string", nil, "bad-envelope")
    refused("no prefix", body, "bad-envelope")
    refused("other prefix", "ASE2:" .. text:sub(6), "bad-envelope")
    refused("bad base64", "ASE1:00000000:zz", "bad-envelope")
    refused("bad stream", "ASE1:00000000:" .. C_EncodingUtil.EncodeBase64("Q" .. "{}"), "bad-envelope")
    refused("checksum mismatch", "ASE1:00000001:" .. body, "bad-checksum")
    -- A body whose checksum matches but whose content was altered elsewhere:
    local function wrap(v)
        local c = C_EncodingUtil.SerializeCBOR(v)
        return "ASE1:" .. E.Adler32(c) .. ":" .. C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(c))
    end
    refused("newer schema", wrap({ s = 3, e = { id = "x" } }), "newer-schema")
    -- #5: a 1-12 build's envelopes are refused as older, never imported.
    refused("older schema", wrap({ s = 1, e = { id = "x" } }), "older-schema")
    refused("string schema", wrap({ s = "2", e = { id = "x" } }), "newer-schema")
    eq("schema is 2", E.SCHEMA, 2)
    local noE = C_EncodingUtil.SerializeCBOR({ s = 2 })
    refused("no entry", "ASE1:" .. E.Adler32(noE) .. ":" .. C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(noE)),
            "bad-envelope")
    local notTable = C_EncodingUtil.SerializeCBOR("hello")
    refused("not a table", "ASE1:" .. E.Adler32(notTable) .. ":" .. C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(notTable)),
            "bad-envelope")
    -- Upper-case hex checksum is the same checksum.
    local up = text:gsub("^ASE1:(%x+):", function(h) return "ASE1:" .. h:upper() .. ":" end)
    check("checksum case-insensitive", E.Decode(up) ~= nil)
end

-- Adler-32 known value ("Wikipedia" = 0x11E60398).
eq("adler32 known value", E.Adler32("Wikipedia"), "11e60398")
-- High half >= 2^15: the value is >= 2^31, which "%08x" of the whole would
-- pass through C's long (zlib.adler32 reference values).
eq("adler32 high half", E.Adler32(string.rep("a", 1000)), "f9d87af8")
local bytes = {}
for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
eq("adler32 all bytes x4", E.Adler32(string.rep(table.concat(bytes), 4)), "e4c9fe10")

-- No codec on this client: refused, never an error.
do
    local saved = C_EncodingUtil
    C_EncodingUtil = nil
    local t, why = E.Encode(entry)
    eq("no codec: encode refused", t, nil)
    eq("no codec: why", why, "encode-failed")
    eq("no codec: decode refused", (E.Decode("ASE1:00000000:00")), nil)
    C_EncodingUtil = saved
    local realSer = C_EncodingUtil.SerializeCBOR
    C_EncodingUtil.SerializeCBOR = function() error("boom") end
    eq("codec error: encode refused", (E.Encode(entry)), nil)
    C_EncodingUtil.SerializeCBOR = realSer
end

finish("test_envelope")
