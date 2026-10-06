------------------------------------------------------------
-- test_packaging.lua - the TOC and .pkgmeta inputs
--
-- Nothing packages this addon yet, but the TOC is what the client loads: a
-- listed file that doesn't exist, or a literal version committed over the
-- packager keyword (it has happened twice on sibling projects), is caught here.
------------------------------------------------------------

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print("  FAIL: " .. name .. (detail and ("  -- " .. detail) or "")) end
end

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

-- Every listed file exists, except the gitignored externals the packager or
-- the deploy script fills in.
local EXTERNAL = { ["Libs/LibGlass-1.0/"] = true }
local listed = 0
for line in (toc .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if line ~= "" and not line:find("^#") then
        listed = listed + 1
        local path = line:gsub("\\", "/")
        local ext = false
        for prefix in pairs(EXTERNAL) do
            if path:sub(1, #prefix) == prefix then ext = true end
        end
        if not ext then check("listed file exists: " .. path, read(path) ~= nil) end
    end
end
check("toc lists files", listed > 0)

-- .pkgmeta: the external is pinned to a tag, never latest, no inline comment.
local pkg = read(".pkgmeta") or ""
check("LibGlass pinned to a tag", pkg:find("Libs/LibGlass%-1%.0:%s*\r?\n%s+url: https://github.com/Spotnick2/LibGlass%s*\r?\n%s+tag: r%d+%s*\r?\n") ~= nil)
check("no tag: latest", not pkg:find("tag:%s*latest"))
for _, dir in ipairs({ "docs", "tests", "Tools", ".claude", ".github" }) do
    check(".pkgmeta ignores " .. dir, pkg:find("\n  %- " .. dir:gsub("%.", "%%.") .. "\r?\n") ~= nil)
end

print(("test_packaging: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
