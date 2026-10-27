--!strict
-- The host half: two blocks over the `t3` CLI.
--
-- `t3.threads` lists a project's threads, newest first. ↑/↓ (or k/j) move,
-- Enter opens the thread in a block, `a` opens it in the T3 Code app,
-- `r` refreshes.
--
-- `t3.thread` shows one thread's latest messages and a composer: type, then
-- Enter sends (Alt+Enter adds a line, Esc clears).
--
-- Both poll: every few seconds while an agent works, slower otherwise.

local common = require("./common")
local ui = tern.ui

local FAST_MS = 3 * 1000
local SLOW_MS = 15 * 1000
local MESSAGES = "30"

type Problem = { text: string, detail: string? }

-- Blocks have no close hook: a state is current while `running` maps its
-- pane to it and the pane still exists. Restart reuses the pane id, so the
-- state object, not the pane, identifies a run.
local running: { [number]: any } = {}

local function alive(state: any): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	running[state.cx.pane] = nil
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	return false
end

local function claim(cx: BlockCx, state: any)
	local previous = running[cx.pane]
	if previous and previous.timer then
		previous.timer:cancel()
		previous.timer = nil
	end
	running[cx.pane] = state
end

local function button(label: string, act: string, tone: string): Node
	local node = ui.badge(label, tone)
	local p: { [string]: any } = node.p or {}
	p.actions = { click = act }
	node.p = p
	return node
end

local function problem_card(head: string, problem: Problem): Node
	local children: { Node } = { ui.md(problem.text) }
	if problem.detail and problem.detail ~= "" then
		table.insert(children, ui.code(problem.detail))
	end
	table.insert(children, ui.row({ button("Retry", "refresh", "accent") }))
	local card = ui.card({ ui.span(head, "strong") }, children)
	local p: { [string]: any } = card.p or {}
	p.tone = "error"
	card.p = p
	return card
end

local function spawn_problem(err: string): Problem
	return {
		text = "Tern could not start the `t3` CLI. Install T3 Code (it puts `t3` in `~/.t3/bin`), then retry.",
		detail = err,
	}
end

-- Schedules the next refresh: fast while any agent works.
local function poll(state: any, busy: boolean, refresh: (any) -> ())
	if state.timer then
		state.timer:cancel()
	end
	state.timer = tern.timer(if busy then FAST_MS else SLOW_MS, function()
		state.timer = nil
		if alive(state) then
			refresh(state)
		end
	end)
end

---------------------------------------------------------------------------
-- t3.threads
---------------------------------------------------------------------------

type ThreadRow = {
	id: string,
	title: string,
	status: string,
	model: string,
	updated: number,
	prs: number,
}

type ListState = {
	cx: BlockCx,
	-- A project id, or a path `t3` resolves to one.
	project: string,
	name: string,
	-- Set when `project` isn't in a T3 Code project: the projects to choose from.
	choices: { common.Project }?,
	choice: string?,
	threads: { ThreadRow }?,
	cursor: string?,
	loading: boolean,
	problem: Problem?,
	timer: TimerHandle?,
}

local LIST_ID = "main.threads."

local function rows_of(data: any): { ThreadRow }?
	if type(data) ~= "table" then
		return nil
	end
	local rows: { ThreadRow } = {}
	for _, t in data do
		if type(t) == "table" and type(t.threadId) == "string" then
			table.insert(rows, {
				id = t.threadId,
				title = tostring(t.title or "Untitled"),
				status = tostring(t.status or "idle"),
				model = tostring(t.model or ""),
				updated = common.epoch(tostring(t.updatedAt or "")) or 0,
				prs = if type(t.pullRequests) == "table" then #t.pullRequests else 0,
			})
		end
	end
	table.sort(rows, function(a, b)
		return a.updated > b.updated
	end)
	return rows
end

local function refresh_list(state: ListState)
	if not alive(state) or state.loading then
		return
	end
	state.loading = true
	local err = common.run({ "thread", "list", "--project", state.project, "--json" }, nil, function(result)
		if not alive(state) then
			return
		end
		state.loading = false
		local rows = rows_of(common.json(result))
		local busy = false
		if rows then
			state.threads = rows
			state.problem = nil
			local found = false
			for _, r in rows do
				found = found or r.id == state.cursor
				busy = busy or common.live(r.status)
			end
			if not found then
				state.cursor = if rows[1] then rows[1].id else nil
			end
		else
			local why = common.why(result)
			if string.find(why, "No T3 Code project", 1, true) then
				-- Not a project folder: offer the projects instead of failing.
				common.projects(function(projects, err)
					if not alive(state) then
						return
					end
					if projects and #projects > 0 then
						state.choices = projects
						state.choice = projects[1].id
						state.problem = nil
					else
						state.problem = { text = "`" .. state.project .. "` isn't in a T3 Code project.", detail = err or why }
					end
					state.cx:render()
				end)
				return
			end
			state.problem = { text = "`t3 thread list` failed for `" .. state.name .. "`.", detail = why }
		end
		state.cx:render()
		poll(state, busy, refresh_list)
	end)
	if err then
		state.loading = false
		state.problem = spawn_problem(err)
	end
end

local function rows(state: ListState): { ThreadRow }
	return state.threads or {}
end

local function cursor_index(state: ListState): number
	for i, r in rows(state) do
		if r.id == state.cursor then
			return i
		end
	end
	return 0
end

local function selected(state: ListState): ThreadRow?
	return rows(state)[cursor_index(state)]
end

local function open_in_app(cx: BlockCx, id: string)
	local link = common.app_link(id)
	if link then
		cx:open(link)
	else
		cx:toast("error", "No local T3 Code environment", "Couldn't read ~/.t3/userdata/environment-id.")
	end
end

local function list_view(state: ListState): Node
	local items: { Item } = {}
	for _, r in rows(state) do
		local value: { Span | string } = {}
		if r.prs > 0 then
			table.insert(value, ui.span(r.prs .. " PR  ", "muted"))
		end
		table.insert(value, ui.span(r.status .. "  ", common.tone(r.status)))
		table.insert(value, ui.span(common.age(r.updated), "muted num"))
		table.insert(items, {
			label = { ui.span(r.title) },
			value = value,
			icon = common.icon(r.status),
			tone = if common.live(r.status) or common.waiting(r.status) then common.tone(r.status) else nil,
		})
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, r in rows(state) do
		local p: { [string]: any } = kids[i].p or {}
		p.key = r.id
		kids[i].p = p
	end
	local p: { [string]: any } = list.p or {}
	p.key = "threads"
	p.selected = if state.cursor then LIST_ID .. state.cursor else nil
	p.empty = { ui.span("No threads in this project yet.", "muted") }
	p.max = { lines = math.max(4, math.floor((state.cx.rows - 4) * 0.72)) }
	list.p = p
	return list
end

local function list_dock(state: ListState): Node
	local live, waiting = 0, 0
	for _, r in rows(state) do
		if common.live(r.status) then
			live += 1
		elseif common.waiting(r.status) then
			waiting += 1
		end
	end
	local status: { Span | string } = { ui.span(#rows(state) .. " threads", "strong") }
	if live > 0 then
		table.insert(status, ui.span("  " .. live .. " running", "accent"))
	end
	if waiting > 0 then
		table.insert(status, ui.span("  " .. waiting .. " waiting on you", "warning"))
	end
	return ui.col({
		ui.lines({
			ui.text(status),
			ui.text({ ui.span("↵ open   a in T3 Code   r refresh", "muted") }),
		}),
	})
end

local PROJECTS_ID = "main.projects."

local function choices(state: ListState): { common.Project }
	return state.choices or {}
end

-- The projects to choose from when the block's folder isn't in one.
local function choices_view(state: ListState): Node
	local items: { Item } = {}
	for _, pr in choices(state) do
		table.insert(items, { label = { ui.span(pr.title) }, value = { ui.span(pr.root, "muted") }, icon = "folder" })
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, pr in choices(state) do
		local p: { [string]: any } = kids[i].p or {}
		p.key = pr.id
		kids[i].p = p
	end
	local p: { [string]: any } = list.p or {}
	p.key = "projects"
	p.selected = if state.choice then PROJECTS_ID .. state.choice else nil
	p.max = { lines = math.max(4, math.floor((state.cx.rows - 6) * 0.72)) }
	list.p = p
	local head = ui.text({ ui.span("`" .. state.name .. "` isn't in a T3 Code project. Pick one:", "muted") })
	return ui.col({ head, list })
end

local function choose(state: ListState, id: string?)
	for _, pr in choices(state) do
		if pr.id == id then
			state.project = pr.id
			state.name = pr.title
			state.choices = nil
			state.choice = nil
			state.cx:save()
			refresh_list(state)
			return
		end
	end
end

local function choice_key(state: ListState, key: Key): boolean?
	local list = choices(state)
	local i = 0
	for n, pr in list do
		if pr.id == state.choice then
			i = n
		end
	end
	local k = key.text or key.name
	local to: number? = nil
	if key.name == "up" or k == "k" then
		to = i - 1
	elseif key.name == "down" or k == "j" then
		to = i + 1
	elseif key.name == "home" or k == "g" then
		to = 1
	elseif key.name == "end" or k == "G" then
		to = #list
	elseif key.name == "enter" or k == "o" then
		choose(state, state.choice)
		return true
	end
	if to == nil then
		return false
	end
	local pr = list[math.clamp(to, 1, math.max(1, #list))]
	if pr then
		state.choice = pr.id
	end
	return true
end

local function move(state: ListState, to: number)
	local list = rows(state)
	local r = list[math.clamp(to, 1, math.max(1, #list))]
	if r then
		state.cursor = r.id
	end
end

tern.block.define("threads", {
	init = function(cx: BlockCx, args: { string }, saved: any): ListState
		local old = if type(saved) == "table" then saved else {}
		local project = args[1] or (if type(old.project) == "string" then old.project else nil) or cx.cwd or "."
		local name = args[2]
			or (if args[1] == nil and type(old.name) == "string" then old.name else nil)
			or string.match(project, "([^/]+)/?$")
			or project
		local state: ListState = {
			cx = cx,
			project = project,
			name = name,
			choices = nil,
			choice = nil,
			threads = nil,
			cursor = nil,
			loading = false,
			problem = nil,
			timer = nil,
		}
		claim(cx, state)
		refresh_list(state)
		return state
	end,

	title = function(state: ListState): string?
		return "T3 · " .. state.name
	end,

	view = function(state: ListState, _cx: BlockCx): BlockView
		if state.choices then
			return { main = ui.col({ choices_view(state) }) }
		elseif state.threads then
			return { main = ui.col({ list_view(state) }), dock = list_dock(state) }
		elseif state.problem then
			return { main = ui.col({ problem_card("Could not load threads", state.problem) }) }
		end
		return { main = ui.col({ ui.progress(nil, "Loading threads…") }) }
	end,

	key = function(state: ListState, key: Key, cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		if state.choices then
			return choice_key(state, key)
		end
		local i = cursor_index(state)
		local k = key.text or key.name
		if key.name == "up" or k == "k" then
			move(state, i - 1)
		elseif key.name == "down" or k == "j" then
			move(state, i + 1)
		elseif key.name == "home" or k == "g" then
			move(state, 1)
		elseif key.name == "end" or k == "G" then
			move(state, #rows(state))
		elseif key.name == "enter" or k == "o" then
			local r = selected(state)
			if r then
				cx:open(common.thread_link(r.id))
			end
			return false
		elseif k == "a" then
			local r = selected(state)
			if r then
				open_in_app(cx, r.id)
			end
			return false
		elseif k == "r" then
			refresh_list(state)
		else
			return false
		end
		return true
	end,

	event = function(state: ListState, ev: UiEvent, cx: BlockCx)
		if ev.ev == "action" and ev.act == "refresh" then
			refresh_list(state)
		elseif (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" and state.choices then
			state.choice = string.sub(ev.item, #PROJECTS_ID + 1)
			if ev.ev == "activate" then
				choose(state, state.choice)
			end
		elseif (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			state.cursor = string.sub(ev.item, #LIST_ID + 1)
			if ev.ev == "activate" then
				cx:open(common.thread_link(state.cursor :: string))
			end
		end
	end,

	save = function(state: ListState): any
		return { project = state.project, name = state.name }
	end,
})

---------------------------------------------------------------------------
-- t3.thread
---------------------------------------------------------------------------

type Message = { role: string, text: string }

type Thread = {
	title: string,
	status: string,
	model: string,
	branch: string?,
	pending: number,
	prs: { { label: string, url: string, state: string } },
}

type ThreadState = {
	cx: BlockCx,
	id: string,
	thread: Thread?,
	messages: { Message },
	draft: string,
	sending: boolean,
	loading: boolean,
	problem: Problem?,
	timer: TimerHandle?,
}

local function thread_of(t: any): Thread
	local prs = {}
	if type(t.pullRequests) == "table" then
		for _, pr in t.pullRequests do
			if type(pr) == "table" and type(pr.url) == "string" then
				table.insert(prs, {
					label = tostring(pr.repository or "PR") .. "#" .. tostring(pr.number or "?"),
					url = pr.url,
					state = tostring(pr.state or ""),
				})
			end
		end
	end
	return {
		title = tostring(t.title or "Untitled"),
		status = tostring(t.status or "idle"),
		model = tostring(t.model or ""),
		branch = if type(t.branch) == "string" then t.branch else nil,
		pending = tonumber(t.pendingRequestCount) or 0,
		prs = prs,
	}
end

local function refresh_thread(state: ThreadState)
	if not alive(state) or state.loading then
		return
	end
	state.loading = true
	local args = { "thread", "show", state.id, "--json", "--messages", MESSAGES }
	local err = common.run(args, nil, function(result)
		if not alive(state) then
			return
		end
		state.loading = false
		local data = common.json(result)
		if type(data) == "table" and type(data.thread) == "table" then
			state.thread = thread_of(data.thread)
			local messages: { Message } = {}
			for _, m in (if type(data.messages) == "table" then data.messages else {}) do
				if type(m) == "table" and type(m.text) == "string" then
					table.insert(messages, { role = tostring(m.role or "assistant"), text = m.text })
				end
			end
			state.messages = messages
			state.problem = nil
		else
			state.problem = { text = "`t3 thread show` failed for this thread.", detail = common.why(result) }
		end
		state.cx:render()
		local thread = state.thread
		poll(state, thread ~= nil and common.live(thread.status), refresh_thread)
	end)
	if err then
		state.loading = false
		state.problem = spawn_problem(err)
	end
end

local function send(state: ThreadState)
	local text = string.match(state.draft, "^%s*(.-)%s*$") or ""
	if text == "" or state.sending then
		return
	end
	state.sending = true
	-- `-` reads the message from stdin, so it can hold anything.
	local err = common.run({ "thread", "send", state.id, "-" }, text, function(result)
		if not alive(state) then
			return
		end
		state.sending = false
		if result.status == 0 then
			state.draft = ""
			table.insert(state.messages, { role = "user", text = text })
			state.cx:save()
			refresh_thread(state)
		else
			state.cx:toast("error", "T3 didn't take the message", common.why(result))
		end
		state.cx:render()
	end)
	if err then
		state.sending = false
		state.cx:toast("error", "Couldn't start t3", err)
	end
end

-- Title, a status line, and one clickable row per pull request (a row of
-- badges doesn't wrap in a narrow pane).
local function header(thread: Thread): Node
	local meta: { Span | string } = { ui.span(thread.status, common.tone(thread.status)) }
	if thread.pending > 0 then
		table.insert(meta, ui.span("  waiting on you in the app", "warning"))
	end
	if thread.model ~= "" then
		table.insert(meta, ui.span("  " .. thread.model, "muted"))
	end
	if thread.branch then
		table.insert(meta, ui.span("  " .. thread.branch, "muted"))
	end
	local rows: { Node } = { ui.text({ ui.span(thread.title, "strong") }), ui.text(meta) }
	for _, pr in thread.prs do
		local b = ui.badge(pr.label .. " " .. pr.state, if pr.state == "merged" then "success" else "accent")
		local p: { [string]: any } = b.p or {}
		p.actions = { click = "pr=" .. pr.url }
		b.p = p
		table.insert(rows, ui.row({ b }))
	end
	return ui.col(rows)
end

-- Messages before the last `OPEN_MESSAGES` start folded to their first line,
-- so a long thread opens near its end.
local OPEN_MESSAGES = 2
local PREVIEW_CHARS = 60

local function message_node(m: Message, folded: boolean): Node
	local who = if m.role == "user" then ui.span("You", "accent strong") else ui.span("Agent", "muted strong")
	local head: { Span | string } = { who }
	if folded then
		local first = string.match(m.text, "^%s*([^\n]*)") or ""
		local cut = utf8.offset(first, PREVIEW_CHARS + 1)
		if cut then
			first = string.sub(first, 1, cut - 1) .. "…"
		end
		table.insert(head, ui.span("  " .. first, "muted"))
	end
	local node = ui.section(head, { ui.md(m.text) })
	local p: { [string]: any } = node.p or {}
	p.collapsible = true
	p.collapsed = folded
	node.p = p
	return node
end

local function composer(state: ThreadState): Node
	local line: { Span | string } = { ui.span("› ", "accent") }
	if state.sending then
		table.insert(line, ui.span(state.draft .. "  sending…", "muted"))
	elseif state.draft == "" then
		table.insert(line, ui.span("Type a message, ↵ to send", "muted"))
	else
		table.insert(line, ui.span(state.draft))
		table.insert(line, ui.span("▌", "accent"))
	end
	return ui.col({ ui.row({ button("Open in T3 Code", "app", "accent") }), ui.text(line) })
end

-- Drops the last UTF-8 character.
local function backspace(s: string): string
	local at = utf8.offset(s, -1)
	return if at then string.sub(s, 1, at - 1) else ""
end

tern.block.define("thread", {
	init = function(cx: BlockCx, args: { string }, saved: any): ThreadState
		local id = args[1] or (if type(saved) == "table" then saved.id else nil) or ""
		local state: ThreadState = {
			cx = cx,
			id = id,
			thread = nil,
			messages = {},
			draft = if type(saved) == "table" and type(saved.draft) == "string" then saved.draft else "",
			sending = false,
			loading = false,
			problem = nil,
			timer = nil,
		}
		claim(cx, state)
		if id == "" then
			state.problem = { text = "This block was opened without a thread id." }
		else
			refresh_thread(state)
		end
		return state
	end,

	title = function(state: ThreadState): string?
		local thread = state.thread
		if thread == nil then
			return "T3 Thread"
		end
		local mark = if common.live(thread.status) then "● " elseif common.waiting(thread.status) then "? " else ""
		return mark .. thread.title
	end,

	view = function(state: ThreadState, _cx: BlockCx): BlockView
		local thread = state.thread
		if thread == nil then
			if state.problem then
				return { main = ui.col({ problem_card("Could not load the thread", state.problem) }) }
			end
			return { main = ui.col({ ui.progress(nil, "Loading thread…") }) }
		end
		local main: { Node } = { header(thread) }
		if state.problem then
			table.insert(main, problem_card("Refresh failed", state.problem))
		end
		for i, m in state.messages do
			table.insert(main, message_node(m, i <= #state.messages - OPEN_MESSAGES))
		end
		if common.live(thread.status) then
			table.insert(main, ui.progress(nil, "Agent is working…"))
		end
		return { main = ui.col(main), dock = composer(state) }
	end,

	key = function(state: ThreadState, key: Key, _cx: BlockCx): boolean?
		if key.name == "paste" and key.text then
			state.draft ..= key.text
		elseif key.name == "enter" and key.alt then
			state.draft ..= "\n"
		elseif key.name == "enter" then
			send(state)
		elseif key.name == "backspace" then
			if state.draft == "" then
				return false
			end
			state.draft = backspace(state.draft)
		elseif key.name == "escape" or (key.ctrl and key.name == "u") then
			if state.draft == "" then
				return false
			end
			state.draft = ""
		elseif key.text and not (key.ctrl or key.meta) then
			state.draft ..= key.text
		else
			return false
		end
		return true
	end,

	event = function(state: ThreadState, ev: UiEvent, cx: BlockCx)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "refresh" then
			refresh_thread(state)
		elseif ev.act == "app" then
			open_in_app(cx, state.id)
		elseif ev.act == "pr" and type(ev.value) == "string" then
			cx:open(ev.value)
		end
	end,

	save = function(state: ThreadState): any
		return { id = state.id, draft = state.draft }
	end,
})
