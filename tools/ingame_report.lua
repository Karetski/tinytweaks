--[[
	Reads what an in-game test session left on disk and prints a report:

	  1. the session: build, taint logging, TinyTweaks version, how it ended;
	  2. Lua errors, warnings and blocked actions, TinyTweaks' first;
	  3. TinyTweaks lines in taint.log;
	  4. TinyTweaks' saved records for the active layout, checked against the frames' state at logout;
	  5. the trail: frame selections, slider moves, Edit Mode, combat, layout changes.

	Usage (tools/ingame.sh finds the files):
	  luajit tools/ingame_report.lua <TinyTweaks.lua> <!TinyTweaksDev.lua> <taint.log> [since]
	  luajit tools/ingame_report.lua --ended <!TinyTweaksDev.lua>   prints how the last session ended

	With `since` ("YYYY-MM-DD HH:MM:SS", when a watch started), errors and the trail cover every
	session that ended since then, so a test run with /reloads in it is reported whole; saved
	records are checked against the last one. Without it, only the last session is reported.

	Loaded with dofile (the tests do), it returns its functions instead of running.
]]

local R = {}

local NEAR = 0.002

local function near(a, b, tolerance)
	return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (tolerance or NEAR)
end

local function fmt(n)
	if type(n) ~= "number" then
		return tostring(n)
	end
	local s = string.format("%.3f", n):gsub("0+$", ""):gsub("%.$", "")
	return s
end

-- The global `name` defined by a SavedVariables file, or nil.
function R.loadSaved(path, name)
	local chunk = path and loadfile(path)
	if not chunk then
		return nil
	end
	local env = {}
	setfenv(chunk, env)
	if not pcall(chunk) then
		return nil
	end
	return env[name]
end

-- Whether an error, warning or blocked action came from TinyTweaks (not the dev recorder).
function R.isOurs(entry)
	if entry.addon then
		return entry.addon == "TinyTweaks"
	end
	local text = (entry.message or "") .. "\n" .. (entry.stack or "")
	return text:find("AddOns[/\\]TinyTweaks[/\\]") ~= nil
end

-- The raid groups as rows, top first: "1 2 3 4 / 5 6 7 8". groups[i] = { x, y } of group i's
-- TOPLEFT point on the container.
function R.gridString(groups)
	local xs, ys, at = {}, {}, {}
	local function unique(list, v)
		for _, existing in ipairs(list) do
			if math.abs(existing - v) < 0.5 then
				return existing
			end
		end
		list[#list + 1] = v
		return v
	end
	for i = 1, 8 do
		local g = groups[i]
		if g and type(g[1]) == "number" and type(g[2]) == "number" then
			local x, y = unique(xs, g[1]), unique(ys, g[2])
			at[x .. ":" .. y] = i
		end
	end
	table.sort(xs)
	table.sort(ys, function(a, b)
		return a > b
	end)
	local rows = {}
	for _, y in ipairs(ys) do
		local cells = {}
		for _, x in ipairs(xs) do
			cells[#cells + 1] = tostring(at[x .. ":" .. y] or ".")
		end
		rows[#rows + 1] = table.concat(cells, " ")
	end
	return table.concat(rows, " / ")
end

-- taint.log blocks (a line plus its indented continuation) that mention TinyTweaks.
function R.taintBlocks(text)
	local blocks, current = {}, nil
	for line in (text or ""):gmatch("[^\r\n]+") do
		if line:match("^%s") and current then
			current[#current + 1] = line
		else
			current = { line }
			blocks[#blocks + 1] = current
		end
	end
	local ours = {}
	for _, block in ipairs(blocks) do
		local joined = table.concat(block, "\n")
		if joined:find("TinyTweaks", 1, true) and not joined:find("!TinyTweaksDev", 1, true) then
			ours[#ours + 1] = joined
		end
	end
	return ours, #blocks
end

-- The TinyTweaksDB layout record for a snapshot's layout ("type:name"; character layouts add
-- ":<character>-<realm>" to the key).
function R.layoutFor(db, layoutKey)
	if not (db and db.layouts and layoutKey) then
		return nil
	end
	if db.layouts[layoutKey] then
		return db.layouts[layoutKey], layoutKey
	end
	for key, layout in pairs(db.layouts) do
		if key:sub(1, #layoutKey + 1) == layoutKey .. ":" then
			return layout, key
		end
	end
	return nil
end

local function pinMatches(record, pin)
	return pin and record.pin and record.pin.point == pin[1] and record.pin.relativeTo == pin[2]
		and record.pin.relativePoint == pin[3] and near(record.pin.offsetX, pin[4], 0.1)
		and near(record.pin.offsetY, pin[5], 0.1)
end

local function sortedKeys(t)
	local keys = {}
	for k in pairs(t or {}) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

-- Checks the layout's typed values and offsets against the frames in a snapshot. Returns a list of
-- { status = "pass" | "fail" | "info", what, detail }.
function R.check(layout, snapshot)
	local results = {}
	local function add(status, what, detail)
		results[#results + 1] = { status = status, what = what, detail = detail }
	end
	local frames = snapshot and snapshot.frames or {}

	for _, key in ipairs(sortedKeys(layout and layout.overrides)) do
		local frame = frames[key]
		for _, setting in ipairs(sortedKeys(layout.overrides[key])) do
			local record = layout.overrides[key][setting]
			local what = string.format("typed value %s on %s (%s), setting %s", fmt(record.value), frame and frame.name or "?", key, tostring(setting))
			local expected = record.value / 100
			if not frame then
				add("info", what, "frame not in the snapshot")
			elseif frame.settings and frame.settings[setting] ~= record.raw then
				add("info", what, string.format("inactive: slider step is %s, typed against %s", tostring(frame.settings[setting]), tostring(record.raw)))
			elseif frame.managed and frame.default then
				local applied = near(frame.scale, expected)
				add(applied and "fail" or "pass", what, "managed frame in its default position: Blizzard's size expected, scale " .. fmt(frame.scale))
			elseif near(frame.scale, expected) or near(frame.alpha, expected) then
				add("pass", what, string.format("scale %s, alpha %s", fmt(frame.scale), fmt(frame.alpha)))
			else
				add("fail", what, string.format("expected %s as scale or alpha; scale %s, alpha %s", fmt(expected), fmt(frame.scale), fmt(frame.alpha)))
			end
		end
	end

	for _, key in ipairs(sortedKeys(layout and layout.positions)) do
		local record = layout.positions[key]
		local frame = frames[key]
		local what = string.format("offset %s, %s on %s (%s)", fmt(record.x), fmt(record.y), frame and frame.name or "?", key)
		if not frame then
			add("info", what, "frame not in the snapshot")
		elseif not pinMatches(record, frame.pin) then
			add("info", what, "inactive: the frame is pinned somewhere else now")
		elseif not frame.point or frame.point[1] ~= record.pin.point then
			add("info", what, "frame isn't anchored at its pin's point")
		else
			local scale = frame.scale or 1
			local ex, ey = (record.pin.offsetX + (record.x or 0)) / scale, (record.pin.offsetY + (record.y or 0)) / scale
			local ok = near(frame.point[4], ex, 0.1) and near(frame.point[5], ey, 0.1)
			add(ok and "pass" or "fail", what, string.format("point %s, %s; expected %s, %s", fmt(frame.point[4]), fmt(frame.point[5]), fmt(ex), fmt(ey)))
		end
	end

	local grid = layout and layout.groupGrid
	if grid then
		local config = string.format("enabled %s, %s columns, %s, start %s, spacing %s/%s", tostring(grid.enabled), tostring(grid.columns), tostring(grid.order), tostring(grid.corner), tostring(grid.hSpacing), tostring(grid.vSpacing))
		local observed = snapshot and snapshot.groups and R.gridString(snapshot.groups)
		add("info", "raid grid: " .. config, observed and ("groups on screen: " .. observed) or "no raid groups shown")
	end
	return results
end

local function describeFrame(frame)
	local parts = { string.format("scale %s alpha %s", fmt(frame.scale), fmt(frame.alpha)) }
	if frame.point then
		parts[#parts + 1] = string.format("at %s %s %s %s,%s", tostring(frame.point[1]), tostring(frame.point[2]), tostring(frame.point[3]), fmt(frame.point[4]), fmt(frame.point[5]))
	end
	if frame.managed and frame.default then
		parts[#parts + 1] = "managed, default position"
	end
	return table.concat(parts, ", ")
end

-- One line per trail entry.
function R.trailLines(entries)
	local lines = {}
	for _, e in ipairs(entries or {}) do
		local text
		if e.event == "slider" then
			local range = e.first ~= nil and e.first ~= e.value and (tostring(e.first) .. " -> " .. tostring(e.value)) or ("-> " .. tostring(e.value))
			text = string.format("slider: %s (%s) setting %s %s%s", tostring(e.name), tostring(e.frame), tostring(e.setting), range, (e.steps or 1) > 1 and string.format(" (%d steps)", e.steps) or "")
		elseif e.event then
			text = string.format("%s%s: %s", e.event, e.addon and (" by " .. e.addon) or "", tostring(e.message or e.func or ""):match("[^\n]*"))
		elseif e.reason == "selected" then
			local key, frame = next(e.frames or {})
			text = frame and string.format("selected %s (%s): %s", tostring(frame.name), key, describeFrame(frame)) or "selected ?"
		else
			text = string.format("%s%s%s", e.reason or "?", e.layout and (", layout " .. e.layout) or "", e.combat and ", in combat" or "")
		end
		lines[#lines + 1] = (e.at or "??:??:??") .. "  " .. text
	end
	return lines
end

-- Report --------------------------------------------------------------------------------------

local function readFile(path)
	local f = path and io.open(path, "rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

-- Sessions that ended at or after `since` ("YYYY-MM-DD HH:MM:SS", which compares as text), oldest
-- first; without `since`, the last session. A session with no end yet counts as ending last.
function R.sessionsSince(sessions, since)
	if not since then
		return { sessions[#sessions] }
	end
	local out = {}
	for _, session in ipairs(sessions) do
		if (session.endedAt or "~") >= since then
			out[#out + 1] = session
		end
	end
	return out
end

local function describeSession(session)
	return string.format("%s to %s (%s)", tostring(session.started), tostring(session.endedAt or "?"),
		tostring(session.ended or "no logout recorded: crash, or still running"))
end

function R.report(dbPath, devPath, taintPath, since)
	local out = {}
	local function say(...)
		out[#out + 1] = string.format(...)
	end
	local log = R.loadSaved(devPath, "TinyTweaksDevLog")
	local selected = R.sessionsSince(log and log.sessions or {}, since)
	local session = selected[#selected]
	local db = R.loadSaved(dbPath, "TinyTweaksDB")

	say("## Session")
	if not session then
		say("No TinyTweaks Dev session recorded%s (%s). Is !TinyTweaksDev installed (make link) and enabled?",
			since and (" since " .. since) or "", tostring(devPath))
		return table.concat(out, "\n")
	end
	if since then
		say("%d session%s since the watch started (%s):", #selected, #selected == 1 and "" or "s", since)
		for i, s in ipairs(selected) do
			say("  %d. %s", i, describeSession(s))
		end
	else
		say("%s", describeSession(session))
	end
	say("build %s; TinyTweaks %s; taintLog %s%s; scriptErrors %s", tostring(session.build), tostring(session.tinyTweaksVersion), tostring(session.taintLog), session.taintLogError and (" (could not set: " .. session.taintLogError .. ")") or "", tostring(session.scriptErrors))
	say("%d addons loaded%s", #(session.addons or {}), session.truncated and "; TRAIL TRUNCATED" or "")

	say("")
	say("## Errors and blocked actions")
	local ours, theirs = {}, {}
	for _, s in ipairs(selected) do
		for _, e in ipairs(s.entries or {}) do
			if e.event and e.event ~= "slider" then
				if R.isOurs(e) then
					ours[#ours + 1] = e
				else
					theirs[#theirs + 1] = e
				end
			end
		end
	end
	if #ours == 0 then
		say("TinyTweaks: none")
	end
	for _, e in ipairs(ours) do
		say("TinyTweaks %s x%s at %s: %s", e.event, tostring(e.count or 1), tostring(e.at), tostring(e.message or e.func))
		if e.stack then
			say("%s", e.stack)
		end
		if e.locals then
			say("locals:\n%s", e.locals)
		end
	end
	if #theirs > 0 then
		say("Other addons or Blizzard: %d", #theirs)
		for _, e in ipairs(theirs) do
			say("  %s %s: %s", e.event, tostring(e.addon or ""), (tostring(e.message or e.func)):match("[^\n]*"))
		end
	end

	say("")
	say("## taint.log")
	local taint = readFile(taintPath)
	if not taint then
		say("No taint.log at %s (taintLog was %s).", tostring(taintPath), tostring(session.taintLog))
	else
		local blocks, total = R.taintBlocks(taint)
		say("%d entries, %d mention TinyTweaks", total, #blocks)
		for _, block in ipairs(blocks) do
			say("%s", block)
		end
	end

	say("")
	say("## Saved records vs. frames at logout")
	local snapshot = session.final
	local layout, layoutKey = R.layoutFor(db, snapshot and snapshot.layout)
	if not snapshot then
		say("No logout snapshot (the session didn't end with a logout or reload).")
	elseif not layout then
		say("No TinyTweaks records for layout %s.", tostring(snapshot.layout))
	else
		say("layout %s", layoutKey)
		for _, r in ipairs(R.check(layout, snapshot)) do
			say("%-4s  %s: %s", r.status:upper(), r.what, r.detail)
		end
	end

	say("")
	say("## Trail")
	for i, s in ipairs(selected) do
		if #selected > 1 then
			say("### session %d: %s", i, describeSession(s))
		end
		for _, line in ipairs(R.trailLines(s.entries)) do
			say("%s", line)
		end
	end
	return table.concat(out, "\n")
end

if arg and arg[0] and arg[0]:find("ingame_report%.lua$") then
	if arg[1] == "--ended" then
		local log = R.loadSaved(arg[2], "TinyTweaksDevLog")
		local sessions = log and log.sessions or {}
		local session = sessions[#sessions]
		print(session and session.ended or "none")
	else
		print(R.report(arg[1], arg[2], arg[3], arg[4]))
	end
end

return R
