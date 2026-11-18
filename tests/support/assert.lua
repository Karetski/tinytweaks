--[[
	Plain assertions for the test runner. Every failure raises an error whose message says what was
	expected and what was observed; the runner prints it with the failing test's name.
]]

local A = {}

local function show(value, indent, seen)
	indent = indent or ""
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	seen = seen or {}
	if seen[value] then
		return "<cycle>"
	end
	seen[value] = true
	local keys = {}
	for k in pairs(value) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then
			return a < b
		end
		return type(a) < type(b)
	end)
	if #keys == 0 then
		return "{}"
	end
	local inner = indent .. "  "
	local parts = {}
	for _, k in ipairs(keys) do
		local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. show(k) .. "]")
		parts[#parts + 1] = inner .. key .. " = " .. show(value[k], inner, seen)
	end
	seen[value] = nil
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end
A.show = show

-- Returns nil when equal, otherwise the path of the first difference.
local function diff(expected, actual, path)
	if type(expected) ~= "table" or type(actual) ~= "table" then
		if expected ~= actual then
			return path
		end
		return nil
	end
	for k, v in pairs(expected) do
		local d = diff(v, actual[k], path .. "." .. tostring(k))
		if d then
			return d
		end
	end
	for k in pairs(actual) do
		if expected[k] == nil then
			return path .. "." .. tostring(k)
		end
	end
	return nil
end

local function fail(message, level)
	error(message, (level or 1) + 2)
end

function A.eq(actual, expected, label)
	local where = diff(expected, actual, "value")
	if where then
		fail(string.format("%sexpected %s\n  got %s\n  first difference at %s",
			label and (label .. ": ") or "", show(expected, "  "), show(actual, "  "), where))
	end
end

function A.near(actual, expected, tolerance, label)
	tolerance = tolerance or 1e-6
	if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
		fail(string.format("%sexpected %s (±%s), got %s", label and (label .. ": ") or "",
			tostring(expected), tostring(tolerance), tostring(actual)))
	end
end

function A.truthy(value, label)
	if not value then
		fail((label or "value") .. ": expected truthy, got " .. tostring(value))
	end
end

function A.falsy(value, label)
	if value then
		fail((label or "value") .. ": expected falsy, got " .. show(value))
	end
end

function A.isNil(value, label)
	if value ~= nil then
		fail((label or "value") .. ": expected nil, got " .. show(value))
	end
end

-- Asserts that fn raises an error whose message contains `pattern` (plain substring).
function A.errors(fn, pattern)
	local ok, err = pcall(fn)
	if ok then
		fail("expected an error" .. (pattern and (" containing " .. string.format("%q", pattern)) or ""))
	end
	if pattern and not tostring(err):find(pattern, 1, true) then
		fail(string.format("expected an error containing %q, got %q", pattern, tostring(err)))
	end
	return err
end

function A.contains(haystack, needle, label)
	if type(haystack) == "string" then
		if not haystack:find(needle, 1, true) then
			fail(string.format("%sexpected %q to contain %q", label and (label .. ": ") or "", haystack, needle))
		end
		return
	end
	for _, v in pairs(haystack) do
		if diff(needle, v, "") == nil then
			return
		end
	end
	fail(string.format("%sexpected %s to contain %s", label and (label .. ": ") or "", show(haystack), show(needle)))
end

return A
