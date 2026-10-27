--!strict
-- Shared by both halves: finding and running the `t3` CLI, T3 Code's thread
-- statuses, and the links that point at a thread.

local M = {}

local TIMEOUT_MS = 30 * 1000

local function home(): string
	return tern.getenv("HOME") or ""
end

-- T3 Code's data directory: T3CODE_HOME when set, else ~/.t3.
local function t3_home(): string
	return tern.getenv("T3CODE_HOME") or (home() .. "/.t3")
end

-- `t3` by name first, then where the desktop app and Homebrew put it: a
-- daemon started by launchd often has a PATH without those directories.
local function candidates(): { string }
	return { "t3", t3_home() .. "/bin/t3", "/opt/homebrew/bin/t3", "/usr/local/bin/t3" }
end

-- Runs `t3 <args>` off the calling thread; `done(result, cx?)` gets the
-- process result. Returns the spawn error of the last attempt when no
-- candidate starts.
function M.run(args: { string }, stdin: string?, done: (ProcessResult, WindowCx?) -> ()): string?
	local last = "t3 is not on this machine's PATH"
	for _, t3 in candidates() do
		if t3 == "t3" or tern.fs.exists(t3) then
			local argv: { string } = { t3 }
			for _, a in args do
				table.insert(argv, a)
			end
			local opts: ProcessOptions = { timeout_ms = TIMEOUT_MS, stdin = stdin, env = { NO_COLOR = "1" } }
			local ok, err = pcall(function()
				tern.process.run(argv, opts, done)
			end)
			if ok then
				return nil
			end
			last = tostring(err)
		end
	end
	return last
end

-- The first few non-empty lines of a failed run's output, for a toast or a card.
function M.why(result: ProcessResult): string
	if result.timed_out then
		return "t3 did not answer within 30 seconds."
	end
	local text = if result.stderr ~= "" then result.stderr else result.stdout
	local out = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(out, line)
		if #out == 4 then
			break
		end
	end
	if #out == 0 then
		return "t3 exited with status " .. result.status .. "."
	end
	return table.concat(out, "\n")
end

-- Decoded JSON output, or nil when the run failed or printed something else.
function M.json(result: ProcessResult): any
	if result.status ~= 0 then
		return nil
	end
	local ok, data = pcall(tern.json.decode, result.stdout)
	return if ok then data else nil
end

export type Project = { id: string, title: string, root: string }

local PROJECTS_SQL = "select project_id as id, title, workspace_root as root from projection_projects "
	.. "where deleted_at is null order by updated_at desc"

-- T3 Code's projects, most recently used first. The CLI can add, remove and
-- rename projects but not list them, so this reads T3 Code's state database
-- read-only. `done(nil, why)` when it can't.
function M.projects(done: ({ Project }?, string?, WindowCx?) -> ())
	local db = t3_home() .. "/userdata/statev2.sqlite"
	local argv = { "/usr/bin/sqlite3", "-readonly", "-json", db, PROJECTS_SQL }
	local ok, err = pcall(function()
		tern.process.run(argv, { timeout_ms = 5000 }, function(result: ProcessResult, cx: WindowCx?)
			if result.status ~= 0 then
				done(nil, M.why(result), cx)
				return
			end
			-- sqlite3 prints nothing at all for an empty result.
			local decoded, data = pcall(tern.json.decode, if result.stdout == "" then "[]" else result.stdout)
			if not decoded or type(data) ~= "table" then
				done(nil, "sqlite3 printed something other than a list of projects.", cx)
				return
			end
			local projects: { Project } = {}
			for _, row in data do
				if type(row) == "table" and type(row.id) == "string" and type(row.root) == "string" then
					table.insert(projects, { id = row.id, title = tostring(row.title or row.root), root = row.root })
				end
			end
			done(projects, nil, cx)
		end)
	end)
	if not ok then
		done(nil, tostring(err), nil)
	end
end

-- The project whose folder holds `path`, the deepest when they nest.
function M.project_for(projects: { Project }, path: string): Project?
	local best: Project? = nil
	for _, p in projects do
		local root = string.gsub(p.root, "/$", "")
		if path == root or string.sub(path, 1, #root + 1) == root .. "/" then
			if best == nil or #root > #best.root then
				best = p
			end
		end
	end
	return best
end

-- Statuses of a thread whose agent is working.
local LIVE = { queued = true, preparing = true, starting = true, running = true }

function M.live(status: string): boolean
	return LIVE[status] == true
end

-- `waiting` means the agent asked something only the app can answer.
function M.waiting(status: string): boolean
	return status == "waiting"
end

function M.tone(status: string): string
	if LIVE[status] then
		return "accent"
	elseif status == "waiting" then
		return "warning"
	elseif status == "failed" or status == "interrupted" or status == "cancelled" then
		return "error"
	elseif status == "completed" then
		return "success"
	end
	return "muted"
end

function M.icon(status: string): string
	if LIVE[status] then
		return "activity"
	elseif status == "waiting" then
		return "help"
	elseif status == "failed" then
		return "x-circle"
	elseif status == "interrupted" or status == "cancelled" then
		return "stop"
	elseif status == "completed" then
		return "check"
	end
	return "message"
end

-- The link T3 Code writes for a thread (`t3-thread://v1/<id>`); this
-- plugin routes it to a thread block.
function M.thread_link(id: string): string
	return "t3-thread://v1/" .. id
end

-- The thread id in a `t3-thread://` link, or nil.
function M.thread_id(url: string): string?
	return string.match(url, "^t3%-thread://v1/([%w%-]+)/?$")
end

-- The desktop app's deep link to a thread: `t3code://threads/<env>/<id>`.
-- Nil when this machine has no local environment id.
function M.app_link(id: string): string?
	local ok, env = pcall(tern.fs.read, t3_home() .. "/userdata/environment-id", 256)
	if not ok then
		return nil
	end
	local trimmed = string.match(env, "^%s*(.-)%s*$")
	if trimmed == nil or trimmed == "" then
		return nil
	end
	return "t3code://threads/" .. trimmed .. "/" .. id
end

-- Seconds since the epoch of an ISO 8601 UTC time (`2026-10-27T18:04:12.336Z`),
-- by the days-from-civil algorithm: `os.time` with a table reads local time.
function M.epoch(iso: string): number?
	local y, m, d, hh, mm, ss = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not (y and m and d and hh and mm and ss) then
		return nil
	end
	local year, month, day = tonumber(y) :: number, tonumber(m) :: number, tonumber(d) :: number
	if month <= 2 then
		year -= 1
	end
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * (if month > 2 then month - 3 else month + 9) + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	return days * 86400 + (tonumber(hh) :: number) * 3600 + (tonumber(mm) :: number) * 60 + (tonumber(ss) :: number)
end

-- How long ago `t` was, compactly: `now`, `12m`, `5h`, `3d`.
function M.age(t: number): string
	local s = math.max(0, os.time() - t)
	if s < 60 then
		return "now"
	elseif s < 3600 then
		return s // 60 .. "m"
	elseif s < 86400 then
		return s // 3600 .. "h"
	end
	return s // 86400 .. "d"
end

return M
