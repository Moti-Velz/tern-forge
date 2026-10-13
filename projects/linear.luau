--!nonstrict
-- Linear over its GraphQL API with a personal API key (Settings → Security & access
-- → Personal API keys), kept in the system keychain as this plugin's secret
-- `linear-api-key`. Reads the issues assigned to you, moves a ticket's status
-- forward, and creates issues. Window half only.

local M = {}

-- FORGE_LINEAR_ENDPOINT points Forge at another GraphQL server (a local stand-in for tests).
local ENDPOINT = tern.getenv("FORGE_LINEAR_ENDPOINT") or "https://api.linear.app/graphql"
local SECRET = "linear-api-key"

-- The key: nil until read from the keychain, false when there is none.
local key = nil
-- The signed-in user, cached after the first lookup: { id, name, workspace, teams = {{id, key, name}} }.
local viewer = nil

local function deferred(done, err)
	tern.timer(0, function(cx) done(nil, err, cx) end)
end

local function request(query, variables, done)
	if type(key) ~= "string" then deferred(done, "Linear isn't connected. Run “Forge: Connect Linear”."); return end
	tern.fetch(ENDPOINT, {
		method = "POST",
		headers = { Authorization = key, ["Content-Type"] = "application/json" },
		body = tern.json.encode({ query = query, variables = variables or {} }),
		timeout_ms = 20000,
	}, function(r, cx)
		if r.error then
			done(nil, if r.timed_out then "Linear didn't answer in time" else "Can't reach Linear: " .. r.error, cx)
			return
		end
		local ok, value = pcall(tern.json.decode, r.body)
		if r.status == 401 or r.status == 400 and ok and type(value) == "table"
			and type(value.errors) == "table" and value.errors[1]
			and tostring(value.errors[1].message):find("[Aa]uthentication") then
			done(nil, "Linear rejected the API key. Run “Forge: Connect Linear” again.", cx)
			return
		end
		if not ok or type(value) ~= "table" then
			done(nil, "Linear returned an unexpected response (" .. tostring(r.status) .. ")", cx)
			return
		end
		if type(value.errors) == "table" and value.errors[1] then
			done(nil, "Linear: " .. tostring(value.errors[1].message), cx)
			return
		end
		done(value.data, nil, cx)
	end)
end

-- Reads the key from the keychain once. done(connected, cx)
function M.load(done)
	if key ~= nil then tern.timer(0, function(cx) done(key ~= false, cx) end); return end
	tern.secrets.get(SECRET):next(function(value, _err, cx)
		key = if type(value) == "string" and value ~= "" then value else false
		done(key ~= false, cx)
	end)
end

function M.connected()
	return type(key) == "string"
end

-- Checks `value` against Linear, then stores it. done(viewer, err, cx)
function M.connect(value, done)
	local previous = key
	key, viewer = value, nil
	M.viewer(function(found, err, cx)
		if not found then
			key = previous
			done(nil, err, cx)
			return
		end
		tern.secrets.set(SECRET, value):next(function(_r, setErr, setCx)
			if setErr then done(nil, "Could not save the key: " .. tostring(setErr), setCx); return end
			done(found, nil, setCx)
		end)
	end)
end

function M.disconnect(done)
	key, viewer = false, nil
	tern.secrets.set(SECRET, nil):next(function(_r, err, cx) done(err == nil, cx) end)
end

-- Who the key belongs to, their workspace's URL key and their teams.
function M.viewer(done)
	if viewer then tern.timer(0, function(cx) done(viewer, nil, cx) end); return end
	request("query { viewer { id name organization { urlKey } teams { nodes { id key name } } } }", nil, function(data, err, cx)
		local v = data and data.viewer
		if not v then done(nil, err or "Linear returned no user", cx); return end
		local teams = {}
		for _, team in (v.teams and v.teams.nodes or {}) do
			table.insert(teams, { id = team.id, key = team.key, name = team.name })
		end
		viewer = { id = v.id, name = v.name, workspace = v.organization and v.organization.urlKey, teams = teams }
		done(viewer, nil, cx)
	end)
end

-- Open issues assigned to you, most recently updated first:
-- {{ id = "ENG-123", title, url, state, updated }}.
function M.my_issues(done)
	request([[query {
		viewer { assignedIssues(first: 50, orderBy: updatedAt,
			filter: { state: { type: { nin: ["completed", "canceled"] } } }) {
			nodes { identifier title url updatedAt state { name type } } } }
	}]], nil, function(data, err, cx)
		local nodes = data and data.viewer and data.viewer.assignedIssues and data.viewer.assignedIssues.nodes
		if not nodes then done(nil, err or "Linear returned no issues", cx); return end
		local out = {}
		for _, issue in nodes do
			table.insert(out, {
				id = issue.identifier, title = issue.title, url = issue.url, updated = issue.updatedAt,
				state = issue.state and issue.state.name,
			})
		end
		done(out, nil, cx)
	end)
end

-- How far along a workflow state is: backlog/triage/unstarted 0, started 1,
-- a started state named like "review" 2, completed/canceled 3.
local function rank(state)
	if not state then return 0 end
	if state.type == "completed" or state.type == "canceled" then return 3 end
	if state.type == "started" then
		return if string.find(string.lower(state.name or ""), "review", 1, true) then 2 else 1
	end
	return 0
end

local STAGES = { started = 1, review = 2, completed = 3 }

-- Moves issue `id` (ENG-123 or its URL) to the team's first state for `stage`
-- ("started", "review" or "completed"), only ever forward: an issue already there
-- or past it is left alone, and a team without a review state skips "review".
-- done(stateName or nil when unchanged, err, cx)
function M.advance(id, stage, done)
	local identifier = string.match(string.upper(id or ""), "(%u[%u%d]*%-%d+)")
	local target = STAGES[stage]
	if not identifier or not target then deferred(done, "Not a Linear issue: " .. tostring(id)); return end
	request([[query($id: String!) { issue(id: $id) {
		id state { name type position }
		team { states { nodes { id name type position } } } } }]], { id = identifier }, function(data, err, cx)
		local issue = data and data.issue
		if not issue then done(nil, err or ("No Linear issue " .. identifier), cx); return end
		if rank(issue.state) >= target then done(nil, nil, cx); return end
		local best
		for _, state in (issue.team and issue.team.states and issue.team.states.nodes or {}) do
			local fits = rank(state) == target and (state.type ~= "canceled")
			if fits and (not best or (state.position or 0) < (best.position or 0)) then best = state end
		end
		if not best then done(nil, nil, cx); return end
		request([[mutation($id: String!, $state: String!) {
			issueUpdate(id: $id, input: { stateId: $state }) { success } }]],
			{ id = issue.id, state = best.id }, function(result, updateErr, nextCx)
				if not (result and result.issueUpdate and result.issueUpdate.success) then
					done(nil, updateErr or "Linear didn't update " .. identifier, nextCx)
					return
				end
				done(best.name, nil, nextCx)
			end)
	end)
end

-- Creates an issue titled `title` in the team with key `teamKey` (else your first
-- team), assigned to you. done({ id, title, url }, err, cx)
function M.create(title, teamKey, done)
	M.viewer(function(me, err, cx)
		if not me then done(nil, err, cx); return end
		local team = me.teams[1]
		for _, candidate in me.teams do
			if candidate.key == teamKey then team = candidate end
		end
		if not team then done(nil, "Your Linear account has no team", cx); return end
		request([[mutation($team: String!, $title: String!, $me: String!) {
			issueCreate(input: { teamId: $team, title: $title, assigneeId: $me }) {
				success issue { identifier title url } } }]],
			{ team = team.id, title = title, me = me.id }, function(data, createErr, nextCx)
				local issue = data and data.issueCreate and data.issueCreate.issue
				if not issue then done(nil, createErr or "Linear didn't create the issue", nextCx); return end
				done({ id = issue.identifier, title = issue.title, url = issue.url }, nil, nextCx)
			end)
	end)
end

return M
