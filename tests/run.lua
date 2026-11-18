--[[
	Zero-dependency test runner (Lua 5.1 / LuaJIT). Run from the repository root:

	  luajit tests/run.lua                      unit + integration + invariants
	  luajit tests/run.lua unit                 one tier (unit | integration | invariants | bench)
	  luajit tests/run.lua tests/unit/core_spec.lua
	  luajit tests/run.lua -f layout_switch     only tests whose name contains the text
	  luajit tests/run.lua -q                   print only failures and the summary
	  luajit tests/run.lua --syntax a.lua b.lua compile-check files and exit

	Spec files (tests/<tier>/*_spec.lua) call the globals the runner provides:

	  test("given_<setup>_when_<action>_then_<outcome>", function() ... end)
	  skip("name", "reason")                    recorded and reported, never run

	Bench files (tests/bench/*_bench.lua) call:

	  bench("name", function() <setup>; return function() <one op> end end)

	After every test the runner calls wow.finish() (when the emulator was loaded), which fails the
	test if a simulated world recorded a Lua error, a taint violation or a blocked action that the
	test did not take with world:takeErrors() / world:takeViolations().
]]

package.path = "tests/?.lua;" .. package.path

local TIERS = { "unit", "integration", "invariants" }
local ALL_TIERS = { unit = true, integration = true, invariants = true, bench = true }

local args = { ... }
local filter, quiet, syntaxOnly = nil, false, false
local targets = {}
local i = 1
while i <= #args do
	local a = args[i]
	if a == "-f" then
		i = i + 1
		filter = args[i]
	elseif a == "-q" then
		quiet = true
	elseif a == "--syntax" then
		syntaxOnly = true
	else
		targets[#targets + 1] = a
	end
	i = i + 1
end

if syntaxOnly then
	local failed = false
	for _, path in ipairs(targets) do
		local fn, err = loadfile(path)
		if not fn then
			io.stderr:write(err, "\n")
			failed = true
		end
	end
	os.exit(failed and 1 or 0)
end

local function listFiles(tier)
	local suffix = tier == "bench" and "_bench.lua" or "_spec.lua"
	local files = {}
	local p = io.popen('ls "tests/' .. tier .. '/"*' .. suffix .. " 2>/dev/null")
	for line in p:lines() do
		files[#files + 1] = line
	end
	p:close()
	return files
end

local files, benchMode = {}, false
if #targets == 0 then
	for _, tier in ipairs(TIERS) do
		for _, f in ipairs(listFiles(tier)) do
			files[#files + 1] = f
		end
	end
else
	for _, t in ipairs(targets) do
		if ALL_TIERS[t] then
			for _, f in ipairs(listFiles(t)) do
				files[#files + 1] = f
			end
		else
			files[#files + 1] = t
		end
	end
end
for _, f in ipairs(files) do
	if f:find("_bench%.lua$") then
		benchMode = true
	end
end

local function out(...)
	if not quiet then
		io.write(...)
	end
end

-- Benchmarks ------------------------------------------------------------------------------

local function runBench(name, setup)
	local op = setup()
	op() -- warm-up (lazy creation, JIT)
	local n, elapsed = 1, 0
	while true do
		local start = os.clock()
		for _ = 1, n do
			op()
		end
		elapsed = os.clock() - start
		if elapsed > 0.2 or n >= 1e6 then
			break
		end
		n = n * 4
	end
	collectgarbage("collect")
	collectgarbage("stop")
	local before = collectgarbage("count")
	for _ = 1, n do
		op()
	end
	local kb = (collectgarbage("count") - before) / n
	collectgarbage("restart")
	io.write(string.format("  %-58s %10.2f us/op %9.3f KB/op  (n=%d)\n", name, elapsed / n * 1e6, kb, n))
end

-- Tests -------------------------------------------------------------------------------------

local passed, failed, skipped = 0, 0, 0
local failures = {}

local function finishWorlds()
	local wow = package.loaded["support.wow"]
	if wow then
		wow.finish()
	end
end

local function runFile(path)
	local cases = {}
	local env = setmetatable({}, { __index = _G })
	env.test = function(name, fn)
		cases[#cases + 1] = { name = name, fn = fn }
	end
	env.skip = function(name, reason)
		cases[#cases + 1] = { name = name, skip = reason or "skipped" }
	end
	env.bench = function(name, setup)
		cases[#cases + 1] = { name = name, bench = setup }
	end
	local chunk, err = loadfile(path)
	if not chunk then
		failed = failed + 1
		failures[#failures + 1] = { path, "(load)", err }
		io.write("LOAD ERROR ", path, "\n  ", err, "\n")
		return
	end
	setfenv(chunk, env)
	local ok, loadErr = pcall(chunk)
	if not ok then
		failed = failed + 1
		failures[#failures + 1] = { path, "(load)", loadErr }
		io.write("LOAD ERROR ", path, "\n  ", tostring(loadErr), "\n")
		return
	end

	out(path, "\n")
	for _, case in ipairs(cases) do
		if not filter or case.name:find(filter, 1, true) then
			if case.bench then
				runBench(case.name, case.bench)
			elseif case.skip then
				skipped = skipped + 1
				out("  skip ", case.name, " (", case.skip, ")\n")
			else
				local okCase, caseErr = xpcall(function()
					case.fn()
					finishWorlds()
				end, debug.traceback)
				if not okCase then
					pcall(finishWorlds) -- drop worlds left over from the failed test
				end
				if okCase then
					passed = passed + 1
					out("  ok   ", case.name, "\n")
				else
					failed = failed + 1
					failures[#failures + 1] = { path, case.name, caseErr }
					out("  FAIL ", case.name, "\n")
				end
			end
		end
	end
end

for _, f in ipairs(files) do
	runFile(f)
end

if benchMode then
	os.exit(failed > 0 and 1 or 0)
end

for _, f in ipairs(failures) do
	io.write("\nFAIL ", f[1], " :: ", f[2], "\n  ", (tostring(f[3]):gsub("\n", "\n  ")), "\n")
end
io.write(string.format("\n%d passed, %d failed, %d skipped\n", passed, failed, skipped))
os.exit(failed > 0 and 1 or 0)
