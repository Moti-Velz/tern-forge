local ui = tern.ui
local Input = require("./input")

local function text(key, value, role)
	return ui.node("text", { key = key, text = value, role = role })
end

-- Everything that differs between the form's modes. The first field takes focus.
local MODES = {
	open = {
		heading = "Open worktree", submit = "Open", fields = { "query", "name" },
		help = function(state)
			local note = if state.note ~= "" then " " .. state.note else ""
			return state.project .. " · New branches start from " .. state.base .. "." .. note
		end,
	},
	rename = {
		heading = "Rename worktree", submit = "Save name", fields = { "name" },
		help = function(state)
			return "Display name only. Branch: " .. state.project .. ". Leave blank to use the branch name; Git and the directory stay unchanged."
		end,
	},
	base = {
		heading = "Change base branch", submit = "Save base branch", fields = { "base" },
		help = function(state)
			return state.project .. " · New worktrees branch from this local branch. Existing worktrees are unchanged."
		end,
	},
	linear = {
		heading = "Linear workspace", submit = "Save workspace", fields = { "linear" },
		help = function(state)
			return state.project .. " · Branches that name a ticket, such as feature/ENG-123, link to it in this workspace. Leave blank to use the Linear CLI's workspace."
		end,
	},
}

local function fieldOrder(state)
	return MODES[state.mode].fields
end

-- At most this many worktrees are suggested under the box.
local SUGGESTIONS = 8

-- The worktrees the box's text names: substring matches on branch, display name,
-- ticket, PR number and project, this project's first. Empty text lists this
-- project's worktrees.
local function suggestions(state)
	local query = string.lower(state.fields.query.text:match("^%s*(.-)%s*$"))
	local out = {}
	for _, c in state.candidates do
		local hay = string.lower(table.concat({
			c.branch or "", c.name or "", c.ticket or "", if c.pr then "#" .. tostring(c.pr) else "", c.project or "",
		}, " "))
		local hit = if query == "" then c.here else string.find(hay, query, 1, true) ~= nil
		if hit then
			table.insert(out, c)
			if #out >= SUGGESTIONS then break end
		end
	end
	return out
end

-- The row Enter acts on: 0 is "open or create what I typed", 1.. a suggestion.
-- Typing selects the first suggestion when it's in this project (they come
-- first); another project's worktree is only opened when picked.
local function resetSelection(state)
	local first = suggestions(state)[1]
	state.sel = if string.find(state.fields.query.text, "%S") and first and first.here then 1 else 0
end

local function focus(state, cx)
	pcall(function()
		cx:frame({ { "focus", "main." .. state.focus } })
	end)
end

local function finish(state, cancelled)
	if state.submitted then
		return
	end
	local response
	if cancelled then
		response = { cancelled = true }
	elseif state.mode == "rename" then
		response = { mode = "rename", name = state.fields.name.text }
	elseif state.mode == "base" then
		if not string.find(state.fields.base.text, "%S") then
			state.error = "Enter a local branch name."
			state.focus = "base"
			return
		end
		response = { mode = "base", base = state.fields.base.text }
	elseif state.mode == "linear" then
		response = { mode = "linear", linear = state.fields.linear.text }
	else
		local pick = state.sel > 0 and suggestions(state)[state.sel] or nil
		if pick then
			response = { mode = "open", path = pick.path }
		elseif not string.find(state.fields.query.text, "%S") then
			state.error = "Enter a branch, ticket or pull request, or pick a worktree."
			state.focus = "query"
			return
		else
			response = { mode = "open", query = state.fields.query.text, name = state.fields.name.text }
		end
	end
	local ok, err = pcall(tern.kv.set, "form:" .. state.token, response)
	if not ok then
		state.error = "Could not send form: " .. tostring(err)
		return
	end
	state.submitted, state.cancelled, state.error = true, cancelled, nil
end

tern.block.define("form", {
	init = function(_cx, args, saved)
		local mode = if MODES[args[2]] then args[2] else "open"
		local state = {
			token = args[1] or "", mode = mode, project = args[3] or "",
			base = args[4] or "master", note = args[5] or "",
			focus = MODES[mode].fields[1],
			submitted = false, cancelled = false, focusScheduled = false,
		}
		state.fields = {
			name = Input.new(if mode == "rename" then args[4] or "" else ""),
			query = Input.new(""),
			base = Input.new(if mode == "base" then args[4] or "" else ""),
			linear = Input.new(if mode == "linear" then args[4] or "" else ""),
		}
		if type(saved) == "table" and saved.token == state.token and saved.mode == mode then
			for name in pairs(state.fields) do
				if type(saved.fields) == "table" and type(saved.fields[name]) == "string" then
					state.fields[name] = Input.new(saved.fields[name])
				end
			end
			if state.fields[saved.focus] then
				state.focus = saved.focus
			end
			state.submitted = saved.submitted == true
			state.cancelled = saved.cancelled == true
		end
		-- The Open box's worktrees, put in kv by Forge's window half before opening the form.
		state.candidates = {}
		if mode == "open" and state.token ~= "" then
			local ok, list = pcall(tern.kv.get, "form-data:" .. state.token)
			if ok and type(list) == "table" then state.candidates = list end
		end
		state.sel = 0
		resetSelection(state)
		-- A restarted form must never publish its response a second time.
		if state.token == "" then
			state.error = "Missing form token. Close this pane and reopen the form from Projects."
			state.submitted = true
		else
			local ok, response = pcall(tern.kv.get, "form:" .. state.token)
			if ok and response ~= nil then
				state.submitted = true
				state.cancelled = type(response) == "table" and response.cancelled == true
			end
		end
		return state
	end,
	-- The form occupies the Projects panel's slot, so keep the panel's title.
	title = function()
		return "Projects"
	end,
	view = function(state, cx)
		local heading = MODES[state.mode].heading
		local children = {
			-- In a row so the link is only as wide as its text, not the whole pane.
			ui.node("row", { key = "nav" }, {
				ui.el("button", {
					key = "back", role = "forge.backLink", text = "← Projects",
					title = "Back to Projects (Esc)", actions = { click = "cancel" },
				}),
			}),
			text("heading", heading, "forge.formHeading"),
		}
		if state.submitted then
			table.insert(children, text("submitted", if state.cancelled then "Returning to Projects…" else "Working…", "forge.message"))
		else
			table.insert(children, text("help", MODES[state.mode].help(state), "forge.hint"))
			local labels = {
				name = if state.mode == "open" then "Display name for a new worktree (optional)" else "Display name (optional)",
				query = "Branch, ticket or pull request", base = "Base branch",
				linear = "Workspace URL or name",
			}
			local placeholders = {
				name = if state.mode == "rename" then state.project else "e.g. Fix onboarding",
				query = "branch · ENG-123 · #42 · link", base = "main", linear = "https://linear.app/your-team",
			}
			for _, name in ipairs(fieldOrder(state)) do
				table.insert(children, text(name .. "Label", labels[name], "forge.fieldLabel"))
				local props = Input.props(state.fields[name])
				props.key, props.role, props.aria = name, "forge.field", labels[name]
				props.placeholder = placeholders[name]
				table.insert(children, ui.node("input", props))
				if name == "query" then
					local typed = state.fields.query.text:match("^%s*(.-)%s*$")
					local rows = {}
					if typed ~= "" then
						table.insert(rows, ui.el("button", {
							key = "typed", role = if state.sel == 0 then "forge.suggestionOn" else "forge.suggestion",
							text = "↵ Open or create “" .. typed .. "”", actions = { click = "pick=0" },
						}))
					end
					for index, c in ipairs(suggestions(state)) do
						local meta = {}
						if c.name and c.name ~= c.branch then table.insert(meta, c.branch or "detached") end
						if c.ticket then table.insert(meta, c.ticket) end
						if c.pr then table.insert(meta, "#" .. tostring(c.pr) .. " " .. (c.prState or "")) end
						if not c.here then table.insert(meta, c.project) end
						if c.primary then table.insert(meta, "primary") end
						table.insert(rows, ui.el("button", {
							key = "s" .. index, role = if state.sel == index then "forge.suggestionOn" else "forge.suggestion",
							title = c.path, actions = { click = "pick=" .. index },
						}, {
							text("label", c.name or c.branch or "Detached HEAD", "forge.suggestionLabel"),
							text("meta", table.concat(meta, " · "), "forge.suggestionMeta"),
						}))
					end
					if #rows > 0 then
						table.insert(children, ui.node("col", { key = "suggestions", role = "forge.suggestions" }, rows))
					end
				end
			end
			table.insert(children, ui.node("row", { key = "buttons", role = "forge.formButtons" }, {
				ui.el("button", {
					key = "submit", role = "forge.primaryButton",
					text = MODES[state.mode].submit,
					actions = { click = "submit" },
				}),
			}))
			table.insert(children, text("keys", if state.mode == "open"
				then "↑↓ to choose · Enter to open · Esc to go back · Tab to the display name"
				else "Enter to submit · Esc to go back · Tab to change fields", "forge.hint"))
			if not state.focusScheduled then
				state.focusScheduled = true
				-- Timer executes after this view mounts; a closed pane safely ignores focus.
				tern.timer(30, function()
					if not state.submitted then
						focus(state, cx)
					end
				end)
			end
		end
		if state.error then
			table.insert(children, text("error", state.error, "forge.error"))
		end
		return { main = ui.node("col", { role = "forge.form" }, children) }
	end,
	key = function(state, key, cx)
		if state.submitted then
			return false
		end
		if key.name == "escape" or key.name == "esc" then
			finish(state, true)
		elseif key.name == "enter" then
			finish(state, false)
			if not state.submitted then focus(state, cx) end
		elseif state.mode == "open" and state.focus == "query" and (key.name == "up" or key.name == "down") then
			local count = #suggestions(state)
			local first = if string.find(state.fields.query.text, "%S") then 0 else 1
			if count == 0 then return false end
			state.sel = math.clamp(state.sel + (if key.name == "up" then -1 else 1), first, count)
		elseif key.name == "tab" then
			local order = fieldOrder(state)
			local index = table.find(order, state.focus) or 1
			state.focus = order[((index - 1 + (if key.shift then -1 else 1)) % #order) + 1]
			focus(state, cx)
		elseif key.meta and string.lower(key.name) == "c" then
			local selection = Input.selection(state.fields[state.focus])
			if selection == "" then return false end
			cx:copy(selection)
		else
			local before = state.fields[state.focus].text
			local handled, err = Input.key(state.fields[state.focus], key)
			if not handled then return false end
			state.error = err
			if state.focus == "query" and state.fields.query.text ~= before then resetSelection(state) end
			focus(state, cx)
		end
		return true
	end,
	event = function(state, event, cx)
		if event.ev == "action" and event.act == "retry" then
			state.submitted, state.cancelled = false, false
			state.error = if type(event.value) == "string" then event.value else "Please correct the form and try again."
			state.focusScheduled = false
			return
		end
		if state.submitted then return end
		if event.ev == "focus" then
			for _, name in ipairs(fieldOrder(state)) do
				if event.id == "main." .. name then
					state.focus = name
					focus(state, cx)
					break
				end
			end
		elseif event.ev == "action" then
			if event.act == "pick" then
				state.sel = tonumber(event.value) or 0
				finish(state, false)
			elseif event.act == "submit" then
				finish(state, false)
			elseif event.act == "cancel" then
				finish(state, true)
			end
			if not state.submitted then focus(state, cx) end
		end
	end,
	save = function(state)
		local fields = {}
		for name, field in pairs(state.fields) do fields[name] = field.text end
		return {
			token = state.token, mode = state.mode, focus = state.focus, fields = fields,
			submitted = state.submitted, cancelled = state.cancelled,
		}
	end,
})

-- The subscription usage block (`forge.usage`).
require("./usage/host")
