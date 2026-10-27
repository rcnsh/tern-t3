--!strict
-- The window half: palette commands that start and open T3 Code threads from
-- the focused pane, routing of `t3-thread://` links to thread blocks, and a
-- status line segment counting the focused project's busy threads.

local common = require("./common")

local THREAD = "t3.thread"
local THREADS = "t3.threads"
-- How often the status line rechecks the focused pane's project, and how long
-- a directory that isn't a T3 Code project is left alone.
local TICK_MS = 15 * 1000
local NOT_PROJECT_MS = 2 * 60 * 1000
-- Terminal lines sent along with "Ask T3 about the last command".
local CONTEXT_LINES = 120

local function focused(cx: WindowCx): PaneInfo?
	local id = cx.session:focused()
	return if id then cx.session:pane(id) else nil
end

local function focused_cwd(cx: WindowCx): string?
	local pane = focused(cx)
	if pane and pane.cwd and pane.cwd ~= "" then
		return pane.cwd
	end
	return nil
end

local function first_line(s: string): string
	return string.match(s, "^%s*([^\n]-)%s*$") or s
end

-- Starts a thread in `cwd`'s project with `message` and opens it beside.
local function start_thread(cx: WindowCx, cwd: string, message: string)
	local err = common.run({ "thread", "start", cwd, "-" }, message, function(result, cx2)
		if cx2 == nil then
			return
		end
		if result.status ~= 0 then
			local why = common.why(result)
			if string.find(why, "No T3 Code project", 1, true) then
				why = why .. "\nAdd it with `t3 project add " .. cwd .. "`."
			end
			cx2:toast("error", "T3 didn't start the thread", why)
			return
		end
		local id = first_line(result.stdout)
		if cx2:new_block(THREAD, { id }, "beside") == nil then
			cx2:toast("success", "Thread started", id)
		end
	end)
	if err then
		cx:toast("error", "Couldn't start t3", err)
	end
end

local function new_thread(cx: WindowCx)
	local cwd = focused_cwd(cx)
	if cwd == nil then
		cx:toast("error", "No directory", "Focus a shell in a T3 Code project first.")
		return
	end
	cx:prompt({ placeholder = "Message for a new T3 thread in " .. cwd, icon = "sparkle", action = "start" })
		:next(function(text, _err, cx2)
			if text and cx2 and string.find(text, "%S") then
				start_thread(cx2, cwd, text)
			end
		end)
end

-- The focused terminal's recent text, last command included.
local function recent_output(cx: WindowCx, pane: number): string
	local read = cx.session:read(pane, { as = "text", lines = CONTEXT_LINES })
	if type(read) == "string" then
		return read
	elseif type(read) == "table" and type(read.lines) == "table" then
		return table.concat(read.lines, "\n")
	end
	return ""
end

local function ask_about_last(cx: WindowCx)
	local pane = focused(cx)
	if pane == nil or pane.cwd == nil or pane.cwd == "" then
		cx:toast("error", "No directory", "Focus a shell in a T3 Code project first.")
		return
	end
	local cwd = pane.cwd :: string
	local last = pane.last
	local output = recent_output(cx, pane.pane)
	local suggestion = if last and last.status ~= 0 then "Why did this fail? Fix it." else ""
	cx:prompt({
		value = suggestion,
		placeholder = "What should T3 do with this output?",
		icon = "sparkle",
		action = "start",
	}):next(function(text, _err, cx2)
		if text == nil or cx2 == nil then
			return
		end
		local parts = { text, "", "From my terminal in `" .. cwd .. "`:" }
		if last then
			table.insert(parts, "Last command: `" .. last.line .. "` (exit " .. last.status .. ", " .. last.took_ms .. " ms)")
		end
		table.insert(parts, "```")
		table.insert(parts, output)
		table.insert(parts, "```")
		start_thread(cx2, cwd, table.concat(parts, "\n"))
	end)
end

local function show_threads(cx: WindowCx)
	local cwd = focused_cwd(cx)
	if cwd == nil then
		cx:toast("error", "No directory", "Focus a shell in a T3 Code project first.")
		return
	end
	if cx:new_block(THREADS, { cwd }, "beside") == nil then
		cx:toast("error", "T3 Code plugin isn't loaded on this host", "Install it where your panes run.")
	end
end

local function open_app(cx: WindowCx)
	local cwd = focused_cwd(cx) or "."
	local err = common.run({ "app", cwd }, nil, function(result, cx2)
		if result.status ~= 0 and cx2 then
			cx2:toast("error", "Couldn't open T3 Code", common.why(result))
		end
	end)
	if err then
		cx:toast("error", "Couldn't start t3", err)
	end
end

local function has_cwd(cx: WindowCx): boolean
	return focused_cwd(cx) ~= nil
end

tern.command({ id = "new", title = "New T3 thread here", icon = "sparkle", available = has_cwd, run = new_thread })
tern.command({
	id = "ask",
	title = "Ask T3 about the last command",
	icon = "sparkle",
	available = has_cwd,
	run = ask_about_last,
})
tern.command({ id = "threads", title = "Show T3 threads", icon = "list", available = has_cwd, run = show_threads })
tern.command({ id = "app", title = "Open project in T3 Code", icon = "open", run = open_app })

-- `t3-thread://v1/<id>` links (T3 Code writes them in replies and `t3 thread
-- list` output) open a thread block; Cmd-click opens the thread in the app.
tern.route.link(function(link: LinkRequest, _cx: WindowCx): RouteDecision?
	local id = common.thread_id(link.url)
	if id == nil then
		return nil
	end
	if link.mods.cmd then
		local app = common.app_link(id)
		if app then
			return { url = app }
		end
	end
	return { block = THREAD, args = { id } }
end)

---------------------------------------------------------------------------
-- Status line: busy threads in the focused pane's project
---------------------------------------------------------------------------

type Counts = { live: number, waiting: number, project: boolean, at: number }

local counts: { [string]: Counts } = {}
local fetching: { [string]: boolean } = {}
local tick: TimerHandle? = nil

local function fetch(cwd: string)
	local known = counts[cwd]
	if fetching[cwd] or (known and not known.project and tern.now() - known.at < NOT_PROJECT_MS) then
		return
	end
	fetching[cwd] = true
	local err = common.run({ "thread", "list", "--project", cwd, "--json" }, nil, function(result, _cx)
		fetching[cwd] = nil
		local data = common.json(result)
		local c: Counts = { live = 0, waiting = 0, project = type(data) == "table", at = tern.now() }
		for _, t in (if type(data) == "table" then data else {}) do
			local status = if type(t) == "table" then tostring(t.status) else ""
			if common.live(status) then
				c.live += 1
			elseif common.waiting(status) then
				c.waiting += 1
			end
		end
		counts[cwd] = c
		tern.chrome.refresh()
	end)
	if err then
		fetching[cwd] = nil
	end
end

local function check_focused(cx: WindowCx)
	local cwd = focused_cwd(cx)
	if cwd then
		fetch(cwd)
	end
end

local function schedule()
	if tick then
		return
	end
	tick = tern.timer(TICK_MS, function(cx: WindowCx?)
		tick = nil
		if cx then
			check_focused(cx)
		end
		schedule()
	end)
end

tern.on("window_start", function(cx: WindowCx)
	check_focused(cx)
	schedule()
end)

tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
	check_focused(cx)
	schedule()
end)

tern.on("cwd", function(_ev: CwdEvent, cx: WindowCx)
	check_focused(cx)
end)

-- Answers from the cache only: the formatter has a 4 ms budget, so the timer
-- and events above run `t3` and call `tern.chrome.refresh()` when it changes.
tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local c = if pane.cwd then counts[pane.cwd] else nil
	if c == nil or (c.live == 0 and c.waiting == 0) then
		return nil
	end
	local parts = {}
	if c.live > 0 then
		table.insert(parts, c.live .. " running")
	end
	if c.waiting > 0 then
		table.insert(parts, c.waiting .. " waiting")
	end
	return {
		{
			text = "T3 " .. table.concat(parts, " · "),
			icon = if c.waiting > 0 then "help" else "sparkle",
			tone = if c.waiting > 0 then "warning" else "muted",
			command = "plugin.t3.threads",
		},
	}
end)
