--!strict
-- The window half: palette commands that start and open T3 Code threads from
-- the focused pane, routing of `t3-thread://` links to thread blocks, and a
-- status line segment counting the focused project's busy threads.
--
-- Commands use the project holding the focused pane's directory, and ask
-- which project when it isn't in one.

local common = require("./common")

type Project = common.Project

local THREAD = "t3.thread"
local THREADS = "t3.threads"
-- How often the status line rechecks the focused pane's project, and how long
-- the project list is reused before it is read again.
local TICK_MS = 15 * 1000
local PROJECTS_MS = 60 * 1000
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

---------------------------------------------------------------------------
-- Projects
---------------------------------------------------------------------------

local projects: { Project }? = nil
local projects_at = -math.huge
local loading_projects: { (({ Project }?, string?, WindowCx?) -> ()) }? = nil

-- The project list, from the cache while it's fresh. Concurrent callers share
-- one read.
local function load_projects(done: ({ Project }?, string?, WindowCx?) -> ())
	if projects and tern.now() - projects_at < PROJECTS_MS then
		done(projects, nil, nil)
		return
	end
	if loading_projects then
		table.insert(loading_projects, done)
		return
	end
	local waiting = { done }
	loading_projects = waiting
	common.projects(function(list, err, cx)
		loading_projects = nil
		if list then
			projects = list
			projects_at = tern.now()
		end
		for _, fn in waiting do
			fn(list or projects, err, cx)
		end
	end)
end

-- Calls `fn` with the project holding `cwd`, or the one the user picks when
-- no project holds it. `cx` is used only until the first callback returns.
local function with_project(cx: WindowCx, cwd: string?, fn: (Project, WindowCx) -> ())
	load_projects(function(list, err, cx2)
		local c = cx2 or cx
		if list == nil or #list == 0 then
			c:toast("error", "No T3 Code projects", err or "Add one with `t3 project add <dir>`.")
			return
		end
		local match = if cwd then common.project_for(list, cwd) else nil
		if match then
			fn(match, c)
			return
		end
		local items: { PickItem } = {}
		for _, p in list do
			table.insert(items, { label = p.title, detail = p.root, icon = "folder", project = p })
		end
		c:pick({ items = items, placeholder = "T3 Code project", icon = "sparkle", action = "use" })
			:next(function(item, _err, cx3)
				if item and cx3 then
					fn(item.project :: Project, cx3)
				end
			end)
	end)
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

-- Starts a thread in `project` with `message` and opens it beside.
local function start_thread(cx: WindowCx, project: Project, message: string)
	local err = common.run({ "thread", "start", project.id, "-" }, message, function(result, cx2)
		if cx2 == nil then
			return
		end
		if result.status ~= 0 then
			cx2:toast("error", "T3 didn't start the thread", common.why(result))
			return
		end
		local id = first_line(result.stdout)
		if cx2:new_block(THREAD, { id }, "beside") == nil then
			cx2:toast("success", "Thread started in " .. project.title, id)
		end
	end)
	if err then
		cx:toast("error", "Couldn't start t3", err)
	end
end

local function new_thread(cx: WindowCx)
	with_project(cx, focused_cwd(cx), function(project, cx2)
		cx2:prompt({ placeholder = "Message for a new thread in " .. project.title, icon = "sparkle", action = "start" })
			:next(function(text, _err, cx3)
				if text and cx3 and string.find(text, "%S") then
					start_thread(cx3, project, text)
				end
			end)
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
	if pane == nil then
		return
	end
	-- Read the pane now: the cx is gone once the picker or prompt answers.
	local cwd = if pane.cwd and pane.cwd ~= "" then pane.cwd else nil
	local last = pane.last
	local output = recent_output(cx, pane.pane)
	local suggestion = if last and last.status ~= 0 then "Why did this fail? Fix it." else ""
	with_project(cx, cwd, function(project, cx2)
		cx2:prompt({
			value = suggestion,
			placeholder = "What should T3 do with this output?",
			icon = "sparkle",
			action = "start",
		}):next(function(text, _err, cx3)
			if text == nil or cx3 == nil then
				return
			end
			local parts = { text, "", "From my terminal in `" .. (cwd or project.root) .. "`:" }
			if last then
				table.insert(parts, "Last command: `" .. last.line .. "` (exit " .. last.status .. ", " .. last.took_ms .. " ms)")
			end
			table.insert(parts, "```")
			table.insert(parts, output)
			table.insert(parts, "```")
			start_thread(cx3, project, table.concat(parts, "\n"))
		end)
	end)
end

local function show_threads(cx: WindowCx)
	with_project(cx, focused_cwd(cx), function(project, cx2)
		if cx2:new_block(THREADS, { project.id, project.title }, "beside") == nil then
			cx2:toast("error", "T3 Code plugin isn't loaded on this host", "Install it where your panes run.")
		end
	end)
end

local function open_app(cx: WindowCx)
	with_project(cx, focused_cwd(cx), function(project, cx2)
		local err = common.run({ "app", project.root }, nil, function(result, cx3)
			if result.status ~= 0 and cx3 then
				cx3:toast("error", "Couldn't open T3 Code", common.why(result))
			end
		end)
		if err then
			cx2:toast("error", "Couldn't start t3", err)
		end
	end)
end

tern.command({ id = "new", title = "New T3 thread", icon = "sparkle", run = new_thread })
tern.command({ id = "ask", title = "Ask T3 about the last command", icon = "sparkle", run = ask_about_last })
tern.command({ id = "threads", title = "Show T3 threads", icon = "list", run = show_threads })
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

type Counts = { live: number, waiting: number }

-- By project id.
local counts: { [string]: Counts } = {}
local fetching: { [string]: boolean } = {}
local tick: TimerHandle? = nil

local function fetch(project: Project)
	if fetching[project.id] then
		return
	end
	fetching[project.id] = true
	local err = common.run({ "thread", "list", "--project", project.id, "--json" }, nil, function(result, _cx)
		fetching[project.id] = nil
		local data = common.json(result)
		local c: Counts = { live = 0, waiting = 0 }
		for _, t in (if type(data) == "table" then data else {}) do
			local status = if type(t) == "table" then tostring(t.status) else ""
			if common.live(status) then
				c.live += 1
			elseif common.waiting(status) then
				c.waiting += 1
			end
		end
		counts[project.id] = c
		tern.chrome.refresh()
	end)
	if err then
		fetching[project.id] = nil
	end
end

-- Only directories inside a project cost a `t3` run.
local function check_focused(cx: WindowCx)
	local cwd = focused_cwd(cx)
	if cwd == nil then
		return
	end
	load_projects(function(list)
		local project = if list then common.project_for(list, cwd) else nil
		if project then
			fetch(project)
		end
	end)
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

-- Answers from the caches only: the formatter has a 4 ms budget, so the timer
-- and events above run `t3` and call `tern.chrome.refresh()` when it changes.
tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local project = if projects and pane.cwd then common.project_for(projects, pane.cwd) else nil
	local c = if project then counts[project.id] else nil
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
