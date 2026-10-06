------------------------------------------------------------
-- test_packaging.lua - the TOC and .pkgmeta inputs
--
-- Nothing packages this addon yet, but the TOC is what the client loads: a
-- listed file that doesn't exist, or a literal version committed over the
-- packager keyword (it has happened twice on sibling projects), is caught here.
------------------------------------------------------------

dofile("tests/harness.lua")

local function read(path)
    local h = io.open(path, "rb")
    if not h then return nil end
    local s = h:read("*a"); h:close(); return s
end

local toc = read("AltStableSync.toc")
check("toc exists", toc ~= nil)
toc = toc or ""

check("interface 16001", toc:find("## Interface: 16001", 1, true) ~= nil)
check("version is the packager keyword", toc:find("## Version: @project-version@", 1, true) ~= nil)
check("account SVs", toc:find("## SavedVariables: AltStableSyncDB AltStableSyncLAS", 1, true) ~= nil)
check("character SV", toc:find("## SavedVariablesPerCharacter: AltStableSyncChar", 1, true) ~= nil)
check("AltStable is optional, not required", toc:find("## OptionalDeps: AltStable", 1, true) ~= nil
    and not toc:find("## Dependencies:", 1, true))

local files = {}
for line in (toc .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if line ~= "" and not line:find("^#") then files[#files + 1] = line end
end

-- The runtime entries the addon cannot load without, in this order. The
-- glass XML comes first (it brings its own LibStub); modules follow Core.lua
-- as they land, so this is a required subsequence, not the whole list.
local REQUIRED = {
    "Libs\\LibGlass-1.0\\LibGlass-1.0.xml",
    "Libs\\LibStub\\LibStub.lua",
    "Core.lua",
}
do
    local at = 0
    for _, want in ipairs(REQUIRED) do
        local found
        for i = at + 1, #files do
            if files[i] == want then found = i; break end
        end
        check("toc lists " .. want .. " in order", found ~= nil)
        at = found or at
    end
end

-- Every listed file exists, except the externals the packager or the deploy
-- script fills in - and those only at their exact expected path, so a
-- misspelling can't hide behind the exemption.
local EXTERNAL = { ["Libs\\LibGlass-1.0\\LibGlass-1.0.xml"] = true }
for _, line in ipairs(files) do
    if not EXTERNAL[line] then
        local path = line:gsub("\\", "/")
        check("listed file exists: " .. path, read(path) ~= nil)
    end
end

-- .pkgmeta: the external is pinned to a tag, never latest, no inline comment.
local pkg = read(".pkgmeta") or ""
check("LibGlass pinned to a tag", pkg:find("Libs/LibGlass%-1%.0:%s*\r?\n%s+url: https://github.com/Spotnick2/LibGlass%s*\r?\n%s+tag: r%d+%s*\r?\n") ~= nil)
check("no tag: latest", not pkg:find("tag:%s*latest"))
for _, dir in ipairs({ "docs", "tests", "Tools", ".claude", ".github" }) do
    check(".pkgmeta ignores " .. dir, pkg:find("\n  %- " .. dir:gsub("%.", "%%.") .. "\r?\n") ~= nil)
end

finish("test_packaging")
