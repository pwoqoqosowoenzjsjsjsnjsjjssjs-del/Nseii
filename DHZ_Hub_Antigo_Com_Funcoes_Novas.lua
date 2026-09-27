-- DHZ HUB / Delta compatibility build - Minimal UI + custom bubble image
-- Based on the uploaded script. Optional executor-only features degrade gracefully.

local __DHZ_OK, __DHZ_ERR = xpcall(function()
local CARRY_RETURN_SPEED_MULT = 1.35
local function applyGothamBold(obj)
	if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
		pcall(function()
			obj.Font = Enum.Font.GothamBold
		end)
	end
end
-- Delta compatibility: external presence/analytics disabled.
local function __dhz_presence() end
local function __dhz_leave() end

local DHZ_VERSION = "4.2.0"
local DHZ_BUILD = "f9ce7f8c"
local env = (type(getgenv) == "function" and getgenv()) or _G
env.DhzGeneration = (env.DhzGeneration or 0) + 1
local BX = {
	generation = env.DhzGeneration,
	version = DHZ_VERSION,
	build = DHZ_BUILD,
	_factories = {},
	_loaded = {},
	_loading = {},
	_conns = {},
}
env.BX = BX
function BX.alive()
	return env.DhzGeneration == BX.generation
end
function BX.module(name, factory)
	if BX._factories[name] then
		error(("duplicate module %q"):format(name), 2)
	end
	BX._factories[name] = factory
end
function BX.require(name)
	local cached = BX._loaded[name]
	if cached ~= nil then
		return cached
	end
	if BX._loading[name] then
		error(("circular dependency: %s"):format(name), 2)
	end
	local factory = BX._factories[name]
	if not factory then
		error(("no such module: %s"):format(name), 2)
	end
	BX._loading[name] = true
	local ok, result = pcall(factory, BX)
	BX._loading[name] = nil
	if not ok then
		error(("module %q failed to load: %s"):format(name, tostring(result)), 2)
	end
	if result == nil then
		error(("module %q returned nil (forgot to return M?)"):format(name), 2)
	end
	BX._loaded[name] = result
	return result
end
function BX.connect(signal, fn)
	local c = signal:Connect(fn)
	BX._conns[# BX._conns + 1] = c
	return c
end
function BX.offthread(fn, timeout)
	local done, result = false, nil
	task.spawn(function()
		local ok, r = pcall(fn)
		if ok then
			result = r
		end
		done = true
	end)
	local startedAt = os.clock()
	timeout = timeout or 5
	while not done and (os.clock() - startedAt) < timeout do
		task.wait(0.03)
	end
	return result, done
end
BX._teardownHooks = {}
function BX.onTeardown(label, fn)
	BX._teardownHooks[# BX._teardownHooks + 1] = {
		label = tostring(label),
		fn = fn
	}
end
function BX.teardown()
	if BX._tornDown then
		return
	end
	BX._tornDown = true
	for i = # BX._teardownHooks, 1, - 1 do
		local h = BX._teardownHooks[i]
		local ok, err = pcall(h.fn)
		if not ok then
			pcall(function()
				local lg = BX._loaded["boot.log"]
				if lg then
					lg._emit(4, "teardown", ("%s: %s"):format(h.label, tostring(err)))
				end
			end)
		end
	end
	BX._teardownHooks = {}
	pcall(function()
		local lg = BX._loaded["boot.log"]
		if lg and lg.flushNow then
			lg.flushNow()
		end
	end)
	if BX.destroyAllScopes then
		pcall(BX.destroyAllScopes)
	end
	for _, c in ipairs(BX._conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	BX._conns = {}
	BX._loaded = {}
end
if type(env.DhzTeardown) == "function" then
	pcall(env.DhzTeardown)
end
env.DhzTeardown = BX.teardown
BX.module("boot.log", function(BX)
	local M = {}
	local TRACE_FILE = "DhzHub_trace.txt"
	local FLUSH_GAP = 3.0
	local RING = 500
	local canWrite = (type(writefile) == "function")
	local debugOn = function()
		local env = (type(getgenv) == "function" and getgenv()) or _G
		return env.DhzDebug == true
	end
	local PREV_FILE = "DhzHub_trace_prev.txt"
	if canWrite and type(readfile) == "function" and type(isfile) == "function" then
		pcall(function()
			local env = (type(getgenv) == "function" and getgenv()) or _G
			if env.__DHZ_LOG_ROTATED then
				return
			end
			env.__DHZ_LOG_ROTATED = true
			if isfile(TRACE_FILE) then
				writefile(PREV_FILE, readfile(TRACE_FILE))
			end
		end)
	end
	local ring, ringN, ringHead = {}, 0, 0
	local flushAt = 0
	local seen, seenN = {}, 0
	local SEEN_MAX = 400
	M.LEVELS = {
		TRACE = 1,
		INFO = 2,
		WARN = 3,
		ERROR = 4
	}
	M.level = M.LEVELS.INFO
	local function stamp()
		return ("%7.2f"):format(os.clock())
	end
	local dirty = false
	local function writeNow()
		if not canWrite then
			return
		end
		flushAt = os.clock()
		dirty = false
		local out, n = {}, 0
		local start = (ringN < RING) and 1 or (ringHead % RING) + 1
		for i = 0, ringN - 1 do
			n = n + 1
			out[n] = ring[((start - 1 + i) % RING) + 1]
		end
		local body = table.concat(out, "\n", 1, n)
		if BX.profile and BX.profile.measure then
			BX.profile.measure("log/writefile", pcall, writefile, TRACE_FILE, body)
		else
			pcall(writefile, TRACE_FILE, body)
		end
	end
	local function flush(force)
		if not canWrite then
			return
		end
		if force then
			return writeNow()
		end
		dirty = true
	end
	if canWrite then
		task.spawn(function()
			while BX.alive() do
				task.wait(FLUSH_GAP)
				if dirty then
					pcall(writeNow)
				end
			end
			if dirty then
				pcall(writeNow)
			end
		end)
	end
	function M.flushNow()
		pcall(writeNow)
	end
	local TAGS = {
		"TRACE",
		"INFO",
		"WARN",
		"ERROR"
	}
	local function emit(level, mod, msg)
		if level < M.level then
			return
		end
		local line = ("[%s] %-5s %-16s %s"):format(stamp(), TAGS[level], mod, msg)
		ringHead = (ringHead % RING) + 1
		ring[ringHead] = line
		if ringN < RING then
			ringN = ringN + 1
		end
		if debugOn() or level >= M.LEVELS.WARN then
			print("[DHZ] " .. line)
		end
		flush(level >= M.LEVELS.ERROR)
	end
	function M.for_module(name)
		return {
			trace = function(m, ...)
				if M.level > 1 then
					return
				end
				emit(1, name, select("#", ...) > 0 and m:format(...) or m)
			end,
			info = function(m, ...)
				emit(2, name, select("#", ...) > 0 and m:format(...) or m)
			end,
			warn = function(m, ...)
				emit(3, name, select("#", ...) > 0 and m:format(...) or m)
			end,
			error = function(m, ...)
				emit(4, name, select("#", ...) > 0 and m:format(...) or m)
			end,
		}
	end
	function M.session(msg)
		emit(2, "session", "=== " .. msg .. " ===")
		flush(true)
	end
	function M.repeats()
		local out = {}
		for label, n in pairs(seen) do
			if n > 1 then
				out[# out + 1] = ("%s x%d"):format(label, n)
			end
		end
		table.sort(out)
		return out
	end
	function BX.try(label, fn, ...)
		local ok, result = pcall(fn, ...)
		if not ok then
			if seen[label] == nil then
				if seenN >= SEEN_MAX then
					label = "(other)"
				else
					seenN = seenN + 1
				end
			end
			local n = (seen[label] or 0) + 1
			seen[label] = n
			if n == 1 then
				emit(4, "try", ("%s: %s"):format(label, tostring(result)))
			elseif n == 10 or n == 100 or n == 1000 then
				emit(3, "try", ("%s: still failing (x%d)"):format(label, n))
			end
		end
		return ok, result
	end
	function BX.guard(label, fn)
		return function(...)
			return select(2, BX.try(label, fn, ...))
		end
	end
	M._emit = emit
	M._seen = seen
	return M
end)
BX._scopes = {}
function BX.scope(name)
	local existing = BX._scopes[name]
	if existing and not existing.dead then
		existing:destroy()
	end
	local sc = {
		name = name,
		dead = false,
		conns = {},
		insts = {},
		threads = {},
		tweens = {},
		gen = BX.generation,
	}
	function sc:alive()
		return (not self.dead) and BX.alive()
	end
	function sc:connect(signal, fn)
		if self.dead then
			return nil
		end
		local c = signal:Connect(fn)
		self.conns[# self.conns + 1] = c
		return c
	end
	function sc:own(inst)
		if self.dead then
			pcall(function()
				inst:Destroy()
			end)
			return inst
		end
		self.insts[# self.insts + 1] = inst
		return inst
	end
	function sc:spawn(label, fn, ...)
		if self.dead then
			return nil
		end
		local th
		th = task.spawn(function(...)
			BX.try(self.name .. "/" .. label, fn, ...)
			for i, t in ipairs(self.threads) do
				if t == th then
					table.remove(self.threads, i)
					break
				end
			end
		end, ...)
		self.threads[# self.threads + 1] = th
		return th
	end
	function sc:loop(label, interval, fn)
		local tag = self.name .. "/" .. label
		local body = BX.profile and BX.profile.wrapLoop(tag, interval, fn) or fn
		return self:spawn(label .. "/loop", function()
			while self:alive() do
				BX.try(tag, body)
				if not self:alive() then
					return
				end
				task.wait(interval)
			end
		end)
	end
	function sc:onFrame(label, signal, fn)
		local tag = self.name .. "/" .. label
		local guarded = BX.guard(tag, fn)
		local timed = BX.profile and BX.profile.wrap(tag, guarded) or guarded
		return self:connect(signal, timed)
	end
	function sc:delay(label, seconds, fn)
		if self.dead then
			return
		end
		task.delay(seconds, function()
			if not self:alive() then
				return
			end
			BX.try(self.name .. "/" .. label, fn)
		end)
	end
	function sc:tween(obj, t, props, style, dir)
		if self.dead then
			return nil
		end
		local tween
		BX.try(self.name .. "/tween", function()
			tween = BX.require("core.services").TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
			tween:Play()
		end)
		if tween then
			self.tweens[# self.tweens + 1] = tween
		end
		return tween
	end
	function sc:destroy()
		if self.dead then
			return
		end
		self.dead = true
		for _, c in ipairs(self.conns) do
			pcall(function()
				c:Disconnect()
			end)
		end
		for _, t in ipairs(self.tweens) do
			pcall(function()
				t:Cancel()
			end)
		end
		for _, i in ipairs(self.insts) do
			pcall(function()
				i:Destroy()
			end)
		end
		local me = coroutine.running()
		for _, th in ipairs(self.threads) do
			if th ~= me then
				pcall(task.cancel, th)
			end
		end
		self.conns, self.insts, self.threads, self.tweens = {}, {}, {}, {}
		if BX._scopes[self.name] == self then
			BX._scopes[self.name] = nil
		end
	end
	function sc:counts()
		return {
			conns = # self.conns,
			insts = # self.insts,
			threads = # self.threads,
			tweens = # self.tweens,
		}
	end
	BX._scopes[name] = sc
	return sc
end
function BX.scopeReport()
	local out = {}
	for name, sc in pairs(BX._scopes) do
		if not sc.dead then
			local c = sc:counts()
			out[# out + 1] = ("%-24s conns=%-3d insts=%-4d threads=%-3d tweens=%d") :format(name, c.conns, c.insts, c.threads, c.tweens)
		end
	end
	table.sort(out)
	return out
end
function BX.destroyAllScopes()
	for _, sc in pairs(BX._scopes) do
		pcall(function()
			sc:destroy()
		end)
	end
	BX._scopes = {}
end
BX.profile = {
	enabled = true,
	_stats = {},
	_mem0 = nil,
	_t0 = os.clock(),
}
local P = BX.profile
P._watch = {}
function P.watch(name, fn)
	P._watch[name] = fn
end
function P.watched()
	local out = {}
	for name, fn in pairs(P._watch) do
		local ok, n = pcall(fn)
		out[# out + 1] = ("%s=%s"):format(name, ok and tostring(n) or "?")
	end
	table.sort(out)
	return out
end
P._marks = {}
local function markRead()
	local plr = game:GetService("Players").LocalPlayer
	local char = plr and plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return - 1, "no-humanoid", false
	end
	return hum.Health, hum:GetState().Name, hum:GetAttribute("DhzStealHum") == true
end
function P.mark(name)
	local ok, health, state, swapped = pcall(markRead)
	local row = {
		name = name,
		at = os.clock(),
		health = ok and health or - 1,
		state = ok and state or "?",
		swapped = ok and swapped or false,
	}
	P._marks[# P._marks + 1] = row
	if # P._marks > 200 then
		table.remove(P._marks, 1)
	end
	return row
end
function P.marksSince(t)
	local out = {}
	for _, r in ipairs(P._marks) do
		if r.at >= (t or 0) then
			out[# out + 1] = ("%s@%.2f hp=%.0f %s%s"):format( r.name, r.at - (t or 0), r.health, r.state, r.swapped and " swapped" or "")
		end
	end
	return out
end
local heapKb = function()
	local ok, v = pcall(collectgarbage, "count")
	return (ok and type(v) == "number") and v or 0
end
P.journalOn = false
P._journal, P._jHead, P.JOURNAL = {}, 0, 512
function P.stamp(label, t0, dt)
	if not P.journalOn then
		return
	end
	P._jHead = (P._jHead % P.JOURNAL) + 1
	local row = P._journal[P._jHead]
	if not row then
		row = {};
		P._journal[P._jHead] = row
	end
	row[1], row[2], row[3] = label, t0, dt
end
local function statFor(label, kind, interval)
	local s = P._stats[label]
	if not s then
		s = {
			n = 0,
			total = 0,
			max = 0,
			last = 0,
			alloc = 0,
			kind = kind,
			interval = interval,
			since = os.clock(),
			yields = 0,
			wall = 0
		}
		P._stats[label] = s
	end
	return s
end
P.frameNo = 0
BX.scope("boot.profile.clock"):connect(game:GetService("RunService").Heartbeat, function()
	P.frameNo = P.frameNo + 1
end)
local function timed(s, label, fn, ...)
	local t0, k0, f0 = os.clock(), heapKb(), P.frameNo
	local r1, r2, r3, r4 = fn(...)
	local dt = os.clock() - t0
	s.n = s.n + 1
	if P.frameNo ~= f0 then
		s.yields = s.yields + 1
		s.wall = s.wall + dt
		return r1, r2, r3, r4
	end
	local dk = heapKb() - k0
	s.total = s.total + dt
	s.last = dt
	if dk > 0 then
		s.alloc = s.alloc + dk
	end
	if dt > s.max then
		s.max = dt
	end
	if P.journalOn then
		P.stamp(label, t0, dt)
	end
	return r1, r2, r3, r4
end
function P.wrap(label, fn)
	local s = statFor(label, "frame")
	return function(...)
		if not P.enabled then
			return fn(...)
		end
		return timed(s, label, fn, ...)
	end
end
function P.wrapLoop(label, interval, fn)
	local s = statFor(label, "loop", interval)
	return function(...)
		if not P.enabled then
			return fn(...)
		end
		return timed(s, label, fn, ...)
	end
end
function P.measure(label, fn, ...)
	if not P.enabled then
		return fn(...)
	end
	timed(statFor(label, "io"), label, fn, ...)
end
function P.rows()
	local rows, now = {}, os.clock()
	for label, s in pairs(P._stats) do
		if s.n > 0 then
			local sync = math.max(s.n - s.yields, 1)
			rows[# rows + 1] = {
				label = label,
				kind = s.kind,
				hz = s.n / math.max(now - s.since, 0.001),
				avg = (s.total / sync) * 1000,
				max = s.max * 1000,
				total = s.total,
				n = s.n,
				yields = s.yields,
				wallAvg = s.yields > 0 and (s.wall / s.yields) * 1000 or 0,
				kbPer = s.alloc / sync,
				interval = s.interval,
			}
		end
	end
	table.sort(rows, function(a, b)
		return a.total > b.total
	end)
	return rows
end
function P.reset()
	for _, s in pairs(P._stats) do
		s.n, s.total, s.max, s.last, s.alloc, s.since = 0, 0, 0, 0, 0, os.clock()
		s.yields, s.wall = 0, 0
	end
end
function P.report()
	local out = {
		("%-40s %-5s %7s %8s %8s %8s %8s %5s"):format("job", "kind", "hz", "avg ms", "max ms", "calls", "kb/call", "yld")
	}
	for _, r in ipairs(P.rows()) do
		out[# out + 1] = ("%-40s %-5s %7.2f %8.3f %8.3f %8d %8.2f %5d") :format(r.label, r.kind, r.hz, r.avg, r.max, r.n, r.kbPer, r.yields)
	end
	return out
end
local StatsService = game:GetService("Stats")
local function memMb()
	local ok, v = pcall(StatsService.GetTotalMemoryUsageMb, StatsService)
	if ok and type(v) == "number" then
		return v
	end
	ok, v = pcall(gcinfo)
	return (ok and type(v) == "number") and (v / 1024) or 0
end
function P.health()
	local conns, threads, scopes, insts = 0, 0, 0, 0
	for _, sc in pairs(BX._scopes or {}) do
		if not sc.dead then
			scopes = scopes + 1
			conns = conns + # sc.conns
			insts = insts + # sc.insts
			threads = threads + # sc.threads
		end
	end
	local mem = memMb()
	P._mem0 = P._mem0 or mem
	local loaded = 0
	for _ in pairs(BX._loaded) do
		loaded = loaded + 1
	end
	return {
		uptime = os.clock() - P._t0,
		mem = mem,
		memGrow = mem - P._mem0,
		scopes = scopes,
		conns = conns,
		insts = insts,
		threads = threads,
		loaded = loaded,
	}
end
function P.start()
	local sc = BX.scope("boot.profile")
	local log = BX.require("boot.log").for_module("profile")
	local fps, lastFrame, last = 0, P.frameNo, os.clock()
	sc:loop("health", 60, function()
		local now = os.clock()
		fps = (P.frameNo - lastFrame) / math.max(now - last, 0.001)
		lastFrame, last = P.frameNo, now
		local h = P.health()
		local w = P.watched()
		log.info("health up=%.0fs fps=%.0f mem=%.0fMB (%+.0f) scopes=%d conns=%d insts=%d threads=%d%s", h.uptime, fps, h.mem, h.memGrow, h.scopes, h.conns, h.insts, h.threads, # w > 0 and (" | " .. table.concat(w, " ")) or "")
	end)
	return sc
end
BX.module("core.services", function(BX)
	local log = BX.require("boot.log").for_module("services")
	local M = {}
	local WANTED = {
		"Players",
		"ReplicatedStorage",
		"RunService",
		"TweenService",
		"UserInputService",
		"Lighting",
		"Workspace",
		"HttpService",
		"CoreGui",
		"TextService",
		"Stats",
		"TeleportService",
	}
	for _, name in ipairs(WANTED) do
		local ok, svc = pcall(game.GetService, game, name)
		if ok and svc then
			M[name] = svc
		else
			log.error("service unavailable: %s", name)
		end
	end
	if M.Players and not M.Players.LocalPlayer then
		local deadline = os.clock() + 10
		while not M.Players.LocalPlayer and os.clock() < deadline do
			task.wait(0.1)
		end
		if M.Players.LocalPlayer then
			log.info("LocalPlayer arrived late (%.1fs) - waited for it", 10 - (deadline - os.clock()))
		else
			log.error("Players.LocalPlayer is still nil after 10s")
		end
	end
	M.LocalPlayer = M.Players and M.Players.LocalPlayer
	return M
end)
BX.module("core.net", function(BX)
	local svc = BX.require("core.services")
	local log = BX.require("boot.log").for_module("net")
	local M = {}
	local container, containerAt = nil, 0
	local CONTAINER_TTL = 30
	local function networking()
		local now = os.clock()
		if container and container.Parent and (now - containerAt) < CONTAINER_TTL then
			return container
		end
		local pkgs = svc.ReplicatedStorage:FindFirstChild("Packages")
		local net = pkgs and pkgs:FindFirstChild("Networking")
		container, containerAt = net, now
		return net
	end
	function M.find(name)
		local net = networking()
		return net and net:FindFirstChild(name) or nil
	end
	function M.call(name, ...)
		local rf = M.find(name)
		if not rf then
			return false, "remote not found: " .. tostring(name)
		end
		local ok, a, b = pcall(function(...)
			return rf:InvokeServer(...)
		end, ...)
		if not ok then
			return false, tostring(a)
		end
		return a, b
	end
	function M.fire(name, ...)
		local re = M.find(name)
		if not re then
			return false, "remote not found: " .. tostring(name)
		end
		local ok, err = pcall(function(...)
			re:FireServer(...)
		end, ...)
		if not ok then
			return false, tostring(err)
		end
		return true
	end
	return M
end)
BX.module("core.data", function(BX)
	local svc = BX.require("core.services")
	local exec = BX.require("core.exec")
	local log = BX.require("boot.log").for_module("data")
	local M = {}
	local cache = {}
	local function atPath( ...)
		local node = svc.ReplicatedStorage
		for _, part in ipairs({
			...
		}) do
			if not node then
				return nil
			end
			node = node:FindFirstChild(part)
		end
		return node
	end
	local function searchModule(name)
		for _, d in ipairs(svc.ReplicatedStorage:GetDescendants()) do
			if d:IsA("ModuleScript") and d.Name == name then
				return d
			end
		end
		return nil
	end
	local function resolve(key, path)
		local held = cache[key]
		if held then
			return held.mod
		end
		if not exec.can.gameRequire then
			log.error("cannot require game modules on this executor (%s) - %s unavailable", tostring(exec.gameRequireWhy), path[# path])
			cache[key] = {
				missing = true
			}
			return nil
		end
		local name = path[# path]
		local inst = atPath(table.unpack(path))
		if not (inst and inst:IsA("ModuleScript")) then
			inst = searchModule(name)
			if inst then
				log.warn("%s was not at %s - found it at %s", name, table.concat(path, "."), inst:GetFullName())
			end
		end
		if not inst then
			cache[key] = {
				missing = true
			}
			log.error("could not resolve the game module %s (expected %s)", name, table.concat(path, "."))
			return nil
		end
		local mod
		local ok = BX.try("data.require." .. key, function()
			mod = require(inst)
		end)
		if not ok or type(mod) ~= "table" then
			cache[key] = {
				missing = true
			}
			log.error("%s could not be required", inst:GetFullName())
			return nil
		end
		cache[key] = {
			mod = mod
		}
		return mod
	end
	function M.assets()
		return resolve("assets", {
			"Data",
			"Assets"
		})
	end
	function M.areas()
		return resolve("areas", {
			"Data",
			"Areas"
		})
	end
	function M.eggState()
		return resolve("eggState", {
			"Client",
			"EggState"
		})
	end
	function M.assetEarnings()
		return resolve("assetEarnings", {
			"Shared",
			"Util",
			"AssetEarnings"
		})
	end
	function M.plotState()
		return resolve("plotState", {
			"Client",
			"PlotState"
		})
	end
	function M.slotIdentity()
		return resolve("slotIdentity", {
			"Shared",
			"Util",
			"AreaEggSlotIdentity"
		})
	end
	function M.resetWall()
		return resolve("resetWall", {
			"Client",
			"AreaEggResetWall"
		})
	end
	function M.bases()
		return resolve("bases", {
			"Data",
			"Bases"
		})
	end
	function M.save()
		return resolve("save", {
			"Shared",
			"Save"
		})
	end
	function M.eggCycle()
		return resolve("eggCycle", {
			"Shared",
			"Util",
			"AreaEggCycle"
		})
	end
	function M.fusionFlags()
		return resolve("fusionFlags", {
			"Shared",
			"Flags",
			"ShrineFusionFlags"
		})
	end
	local LIMIT_FALLBACK = 115
	function M.eggInventory()
		local count, limit
		BX.try("data.eggInventoryCount", function()
			local save = M.save()
			local s = save and save.Get and save.Get(svc.Players.LocalPlayer)
			if type(s) == "table" and type(s.EggInventory) == "table" then
				count = 0
				for _ in pairs(s.EggInventory) do
					count = count + 1
				end
			end
		end)
		BX.try("data.eggInventoryLimit", function()
			local flags = M.fusionFlags()
			local f = flags and flags.EggInventoryLimit
			limit = f and type(f.Get) == "function" and tonumber(f:Get()) or nil
		end)
		limit = limit or LIMIT_FALLBACK
		if not count then
			return nil, nil, limit
		end
		return count >= limit, count, limit
	end
	function M.secondsUntilReset()
		local cyc = M.eggCycle()
		if not (cyc and type(cyc.SecondsUntilReset) == "function") then
			return nil
		end
		local ok, s = pcall(cyc.SecondsUntilReset, workspace:GetServerTimeNow())
		return ok and tonumber(s) or nil
	end
	function M.fieldSealed()
		local wall = M.resetWall()
		if not (wall and type(wall.IsSealed) == "function") then
			return nil
		end
		local ok, sealed = pcall(wall.IsSealed)
		if not ok then
			return nil
		end
		return sealed == true
	end
	function M.assetsDir()
		local a = M.assets()
		return a and a.Directory or nil
	end
	function M.areasDir()
		local a = M.areas()
		return a and a.Directory or nil
	end
	function M.report()
		local out = {}
		for key, held in pairs(cache) do
			out[# out + 1] = key .. (held.missing and "=MISSING" or "=ok")
		end
		table.sort(out)
		return out
	end
	return M
end)
BX.module("core.profiles", function(BX)
	local svc = BX.require("core.services")
	local exec = BX.require("core.exec")
	local log = BX.require("boot.log").for_module("profiles")
	local M = {}
	local FORMAT = 1
	local DIR = "DhzHub/profiles"
	local SETTINGS = "DhzHub/settings.json"
	M.FORMAT = FORMAT
	local SKIP_KEYS = {
		"url",
		"token",
		"secret",
		"key",
		"password"
	}
	local ALLOW = {
		AntiTreadmill = true,
		FarmAreas = true,
		FarmRarities = true,
		FarmTargetBy = true,
		WebhookOn = true,
		Theme = true,
		Background = true,
	}
	M.ALLOW = ALLOW
	local function skipped(name)
		if not ALLOW[name] then
			return true
		end
		local n = tostring(name):lower()
		for _, bad in ipairs(SKIP_KEYS) do
			if n:find(bad, 1, true) then
				return true
			end
		end
		return false
	end
	function M.available()
		return exec.can.files and exec.can.folders and true or false
	end
	local listing, listingOk = {}, false
	local function safeName(name)
		name = tostring(name or ""):gsub("[^%w%-_ ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
		return name
	end
	local function pathFor(name)
		return DIR .. "/" .. name .. ".json"
	end
	function M.refresh()
		listing, listingOk = {}, false
		if not M.available() then
			return listing
		end
		BX.try("profiles.refresh", function()
			exec.ensureFolder("DHZ HUB")
			exec.ensureFolder(DIR)
			local files = exec.listFiles(DIR)
			if not files then
				log.warn("this executor has no listfiles - saved profiles cannot be listed")
				return
			end
			for _, f in ipairs(files) do
				local name = tostring(f):match("([^/\\]+)%.json$")
				if name then
					listing[# listing + 1] = name
				end
			end
			table.sort(listing)
			listingOk = true
		end)
		return listing
	end
	function M.list()
		if not listingOk then
			M.refresh()
		end
		return listing
	end
	local flagSource = nil
	function M.setFlagSource(fn)
		flagSource = fn
	end
	local appearanceSource, appearanceApply = nil, nil
	function M.setAppearanceHooks(read, apply)
		appearanceSource, appearanceApply = read, apply
	end
	local function collectFlags()
		local out = {}
		if type(flagSource) ~= "function" then
			return out
		end
		local ok, flags = pcall(flagSource)
		if not ok or type(flags) ~= "table" then
			return out
		end
		for name, el in pairs(flags) do
			if not skipped(name) then
				local v
				if type(el) == "table" then
					v = el.CurrentValue
					if v == nil then
						v = el.Value
					end
					if v == nil then
						v = el.value
					end
				else
					v = el
				end
				local t = type(v)
				if t == "boolean" or t == "number" or t == "string" then
					out[tostring(name)] = v
				elseif t == "table" then
					local copy = {}
					for i, item in ipairs(v) do
						if type(item) == "string" or type(item) == "number" then
							copy[i] = item
						end
					end
					out[tostring(name)] = copy
				end
			end
		end
		return out
	end
	function M.save(name)
		if not M.available() then
			return false, "This executor cannot save files"
		end
		name = safeName(name)
		if name == "" then
			return false, "Give the profile a name"
		end
		local payload = {
			version = FORMAT,
			saved = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			build = tostring(BX.build),
			flags = collectFlags(),
			appearance = (type(appearanceSource) == "function") and select(2, pcall(appearanceSource)) or nil,
		}
		local body
		local okEnc = pcall(function()
			body = svc.HttpService:JSONEncode(payload)
		end)
		if not okEnc or not body then
			return false, "Could not encode the profile"
		end
		local path = pathFor(name)
		local ok = BX.try("profiles.save", function()
			exec.ensureFolder("DHZ HUB")
			exec.ensureFolder(DIR)
			if not exec.writeFile(path, body) then
				error("writefile refused", 0)
			end
		end)
		if not ok then
			return false, "Could not write the profile"
		end
		if not exec.isFile(path) then
			log.warn("profile %q: writefile returned but isfile says no", name)
			return false, "Written but not found - this executor's file access is broken"
		end
		local back = exec.readFile(path)
		if back ~= body then
			log.warn("profile %q: readback mismatch (%d vs %d bytes)", name, type(back) == "string" and # back or - 1, # body)
			return false, "Written but readback differs - not saved"
		end
		M.refresh()
		log.info("saved profile %q (%d flags)", name, (function()
			local n = 0
			for _ in pairs(payload.flags) do
				n = n + 1
			end
			return n
		end)())
		return true, "Saved " .. name
	end
	function M.load(name)
		if not M.available() then
			return false, "This executor cannot read files"
		end
		name = safeName(name)
		if name == "" then
			return false, "Pick a profile"
		end
		local path = pathFor(name)
		if not exec.isFile(path) then
			return false, "No profile called " .. name
		end
		local body = exec.readFile(path)
		if type(body) ~= "string" or body == "" then
			return false, name .. " is empty"
		end
		local data
		local okDec = pcall(function()
			data = svc.HttpService:JSONDecode(body)
		end)
		if not okDec or type(data) ~= "table" then
			log.warn("profile %q is not valid JSON - refusing it", name)
			return false, name .. " is corrupt"
		end
		local v = tonumber(data.version) or 0
		if v > FORMAT then
			return false, name .. " was saved by a newer version"
		end
		if v < FORMAT then
			log.info("profile %q is format %d, current is %d - loading as-is", name, v, FORMAT)
		end
		local applied = 0
		if type(data.flags) == "table" and type(flagSource) == "function" then
			local ok, flags = pcall(flagSource)
			if ok and type(flags) == "table" then
				for key, value in pairs(data.flags) do
					local el = (not skipped(key)) and flags[key] or nil
					if type(el) == "table" and type(el.Set) == "function" then
						if BX.try("profiles.set." .. tostring(key), function()
							el:Set(value)
						end) then
							applied = applied + 1
						end
					end
				end
			end
		end
		if type(data.appearance) == "table" and type(appearanceApply) == "function" then
			BX.try("profiles.appearance", function()
				appearanceApply(data.appearance)
			end)
		end
		log.info("loaded profile %q (%d controls)", name, applied)
		return true, ("Loaded %s (%d settings)"):format(name, applied)
	end
	function M.delete(name)
		if not M.available() then
			return false, "This executor cannot delete files"
		end
		name = safeName(name)
		local path = pathFor(name)
		if name == "" or not exec.isFile(path) then
			return false, "No such profile"
		end
		local ok = BX.try("profiles.delete", function()
			exec.deleteFile(path)
		end)
		M.refresh()
		if not ok then
			return false, "Could not delete " .. name
		end
		log.info("deleted profile %q", name)
		return true, "Deleted " .. name
	end
	local function readSettings()
		if not M.available() or not exec.isFile(SETTINGS) then
			return {}
		end
		local body = exec.readFile(SETTINGS)
		local data
		pcall(function()
			data = svc.HttpService:JSONDecode(body)
		end)
		return type(data) == "table" and data or {}
	end
	function M.autoLoadName()
		local s = readSettings()
		local n = s.autoLoad
		return type(n) == "string" and n ~= "" and n or nil
	end
	function M.setAutoLoad(name)
		if not M.available() then
			return false, "This executor cannot save files"
		end
		name = safeName(name)
		local s = readSettings()
		s.autoLoad = (name ~= "" and name) or nil
		s.version = FORMAT
		local body
		if not pcall(function()
			body = svc.HttpService:JSONEncode(s)
		end) then
			return false, "Could not save the setting"
		end
		BX.try("profiles.settings", function()
			exec.ensureFolder("DHZ HUB")
			exec.writeFile(SETTINGS, body)
		end)
		log.info("auto-load profile is now %s", name ~= "" and ("%q"):format(name) or "off")
		return true, name ~= "" and ("Auto-loading " .. name) or "Auto-load off"
	end
	local autoLoadRan = false
	function M.runAutoLoad()
		if autoLoadRan then
			return false, "already ran"
		end
		autoLoadRan = true
		local name = M.autoLoadName()
		if not name then
			return false, "no auto-load profile set"
		end
		local ok, msg = M.load(name)
		if not ok then
			log.warn("auto-load failed: %s", tostring(msg))
		end
		return ok, msg
	end
	return M
end)
BX.module("core.exec", function(BX)
	local log = BX.require("boot.log").for_module("exec")
	local M = {}
	local env = (type(getgenv) == "function" and getgenv()) or _G
	local deny = type(env.DHZ_CAPS_DENY) == "table" and env.DHZ_CAPS_DENY or {}
	M.simulatedDenies = deny
	local function fn(name)
		if deny[name] then
			return nil
		end
		local ok, v
		ok, v = pcall(function()
			return type(getgenv) == "function" and getgenv()[name] or nil
		end)
		if not ok or type(v) ~= "function" then
			ok, v = pcall(function()
				return getfenv and getfenv()[name] or nil
			end)
		end
		if not ok or type(v) ~= "function" then
			ok, v = pcall(function()
				return (_G and _G[name])
			end)
		end
		if not ok or type(v) ~= "function" then
			ok, v = pcall(function()
				local chunk = loadstring and loadstring("return " .. name)
				return chunk and chunk() or nil
			end)
		end
		return (ok and type(v) == "function") and v or nil
	end
	local function first( ...)
		for _, name in ipairs({
			...
		}) do
			local f = fn(name)
			if f then
				return f, name
			end
		end
		return nil, nil
	end
	local f_writefile = first("writefile")
	local f_readfile = first("readfile")
	local f_isfile = first("isfile")
	local f_delfile = first("delfile")
	local f_isfolder = first("isfolder")
	local f_makefolder = first("makefolder")
	local f_listfiles = first("listfiles")
	local f_customasset = first("getcustomasset", "getsynasset")
	local f_gethui = first("gethui")
	local f_getgc = first("getgc")
	local f_getconns = first("getconnections")
	local f_hookfn = first("hookfunction", "replaceclosure")
	local f_getrawmeta = first("getrawmetatable")
	local f_setreadonly = first("setreadonly", "make_writeable")
	local f_queueport = first("queue_on_teleport", "queueonteleport")
	local f_identify = first("identifyexecutor", "getexecutorname")
	local f_fireprompt = first("fireproximityprompt")
	local f_clip, clipName = first("setclipboard", "toclipboard", "set_clipboard", "setrbxclipboard")
	local canRequire, requireWhy = false, "no ModuleScript to probe"
	do
		local ok, err = pcall(function()
			local RS = game:GetService("ReplicatedStorage")
			local probe = RS:FindFirstChildWhichIsA("ModuleScript", true)
			if not probe then
				return
			end
			local r = require(probe)
			canRequire, requireWhy = true, probe:GetFullName()
		end)
		if not ok then
			requireWhy = tostring(err)
		end
		if deny.gameRequire then
			canRequire, requireWhy = false, "simulated deny"
		end
	end
	local f_request, requestName
	do
		local ok, v = pcall(function()
			return syn and syn.request
		end)
		if ok and type(v) == "function" then
			f_request, requestName = v, "syn.request"
		else
			ok, v = pcall(function()
				return http and http.request
			end)
			if ok and type(v) == "function" then
				f_request, requestName = v, "http.request"
			else
				f_request, requestName = first("request", "http_request", "httprequest")
			end
		end
	end
	M.can = {
		files = (f_writefile and f_readfile and f_isfile) and true or false,
		folders = (f_isfolder and f_makefolder) and true or false,
		listFiles = f_listfiles and true or false,
		customAsset = f_customasset and true or false,
		hiddenUi = f_gethui and true or false,
		gc = f_getgc and true or false,
		connections = f_getconns and true or false,
		hooking = (f_hookfn and f_getrawmeta) and true or false,
		clipboard = f_clip and true or false,
		request = f_request and true or false,
		teleportQueue = f_queueport and true or false,
		prompts = true,
		gameRequire = canRequire,
	}
	M.promptVia = f_fireprompt and "fireproximityprompt" or "InputHoldBegin"
	M.gameRequireWhy = requireWhy
	M.name = "unknown"
	if f_identify then
		local ok, n = pcall(f_identify)
		if ok and type(n) == "string" and # n > 0 then
			M.name = n
		end
	end
	function M.hiddenParent()
		if f_gethui then
			local ok, ui = pcall(f_gethui)
			if ok and ui then
				return ui
			end
		end
		local svc = BX.require("core.services")
		local lp = svc.Players and svc.Players.LocalPlayer
		local pg = lp and lp:FindFirstChild("PlayerGui")
		if pg then
			return pg
		end
		return svc.CoreGui
	end
	function M.writeFile(path, data)
		if not f_writefile then
			return false
		end
		return (BX.try("exec.writeFile", f_writefile, path, data))
	end
	function M.readFile(path)
		if not f_readfile then
			return nil
		end
		local ok, data = BX.try("exec.readFile", f_readfile, path)
		return ok and data or nil
	end
	function M.isFile(path)
		if not f_isfile then
			return false
		end
		local ok, yes = pcall(f_isfile, path)
		return ok and yes or false
	end
	function M.listFiles(path)
		if not f_listfiles then
			return nil
		end
		local ok, files = BX.try("exec.listFiles", f_listfiles, path)
		if not ok or type(files) ~= "table" then
			return nil
		end
		return files
	end
	function M.deleteFile(path)
		if not f_delfile then
			return false
		end
		return (BX.try("exec.deleteFile", f_delfile, path))
	end
	function M.ensureFolder(path)
		if not M.can.folders then
			return false
		end
		local built = ""
		for part in tostring(path):gmatch("[^/]+") do
			built = (built == "") and part or (built .. "/" .. part)
			local ok, exists = pcall(f_isfolder, built)
			if ok and not exists then
				if not BX.try("exec.makeFolder", f_makefolder, built) then
					return false
				end
			end
		end
		return true
	end
	function M.customAsset(path)
		if not f_customasset then
			return nil
		end
		local ok, id = BX.try("exec.customAsset", f_customasset, path)
		return ok and id or nil
	end
	function M.clipboard(text)
		for _, name in ipairs({
			"setclipboard",
			"toclipboard",
			"set_clipboard",
			"setrbxclipboard"
		}) do
			local f = fn(name)
			if f and pcall(f, text) then
				return true
			end
		end
		return false
	end
	function M.httpRequest(opts)
		if not f_request then
			return nil
		end
		local ok, res = BX.try("exec.httpRequest", f_request, opts)
		return ok and res or nil
	end
	function M.gcScan(tablesOnly)
		if not f_getgc then
			return {}
		end
		local t0 = os.clock()
		local ok, objs = BX.try("exec.gcScan", f_getgc, tablesOnly and true or false)
		if not ok or type(objs) ~= "table" then
			return {}
		end
		local ms = (os.clock() - t0) * 1000
		M.lastGcMs = ms
		log.warn("gc sweep: %d objects in %.0fms", # objs, ms)
		return objs
	end
	function M.firePrompt(prompt, holdDuration)
		if f_fireprompt then
			return (BX.try("exec.firePrompt", f_fireprompt, prompt, holdDuration or 0))
		end
		return (BX.try("exec.firePrompt.hold", function()
			prompt:InputHoldBegin()
			local hold = tonumber(holdDuration)
			if hold == nil then
				hold = tonumber(prompt.HoldDuration) or 0
			end
			if hold > 0 then
				task.wait(hold + 0.05)
			end
			prompt:InputHoldEnd()
		end))
	end
	function M.report()
		local have, missing = {}, {}
		for k, v in pairs(M.can) do
			table.insert(v and have or missing, k)
		end
		table.sort(have);
		table.sort(missing)
		local denied = {}
		for k in pairs(deny) do
			denied[# denied + 1] = tostring(k)
		end
		table.sort(denied)
		return {
			executor = M.name,
			have = have,
			missing = missing,
			denied = denied,
			promptVia = M.promptVia,
			gameRequireWhy = requireWhy,
		}
	end
	local r = M.report()
	log.info("executor=%s clipboard=%s request=%s prompts=%s gameRequire=%s (%s)", M.name, tostring(clipName), tostring(requestName), M.promptVia, tostring(canRequire), tostring(requireWhy))
	if # r.denied > 0 then
		log.warn("SIMULATED capability denies active: %s", table.concat(r.denied, ", "))
	end
	log.info("supported: %s", # r.have > 0 and table.concat(r.have, ", ") or "(none)")
	if # r.missing > 0 then
		log.warn("unsupported here: %s", table.concat(r.missing, ", "))
	end
	return M
end)
BX.module("core.device", function(BX)
	local svc = BX.require("core.services")
	local cfg = BX.require("core.config")
	local log = BX.require("boot.log").for_module("device")
	local M = {}
	M.isTouch = svc.UserInputService.TouchEnabled and not svc.UserInputService.KeyboardEnabled
	local function shortSide()
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize
		if not vp or vp.Y < 10 then
			return 1080
		end
		return math.min(vp.X, vp.Y)
	end
	M.smallScreen = shortSide() < 500
	M.tier = (M.isTouch and M.smallScreen) and "low" or "mid"
	M.fps = nil
	local MULT = {
		low = 2.2,
		mid = 1.35,
		high = 1.0
	}
	function M.scale(seconds)
		return seconds * (MULT[M.tier] or 1.35)
	end
	function M.budget(n)
		local share = (M.tier == "low" and 0.35) or (M.tier == "mid" and 0.7) or 1
		return math.max(1, math.floor(n * share + 0.5))
	end
	function M.lite()
		return M.tier == "low"
	end
	local listeners = {}
	function M.onTier(sc, label, fn)
		listeners[# listeners + 1] = {
			scope = sc,
			label = label,
			fn = fn
		}
	end
	local function setTier(t)
		if M.tier == t then
			return
		end
		local was = M.tier
		M.tier = t
		log.info("tier %s -> %s (fps %.0f, touch=%s, short=%d)", was, t, M.fps or - 1, tostring(M.isTouch), shortSide())
		for i = # listeners, 1, - 1 do
			local L = listeners[i]
			if not L.scope or L.scope.dead then
				table.remove(listeners, i)
			else
				BX.try("device/" .. L.label, L.fn, t, was)
			end
		end
	end
	local sc = BX.scope("core.device")
	local lastFrame, lastAt = BX.profile.frameNo, os.clock()
	local pending, pendingCount = nil, 0
	sc:loop("measure", 5, function()
		local now = os.clock()
		local fps = (BX.profile.frameNo - lastFrame) / math.max(now - lastAt, 0.001)
		lastFrame, lastAt = BX.profile.frameNo, now
		M.fps = M.fps and (M.fps + (fps - M.fps) * 0.4) or fps
		local want = M.tier
		if M.tier == "high" then
			if M.fps < 45 then
				want = "mid"
			end
		elseif M.tier == "mid" then
			if M.fps < cfg.LITE_FPS then
				want = "low"
			elseif M.fps > 75 then
				want = "high"
			end
		else
			if M.fps > 40 then
				want = "mid"
			end
		end
		if want == "high" and M.isTouch and M.smallScreen then
			want = "mid"
		end
		if want == M.tier then
			pending, pendingCount = nil, 0
			return
		end
		if pending == want then
			pendingCount = pendingCount + 1
		else
			pending, pendingCount = want, 1
		end
		if pendingCount >= 2 then
			setTier(want)
			pending, pendingCount = nil, 0
		end
	end)
	log.info("start tier=%s touch=%s smallScreen=%s", M.tier, tostring(M.isTouch), tostring(M.smallScreen))
	return M
end)
BX.module("core.character", function(BX)
	local svc = BX.require("core.services")
	local log = BX.require("boot.log").for_module("character")
	local M = {}
	local plr = svc.LocalPlayer
	local current = setmetatable({}, {
		__mode = "v"
	})
	local listeners = {}
	function M.get()
		local c = current.char
		if c and c.Parent then
			return c
		end
		return plr and plr.Character
	end
	function M.root()
		local c = M.get()
		return c and c:FindFirstChild("HumanoidRootPart")
	end
	function M.humanoid()
		local c = M.get()
		return c and c:FindFirstChildOfClass("Humanoid")
	end
	local function fire(char)
		current.char = char
		for i = # listeners, 1, - 1 do
			local L = listeners[i]
			if not L.scope or L.scope.dead then
				table.remove(listeners, i)
			else
				BX.try(("character/%s"):format(L.label), L.fn, char)
			end
		end
	end
	function M.onSpawn(sc, label, fn)
		listeners[# listeners + 1] = {
			scope = sc,
			label = label,
			fn = fn
		}
		local c = M.get()
		if c then
			BX.try(("character/%s"):format(label), fn, c)
		end
	end
	local sc = BX.scope("core.character")
	if plr then
		sc:connect(plr.CharacterAdded, function(char)
			log.trace("respawn")
			task.spawn(function()
				BX.try("character/wait", function()
					char:WaitForChild("HumanoidRootPart", 10)
				end)
				if BX.alive() then
					fire(char)
				end
			end)
		end)
		sc:connect(plr.CharacterRemoving, function()
			current.char = nil
		end)
		current.char = plr.Character
	else
		log.error("no LocalPlayer - character tracking unavailable")
	end
	M._listenerCount = function()
		return # listeners
	end
	return M
end)
BX.module("core.restore", function(BX)
	local ch = BX.require("core.character")
	local log = BX.require("boot.log").for_module("restore")
	local M = {}
	local entries = {}
	local order = {}
	BX.profile.watch("restore.pending", function()
		return # order
	end)
	function M.remember(key, read, write)
		if entries[key] then
			return false
		end
		local ok, value = pcall(read)
		if not ok then
			log.warn("could not read %s to remember it: %s", key, tostring(value))
			return false
		end
		entries[key] = {
			read = read,
			write = write,
			original = value,
			char = ch.get(),
			at = os.clock(),
		}
		order[# order + 1] = key
		return true
	end
	function M.onRestore(key, undo)
		if entries[key] then
			return false
		end
		entries[key] = {
			undo = undo,
			char = ch.get(),
			at = os.clock()
		}
		order[# order + 1] = key
		return true
	end
	function M.permanent(key, why)
		if entries[key] then
			return false
		end
		entries[key] = {
			permanent = why or "not reversible",
			char = ch.get()
		}
		order[# order + 1] = key
		return true
	end
	function M.restoreAll()
		local restored, skipped, failed = 0, 0, 0
		local liveChar = ch.get()
		for i = # order, 1, - 1 do
			local key = order[i]
			local e = entries[key]
			if e then
				if e.permanent then
					skipped = skipped + 1
				elseif e.char and e.char ~= liveChar then
					skipped = skipped + 1
				else
					local ok, err = pcall(function()
						if e.undo then
							e.undo()
						else
							e.write(e.original)
						end
					end)
					if ok then
						restored = restored + 1
					else
						failed = failed + 1
						log.error("restoring %s failed: %s", key, tostring(err))
					end
				end
				entries[key] = nil
			end
			table.remove(order, i)
		end
		return restored, skipped, failed
	end
	function M.audit()
		local diffs = {}
		for _, key in ipairs(order) do
			local e = entries[key]
			if e and e.read then
				local ok, now = pcall(e.read)
				if ok and tostring(now) ~= tostring(e.original) then
					diffs[# diffs + 1] = ("%s: %s (was %s)") :format(key, tostring(now), tostring(e.original))
				end
			elseif e and e.permanent then
				diffs[# diffs + 1] = ("%s: %s"):format(key, e.permanent)
			end
		end
		return diffs
	end
	function M.pending()
		return # order
	end
	local sc = BX.scope("core.restore")
	ch.onSpawn(sc, "restore.respawn", function(char)
		local dropped = 0
		for i = # order, 1, - 1 do
			local key = order[i]
			local e = entries[key]
			if e and e.char and e.char ~= char then
				entries[key] = nil
				table.remove(order, i)
				dropped = dropped + 1
			end
		end
		if dropped > 0 then
			log.trace("dropped %d entries captured against the old character", dropped)
		end
	end)
	return M
end)
BX.module("core.config", function(BX)
	return {
		CARRY_SPEED = 500,
		OUTBOUND_SPEED_MIN = 500,
		OUTBOUND_SPEED_MAX = 1200,
		LITE_FPS = 25,
		STATS_HZ = 4,
		LOG_LEVEL = 2,
		KEY_VALIDATE_URL = "https://YOUR-VERCEL-URL/api/key/validate",
		KEY_SESSION_URL = "",
		KEY_WEBSITE_URL = "https://YOUR-VERCEL-URL/key.html",
		DEFAULT_BACKGROUND = "108858454360177",
	}
end)
BX.module("core.state", function(BX)
	return {
		heldEggUid = nil,
		autoStealOn = false,
		stayOnTreadmill = false,
		lastFps = 0,
		startedAt = os.clock(),
	}
end)
BX.module("core.motion", function(BX)
	local svc = BX.require("core.services")
	local log = BX.require("boot.log").for_module("motion")
	local M = {}
	local PRIORITY = {
		autosteal = 100,
		bossfight = 90,
		hold = 80,
		fly = 50,
		speed = 40
	}
	M.PRIORITY = PRIORITY
	local claims = {}
	local preemptFns = {}
	local stats = {
		claims = 0,
		preempts = 0,
		rejections = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.owner()
		local best, bestP = nil, - 1
		for name in pairs(claims) do
			local p = PRIORITY[name] or 0
			if p > bestP then
				best, bestP = name, p
			end
		end
		return best
	end
	function M.blockedBy(name)
		local mine = PRIORITY[name] or 0
		local top = M.owner()
		if top and top ~= name and (PRIORITY[top] or 0) > mine then
			return top
		end
		return nil
	end
	function M.onPreempt(name, fn)
		preemptFns[name] = fn
	end
	function M.claim(name)
		local blocker = M.blockedBy(name)
		if claims[name] then
			return blocker == nil, blocker
		end
		claims[name] = true
		stats.claims = stats.claims + 1
		local mine = PRIORITY[name] or 0
		for other in pairs(claims) do
			if other ~= name and (PRIORITY[other] or 0) < mine and preemptFns[other] then
				stats.preempts = stats.preempts + 1
				BX.try("motion.preempt." .. other, preemptFns[other], name)
			end
		end
		if blocker then
			log.info("%s claimed under %s (waiting)", name, blocker)
		end
		return blocker == nil, blocker
	end
	function M.release(name)
		claims[name] = nil
	end
	function M.holds(name)
		return claims[name] == true
	end
	local rejections = {}
	local RING = 64
	local head = 0
	local listeners = {}
	local function hasRelocate(v, depth)
		depth = depth or 0
		if type(v) == "string" then
			return v:find("Relocate", 1, true) ~= nil
		end
		if type(v) == "table" and depth < 2 then
			for k, x in pairs(v) do
				if hasRelocate(k, depth + 1) or hasRelocate(x, depth + 1) then
					return true
				end
			end
		end
		return false
	end
	local function reject(kind)
		stats.rejections = stats.rejections + 1
		head = (head % RING) + 1
		local now = os.clock()
		local who = M.owner()
		rejections[head] = {
			at = now,
			kind = kind,
			owner = who
		}
		log.info("server correction (%s) while %s owned the character", kind, tostring(who or "nobody"))
		for i = # listeners, 1, - 1 do
			local L = listeners[i]
			if L.scope and L.scope.dead then
				table.remove(listeners, i)
			else
				BX.try("motion.onRejected", L.fn, kind, who)
			end
		end
	end
	function M.rejectionsSince(t)
		local n = 0
		for _, r in pairs(rejections) do
			if r.at >= (t or 0) then
				n = n + 1
			end
		end
		return n
	end
	function M.lastRejectionAt()
		local last = 0
		for _, r in pairs(rejections) do
			if r.at > last then
				last = r.at
			end
		end
		return last
	end
	function M.onRejected(scope, fn)
		listeners[# listeners + 1] = {
			scope = scope,
			fn = fn
		}
	end
	local sc = BX.scope("core.motion")
	BX.try("motion.watch", function()
		local net = svc.ReplicatedStorage:FindFirstChild("Packages")
		net = net and net:FindFirstChild("Networking")
		if not net then
			log.warn("no Networking folder - corrections not observable")
			return
		end
		local began = net:FindFirstChild("RE/RigSync/CorrectionBegan")
		if began and began:IsA("RemoteEvent") then
			sc:connect(began.OnClientEvent, function()
				reject("CorrectionBegan")
			end)
		end
		local refresh = net:FindFirstChild("RE/RigSync/Refresh")
		if refresh and refresh:IsA("RemoteEvent") then
			sc:connect(refresh.OnClientEvent, function(...)
				for i = 1, select("#", ...) do
					if hasRelocate((select(i, ...))) then
						reject("Relocate")
						return
					end
				end
			end)
		end
		log.info("watching RigSync corrections (began=%s refresh=%s)", tostring(began ~= nil), tostring(refresh ~= nil))
	end)
	BX.profile.watch("motion.owner", function()
		return M.owner() or "-"
	end)
	return M
end)
BX.module("core.util", function(BX)
	local M = {}
	function M.clamp(v, lo, hi)
		return math.max(lo, math.min(hi, v))
	end
	function M.round(v, places)
		local m = 10 ^ (places or 0)
		return math.floor(v * m + 0.5) / m
	end
	function M.wait(seconds)
		task.wait(seconds)
		return BX.alive()
	end
	function M.short(n)
		if n >= 1e6 then
			return ("%.1fM"):format(n / 1e6)
		end
		if n >= 1e3 then
			return ("%.1fk"):format(n / 1e3)
		end
		return tostring(math.floor(n))
	end
	return M
end)
BX.module("ui.splash", function(BX)
	local M = {}
	M.step = function()
	end
	M.discord = function()
	end
	M.fail = function()
	end
	M.done = function()
	end
	M.whenClosed = function(fn)
		pcall(fn)
	end
	M.isWaitingForUser = function()
		return false
	end
	return M
end)
BX.module("ui.stats", function(BX)
	local svc = BX.require("core.services")
	local cfg = BX.require("core.config")
	local st = BX.require("core.state")
	local log = BX.require("boot.log").for_module("stats")
	local M = {}
	local Stats, RunService = svc.Stats, svc.RunService
	local UIS, TS, HS = svc.UserInputService, svc.TweenService, svc.HttpService
	local TextService = svc.TextService
	local BG_TOP = Color3.fromRGB(26, 26, 30)
	local BG_BOT = Color3.fromRGB(14, 14, 17)
	local ELEMENT = Color3.fromRGB(41, 41, 48)
	local ACCENT = Color3.fromRGB(206, 206, 212)
	local ICON = Color3.fromRGB(240, 240, 246)
	local TEXT = Color3.fromRGB(220, 220, 220)
	local WARN = Color3.fromRGB(240, 190, 90)
	local BAD = Color3.fromRGB(240, 110, 110)
	local FONT, TEXT_SIZE = Enum.Font.GothamMedium, 13
	local STROKE_T = 0.45
	local POS_FILE = "DhzHub_stats_pos.json"
	local NUM_EASE_K = 12
	local TONE_FADE = 0.45
	local FPS_ALPHA = 0.28
	local PING_ALPHA = 0.30
	local BANDS = {
		fps = {
			dir = - 1,
			warn = {
				enter = 50,
				exit = 54
			},
			bad = {
				enter = 25,
				exit = 29
			}
		},
		ping = {
			dir = 1,
			warn = {
				enter = 150,
				exit = 132
			},
			bad = {
				enter = 250,
				exit = 220
			}
		},
	}
	local SPIKE_FACTOR = 2.5
	local SPIKE_FLOOR = 120
	local SPIKE_CONFIRM = 2
	local STALE_AFTER = 6
	local BLANK = "--"
	local ICON_ROOT = "DhzHub/icons"
	local ICON_DIR = ICON_ROOT .. "/v1"
	local ICON_BASE = "https://raw.githubusercontent.com/google/material-design-icons/3.0.1/"
	local ICON_SRC = {
		clock = "action/2x_web/ic_schedule_white_48dp.png",
		pulse = "editor/2x_web/ic_show_chart_white_48dp.png",
		wifi = "notification/2x_web/ic_wifi_white_48dp.png",
	}
	local iconAsset = {}
	local iconTone = {}
	local iconsAsked = false
	local sessionT0 = os.clock()
	local gui, pill, scaler, stroke
	local sc
	local bars, labels, fadeList, iconBoxes = {}, {}, {}, {}
	local cellFrames = {}
	local tip, tipLabel, tipStroke, tipScale
	local hovering = false
	local frames, shownFps = 0, nil
	local fpsLevel, pingLevel = 0, 0
	local pingEma, pingSuspect, pingSeenAt = nil, 0, nil
	local hoverKind, hoverUntil = nil, 0
	local target, moving, dragging = nil, false, false
	local grabInput, grabStart, grabPos
	local baseScale, closing = 1, false
	local function mk(class, props, parent)
		local o = Instance.new(class)
		for k, v in pairs(props) do
			o[k] = v
		end
		o.Parent = parent
		return o
	end
	local function tw(o, t, props, style)
		BX.try("stats.tween", function()
			TS:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props):Play()
		end)
	end
	local function line(parent, x1, y1, x2, y2)
		local dx, dy = x2 - x1, y2 - y1
		mk("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2),
			Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) + 1, 1.5),
			Rotation = math.deg(math.atan2(dy, dx)),
			BackgroundColor3 = ICON,
			BorderSizePixel = 0,
		}, parent)
	end
	local function drawIcon(box, kind)
		if kind == "clock" then
			local ring = mk("Frame", {
				Position = UDim2.fromOffset(2, 2),
				Size = UDim2.fromOffset(12, 12),
				BackgroundTransparency = 1,
			}, box)
			mk("UICorner", {
				CornerRadius = UDim.new(0, 0)
			}, ring)
			mk("UIStroke", {
				Color = ICON,
				Thickness = 1.5
			}, ring)
			line(box, 8, 8, 8, 5)
			line(box, 8, 8, 10.5, 8)
		elseif kind == "pulse" then
			local p = {
				{
					1,
					9
				},
				{
					4.5,
					9
				},
				{
					6.5,
					4
				},
				{
					9.5,
					13
				},
				{
					11.5,
					9
				},
				{
					15,
					9
				}
			}
			for i = 1, # p - 1 do
				line(box, p[i][1], p[i][2], p[i + 1][1], p[i + 1][2])
			end
		else
			bars = {}
			for i = 1, 3 do
				local h = 2 + i * 3.5
				bars[i] = mk("Frame", {
					Position = UDim2.fromOffset(2 + (i - 1) * 4.5, 14 - h),
					Size = UDim2.fromOffset(3, h),
					BackgroundColor3 = ICON,
					BorderSizePixel = 0,
				}, box)
				mk("UICorner", {
					CornerRadius = UDim.new(0, 0)
				}, bars[i])
			end
		end
	end
	local function validPng(data)
		if type(data) ~= "string" or # data < 200 then
			return false
		end
		if data:sub(2, 4) ~= "PNG" then
			return false
		end
		local function be32(at)
			local a, b, c, d = data:byte(at, at + 3)
			if not d then
				return 0
			end
			return ((a * 256 + b) * 256 + c) * 256 + d
		end
		local w, h = be32(17), be32(21)
		return w >= 16 and w <= 512 and h >= 16 and h <= 512
	end
	local function fillIcon(box, kind)
		for _, c in ipairs(box:GetChildren()) do
			c:Destroy()
		end
		if kind == "wifi" then
			bars = {}
		end
		if iconAsset[kind] then
			mk("ImageLabel", {
				Name = "Img",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = iconAsset[kind],
				ImageColor3 = iconTone[kind] or ICON,
				ScaleType = Enum.ScaleType.Fit,
			}, box)
		else
			drawIcon(box, kind)
		end
	end
	local function icon(parent, kind)
		local box = mk("Frame", {
			Size = UDim2.fromOffset(16, 16),
			BackgroundTransparency = 1
		}, parent)
		iconBoxes[kind] = box
		fillIcon(box, kind)
		return box
	end
	local function cell(parent, order, kind, widest)
		local c = mk("Frame", {
			LayoutOrder = order,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 18),
			BackgroundTransparency = 1,
		}, parent)
		mk("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, c)
		icon(c, kind).LayoutOrder = 1
		local w = 0
		BX.try("stats.measure", function()
			w = TextService:GetTextSize(widest, TEXT_SIZE, FONT, Vector2.new(1000, 100)).X
		end)
		return mk("TextLabel", {
			LayoutOrder = 2,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(math.ceil(w), 18),
			BackgroundTransparency = 1,
			Font = FONT,
			TextSize = TEXT_SIZE,
			TextColor3 = TEXT,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "--",
		}, c)
	end
	local function divider(parent, order)
		mk("Frame", {
			LayoutOrder = order,
			Size = UDim2.fromOffset(1, 14),
			BackgroundColor3 = ACCENT,
			BackgroundTransparency = 0.82,
			BorderSizePixel = 0,
			Name = "Divider",
		}, parent)
	end
	local function clock(s)
		s = math.floor(s)
		local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
		if h > 0 then
			return ("%d:%02d:%02d"):format(h, m, s % 60)
		end
		return ("%02d:%02d"):format(m, s % 60)
	end
	local function readPing()
		local ok, v = pcall(function()
			return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		if ok and type(v) == "number" and v > 0 then
			return v
		end
		ok, v = pcall(function()
			return svc.LocalPlayer:GetNetworkPing() * 1000
		end)
		return (ok and type(v) == "number") and v or nil
	end
	local function paint(obj, prop, color)
		if obj and obj[prop] ~= color then
			tw(obj, TONE_FADE, {
				[prop] = color
			})
		end
	end
	local function ema(prev, value, alpha)
		if prev == nil then
			return value
		end
		return prev + (value - prev) * alpha
	end
	local LEVEL_COLOR = {
		[0] = TEXT,
		[1] = WARN,
		[2] = BAD
	}
	local function grade(band, v, cur)
		cur = cur or 0
		local function worseThan(x)
			if band.dir < 0 then
				return v <= x
			else
				return v >= x
			end
		end
		local function betterThan(x)
			if band.dir < 0 then
				return v >= x
			else
				return v <= x
			end
		end
		if cur >= 2 then
			if not betterThan(band.bad.exit) then
				return 2
			end
			return betterThan(band.warn.exit) and 0 or 1
		elseif cur == 1 then
			if worseThan(band.bad.enter) then
				return 2
			end
			return betterThan(band.warn.exit) and 0 or 1
		else
			if worseThan(band.bad.enter) then
				return 2
			end
			return worseThan(band.warn.enter) and 1 or 0
		end
	end
	local QUALITY = {
		fps = {
			[0] = "Smooth",
			[1] = "Fair",
			[2] = "Poor"
		},
		ping = {
			[0] = "Excellent",
			[1] = "Good",
			[2] = "Poor"
		},
	}
	local function tintIcon(kind, color)
		if iconTone[kind] == color then
			return
		end
		iconTone[kind] = color
		local box = iconBoxes[kind]
		if not box or not box.Parent then
			return
		end
		for _, d in ipairs(box:GetDescendants()) do
			if d:IsA("ImageLabel") then
				paint(d, "ImageColor3", color)
			elseif d:IsA("UIStroke") then
				paint(d, "Color", color)
			elseif d:IsA("Frame") and d.BackgroundTransparency < 1 then
				paint(d, "BackgroundColor3", color)
			end
		end
	end
	local NUM = {
		{
			key = "fps",
			fmt = "%d FPS"
		},
		{
			key = "ping",
			fmt = "%d ms"
		},
	}
	local function entry(key)
		for i = 1, # NUM do
			if NUM[i].key == key then
				return NUM[i]
			end
		end
	end
	local function setTarget(key, value)
		local e = entry(key)
		if not e then
			return
		end
		e.target = value
		if e.shown == nil then
			e.shown = value
		end
	end
	local function setUnavailable(key)
		local e = entry(key)
		if not e or e.target == nil then
			return
		end
		e.shown, e.target, e.lastWhole = nil, nil, nil
		local label = labels[key]
		if label and label.Text ~= BLANK then
			label.Text = BLANK
		end
	end
	local function easeNumbers(dt)
		local k = 1 - math.exp(- dt * NUM_EASE_K)
		for i = 1, # NUM do
			local e = NUM[i]
			local label = labels[e.key]
			if e.target and label then
				local diff = e.target - e.shown
				if diff < 0.01 and diff > - 0.01 then
					e.shown = e.target
				else
					e.shown += diff * k
				end
				local whole = math.floor(e.shown + 0.5)
				if whole ~= e.lastWhole then
					e.lastWhole = whole
					label.Text = e.fmt:format(whole)
				end
			end
		end
	end
	local function resetNumbers()
		for i = 1, # NUM do
			local e = NUM[i]
			e.shown, e.target, e.lastWhole = nil, nil, nil
		end
	end
	local DETAIL_HOLD = 2.5
	local function detailFor(kind)
		if kind == "clock" then
			return "Session time"
		end
		local key = (kind == "pulse") and "fps" or "ping"
		local e = entry(key)
		if not e or not e.target then
			return (key == "fps" and "FPS" or "Ping") .. "  \u{B7}  no reading"
		end
		local level = (key == "fps") and fpsLevel or pingLevel
		local word = QUALITY[key][level]
		if key == "fps" then
			return ("%d FPS  \u{B7}  %s"):format(math.floor(e.target + 0.5), word)
		end
		return ("%d ms  \u{B7}  %s"):format(math.floor(e.target + 0.5), word)
	end
	local function hideTip()
		hoverKind, hoverUntil = nil, 0
		if not tip then
			return
		end
		tw(tip, 0.18, {
			BackgroundTransparency = 1
		})
		tw(tipLabel, 0.18, {
			TextTransparency = 1
		})
		if tipStroke then
			tw(tipStroke, 0.18, {
				Transparency = 1
			})
		end
	end
	local function placeTip()
		if not tip or not pill or not hoverKind then
			return
		end
		local cellF = cellFrames[hoverKind]
		local cx = cellF and cellF.Parent and (cellF.AbsolutePosition.X + cellF.AbsoluteSize.X / 2) or (pill.AbsolutePosition.X + pill.AbsoluteSize.X / 2)
		local halfW = tip.AbsoluteSize.X / 2
		local vpX = gui.AbsoluteSize.X
		cx = math.clamp(cx, halfW + 6, math.max(vpX - halfW - 6, halfW + 6))
		tip.Position = UDim2.fromOffset(cx, pill.AbsolutePosition.Y + pill.AbsoluteSize.Y + 6)
	end
	local function showTip(kind)
		if not tip or not pill or hoverKind == kind then
			return
		end
		hoverKind = kind
		tipLabel.Text = detailFor(kind)
		placeTip()
		tw(tip, 0.16, {
			BackgroundTransparency = 0.08
		})
		tw(tipLabel, 0.16, {
			TextTransparency = 0
		})
		if tipStroke then
			tw(tipStroke, 0.16, {
				Transparency = 0.55
			})
		end
	end
	local function kindAtX(x)
		for kind, f in pairs(cellFrames) do
			if f.Parent then
				local left = f.AbsolutePosition.X
				if x >= left and x <= left + f.AbsoluteSize.X then
					return kind
				end
			end
		end
		return nil
	end
	local function pickScale()
		local vp = gui and gui.AbsoluteSize or Vector2.new(1000, 1000)
		local touch = UIS.TouchEnabled and not UIS.KeyboardEnabled
		if not touch then
			return 1.2
		end
		local short = math.min(vp.X, vp.Y)
		if short < 10 then
			return 0.85
		end
		return math.clamp(short / 620, 0.78, 1.25)
	end
	local function defaultPos()
		local vy = gui and gui.AbsoluteSize.Y or 0
		return UDim2.fromScale(0.5, vy > 0 and (8 / vy) or 0.01)
	end
	local function clampPos(p)
		local vp, sz = gui.AbsoluteSize, pill.AbsoluteSize
		if vp.X < 1 or vp.Y < 1 then
			return p
		end
		local hx, hy = (sz.X / 2 + 4) / vp.X, (sz.Y + 4) / vp.Y
		local top = 4 / vp.Y
		return UDim2.fromScale( math.clamp(p.X.Scale, math.min(hx, 0.5), math.max(1 - hx, 0.5)), math.clamp(p.Y.Scale, top, math.max(1 - hy, top)))
	end
	local function loadPos()
		local ok, t = pcall(function()
			return HS:JSONDecode(readfile(POS_FILE))
		end)
		if ok and type(t) == "table" and tonumber(t.x) and tonumber(t.y) then
			return UDim2.fromScale(tonumber(t.x), tonumber(t.y))
		end
		return nil
	end
	local function savePos(p)
		if type(writefile) ~= "function" or not p then
			return
		end
		BX.try("stats.savePos", function()
			writefile(POS_FILE, HS:JSONEncode({
				x = p.X.Scale,
				y = p.Y.Scale
			}))
		end)
	end
	local function moveTo(p)
		target = clampPos(p)
		moving = true
	end
	local function dragTo(at)
		if not gui or not grabStart then
			return
		end
		local vp = gui.AbsoluteSize
		if vp.X < 1 or vp.Y < 1 then
			return
		end
		local dx, dy = at.X - grabStart.X, at.Y - grabStart.Y
		moveTo(UDim2.fromScale(grabPos.X.Scale + dx / vp.X, grabPos.Y.Scale + dy / vp.Y))
	end
	local function release()
		if not dragging then
			return
		end
		dragging, grabInput = false, nil
		if scaler then
			tw(scaler, 0.25, {
				Scale = baseScale
			}, Enum.EasingStyle.Back)
		end
		if stroke then
			tw(stroke, 0.3, {
				Transparency = STROKE_T
			})
		end
		savePos(target)
	end
	local function collectFade()
		fadeList = {}
		if not pill then
			return
		end
		local function add(o, prop)
			fadeList[# fadeList + 1] = {
				o,
				prop,
				o[prop]
			}
		end
		add(pill, "BackgroundTransparency")
		add(stroke, "Transparency")
		for _, d in ipairs(pill:GetDescendants()) do
			if d:IsA("TextLabel") then
				add(d, "TextTransparency")
			elseif d:IsA("ImageLabel") then
				add(d, "ImageTransparency")
			elseif d:IsA("UIStroke") then
				add(d, "Transparency")
			elseif d:IsA("Frame") and d.BackgroundTransparency < 1 then
				add(d, "BackgroundTransparency")
			end
		end
	end
	local function fade(on, t, pop)
		for _, f in ipairs(fadeList) do
			if f[1].Parent then
				tw(f[1], t, {
					[f[2]] = on and f[3] or 1
				})
			end
		end
		if scaler then
			tw(scaler, t, {
				Scale = on and baseScale or baseScale * 0.9
			}, (on and pop) and Enum.EasingStyle.Back or Enum.EasingStyle.Quint)
		end
	end
	local function teardown()
		if sc then
			sc:destroy();
			sc = nil
		end
		if gui then
			pcall(function()
				gui:Destroy()
			end)
		end
		gui, pill, scaler, stroke = nil, nil, nil, nil
		bars, labels, fadeList, iconBoxes = {}, {}, {}, {}
		cellFrames = {}
		tip, tipLabel, tipStroke = nil, nil, nil
		dragging, moving, closing, shownFps, grabInput = false, false, false, nil, nil
		resetNumbers()
		iconTone = {}
		fpsLevel, pingLevel = 0, 0
		pingEma, pingSuspect, pingSeenAt = nil, 0, nil
		hoverKind, hoverUntil, hovering = nil, 0, false
	end
	local function build()
		sc = BX.scope("ui.stats")
		local parent = (gethui and gethui()) or svc.CoreGui
		local old = parent:FindFirstChild("DhzStats")
		if old then
			old:Destroy()
		end
		gui = mk("ScreenGui", {
			Name = "DhzStats",
			DisplayOrder = 999996,
			IgnoreGuiInset = true,
			ResetOnSpawn = false,
			ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		}, parent)
		local touch = UIS.TouchEnabled and not UIS.KeyboardEnabled
		pill = mk("TextButton", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.01),
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, touch and 36 or 30),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.06,
			BorderSizePixel = 0,
			Active = true,
			AutoButtonColor = false,
			Text = "",
			Selectable = false,
		}, gui)
		mk("UICorner", {
			CornerRadius = UDim.new(0, 0)
		}, pill)
		mk("UIGradient", {
			Color = ColorSequence.new(BG_TOP, BG_BOT),
			Rotation = 90
		}, pill)
		stroke = mk("UIStroke", {
			Color = Color3.new(1, 1, 1),
			Transparency = STROKE_T,
			Thickness = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, pill)
		mk("UIGradient", {
			Color = ColorSequence.new(ACCENT, ELEMENT),
			Rotation = 90
		}, stroke)
		mk("UIPadding", {
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12)
		}, pill)
		mk("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, pill)
		baseScale = pickScale()
		scaler = mk("UIScale", {
			Scale = baseScale
		}, pill)
		labels.time = cell(pill, 1, "clock", "00:00")
		divider(pill, 2)
		labels.fps = cell(pill, 3, "pulse", "000 FPS")
		divider(pill, 4)
		labels.ping = cell(pill, 5, "wifi", "000 ms")
		if not iconsAsked and type(getcustomasset) == "function" and type(writefile) == "function" then
			iconsAsked = true
			sc:spawn("icons", function()
				BX.try("stats.iconDirs", function()
					for _, dir in ipairs({
						"DHZ HUB",
						ICON_ROOT,
						ICON_DIR
					}) do
						if not isfolder(dir) then
							makefolder(dir)
						end
					end
				end)
				local got = 0
				for kind, src in pairs(ICON_SRC) do
					local path = ICON_DIR .. "/" .. kind .. ".png"
					local ok = BX.try("stats.icon." .. kind, function()
						local have = type(isfile) == "function" and isfile(path) and validPng(readfile(path))
						if not have then
							local png = game:HttpGet(ICON_BASE .. src)
							assert(validPng(png), "not a usable png")
							writefile(path, png)
						end
						iconAsset[kind] = getcustomasset(path)
					end)
					if ok then
						got += 1
					end
				end
				log.info("material icons ready: %d/3", got)
				if got > 0 and gui and not closing and sc and sc:alive() then
					for kind, box in pairs(iconBoxes) do
						if box.Parent and iconAsset[kind] then
							fillIcon(box, kind)
							local img = box:FindFirstChild("Img")
							if img then
								fadeList[# fadeList + 1] = {
									img,
									"ImageTransparency",
									0
								}
							end
						end
					end
				end
			end)
		end
		tip = mk("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 22),
			BackgroundColor3 = BG_BOT,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 5,
		}, gui)
		mk("UICorner", {
			CornerRadius = UDim.new(0, 0)
		}, tip)
		tipStroke = mk("UIStroke", {
			Color = ELEMENT,
			Transparency = 1,
			Thickness = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}, tip)
		mk("UIPadding", {
			PaddingLeft = UDim.new(0, 9),
			PaddingRight = UDim.new(0, 9)
		}, tip)
		tipScale = mk("UIScale", {
			Scale = baseScale
		}, tip)
		tipLabel = mk("TextLabel", {
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 22),
			BackgroundTransparency = 1,
			Font = FONT,
			TextSize = 12,
			TextColor3 = TEXT,
			TextTransparency = 1,
			Text = "",
			ZIndex = 5,
		}, tip)
		target = clampPos(loadPos() or defaultPos())
		pill.Position = target
		sc:connect(gui:GetPropertyChangedSignal("AbsoluteSize"), BX.guard("stats.resize", function()
			baseScale = pickScale()
			if scaler and not dragging then
				scaler.Scale = baseScale
			end
			if tipScale then
				tipScale.Scale = baseScale
			end
			if target then
				moveTo(target)
			end
		end))
		sc:connect(pill.MouseEnter, function()
			hovering = true
		end)
		sc:connect(pill.MouseLeave, function()
			hovering = false;
			hideTip()
		end)
		local lastTap = 0
		sc:connect(pill.InputBegan, BX.guard("stats.grab", function(inp)
			local kind = inp.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
				return
			end
			local now = os.clock()
			if now - lastTap < 0.3 then
				lastTap = 0
				release()
				moveTo(defaultPos())
				savePos(target)
				return
			end
			lastTap = now
			if kind == Enum.UserInputType.Touch then
				local k = kindAtX(inp.Position.X)
				if k then
					showTip(k)
					hoverUntil = now + DETAIL_HOLD
				end
			end
			dragging, grabInput, grabPos = true, inp, target or pill.Position
			grabStart = (kind == Enum.UserInputType.MouseButton1) and UIS:GetMouseLocation() or inp.Position
			tw(scaler, 0.2, {
				Scale = baseScale * 1.05
			}, Enum.EasingStyle.Back)
			tw(stroke, 0.2, {
				Transparency = 0.1
			})
		end))
		sc:connect(UIS.InputChanged, BX.guard("stats.dragTouch", function(inp)
			if dragging and grabInput and inp == grabInput and inp.UserInputType == Enum.UserInputType.Touch then
				dragTo(inp.Position)
			end
		end))
		sc:connect(UIS.InputEnded, BX.guard("stats.release", function(inp)
			if not dragging or not grabInput then
				return
			end
			if inp == grabInput or (inp.UserInputType == Enum.UserInputType.MouseButton1 and grabInput.UserInputType == Enum.UserInputType.MouseButton1) then
				release()
			end
		end))
		collectFade()
	end
	function M.show(on)
		if not on then
			if not gui or closing then
				return
			end
			closing = true
			release()
			fade(false, 0.22)
			local g = gui
			task.delay(0.25, function()
				if gui == g and closing then
					teardown()
				end
			end)
			return
		end
		if gui then
			if closing then
				closing = false;
				fade(true, 0.3)
			end
			return
		end
		local built, why = pcall(build)
		if not built then
			log.error("could not build: %s", tostring(why))
			teardown()
			return
		end
		for _, f in ipairs(fadeList) do
			if f[1].Parent then
				f[1][f[2]] = 1
			end
		end
		scaler.Scale = baseScale * 0.9
		BX.try("stats.entryPos", function()
			local vy = math.max(gui.AbsoluteSize.Y, 1)
			pill.Position = UDim2.fromScale(target.X.Scale, target.Y.Scale - 12 / vy)
		end)
		local entering = gui
		sc:spawn("entrance", function()
			for _ = 1, 10 do
				if RunService.RenderStepped:Wait() < 0.05 then
					break
				end
			end
			if gui ~= entering or closing or not BX.alive() then
				return
			end
			fade(true, 0.35, true)
			moving = true
		end)
		sc:delay("settle", 0.1, function()
			if pill and target then
				moveTo(target)
			end
		end)
		frames = 0
		sc:onFrame("frame", RunService.RenderStepped, function(dt)
			frames += 1
			easeNumbers(dt)
			if hovering and not dragging then
				local k = kindAtX(UIS:GetMouseLocation().X)
				if k then
					showTip(k)
				elseif hoverKind then
					hideTip()
				end
			elseif hoverUntil > 0 and os.clock() > hoverUntil then
				hideTip()
			end
			if hoverKind then
				placeTip()
			end
			if dragging and grabInput and grabInput.UserInputType == Enum.UserInputType.MouseButton1 then
				dragTo(UIS:GetMouseLocation())
			end
			if moving and target and pill then
				local p = pill.Position:Lerp(target, 1 - math.exp(- math.min(dt, 1 / 30) * 20))
				if math.abs(p.X.Scale - target.X.Scale) < 1e-4 and math.abs(p.Y.Scale - target.Y.Scale) < 1e-4 then
					p = target
					if not dragging then
						moving = false
					end
				end
				pill.Position = p
			end
		end)
		local myGui = gui
		sc:spawn("ticker", function()
			local last = os.clock()
			local interval = 1 / math.max(cfg.STATS_HZ / 2, 1)
			local tick = BX.profile.wrapLoop("ui.stats/ticker", interval, function()
				local now = os.clock()
				local t = clock(now - sessionT0)
				if labels.time.Text ~= t then
					labels.time.Text = t
				end
				local rawFps = frames / math.max(now - last, 0.001)
				frames, last = 0, now
				shownFps = ema(shownFps, rawFps, FPS_ALPHA)
				st.lastFps = shownFps
				setTarget("fps", shownFps)
				fpsLevel = grade(BANDS.fps, shownFps, fpsLevel)
				local fpsTone = LEVEL_COLOR[fpsLevel]
				paint(labels.fps, "TextColor3", fpsTone)
				tintIcon("pulse", fpsTone)
				if hoverKind and tipLabel then
					local fresh = detailFor(hoverKind)
					if tipLabel.Text ~= fresh then
						tipLabel.Text = fresh
					end
				end
				local raw = readPing()
				if raw and pingEma and raw > math.max(pingEma * SPIKE_FACTOR, SPIKE_FLOOR) then
					pingSuspect = pingSuspect + 1
					if pingSuspect < SPIKE_CONFIRM then
						log.trace("ping outlier held: %.0fms (settled %.0fms)", raw, pingEma)
						raw = nil
					end
				elseif raw then
					pingSuspect = 0
				end
				if raw then
					pingEma = ema(pingEma, raw, PING_ALPHA)
					pingSeenAt = now
					setTarget("ping", pingEma)
					pingLevel = grade(BANDS.ping, pingEma, pingLevel)
					local pingTone = LEVEL_COLOR[pingLevel]
					paint(labels.ping, "TextColor3", pingTone)
					tintIcon("wifi", pingTone)
					if not closing then
						local lit = 3 - pingLevel
						for i, b in ipairs(bars) do
							local want = i <= lit and 0 or 0.7
							if b.Parent and b.BackgroundTransparency ~= want then
								tw(b, 0.3, {
									BackgroundTransparency = want
								})
							end
						end
					end
				elseif pingSeenAt and (now - pingSeenAt) > STALE_AFTER then
					setUnavailable("ping")
					pingEma, pingLevel, pingSeenAt = nil, 0, nil
					tintIcon("wifi", TEXT)
				end
			end)
			while gui == myGui and myGui.Parent and BX.alive() do
				task.wait(interval)
				if gui ~= myGui then
					return
				end
				BX.try("stats.tick", tick)
			end
			if not BX.alive() then
				teardown()
			end
		end)
	end
	M._probe = function()
		return {
			guiAlive = gui ~= nil and gui.Parent ~= nil,
			time = labels.time and labels.time.Text,
			fps = labels.fps and labels.fps.Text,
			ping = labels.ping and labels.ping.Text,
			scale = scaler and scaler.Scale,
			pillSize = pill and tostring(pill.AbsoluteSize),
			conns = sc and # sc.conns or 0,
			fadeN = # fadeList,
		}
	end
	return M
end)
BX.module("ui.window", function(BX)
	local log = BX.require("boot.log").for_module("window")
	local M = {
		ok = true,
		window = {},
		lib = {},
		screen = nil,
		hasNotify = false
	}
	function M.hide()
		return true
	end
	function M.reveal()
		return true
	end
	function M.isVisible()
		return false
	end
	function M.tab(name, order)
		return nil
	end
	function M.notify(title, content, duration)
		log.info("[notify] %s: %s", tostring(title or "DHZ HUB"), tostring(content or ""))
		return false
	end
	function M.unload()
		return true
	end
	M.ORDER = {
		Home = 10,
		Main = 20,
		Farm = 30,
		Event = 40,
		Movement = 50,
		Misc = 60,
		Config = 90
	}
	log.info("direct DHZ UI enabled")
	return M
end)
BX.module("ui.tabs.home", function(BX)
	local exec = BX.require("core.exec")
	local win = BX.require("ui.window")
	local log = BX.require("boot.log").for_module("home")
	local M = {}
	local INVITE = "https://discord.gg/9KSXyabAYV"
	local UPDATES = "V4 (rebuild)\n" .. "- Rebuilt from the ground up: lighter, and every feature cleans up after itself\n" .. "- Stats counter: Material icons, colours that settle instead of flickering\n" .. "- Hover or tap a stat for detail\n" .. "- Loading screen with the Discord built in\n" .. "- Works the same on phones and weaker PCs, not just fast desktops\n"
	function M.build(tab)
		if not tab then
			return M
		end
		tab:CreateSection({
			name = "Discord"
		})
		tab:CreateButton({
			name = "Join Discord",
			description = "discord.gg/9KSXyabAYV",
			callback = function()
				local copied = exec.clipboard(INVITE)
				BX.try("home.openBrowser", function()
					game:GetService("GuiService"):OpenBrowserWindow(INVITE)
				end)
				log.info("discord: %s (copied=%s)", INVITE, tostring(copied))
				win.notify("DHZ HUB", copied and "Invite copied to clipboard" or ("Join at " .. INVITE))
			end,
		})
		tab:CreateSection({
			name = "Updates"
		})
		tab:CreateText({
			name = "Latest",
			text = UPDATES
		})
		return M
	end
	return M
end)
BX.module("features.targetpanel", function(BX)
	local svc = BX.require("core.services")
	local dev = BX.require("core.device")
	local eggs = BX.require("features.eggs")
	local data = BX.require("core.data")
	local auto = BX.require("features.autosteal")
	local ch = BX.require("core.character")
	local log = BX.require("boot.log").for_module("targetpanel")
	local M = {}
	local gui, panel, scroll, status = nil, nil, nil, nil
	local uiConns = {}
	local sc = nil
	local cards = {}
	local selectedUid = nil
	local selectedEgg = nil
	local goButton = nil
	local running = false
	local goRequestId = 0
	local restartingAuto = false
	local ignoreStopUntil = 0
	local unwalkHumanoid = nil
	local unwalkOldWalkSpeed = nil
	local unwalkOldAutoRotate = nil
	local carryAnimate = nil
	local carryAnimateWasEnabled = nil
	local MAX = 40
	local function setCarryAnimation(on)
		local char = ch.character()
		if on then
			local animate = char and char:FindFirstChild("Animate")
			if animate and animate:IsA("LocalScript") then
				carryAnimate = animate
				carryAnimateWasEnabled = animate.Enabled
				animate.Enabled = false
			end
			local hum = ch.humanoid()
			if hum then
				for _, track in ipairs(hum:GetPlayingAnimationTracks()) do
					pcall(function()
						track:Stop(0)
					end)
				end
			end
		else
			if carryAnimate and carryAnimate.Parent and carryAnimate:IsA("LocalScript") and carryAnimateWasEnabled ~= nil then
				carryAnimate.Enabled = carryAnimateWasEnabled
			end
			carryAnimate = nil
			carryAnimateWasEnabled = nil
		end
	end
	local function setUnwalk(on)
		local hum = on and ch.humanoid() or unwalkHumanoid
		if on then
			if not hum then
				return
			end
			if unwalkHumanoid ~= hum then
				unwalkHumanoid = hum
				unwalkOldWalkSpeed = hum.WalkSpeed
				unwalkOldAutoRotate = hum.AutoRotate
			end
			pcall(function()
				hum.WalkSpeed = 0
				hum.AutoRotate = false
			end)
		else
			local oldHum = unwalkHumanoid
			local oldSpeed = unwalkOldWalkSpeed
			local oldRotate = unwalkOldAutoRotate
			unwalkHumanoid, unwalkOldWalkSpeed, unwalkOldAutoRotate = nil, nil, nil
			if oldHum and oldHum.Parent then
				pcall(function()
					if oldSpeed ~= nil then
						oldHum.WalkSpeed = oldSpeed
					end
					if oldRotate ~= nil then
						oldHum.AutoRotate = oldRotate
					end
				end)
			end
		end
	end
	local BG = Color3.fromRGB(38, 4, 15)
	local CARD = Color3.fromRGB(56, 6, 20)
	local CARD2 = Color3.fromRGB(66, 8, 24)
	local TEXT = Color3.fromRGB(245, 242, 242)
	local SUB = Color3.fromRGB(205, 185, 190)
	local ACCENT = Color3.fromRGB(220, 55, 80)
	local SELECTED = Color3.fromRGB(255, 150, 165)
	local function fmtRate(n)
		return eggs.formatRate(tonumber(n) or 0)
	end
	local function fmtKg(n)
		n = tonumber(n) or 0
		if n <= 0 then
			return "?"
		end
		return n >= 100 and ("%.0f"):format(n) or ("%.1f"):format(n)
	end
	local function normalizeIcon(icon)
		if type(icon) == "number" then
			return "rbxassetid://" .. tostring(icon)
		end
		if type(icon) == "string" and icon ~= "" then
			if icon:match("^%d+$") then
				return "rbxassetid://" .. icon
			end
			return icon
		end
		return ""
	end
	local function iconFor(e, dir)
		local d = e and e.assetCategory and dir and dir[e.assetCategory] or nil
		local icon = normalizeIcon(d and d.Icon or nil)
		if icon ~= "" then
			return icon
		end
		return normalizeIcon(e and (e.icon or e.Icon or e.image or e.Image))
	end
	local function rarityFor(e, dir)
		local d = e and e.assetCategory and dir and dir[e.assetCategory] or nil
		if e and e.rarity and e.rarity ~= "?" then
			return tostring(e.rarity)
		end
		if d and d.Rarity then
			return tostring(d.Rarity.DisplayName or d.Rarity._id or "?")
		end
		return "?"
	end
	local function destroyCards()
		for _, c in ipairs(cards) do
			pcall(function()
				c:Destroy()
			end)
		end
		table.clear(cards)
	end
	local function goToSelected()
		local e = selectedEgg
		if not e or not e.uid then
			if status then
				status.Text = "Choose a target first"
			end
			return
		end
		goRequestId = goRequestId + 1
		local myRequest = goRequestId
		task.spawn(function()
			BX.try("targetpanel.start", function()
				if auto.isRunning() and auto.owner() == "main" then
					restartingAuto = true
					ignoreStopUntil = os.clock() + 1.0
					auto.setEnabled(false, "main")
					local deadline = os.clock() + 1.0
					while auto.isRunning() and os.clock() < deadline do
						task.wait(0.03)
					end
					restartingAuto = false
				end
				if myRequest ~= goRequestId then
					return
				end
				auto.setOptions("main", {
					uid = e.uid,
					continuous = false,
				})
				local ok, why = auto.setEnabled(true, "main")
				if ok == false then
					setUnwalk(false)
					if status then
						status.Text = "Auto Steal: " .. tostring(why)
					end
				else
					running = true
					if status then
						status.Text = ("Going to: %s"):format(tostring(e.name))
					end
				end
			end)
		end)
	end
	local function selectEgg(e)
		if not e or not e.uid then
			return
		end
		selectedUid = e.uid
		selectedEgg = e
		if status then
			status.Text = ("Selected: %s  |  %s/s"):format(tostring(e.name), fmtRate(e.value))
		end
	end
	local function styleButton(btn, on)
		btn.BackgroundColor3 = on and CARD2 or CARD
		local stroke = btn:FindFirstChild("TargetStroke")
		if stroke then
			stroke.Color = on and SELECTED or Color3.fromRGB(105, 25, 40)
			stroke.Thickness = on and 2 or 1
		end
	end
	local function makeCard(e, dir, index)
		local b = Instance.new("TextButton")
		b.Name = "Target_" .. tostring(index)
		b.Size = UDim2.new(1, - 8, 0, 82)
		b.BackgroundColor3 = CARD
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.Text = ""
		b.LayoutOrder = index
		b.Parent = scroll
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 0)
		local st = Instance.new("UIStroke")
		st.Name = "TargetStroke"
		st.Color = Color3.fromRGB(105, 25, 40)
		st.Transparency = 0.15
		st.Thickness = 1
		st.Parent = b
		local img = Instance.new("ImageLabel")
		img.Size = UDim2.fromOffset(58, 58)
		img.Position = UDim2.fromOffset(10, 12)
		img.BackgroundTransparency = 1
		img.ScaleType = Enum.ScaleType.Fit
		img.Image = iconFor(e, dir)
		img.Parent = b
		local name = Instance.new("TextLabel")
		name.Size = UDim2.new(1, - 82, 0, 22)
		name.Position = UDim2.fromOffset(76, 7)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.GothamBold
		name.TextSize = 14
		name.TextColor3 = TEXT
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = tostring(e.name or "Unknown")
		name.Parent = b
		local line = Instance.new("TextLabel")
		line.Size = UDim2.new(1, - 82, 0, 21)
		line.Position = UDim2.fromOffset(76, 29)
		line.BackgroundTransparency = 1
		line.Font = Enum.Font.GothamBold
		line.TextSize = 11
		line.TextColor3 = Color3.fromRGB(100, 255, 150)
		line.TextXAlignment = Enum.TextXAlignment.Left
		line.Text = ("Gen: %s/s    KG: %s"):format(fmtRate(e.value), fmtKg(e.kg))
		line.Parent = b
		local rarity = Instance.new("TextLabel")
		rarity.Size = UDim2.new(1, - 82, 0, 20)
		rarity.Position = UDim2.fromOffset(76, 50)
		rarity.BackgroundTransparency = 1
		rarity.Font = Enum.Font.GothamBold
		rarity.TextSize = 11
		rarity.TextColor3 = SUB
		rarity.TextXAlignment = Enum.TextXAlignment.Left
		rarity.TextTruncate = Enum.TextTruncate.AtEnd
		rarity.Text = "Rarity: " .. rarityFor(e, dir)
		rarity.Parent = b
		styleButton(b, selectedUid == e.uid)
		b.MouseButton1Click:Connect(function()
			selectEgg(e)
			for _, other in ipairs(cards) do
				styleButton(other, other == b)
			end
		end)
		return b
	end
	local function rebuild()
		if not scroll or not scroll.Parent then
			return
		end
		local list = eggs.list({}, true)
		local dir = data.assetsDir()
		destroyCards()
		local n = math.min(# list, MAX)
		for i = 1, n do
			cards[# cards + 1] = makeCard(list[i], dir, i)
		end
		scroll.CanvasSize = UDim2.fromOffset(0, n * 88 + 8)
		if n == 0 then
			status.Text = "No eggs found"
		elseif selectedUid then
			local found = false
			for i = 1, n do
				if list[i].uid == selectedUid then
					found = true
					break
				end
			end
			if not found then
				selectedUid = nil
				selectedEgg = nil
			end
		end
	end
	local function buildGui()
		if gui and gui.Parent then
			return
		end
		local parent
		local ok = pcall(function()
			parent = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
		end)
		if not ok or not parent then
			return
		end
		gui = Instance.new("ScreenGui")
		gui.Name = "DHZ_TargetBrowser"
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = parent
		panel = Instance.new("Frame")
		panel.Name = "TargetBrowser"
		panel.Size = UDim2.fromOffset(350, 470)
		panel.AnchorPoint = Vector2.new(1, 0.5)
		panel.Position = UDim2.new(1, - 10, 0.5, 0)
		panel.BackgroundColor3 = BG
		panel.BorderSizePixel = 0
		panel.Parent = gui
		Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 0)
		local ps = Instance.new("UIStroke", panel)
		ps.Color = ACCENT
		ps.Transparency = 0.15
		ps.Thickness = 2
		local header = Instance.new("Frame")
		header.Size = UDim2.new(1, 0, 0, 62)
		header.BackgroundTransparency = 1
		header.Parent = panel
		local title = Instance.new("TextLabel")
		title.Size = UDim2.new(1, - 24, 0, 28)
		title.Position = UDim2.fromOffset(14, 8)
		title.BackgroundTransparency = 1
		title.Font = Enum.Font.GothamBold
		title.TextSize = 19
		title.TextColor3 = TEXT
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Text = "Target UI"
		title.Parent = header
		local sort = Instance.new("TextLabel")
		sort.Size = UDim2.new(1, - 24, 0, 18)
		sort.Position = UDim2.fromOffset(14, 36)
		sort.BackgroundTransparency = 1
		sort.Font = Enum.Font.GothamBold
		sort.TextSize = 10
		sort.TextColor3 = SUB
		sort.TextXAlignment = Enum.TextXAlignment.Left
		sort.Text = "BEST -> WORST  -  sorted by Gen/s"
		sort.Parent = header
		scroll = Instance.new("ScrollingFrame")
		scroll.Name = "Targets"
		scroll.Position = UDim2.fromOffset(8, 66)
		scroll.Size = UDim2.new(1, - 16, 1, - 104)
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.ScrollBarThickness = 3
		scroll.CanvasSize = UDim2.new()
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
		scroll.Parent = panel
		local pad = Instance.new("UIPadding", scroll)
		pad.PaddingTop = UDim.new(0, 3)
		pad.PaddingBottom = UDim.new(0, 5)
		local layout = Instance.new("UIListLayout", scroll)
		layout.Padding = UDim.new(0, 6)
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		status = Instance.new("TextLabel")
		status.Size = UDim2.new(1, - 20, 0, 28)
		status.Position = UDim2.new(0, 10, 1, - 34)
		status.BackgroundTransparency = 1
		status.Font = Enum.Font.GothamBold
		status.TextSize = 10
		status.TextColor3 = SUB
		status.TextXAlignment = Enum.TextXAlignment.Left
		status.Text = "Select an egg, then press GO"
		status.Parent = panel
		goButton = Instance.new("TextButton")
		goButton.Name = "Go"
		goButton.Size = UDim2.fromOffset(62, 28)
		goButton.Position = UDim2.new(1, - 72, 1, - 38)
		goButton.BackgroundColor3 = ACCENT
		goButton.BorderSizePixel = 0
		goButton.AutoButtonColor = false
		goButton.Font = Enum.Font.GothamBold
		goButton.TextSize = 12
		goButton.TextColor3 = TEXT
		goButton.Text = "GO"
		goButton.Parent = panel
		Instance.new("UICorner", goButton).CornerRadius = UDim.new(0, 0)
		local goStroke = Instance.new("UIStroke", goButton)
		goStroke.Color = SELECTED
		goStroke.Transparency = 0.15
		goStroke.Thickness = 1
		goButton.MouseButton1Click:Connect(function()
			goToSelected()
		end)
		local UIS = svc.UserInputService
		local dragging, dragStart, startPos
		uiConns[# uiConns + 1] = header.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = panel.Position
			end
		end)
		uiConns[# uiConns + 1] = header.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
		uiConns[# uiConns + 1] = UIS.InputChanged:Connect(function(input)
			if not dragging then
				return
			end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local delta = input.Position - dragStart
			panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end)
	end
	function M.setVisible(on)
		if on then
			buildGui()
			if panel then
				panel.Visible = true
			end
			if not sc then
				local ES = data.eggState()
				if ES and ES.CarryChanged then
					uiConns[# uiConns + 1] = ES.CarryChanged:Connect(function(info)
						local isCarrying = type(info) == "table" and info.IsCarrying == true
						setUnwalk(isCarrying)
						setCarryAnimation(isCarrying)
					end)
				end
				sc = BX.scope("features.targetpanel")
				sc:loop("refresh", dev.scale(0.8), function()
					if panel and panel.Visible then
						rebuild()
					end
				end)
			end
			task.spawn(function()
				BX.try("targetpanel.initial", rebuild)
			end)
		else
			if panel then
				panel.Visible = false
			end
			if sc then
				sc:destroy()
				sc = nil
			end
		end
	end
	function M.destroy()
		if sc then
			sc:destroy()
			sc = nil
		end
		for _, c in ipairs(uiConns) do
			pcall(function()
				c:Disconnect()
			end)
		end
		table.clear(uiConns)
		if gui then
			pcall(function()
				gui:Destroy()
			end)
		end
		gui, panel, scroll, status, goButton = nil, nil, nil, nil, nil
		selectedEgg = nil
		table.clear(cards)
		setUnwalk(false)
		setCarryAnimation(false)
	end
	auto.onStop(function(why, whose)
		if whose and whose ~= "main" then
			return
		end
		if restartingAuto or os.clock() < ignoreStopUntil then
			return
		end
		running = false
		setUnwalk(false)
		task.spawn(function()
			if status and status.Parent then
				status.Text = why == "delivered" and "Delivered - choose another target" or ("Stopped: " .. tostring(why))
			end
		end)
	end)
	BX.onTeardown("targetpanel", function()
		M.destroy()
	end)
	return M
end)
BX.module("ui.tabs.main", function(BX)
	local auto = BX.require("features.autosteal")
	local eggs = BX.require("features.eggs")
	local targetPanel = BX.require("features.targetpanel")
	local dev = BX.require("core.device")
	local tread = BX.require("features.treadmill")
	local win = BX.require("ui.window")
	local log = BX.require("boot.log").for_module("main")
	local M = {}
	local MAX_EGGS = 40
	local labelToUid = {}
	local rows = {}
	local selectedUid = nil
	local dropdown, toggle = nil, nil
	local selfWrites = 0
	BX.profile.watch("ui.dropdown", function()
		return # rows
	end)
	local function labelFor(egg)
		local suffix = ""
		if egg.guardHeld then
			suffix = "  (guard)"
		elseif egg.dropped then
			suffix = "  (floor)"
		end
		return ("%s  |  %s/s%s"):format(egg.name, eggs.formatRate(egg.value), suffix)
	end
	local function labelName(value)
		if type(value) ~= "string" then
			return nil
		end
		return value:match("^(.-)%s%s|%s%s") or value
	end
	local function buildOptions()
		local list = eggs.list({}, true)
		labelToUid = {}
		rows = {}
		local options, used = {}, {}
		for i, egg in ipairs(list) do
			if i > MAX_EGGS then
				break
			end
			local label = labelFor(egg)
			if used[label] then
				local n = used[label] + 1
				used[label] = n
				label = label .. ("  #%d"):format(n)
			else
				used[label] = 1
			end
			labelToUid[label] = egg.uid
			rows[# rows + 1] = egg
			options[# options + 1] = label
		end
		if # options == 0 then
			options[1] = "No eggs found"
		end
		return options
	end
	local function eggForLabel(value)
		if type(value) ~= "string" or value == "" or value == "No eggs found" then
			return nil
		end
		local uid = labelToUid[value]
		if uid then
			for _, e in ipairs(rows) do
				if e.uid == uid then
					return e
				end
			end
			return {
				uid = uid,
				name = labelName(value) or value
			}
		end
		local want = labelName(value)
		if want then
			for _, e in ipairs(rows) do
				if e.name == want then
					return e
				end
			end
		end
		return nil
	end
	local refreshing = false
	local function refresh(reason)
		if refreshing or not dropdown then
			return
		end
		refreshing = true
		local options = BX.offthread(buildOptions, 5)
		local ok = BX.try("main.refresh", function()
			if type(options) ~= "table" then
				log.warn("refresh: egg read timed out - list left as it was")
				return
			end
			local keep = nil
			if selectedUid then
				for label, uid in pairs(labelToUid) do
					if uid == selectedUid then
						keep = label
						break
					end
				end
				if not keep then
					log.info("selected egg %s is gone - clearing", tostring(selectedUid))
					selectedUid = nil
					if not (auto.isRunning() and auto.owner() == "main") then
						auto.setOptions("main", {
							uid = nil
						})
					end
				end
			end
			dropdown:Refresh(options)
			if keep then
				dropdown:Set(keep)
			end
		end)
		refreshing = false
		log.trace("refresh (%s): %d options%s", tostring(reason), # rows, ok and "" or " FAILED")
	end
	M.refresh = refresh
	function M.build(tab)
		if not tab then
			return M
		end
		task.spawn(function()
			targetPanel.setVisible(true)
		end)
		tab:CreateSection({
			name = "How It Works"
		})
		tab:CreateText({
			name = "How It Works",
			text = "Pick an egg and press Auto Steal. It baits the Forest " .. "guard, teleports to your egg, carries it to the safe zone " .. "and stops.",
		})
		tab:CreateSection({
			name = "Target Egg"
		})
		tab:CreateText({
			name = "Target Browser",
			text = "The Target UI shows the same ESP information inside the hub. " .. "Tap a card to select it and start Auto Steal immediately. " .. "Targets are ordered from best to worst by Gen/s.",
		})
		tab:CreateButton({
			name = "Open Target UI",
			callback = function()
				targetPanel.setVisible(true)
			end,
		})
		tab:CreateSection({
			name = "Auto Steal"
		})
		toggle = tab:CreateToggle({
			name = "Auto Steal",
			value = false,
			flag = "AutoSteal",
			callback = function(on)
				if on then
					selfWrites = 0
					local okStart, why = auto.setEnabled(true, "main")
					if okStart == false then
						win.notify("Auto Steal", tostring(why), 6)
						task.spawn(function()
							BX.try("main.toggleRefused", function()
								if toggle and toggle.Set then
									selfWrites = selfWrites + 1
									toggle:Set(false)
								end
							end)
						end)
					end
					return
				end
				if selfWrites > 0 then
					selfWrites = selfWrites - 1
					return
				end
				auto.setEnabled(false, "main")
			end,
		})
		auto.onIdle(function(why, whose)
			if whose and whose ~= "main" then
				return
			end
			local text = tostring(why)
			if text:find("egg inventory full", 1, true) then
				text = "Waiting: your egg inventory is full" .. (text:match("%(%d+/%d+%)") and (" " .. text:match("%(%d+/%d+%)")) or "") .. ". Sell, place or hatch eggs - it starts by itself."
			elseif text == "field resetting" then
				local data = BX.require("core.data")
				local left = data.secondsUntilReset()
				local wait
				if data.fieldSealed() then
					wait = (left and left < 60) and (left + 6) or 6
				else
					wait = left and (left + 6) or nil
				end
				text = wait and ("Waiting for the egg field reset - Auto Steal starts by itself in ~%ds. Leave it on."):format(math.ceil(wait)) or "Waiting for the egg field reset - Auto Steal starts by itself. Leave it on."
			else
				text = "Waiting: " .. text
			end
			task.spawn(function()
				win.notify("Auto Steal", text, 7)
			end)
		end)
		auto.onStop(function(why, whose)
			if whose and whose ~= "main" then
				return
			end
			auto.setOptions("main", {
				uid = selectedUid,
				continuous = true
			})
			if why == "selected egg is gone" then
				task.spawn(function()
					win.notify("Auto Steal", "Your egg is gone - stopped. Pick another.", 5)
				end)
			end
			task.spawn(function()
				BX.try("main.toggleOff", function()
					if toggle and toggle.Set then
						selfWrites = selfWrites + 1
						toggle:Set(false)
					end
				end)
			end)
			if why == "delivered" then
				task.spawn(function()
					win.notify("Auto Steal", "Delivered - stopped.", 4)
				end)
			end
		end)
		tab:CreateSection({
			name = "ESP"
		})
		tab:CreateText({
			name = "Target ESP",
			text = "Egg ESP cards are shown in the Target UI instead of being drawn over the map. " .. "The card keeps the image, name, Gen/s, KG and rarity.",
		})
		tab:CreateButton({
			name = "Show Target Cards",
			callback = function()
				targetPanel.setVisible(true)
			end,
		})
		tab:CreateToggle({
			name = "Plot ESP",
			value = false,
			callback = function(on)
				BX.try("main.plotEsp", function()
					BX.require("features.esp.plot").setEnabled(on)
				end)
			end,
		})
		tab:CreateSection({
			name = "Anti Treadmill"
		})
		tab:CreateToggle({
			name = "Anti Treadmill",
			value = true,
			flag = "AntiTreadmill",
			callback = function(on)
				tread.setEnabled(on and true or false)
			end,
		})
		local sc = BX.scope("ui.tabs.main")
		sc:loop("prune", dev.scale(10), function()
			if not selectedUid then
				return
			end
			local still = eggs.get(selectedUid)
			if not still then
				refresh("selected egg vanished")
			end
		end)
		log.info("main tab built (%d eggs)", # rows)
		return M
	end
	return M
end)
BX.module("ui.tabs.farm", function(BX)
	local auto = BX.require("features.autosteal")
	local eggs = BX.require("features.eggs")
	local filter = BX.require("features.farm.filter")
	local hold = BX.require("features.farm.treadmill_on")
	local pets = BX.require("features.farm.pets")
	local care = BX.require("features.farm.plotcare")
	local win = BX.require("ui.window")
	local log = BX.require("boot.log").for_module("farm.tab")
	local M = {}
	local autoToggle, holdToggle, statusLine
	local areaDrop, rarityDrop
	local statusSc, lastStatus = nil, nil
	local function paintStatus(text)
		if not statusLine or text == lastStatus then
			return
		end
		if BX.try("farm.status", function()
			statusLine:Set(text)
		end) then
			lastStatus = text
		end
	end
	local function statusText()
		local st = filter.status()
		if not auto.isRunning() or auto.owner() ~= "farm" then
			return "off"
		end
		local idle = auto.status().idle
		if idle then
			local areasOut = tostring(idle):match("guards out: (.+)%)$")
			if areasOut then
				return "ON  \u{B7}  waiting for the guard to walk home (" .. areasOut .. ") - keeps going by itself"
			end
			return "ON  \u{B7}  waiting: " .. tostring(idle)
		end
		if care.isPlacing() and care.status():find("walking to your plot", 1, true) then
			return "ON  \u{B7}  placing the egg on your plot"
		end
		return "ON  \u{B7}  " .. tostring(st.text)
	end
	local statusWanted = false
	local pendingStatus = nil
	local plotLine, lastPlot = nil, nil
	local function watchStatus(on)
		statusWanted = on and true or false
	end
	local function watchPlot()
	end
	local selfAuto, selfHold = 0, 0
	local areaIds, rarityIds = {}, {}
	local function labelsAndMap(rows)
		local labels, map = {}, {}
		for _, r in ipairs(rows) do
			labels[# labels + 1] = r.label
			map[r.label] = r.id
		end
		return labels, map
	end
	local function idsFor(picked, map)
		local out = {}
		if type(picked) == "table" then
			for _, label in pairs(picked) do
				local id = map[tostring(label)]
				if id then
					out[# out + 1] = id
				end
			end
		elseif type(picked) == "string" and picked ~= "" then
			local id = map[picked]
			if id then
				out[# out + 1] = id
			end
		end
		return out
	end
	local function farmOptions()
		return {
			pick = filter.pick,
			continuous = true,
		}
	end
	function M.build(tab)
		if not tab then
			return M
		end
		tab:CreateSection({
			name = "How It Works"
		})
		tab:CreateText({
			name = "How It Works",
			text = "Describe what you want and press Auto Steal. It keeps " .. "taking eggs that match until you turn it off. Main takes " .. "one egg you picked by name instead.",
		})
		tab:CreateSection({
			name = "Egg Filters"
		})
		local areaRows = filter.areaOptions()
		local areaLabels
		areaLabels, areaIds = labelsAndMap(areaRows)
		areaDrop = tab:CreateDropdown({
			name = "Areas",
			options = # areaLabels > 0 and areaLabels or {
				"No areas found"
			},
			multiSelect = true,
			flag = "FarmAreas",
			callback = function(picked)
				filter.setAreas(idsFor(picked, areaIds))
			end,
		})
		local rarityRows = filter.rarityOptions()
		local rarityLabels
		rarityLabels, rarityIds = labelsAndMap(rarityRows)
		rarityDrop = tab:CreateDropdown({
			name = "Rarities",
			options = # rarityLabels > 0 and rarityLabels or {
				"No rarities found"
			},
			multiSelect = true,
			flag = "FarmRarities",
			callback = function(picked)
				filter.setRarities(idsFor(picked, rarityIds))
			end,
		})
		tab:CreateDropdown({
			name = "Target By",
			options = filter.targetByOptions(),
			currentOption = "Income",
			flag = "FarmTargetBy",
			callback = function(v)
				filter.setTargetBy(type(v) == "table" and v[1] or v)
			end,
		})
		tab:CreateButton({
			name = "Refresh Eggs",
			callback = function()
				eggs.invalidate("farm refresh")
				eggs.list({}, true)
				local n = filter.matchCount()
				log.info("refresh: %d eggs match (%s)", n, filter.describe())
				win.notify("Farm", n .. " eggs match your filters", 3)
				local _, why = filter.pick()
				if not statusWanted then
					pendingStatus = ("%d eggs match your filters%s"):format(n, why and (n == 0) and ("  \u{B7}  " .. tostring(filter.status().text)) or "")
				end
			end,
		})
		tab:CreateSection({
			name = "Auto Farm"
		})
		statusLine = tab:CreateText({
			name = "Status",
			text = "off"
		})
		autoToggle = tab:CreateToggle({
			name = "Auto Steal",
			value = false,
			flag = "FarmAutoSteal",
			callback = function(on)
				BX.try("farm.autoToggle", function()
					log.info("toggle -> %s", on and "ON" or "OFF")
					if on then
						selfAuto = 0
						if hold.isOn() then
							hold.setEnabled(false)
						end
						auto.setOptions("farm", farmOptions())
						log.info("options handed over (%s)", filter.describe())
						local okStart, why = auto.setEnabled(true, "farm")
						log.info("start requested: running=%s owner=%s", tostring(auto.isRunning()), tostring(auto.owner()))
						if okStart == false then
							pendingStatus = tostring(why)
							win.notify("Farm", tostring(why), 6)
							task.spawn(function()
								BX.try("farm.toggleRefused", function()
									if autoToggle and autoToggle.Set then
										selfAuto = selfAuto + 1
										autoToggle:Set(false)
									end
								end)
							end)
							return
						end
						watchStatus(true)
						return
					end
					watchStatus(false)
					if selfAuto > 0 then
						selfAuto = selfAuto - 1
						log.trace("ignored our own Set(false)")
						return
					end
					auto.setEnabled(false, "farm")
				end)
			end,
		})
		holdToggle = tab:CreateToggle({
			name = "Stay On Treadmill",
			value = false,
			flag = "StayOnTreadmill",
			callback = function(on)
				if selfHold > 0 then
					selfHold = selfHold - 1
					return
				end
				local ok, why = hold.setEnabled(on and true or false)
				if on and not ok then
					BX.try("farm.holdRefused", function()
						if holdToggle and holdToggle.Set then
							selfHold = selfHold + 1
							holdToggle:Set(false)
						end
					end)
					win.notify("Farm", tostring(why or "Could not stay on the belt"), 4)
				end
			end,
		})
		tab:CreateSection({
			name = "Plot"
		})
		plotLine = tab:CreateText({
			name = "Plot",
			text = care.status()
		})
		tab:CreateToggle({
			name = "Auto Place Eggs",
			value = false,
			callback = function(on)
				BX.try("farm.autoPlace", function()
					care.setPlace(on)
				end)
				watchPlot()
			end,
		})
		tab:CreateToggle({
			name = "Auto Hatch",
			value = false,
			callback = function(on)
				BX.try("farm.autoHatch", function()
					care.setHatch(on)
				end)
				watchPlot()
			end,
		})
		tab:CreateSection({
			name = "Pets"
		})
		tab:CreateButton({
			name = "Equip Best Pets",
			callback = function()
				local ok, msg = pets.equipBest()
				win.notify("Pets", tostring(msg), ok and 3 or 4)
			end,
		})
		statusSc = BX.scope("ui.tabs.farm.paint")
		statusSc:loop("paint", 1.0, function()
			if statusWanted then
				pendingStatus = nil
				paintStatus(statusText())
			elseif pendingStatus then
				paintStatus(pendingStatus)
				pendingStatus = nil
			elseif lastStatus and lastStatus:find("^ON") and not auto.isRunning() then
				paintStatus("off")
			end
			if plotLine then
				local text = care.status()
				if text ~= lastPlot and BX.try("farm.plotPaint", function()
					plotLine:Set(text)
				end) then
					lastPlot = text
				end
			end
		end)
		if not M.wiredPlace then
			M.wiredPlace = true
			auto.setBetweenCycles(function(whose)
				if whose ~= "farm" or not care.isPlacing() then
					return
				end
				care.placeNow()
			end)
		end
		if not M.wired then
			M.wired = true
			auto.onStop(function(why, whose)
				if whose and whose ~= "farm" then
					return
				end
				task.spawn(function()
					BX.try("farm.toggleOff", function()
						watchStatus(false)
						if autoToggle and autoToggle.Set then
							selfAuto = selfAuto + 1
							autoToggle:Set(false)
						end
					end)
				end)
			end)
		end
		log.info("farm tab built (%d areas, %d rarities)", # areaLabels, # rarityLabels)
		return M
	end
	function M.teardown()
		autoToggle, holdToggle, statusLine, areaDrop, rarityDrop = nil, nil, nil, nil, nil
		lastStatus = nil
		if statusSc then
			statusSc:destroy()
			statusSc = nil
		end
		if auto.isRunning() and auto.owner() == "farm" then
			auto.setEnabled(false, "farm")
		end
		if hold.isOn() then
			hold.setEnabled(false)
		end
		plotLine, lastPlot = nil, nil
		statusWanted = false
		care.setPlace(false)
		care.setHatch(false)
		log.info("farm tab torn down")
	end
	return M
end)
BX.module("ui.tabs.event", function(BX)
	local boss = BX.require("features.boss")
	local fight = BX.require("features.bossfight")
	local rift = BX.require("features.rift")
	local auto = BX.require("features.autosteal")
	local win = BX.require("ui.window")
	local log = BX.require("boot.log").for_module("event.tab")
	local M = {}
	local K = {
		PAINT = 1.0,
	}
	M.K = K
	local sc = nil
	local bossLine, fightLine, riftLine, petDrop, autoRiftToggle, fightToggle
	local suppressDrop, selfAuto = 0, 0
	local lastOptSig = nil
	local painted = {}
	local function say(msg, secs)
		win.notify("Event", tostring(msg), secs or 3)
	end
	local function paint(el, st)
		if not el then
			return
		end
		local last = painted[el]
		if not last then
			last = {}
			painted[el] = last
		end
		if st.title and st.title ~= last.title then
			if BX.try("event.setTitle", function()
				el:SetTitle(st.title)
			end) then
				last.title = st.title
			end
		end
		if st.body ~= last.body then
			if BX.try("event.setBody", function()
				el:Set(st.body)
			end) then
				last.body = st.body
			end
		end
	end
	local function repaintBoss()
		paint(bossLine, boss.status())
		paint(fightLine, fight.status())
	end
	local function repaintRift()
		paint(riftLine, rift.status())
		if not petDrop then
			return
		end
		local opts = rift.options()
		local sig = table.concat(opts, "\1")
		if sig == lastOptSig then
			return
		end
		lastOptSig = sig
		BX.try("event.refreshDrop", function()
			suppressDrop = suppressDrop + 1
			petDrop:Refresh(opts)
		end)
	end
	function M.build(tab)
		if not tab then
			return M
		end
		tab:CreateSection({
			name = "Boss"
		})
		bossLine = tab:CreateText({
			name = "Abyss Overlord",
			text = "Reading..."
		})
		tab:CreateButton({
			name = "Enter the boss world",
			description = "Only works while it is open",
			callback = function()
				if not boss.isOn() then
					boss.setEnabled(true)
				end
				task.spawn(function()
					BX.try("event.enter", function()
						local ok, why = boss.enter()
						say(why, ok and 3 or 4)
					end)
				end)
			end,
		})
		tab:CreateToggle({
			name = "Auto enter",
			description = "Joins as soon as it opens",
			value = false,
			callback = function(v)
				v = v and true or false
				if v and not boss.isOn() then
					boss.setEnabled(true)
				end
				boss.setAutoEnter(v)
				say("Auto enter " .. (v and "ON" or "OFF"))
			end,
		})
		fightToggle = tab:CreateToggle({
			name = "Auto fight",
			description = "Breaks the crystals, then the boss",
			value = false,
			callback = function(v)
				v = v and true or false
				fight.setEnabled(v)
				say("Auto fight " .. (v and "ON" or "OFF"))
			end,
		})
		fightLine = tab:CreateText({
			name = "Auto fight",
			text = "off"
		})
		tab:CreateButton({
			name = "Claim mastery rewards",
			description = "Collects everything you have earned",
			callback = function()
				task.spawn(function()
					BX.try("event.claim", function()
						local n, msg = boss.claimMilestones()
						say(msg, n > 0 and 3 or 4)
					end)
				end)
			end,
		})
		tab:CreateSection({
			name = "Rift"
		})
		riftLine = tab:CreateText({
			name = "Rift",
			text = "reading..."
		})
		petDrop = tab:CreateDropdown({
			name = "Rift pet",
			options = {
				rift.K.NONE_LABEL
			},
			currentOption = rift.K.NONE_LABEL,
			callback = function(v)
				if suppressDrop > 0 then
					suppressDrop = suppressDrop - 1
					log.trace("ignored our own dropdown write")
					return
				end
				if not rift.isOn() then
					rift.setEnabled(true)
				end
				local picked = type(v) == "table" and v[1] or v
				local id = rift.idForLabel(picked)
				rift.setPick(id)
				if id then
					say("Rift pet: " .. rift.petName(id))
				end
			end,
		})
		tab:CreateButton({
			name = "Refresh",
			description = "Re-read the rift and the pet list",
			callback = function()
				if not rift.isOn() then
					rift.setEnabled(true)
				end
				if not boss.isOn() then
					boss.setEnabled(true)
				end
				boss.refresh()
				task.spawn(function()
					BX.try("event.riftRefresh", function()
						rift.refresh("refresh button")
						local out = rift.onField()
						if # out > 0 then
							local names = {}
							for _, id in ipairs(out) do
								names[# names + 1] = rift.petName(id)
							end
							say("Rift: " .. table.concat(names, ", "), 4)
						else
							say("Rift: none out", 3)
						end
					end)
				end)
			end,
		})
		autoRiftToggle = tab:CreateToggle({
			name = "Auto steal rift pets",
			description = "Steals only the rift pets",
			value = false,
			callback = function(v)
				if not v then
					if selfAuto > 0 then
						selfAuto = selfAuto - 1
						return
					end
					if auto.isRunning() and auto.owner() == "rift" then
						auto.setEnabled(false, "rift")
					end
					say("Rift auto OFF")
					return
				end
				if not rift.isOn() then
					rift.setEnabled(true)
				end
				auto.setOptions("rift", {
					pick = rift.pickTarget,
					continuous = true
				})
				auto.setEnabled(true, "rift")
				say("Rift auto ON")
			end,
		})
		tab:CreateToggle({
			name = "Auto trade-in",
			description = "Puts your 3 rift pets in the Rift when you have them (lightest first, never equipped)",
			value = false,
			callback = function(v)
				v = v and true or false
				rift.setAutoTrade(v)
				say("Auto trade-in " .. (v and "ON" or "OFF"))
			end,
		})
		if not M.wired then
			rift.onTrade(function(r)
				if not sc then
					return
				end
				if r == "traded" then
					say("Rift: traded in - Rift Egg added to your eggs", 5)
				elseif r ~= "revealed" then
					say("Rift trade-in " .. tostring(r), 6)
				end
			end)
		end
		sc = BX.scope("ui.tabs.event")
		sc:loop("paint", K.PAINT, function()
			repaintBoss()
			repaintRift()
		end)
		boss.setEnabled(true)
		rift.setEnabled(true)
		if not M.wired then
			M.wired = true
			auto.onStop(function(_, whose)
				if whose and whose ~= "rift" then
					return
				end
				task.spawn(function()
					BX.try("event.riftAutoOff", function()
						if autoRiftToggle and autoRiftToggle.Set then
							selfAuto = selfAuto + 1
							autoRiftToggle:Set(false)
						end
					end)
				end)
			end)
		end
		log.info("event tab built (V3.1 layout: Boss 5 + Rift 4; watchers on, painter %.0fs)", K.PAINT)
		return M
	end
	function M.teardown()
		bossLine, fightLine, riftLine, petDrop, autoRiftToggle, fightToggle = nil, nil, nil, nil, nil, nil
		painted, lastOptSig, suppressDrop, selfAuto = {}, nil, 0, 0
		if sc then
			sc:destroy()
			sc = nil
		end
		BX.try("event.teardown", function()
			if auto.isRunning() and auto.owner() == "rift" then
				auto.setEnabled(false, "rift")
			end
			fight.setEnabled(false)
			boss.setAutoEnter(false)
			boss.setEnabled(false)
			rift.setAutoTrade(false)
			rift.setEnabled(false)
		end)
		log.info("event tab torn down")
	end
	return M
end)
BX.module("ui.tabs.misc", function(BX)
	local servers = BX.require("features.misc.servers")
	local hook = BX.require("features.misc.webhook")
	local fps = BX.require("features.fps")
	local win = BX.require("ui.window")
	local log = BX.require("boot.log").for_module("misc.tab")
	local M = {}
	local webhookStatus = nil
	local function say(title, ok, msg)
		win.notify(title, tostring(msg), ok and 3 or 4)
	end
	function M.build(tab)
		if not tab then
			return M
		end
		tab:CreateSection({
			name = "Performance"
		})
		tab:CreateToggle({
			name = "FPS Boost",
			value = true,
			callback = function(on)
				on = on and true or false
				if not on then
					fps.userTurnedOff = true
				end
				BX.try("misc.fpsToggle", function()
					fps.setEnabled(on)
				end)
			end,
		})
		tab:CreateSection({
			name = "Servers"
		})
		tab:CreateButton({
			name = "Lowest Server",
			callback = function()
				local ok, msg = servers.lowestServer()
				say("Servers", ok, msg)
			end,
		})
		tab:CreateButton({
			name = "Server Hop",
			callback = function()
				local ok, msg = servers.hop()
				say("Servers", ok, msg)
			end,
		})
		tab:CreateSection({
			name = "Webhooks"
		})
		local exec = BX.require("core.exec")
		tab:CreateToggle({
			name = "Enable Webhook",
			value = false,
			flag = "WebhookOn",
			callback = function(on)
				BX.try("misc.webhookToggle", function()
					hook.setEnabled(on)
				end)
				if on and not exec.can.request then
					local why = "Webhooks are not supported by this executor (no HTTP request API)"
					log.warn("%s", why)
					win.notify("Webhook", why, 6)
					BX.try("misc.webhookStatus", function()
						if webhookStatus then
							webhookStatus:Set(why)
						end
					end)
				end
			end,
		})
		if not exec.can.request then
			webhookStatus = tab:CreateText({
				name = "Webhook",
				text = "Not supported by this executor (no HTTP request API). Everything else works.",
			})
		end
		tab:CreateInput({
			name = "Webhook URL",
			placeholder = "https://discord.com/api/webhooks/...",
			callback = function(v)
				local ok, msg = hook.setUrl(v)
				if not ok then
					say("Webhooks", false, msg)
				end
			end,
		})
		tab:CreateButton({
			name = "Test Webhook",
			callback = function()
				local ok, msg = hook.test()
				say("Webhooks", ok, msg)
			end,
		})
		log.info("misc tab built")
		return M
	end
	function M.teardown()
		webhookStatus = nil
		BX.try("misc.teardown", function()
			hook.setEnabled(false)
		end)
		log.info("misc tab torn down")
	end
	return M
end)
BX.module("ui.tabs.movement", function(BX)
	local speed = BX.require("features.speed")
	local dev = BX.require("core.device")
	local win = BX.require("ui.window")
	local log = BX.require("boot.log").for_module("movement.tab")
	local M = {}
	local speedToggle
	local speedSelfWrites = 0
	local sc = nil
	local speedLine, lastSpeedLine = nil, nil
	local function paintSpeed()
		if not speedLine then
			return
		end
		local text = speed.status()
		if text == lastSpeedLine then
			return
		end
		if BX.try("movement.speedPaint", function()
			speedLine:Set(text)
		end) then
			lastSpeedLine = text
		end
	end
	function M.build(tab)
		if not tab then
			return M
		end
		tab:CreateSection({
			name = "How It Works"
		})
		tab:CreateText({
			name = "How It Works",
			text = "Speed Boost makes your normal walking faster - you steer, it " .. "only adds speed. It pauses by itself while Auto Steal or Auto " .. "fight is moving you, and turns itself off if the server keeps " .. "correcting your movement.",
		})
		tab:CreateSection({
			name = "Speed"
		})
		speedLine = tab:CreateText({
			name = "Speed",
			text = speed.status()
		})
		speedToggle = tab:CreateToggle({
			name = "Speed Boost",
			value = false,
			callback = function(on)
				if not on and speedSelfWrites > 0 then
					speedSelfWrites = speedSelfWrites - 1
					paintSpeed()
					return
				end
				if on then
					speedSelfWrites = 0
				end
				BX.try("movement.speedToggle", function()
					speed.setEnabled(on)
				end)
				paintSpeed()
			end,
		})
		if not M.wired then
			M.wired = true
			speed.onAutoOff(function(why)
				win.notify("Movement", tostring(why), 6)
			end)
		end
		BX.try("movement.speedSlider", function()
			if type(tab.CreateSlider) ~= "function" then
				error("no CreateSlider on this build", 0)
			end
			tab:CreateSlider({
				name = "Walk Speed",
				range = {
					speed.K.SPEED_MIN,
					speed.K.SPEED_MAX
				},
				increment = 10,
				currentValue = speed.K.SPEED_DEFAULT,
				suffix = " studs/s",
				callback = function(v)
					speed.setSpeed(v)
					paintSpeed()
				end,
			})
		end)
		sc = BX.scope("ui.tabs.movement")
		sc:loop("sync", dev.scale(1.0), function()
			paintSpeed()
			if speedToggle and not speed.isOn() then
				local shown = speedToggle.CurrentValue
				if shown == nil then
					shown = speedToggle.Value
				end
				if shown == true then
					BX.try("movement.speedForceOff", function()
						speedSelfWrites = speedSelfWrites + 1
						speedToggle:Set(false)
					end)
				end
			end
		end)
		log.info("movement tab built (touch=%s, fly removed)", tostring(dev.isTouch))
		return M
	end
	function M.teardown()
		speedToggle, speedSelfWrites = nil, 0
		speedLine, lastSpeedLine = nil, nil
		if sc then
			sc:destroy()
			sc = nil
		end
		BX.try("movement.speedTeardown", function()
			speed.setEnabled(false)
		end)
		log.info("movement tab torn down")
	end
	return M
end)
BX.module("ui.tabs.config", function(BX)
	local prof = BX.require("core.profiles")
	local look = BX.require("features.misc.appearance")
	local win = BX.require("ui.window")
	local log = BX.require("boot.log").for_module("config.tab")
	local M = {}
	local nameBox, loadDrop, autoDrop, bgInput, statusLine
	local NONE = "None"
	local function say(ok, msg)
		win.notify("Config", tostring(msg), ok and 3 or 4)
		BX.try("config.status", function()
			if statusLine then
				statusLine:Set(tostring(msg))
			end
		end)
	end
	local function options()
		local list = prof.list()
		local out = {
			NONE
		}
		for _, n in ipairs(list) do
			out[# out + 1] = n
		end
		return out
	end
	local function refreshLists()
		local opts = options()
		BX.try("config.refreshLists", function()
			if loadDrop and loadDrop.Refresh then
				loadDrop:Refresh(opts)
			end
			if autoDrop and autoDrop.Refresh then
				autoDrop:Refresh(opts)
			end
		end)
		return opts
	end
	local function boxValue(box)
		if not box then
			return ""
		end
		local v = box.CurrentValue
		if v == nil or v == "" then
			v = box.Value
		end
		if v == nil or v == "" then
			v = box.value
		end
		if (v == nil or v == "") and typeof(box.input) == "Instance" then
			pcall(function()
				v = box.input.Text
			end)
		end
		return tostring(v or "")
	end
	local function pick(v)
		local s = type(v) == "table" and v[1] or v
		s = tostring(s or "")
		if s == NONE then
			return ""
		end
		return s
	end
	function M.build(tab)
		if not tab then
			return M
		end
		tab:CreateSection({
			name = "Appearance"
		})
		tab:CreateDropdown({
			name = "Theme",
			options = look.themes(),
			flag = "Theme",
			callback = function(v)
				local ok, msg = look.setTheme(pick(v))
				if not ok then
					say(false, msg)
				end
			end,
		})
		bgInput = tab:CreateInput({
			name = "Background Image ID",
			placeholder = "0000000000",
			flag = "Background",
			callback = function(v)
				local ok, msg = look.setBackground(v)
				say(ok, msg)
			end,
		})
		tab:CreateButton({
			name = "Clear Background",
			callback = function()
				local ok, msg = look.clearBackground()
				BX.try("config.clearInput", function()
					if bgInput and bgInput.Set then
						bgInput:Set("")
					end
				end)
				say(ok, msg)
			end,
		})
		tab:CreateSection({
			name = "Profiles"
		})
		if not prof.available() then
			tab:CreateText({
				name = "Profiles",
				text = "Config saving is not supported by this executor. " .. "Everything else works normally.",
			})
			log.warn("no filesystem (%s) - profile controls not built", table.concat(BX.require("core.exec").report().missing, ","))
			return M
		end
		nameBox = tab:CreateInput({
			name = "Profile Name",
			placeholder = "my settings",
			callback = function()
			end,
		})
		statusLine = tab:CreateText({
			name = "Status",
			text = "Type a name and press Save Profile"
		})
		tab:CreateButton({
			name = "Save Profile",
			callback = function()
				local ok, msg = prof.save(boxValue(nameBox))
				if ok then
					refreshLists()
				end
				say(ok, msg)
			end,
		})
		loadDrop = tab:CreateDropdown({
			name = "Load Profile",
			options = options(),
			currentOption = NONE,
			callback = function(v)
				local name = pick(v)
				if name == "" then
					return
				end
				local ok, msg = prof.load(name)
				say(ok, msg)
			end,
		})
		tab:CreateButton({
			name = "Refresh Profiles",
			callback = function()
				prof.refresh()
				local opts = refreshLists()
				say(true, (# opts - 1) .. " profiles")
			end,
		})
		tab:CreateButton({
			name = "Delete Profile",
			callback = function()
				local ok, msg = prof.delete(boxValue(nameBox))
				if ok then
					refreshLists()
				end
				say(ok, msg)
			end,
		})
		autoDrop = tab:CreateDropdown({
			name = "Auto Load Profile",
			options = options(),
			currentOption = prof.autoLoadName() or NONE,
			callback = function(v)
				local ok, msg = prof.setAutoLoad(pick(v))
				say(ok, msg)
			end,
		})
		log.info("config tab built (%d profiles)", # prof.list())
		return M
	end
	return M
end)
BX.module("features.movement", function(BX)
	local svc = BX.require("core.services")
	local ch = BX.require("core.character")
	local dev = BX.require("core.device")
	local rs = BX.require("core.restore")
	local log = BX.require("boot.log").for_module("movement")
	local RunService, Players = svc.RunService, svc.Players
	local M = {}
	local K = {
		GROUND_OFFSET = 3,
		CRUISE_UP = 18,
		RAMP_FRAC = 0.12,
		RAMP_MAX = 220,
		RAMP_MIN = 40,
		START_SPEED = 0.45,
		SPEED_RAMP_FRAC = 0.28,
		SLOW_RADIUS = 50,
		SLOW_SPEED = 260,
		ARRIVE = 5,
		MAX_DT = 0.05,
		MAX_FRAME = 0.25,
		MAX_DEBT = 2.0,
		MAX_STEP = 20,
		SPEED = 1200,
		SPEED_NOSPOOF = 500,
		NOSPOOF_FLOOR = 300,
		NOSPOOF_CONVERGE = 40,
		DROP_SPEED = 400,
		SPOOF_HEADROOM = 1.35,
		WS_MAX = 4000,
		WALKSPEED_SANE_MIN = 40,
		RELOC_CLAMP_FOR = 6,
		RELOC_CLAMP_RATIO = 1.04,
		TP_SETTLE = 0.35,
		TP_LANDED = 30,
	}
	M.K = K
	local ac = nil
	function M.setAnticheat(adapter)
		ac = adapter
	end
	local function acGet(name)
		local f = ac and ac[name]
		return type(f) == "function" and f or nil
	end
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.IgnoreWater = true
	local filterDirty = true
	local scratchIgnore = {}
	local function rebuildFilter()
		local n = 0
		for i = # scratchIgnore, 1, - 1 do
			scratchIgnore[i] = nil
		end
		for _, pl in ipairs(Players:GetPlayers()) do
			if pl.Character then
				n = n + 1
				scratchIgnore[n] = pl.Character
			end
		end
		groundParams.FilterDescendantsInstances = scratchIgnore
		filterDirty = false
	end
	local function solidGroundY(pos)
		if filterDirty then
			rebuildFilter()
		end
		local origin = pos + Vector3.new(0, 80, 0)
		local dir = Vector3.new(0, - 700, 0)
		local extra = nil
		for _ = 1, 15 do
			local r = workspace:Raycast(origin, dir, groundParams)
			if not r then
				break
			end
			if r.Instance.CanCollide then
				if extra then
					groundParams.FilterDescendantsInstances = scratchIgnore
				end
				return r.Position.Y + K.GROUND_OFFSET
			end
			extra = extra or table.clone(scratchIgnore)
			extra[# extra + 1] = r.Instance
			groundParams.FilterDescendantsInstances = extra
		end
		if extra then
			groundParams.FilterDescendantsInstances = scratchIgnore
		end
		return nil
	end
	local function groundOr(pos, fallback)
		return solidGroundY(pos) or fallback
	end
	M.groundY = solidGroundY
	local noclipSc, noclipWas, noclipParts, noclipFor = nil, nil, nil, nil
	local function noclipStep()
		local char = ch.get()
		if not char then
			return
		end
		if noclipFor ~= char or not noclipParts then
			noclipParts, noclipFor, noclipWas = {}, char, {}
			for _, p in ipairs(char:GetDescendants()) do
				if p:IsA("BasePart") then
					noclipParts[# noclipParts + 1] = p
					noclipWas[p] = p.CanCollide
				end
			end
		end
		for i = 1, # noclipParts do
			local p = noclipParts[i]
			if p.Parent and p.CanCollide then
				p.CanCollide = false
			end
		end
	end
	function M.noclip(on)
		if on then
			if noclipSc then
				return
			end
			rs.onRestore("movement.noclip", function()
				M.noclip(false)
			end)
			noclipSc = BX.scope("features.movement.noclip")
			noclipSc:onFrame("noclip", RunService.Stepped, noclipStep)
		else
			if not noclipSc then
				return
			end
			noclipSc:destroy()
			noclipSc = nil
			if noclipWas then
				for part, was in pairs(noclipWas) do
					if part.Parent then
						pcall(function()
							part.CanCollide = was
						end)
					end
				end
			end
			noclipParts, noclipWas, noclipFor = nil, nil, nil
		end
	end
	local brk = {
		low = nil,
		high = nil,
		speed = nil,
		legSpeed = nil,
		legRelocs = nil
	}
	function M.outboundSpeed()
		return K.SPEED
	end
	function M.carrySpeedCap()
		if not acGet("relocateCount") then
			return K.SPEED_NOSPOOF
		end
		return brk.speed or K.SPEED_NOSPOOF
	end
	local function bracketAfterLeg()
		local count = acGet("relocateCount")
		if not count or not brk.legSpeed then
			return
		end
		local used = brk.legSpeed
		local hadRelocs = count() > (brk.legRelocs or 0)
		if hadRelocs then
			brk.high = used
		else
			brk.low = math.max(brk.low or K.SPEED_NOSPOOF, used)
		end
		local low = brk.low or K.SPEED_NOSPOOF
		local nextSpeed
		if brk.high then
			if (brk.high - low) <= K.NOSPOOF_CONVERGE then
				nextSpeed = low
			else
				nextSpeed = math.floor((low + brk.high) / 2)
			end
		else
			nextSpeed = math.min(K.SPEED, low * 2)
		end
		nextSpeed = math.clamp(nextSpeed, K.NOSPOOF_FLOOR, K.SPEED)
		if nextSpeed ~= (brk.speed or K.SPEED_NOSPOOF) then
			log.info("travel: %s at %d - next leg %d studs/s (bracket %d..%s)", hadRelocs and "relocated" or "clean", used, nextSpeed, low, tostring(brk.high or "-"))
		end
		brk.speed = nextSpeed
		brk.legSpeed = nil
	end
	local stats = {
		legs = 0,
		cancelled = 0,
		respawned = 0,
		timedOut = 0,
		arrived = 0,
		teleports = 0,
		tpLanded = 0,
		tpRefused = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.teleport(pos, tag)
		local char, hrp = ch.get(), ch.root()
		if not char or not hrp then
			return false, math.huge
		end
		local gy = solidGroundY(pos)
		local dest = Vector3.new(pos.X, gy or pos.Y, pos.Z)
		local from = hrp.Position
		local ok = pcall(function()
			char:PivotTo(CFrame.new(dest))
		end)
		if ok then
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
		end
		task.wait(dev.scale(K.TP_SETTLE))
		local h2 = ch.root()
		local gap = h2 and (h2.Position - dest).Magnitude or math.huge
		local landed = gap <= K.TP_LANDED
		stats.teleports = stats.teleports + 1
		if landed then
			stats.tpLanded = stats.tpLanded + 1
		else
			stats.tpRefused = stats.tpRefused + 1
		end
		log.info("tp %s: %.0f studs -> %s (%.0f off, tier=%s)", tostring(tag), (dest - from).Magnitude, landed and "landed" or "REFUSED", gap, dev.tier)
		return landed, gap
	end
	local function writeStep(char, hum, hrp, dest, look)
		if hum then
			hum:Move(Vector3.zero, false)
		end
		char:PivotTo(CFrame.lookAt(dest, dest + look))
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end
	function M.travel(opts)
		local pos = opts.to
		local tag = opts.tag or "leg"
		local arrive = opts.arrive or K.ARRIVE
		local carrying = opts.carrying and true or false
		local cancel = opts.cancel
		local char = ch.get()
		local hrp = ch.root()
		local hum = ch.humanoid()
		if not char or not hrp then
			log.warn("%s: no character to move", tag)
			return false, {
				reason = "no-character"
			}
		end
		local speed = math.max(opts.speed or K.SPEED_NOSPOOF, 40)
		local start = hrp.Position
		local flatTotal = Vector3.new(pos.X - start.X, 0, pos.Z - start.Z).Magnitude
		if flatTotal < 1 then
			return true, {
				reason = "already-there",
				distance = 0
			}
		end
		local startGround = groundOr(start, start.Y)
		local endGround = groundOr(pos, pos.Y)
		local landY = endGround
		local cruiseY = math.max(startGround, endGround, start.Y, pos.Y) + K.CRUISE_UP
		local ramp = math.clamp(flatTotal * K.RAMP_FRAC, K.RAMP_MIN, K.RAMP_MAX)
		if ramp * 2 > flatTotal * 0.9 then
			ramp = flatTotal * 0.45
		end
		if flatTotal < K.RAMP_MIN * 2 then
			cruiseY = math.max(start.Y, pos.Y)
		end
		local wasPS = hum and hum.PlatformStand or false
		if hum then
			rs.remember("movement.platformStand", function()
				return hum.PlatformStand
			end, function(v)
				hum.PlatformStand = v
			end)
			hum.PlatformStand = true
		end
		local push, spoofFn = acGet("push"), acGet("spoof")
		local spoof = (not carrying) and hum and true or false
		local claimWS, savedWS = nil, nil
		if spoof then
			rs.remember("movement.walkSpeed", function()
				return hum.WalkSpeed
			end, function(v)
				hum.WalkSpeed = v
			end)
			savedWS = hum.WalkSpeed
			claimWS = math.clamp(speed * K.SPOOF_HEADROOM, 16, K.WS_MAX)
			hum.WalkSpeed = claimWS
		end
		if not carrying and not spoof then
			brk.legSpeed = speed
			local count = acGet("relocateCount")
			brk.legRelocs = count and count() or 0
		end
		local legAt = os.clock()
		local t0 = legAt
		local deadline = t0 + math.max(flatTotal / speed, 0.3) * 3 + 6
		local lastT = t0
		local arcDebt = 0
		local ok, reason = false, "timeout"
		local frames, subStepTotal, maxFrameSeen = 0, 0, 0
		log.trace("%s: begin %.0f studs at %.0f studs/s (carrying=%s spoof=%s tier=%s)", tag, flatTotal, speed, tostring(carrying), tostring(spoof), dev.tier)
		while os.clock() < deadline do
			if cancel and cancel() then
				reason = "cancelled"
				break
			end
			local liveChar = ch.get()
			if liveChar ~= char then
				reason = "respawned"
				break
			end
			local hh = ch.root()
			if not hh then
				reason = "lost-root"
				break
			end
			local now = os.clock()
			local raw = now - lastT
			lastT = now
			arcDebt = math.min(arcDebt + raw, K.MAX_DEBT)
			local frameDt = math.min(arcDebt, K.MAX_FRAME)
			arcDebt = arcDebt - frameDt
			if raw > maxFrameSeen then
				maxFrameSeen = raw
			end
			local subSteps = math.max(1, math.ceil(frameDt / K.MAX_DT))
			local dt = frameDt / subSteps
			frames = frames + 1
			subStepTotal = subStepTotal + subSteps
			local flat = Vector3.new(pos.X - hh.Position.X, 0, pos.Z - hh.Position.Z)
			local rem = flat.Magnitude
			if rem <= arrive then
				ok, reason = true, "arrived"
				break
			end
			local done = math.max(flatTotal - rem, 0)
			local want
			local speedRamp = math.max(ramp * K.SPEED_RAMP_FRAC, 1)
			if rem <= K.SLOW_RADIUS then
				want = math.min(K.SLOW_SPEED, speed)
			elseif rem < ramp then
				local f = rem / ramp
				want = math.max(speed * f, math.min(K.SLOW_SPEED, speed))
			elseif done < speedRamp then
				want = speed * (K.START_SPEED + (1 - K.START_SPEED) * (done / speedRamp))
			else
				want = speed
			end
			local lastReloc = acGet("lastRelocateAt")
			local relocAt = lastReloc and lastReloc() or nil
			if relocAt and (not carrying or relocAt >= legAt) and (os.clock() - relocAt) < K.RELOC_CLAMP_FOR then
				local allowFn = acGet("allowance")
				local allow = allowFn and allowFn() or nil
				if not allow and hum and hum.WalkSpeed > K.WALKSPEED_SANE_MIN then
					allow = hum.WalkSpeed * K.RELOC_CLAMP_RATIO
				end
				if allow and allow > 0 and want > allow then
					want = allow
				end
			end
			local wantY
			if carrying then
				wantY = landY
			elseif done < ramp then
				wantY = start.Y + (cruiseY - start.Y) * (done / ramp)
			elseif rem < ramp then
				wantY = landY + (cruiseY - landY) * (rem / ramp)
			else
				wantY = cruiseY
			end
			local arrived = false
			for _ = 1, subSteps do
				local hp = hh.Position
				local f2 = Vector3.new(pos.X - hp.X, 0, pos.Z - hp.Z)
				local rem2 = f2.Magnitude
				if rem2 <= arrive then
					arrived = true
					break
				end
				local moveWant = carrying and (want * CARRY_RETURN_SPEED_MULT) or want
				local step = math.min(rem2, moveWant * dt, K.MAX_STEP)
				local unit = f2.Unit
				local nxt = hp + unit * step
				if carrying then
					local gy = groundOr(Vector3.new(nxt.X, hp.Y, nxt.Z), landY)
					pcall(writeStep, char, hum, hh, Vector3.new(nxt.X, gy, nxt.Z), unit)
				else
					pcall(writeStep, char, hum, hh, Vector3.new(nxt.X, wantY, nxt.Z), unit)
				end
			end
			if arrived then
				ok, reason = true, "arrived"
				break
			end
			if spoof then
				if hum.WalkSpeed < claimWS - 1 then
					hum.WalkSpeed = claimWS
				end
				if push or spoofFn then
					local told = flat.Unit * math.min(want, claimWS)
					if push then
						push(hh, hum, told)
					else
						spoofFn(claimWS, told)
					end
				end
				pcall(function()
					hh.AssemblyLinearVelocity = Vector3.zero
				end)
			end
			RunService.Heartbeat:Wait()
		end
		local hz = ch.root()
		local liveChar = ch.get()
		if hz and liveChar == char then
			local gy = solidGroundY(hz.Position)
			if gy and math.abs(hz.Position.Y - gy) > 1 then
				pcall(function()
					char:PivotTo(CFrame.new(hz.Position.X, gy, hz.Position.Z))
				end)
			end
		end
		if spoof and hum and hum.Parent then
			local legalFn = acGet("legalWalkSpeed")
			local legal = legalFn and legalFn() or savedWS or 16
			pcall(function()
				hum.WalkSpeed = math.max(legal, 16)
			end)
		end
		if hum and hum.Parent then
			hum.PlatformStand = wasPS
			local hstate = hum:GetState()
			if hstate == Enum.HumanoidStateType.Freefall or hstate == Enum.HumanoidStateType.PlatformStanding or hstate == Enum.HumanoidStateType.Physics then
				pcall(function()
					hum:ChangeState(Enum.HumanoidStateType.Landed)
				end)
			end
		end
		if hz then
			hz.AssemblyLinearVelocity = Vector3.zero
			hz.AssemblyAngularVelocity = Vector3.zero
		end
		if not carrying and not spoof then
			bracketAfterLeg()
		end
		local gap = hz and Vector3.new(pos.X - hz.Position.X, 0, pos.Z - hz.Position.Z).Magnitude or math.huge
		local elapsed = os.clock() - t0
		local settled = ok or gap <= arrive + 4
		stats.legs = stats.legs + 1
		stats[settled and "arrived" or (reason == "cancelled" and "cancelled") or (reason == "respawned" and "respawned") or "timedOut"] = (stats[settled and "arrived" or (reason == "cancelled" and "cancelled") or (reason == "respawned" and "respawned") or "timedOut"] or 0) + 1
		local level = settled and log.trace or log.warn
		level("%s: %s %.0f studs in %.2fs (want %.0f/s, %.0f/s actual, %.1f short) " .. "reason=%s frames=%d sub=%.1f worstFrame=%.0fms tier=%s", tag, settled and "ok" or "FAILED", flatTotal, elapsed, speed, flatTotal / math.max(elapsed, 0.001), gap, reason, frames, frames > 0 and (subStepTotal / frames) or 0, maxFrameSeen * 1000, dev.tier)
		return settled, {
			reason = reason,
			distance = flatTotal,
			elapsed = elapsed,
			gap = gap,
			frames = frames,
			worstFrameMs = maxFrameSeen * 1000,
		}
	end
	function M.descend(tag)
		tag = tag or "land"
		local char, h = ch.get(), ch.root()
		if not char or not h then
			return false
		end
		local hum = ch.humanoid()
		local gy = solidGroundY(h.Position)
		if not gy then
			if hum then
				hum.PlatformStand = false
			end
			log.trace("%s: no ground below - falling", tag)
			return false
		end
		local x, z = h.Position.X, h.Position.Z
		local from = h.Position.Y
		if from - gy <= 2 then
			if hum then
				hum.PlatformStand = false
			end
			return true
		end
		if hum then
			hum.PlatformStand = true
		end
		local t0 = os.clock()
		local dur = math.clamp((from - gy) / math.max(K.DROP_SPEED, 50), 0.05, 1.2)
		while os.clock() - t0 < dur do
			if ch.get() ~= char then
				break
			end
			local hh = ch.root()
			if not hh then
				break
			end
			local f = (os.clock() - t0) / dur
			local y = from + (gy - from) * f
			pcall(function()
				char:PivotTo(CFrame.new(x, y, z) * (hh.CFrame - hh.CFrame.Position))
				hh.AssemblyLinearVelocity = Vector3.zero
			end)
			RunService.Heartbeat:Wait()
		end
		if ch.get() == char then
			pcall(function()
				char:PivotTo(CFrame.new(x, gy, z))
			end)
		end
		if hum and hum.Parent then
			hum.PlatformStand = false
			pcall(function()
				hum:ChangeState(Enum.HumanoidStateType.Landed)
			end)
		end
		log.trace("%s: descended %.0f studs to ground", tag, from - gy)
		return true
	end
	local sc = BX.scope("features.movement")
	sc:connect(Players.PlayerAdded, function()
		filterDirty = true
	end)
	sc:connect(Players.PlayerRemoving, function()
		filterDirty = true
	end)
	ch.onSpawn(sc, "movement.respawn", function()
		filterDirty = true
		noclipParts, noclipWas, noclipFor = nil, nil, nil
	end)
	function M.reset()
		M.noclip(false)
	end
	return M
end)
BX.module("features.speed", function(BX)
	local svc = BX.require("core.services")
	local ch = BX.require("core.character")
	local st = BX.require("core.state")
	local cfg = BX.require("core.config")
	local data = BX.require("core.data")
	local motion = BX.require("core.motion")
	local log = BX.require("boot.log").for_module("speed")
	local M = {}
	local K = {
		SPEED_DEFAULT = 300,
		SPEED_MIN = 20,
		SPEED_MAX = 1000,
		FORCE = 1e7,
		DEADZONE = 0.05,
		COOLDOWN = 3.0,
		STRIKES = 3,
		STRIKE_WINDOW = 30,
		SNAP_MIN = 30,
	}
	M.K = K
	local sc, enabled = nil, false
	local speed = K.SPEED_DEFAULT
	local att, lv = nil, nil
	local carrying = false
	local standDown = nil
	local coolUntil, strikes = 0, {}
	local boostedAt = 0
	local lastPos = nil
	local autoOffWhy = nil
	local autoOffListeners = {}
	local stats = {
		enables = 0,
		frames = 0,
		respawns = 0,
		corrections = 0,
		autoOffs = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isOn()
		return enabled
	end
	function M.speed()
		return speed
	end
	function M.onAutoOff(fn)
		autoOffListeners[# autoOffListeners + 1] = fn
	end
	function M.setSpeed(n)
		n = tonumber(n)
		if not n then
			return false, "not a number"
		end
		speed = math.clamp(math.floor(n), K.SPEED_MIN, K.SPEED_MAX)
		log.info("speed %d studs/s", speed)
		return true, speed
	end
	local OWNER_TEXT = {
		autosteal = "Auto Steal is running",
		bossfight = "Auto fight is moving you",
		hold = "holding the treadmill",
		fly = "Fly is on"
	}
	local function blocker()
		local above = motion.blockedBy("speed")
		if above then
			return OWNER_TEXT[above] or (above .. " is moving you")
		end
		if os.clock() < coolUntil then
			return "server corrected your movement - cooling down"
		end
		if st.autoStealOn then
			return "Auto Steal is running"
		end
		if st.stayOnTreadmill then
			return "holding the treadmill"
		end
		local fly = BX._loaded["features.fly"]
		if fly and fly.isOn() then
			return "Fly is on"
		end
		local fight = BX._loaded["features.bossfight"]
		local lp = svc.Players.LocalPlayer
		if fight and fight.isOn() and lp and lp:GetAttribute("InBossArena") == true then
			return "Auto fight is in the arena"
		end
		return nil
	end
	local function detach()
		if lv then
			pcall(function()
				lv:Destroy()
			end)
		end
		if att then
			pcall(function()
				att:Destroy()
			end)
		end
		att, lv = nil, nil
	end
	local function attach(root)
		detach()
		if not (root and root:IsA("BasePart")) then
			return false
		end
		att = Instance.new("Attachment")
		att.Name = "DhzSpeedAtt"
		lv = Instance.new("LinearVelocity")
		lv.Name = "DhzSpeed"
		lv.Attachment0 = att
		lv.MaxForce = K.FORCE
		lv.RelativeTo = Enum.ActuatorRelativeTo.World
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
		lv.PrimaryTangentAxis = Vector3.new(1, 0, 0)
		lv.SecondaryTangentAxis = Vector3.new(0, 0, 1)
		lv.Enabled = false
		sc:own(att)
		sc:own(lv)
		att.Parent = root
		lv.Parent = root
		return true
	end
	local function step()
		if not lv then
			return
		end
		stats.frames = stats.frames + 1
		local why = blocker()
		if why ~= standDown then
			standDown = why
			if why then
				log.info("standing down: %s", why)
			end
		end
		if why then
			if lv.Enabled then
				lv.Enabled = false
			end
			lastPos = nil
			return
		end
		local hum = ch.humanoid()
		local root = ch.root()
		if not hum or not root or hum.Health <= 0 or lv.Parent ~= root then
			if lv.Enabled then
				lv.Enabled = false
			end
			lastPos = nil
			return
		end
		local pos = root.Position
		if lastPos and lv.Enabled then
			local frameMax = math.max(speed * 0.1, K.SNAP_MIN)
			if (pos - lastPos).Magnitude > frameMax then
				lastPos = pos
				M.corrected("snap")
				return
			end
		end
		lastPos = pos
		local dir = hum.MoveDirection
		if dir.Magnitude < K.DEADZONE then
			local v = root.AssemblyLinearVelocity
			local flat = Vector3.new(v.X, 0, v.Z).Magnitude
			if flat > (hum.WalkSpeed + 5) then
				lv.PlaneVelocity = Vector2.zero
				if not lv.Enabled then
					lv.Enabled = true
				end
			elseif lv.Enabled then
				lv.Enabled = false
			end
			return
		end
		local v = speed
		if carrying then
			v = math.min(v, (tonumber(cfg.CARRY_SPEED) or 500) * 0.9)
		end
		local u = dir.Unit
		lv.PlaneVelocity = Vector2.new(u.X * v, u.Z * v)
		if not lv.Enabled then
			lv.Enabled = true
		end
		boostedAt = os.clock()
	end
	function M.corrected(kind)
		if not enabled or not lv then
			return
		end
		local now = os.clock()
		if (now - boostedAt) > 0.6 then
			return
		end
		stats.corrections = stats.corrections + 1
		lv.Enabled = false
		BX.try("speed.cutMomentum", function()
			local root = ch.root()
			if root then
				local v = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(0, math.min(v.Y, 0), 0)
			end
		end)
		coolUntil = now + K.COOLDOWN
		for i = # strikes, 1, - 1 do
			if now - strikes[i] > K.STRIKE_WINDOW then
				table.remove(strikes, i)
			end
		end
		strikes[# strikes + 1] = now
		log.warn("server corrected the boost (%s) at %d studs/s - strike %d/%d, pausing %.0fs", tostring(kind), speed, # strikes, K.STRIKES, K.COOLDOWN)
		if # strikes >= K.STRIKES then
			autoOffWhy = ("the server corrected your movement %d times - Speed Boost turned off"):format(# strikes)
			stats.autoOffs = stats.autoOffs + 1
			log.warn("%s", autoOffWhy)
			task.spawn(function()
				M.setEnabled(false)
				for _, fn in ipairs(autoOffListeners) do
					BX.try("speed.onAutoOff", fn, autoOffWhy)
				end
			end)
		end
	end
	function M.setEnabled(on)
		on = on and true or false
		if on == enabled then
			return true
		end
		if not on then
			enabled = false
			motion.release("speed")
			if sc then
				sc:destroy()
				sc = nil
			end
			lastPos, strikes, coolUntil = nil, {}, 0
			BX.try("speed.offBrake", function()
				local root = ch.root()
				if root then
					local v = root.AssemblyLinearVelocity
					root.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
				end
			end)
			att, lv, standDown = nil, nil, nil
			log.info("off")
			return true
		end
		enabled = true
		autoOffWhy = nil
		stats.enables = stats.enables + 1
		sc = BX.scope("features.speed")
		motion.claim("speed")
		motion.onRejected(sc, function(kind)
			M.corrected(kind)
		end)
		BX.try("speed.carryWatch", function()
			local ES = data.eggState()
			if ES and ES.CarryChanged then
				sc:connect(ES.CarryChanged, function(info)
					carrying = type(info) == "table" and info.IsCarrying == true
				end)
			end
		end)
		BX.try("speed.carryNow", function()
			carrying = BX.require("features.eggs").carryingUid() ~= nil
		end)
		ch.onSpawn(sc, "speed.respawn", function(char)
			stats.respawns = stats.respawns + 1
			local root = char and char:WaitForChild("HumanoidRootPart", 5)
			attach(root)
		end)
		local okPre, pre = pcall(function()
			return svc.RunService.PreSimulation
		end)
		local signal = (okPre and pre) or svc.RunService.Heartbeat
		sc:onFrame("step", signal, step)
		log.info("on (%d studs/s)", speed)
		return true
	end
	BX.onTeardown("speed", function()
		M.setEnabled(false)
	end)
	function M.status()
		if not enabled then
			return autoOffWhy and ("off  \u{B7}  " .. autoOffWhy) or "off"
		end
		if standDown then
			return "paused: " .. standDown
		end
		return ("on  \u{B7}  %d studs/s"):format(speed)
	end
	return M
end)
BX.module("features.humanoid", function(BX)
	local svc = BX.require("core.services")
	local ch = BX.require("core.character")
	local rs = BX.require("core.restore")
	local log = BX.require("boot.log").for_module("humanoid")
	local M = {}
	local SWAP_ATTR = "DhzStealHum"
	M.SWAP_ATTR = SWAP_ATTR
	local sc = nil
	local swapPrior = nil
	local stats = {
		swaps = 0,
		alreadySwapped = 0,
		failures = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isSwapped()
		local hum = ch.humanoid()
		return hum ~= nil and hum:GetAttribute(SWAP_ATTR) == true
	end
	local function applyStates(prior)
		local hum = ch.humanoid()
		if not hum or hum:GetAttribute(SWAP_ATTR) ~= true then
			return
		end
		hum:SetStateEnabled(Enum.HumanoidStateType.Dead, prior.dead)
		hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, prior.fallingDown)
		hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, prior.ragdoll)
		hum.BreakJointsOnDeath = prior.breakJoints
	end
	local function rememberStates(prior)
		rs.remember("humanoid.states", function()
			return prior
		end, function(v)
			applyStates(v)
		end)
	end
	function M.swap(char)
		char = char or ch.get()
		if not char then
			return false
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum then
			return false
		end
		if hum:GetAttribute(SWAP_ATTR) == true then
			stats.alreadySwapped = stats.alreadySwapped + 1
			if not swapPrior then
				local d = hum:GetAttribute("DhzPriorDead")
				if d ~= nil then
					swapPrior = {
						dead = d,
						fallingDown = hum:GetAttribute("DhzPriorFallingDown") ~= false,
						ragdoll = hum:GetAttribute("DhzPriorRagdoll") ~= false,
						breakJoints = hum:GetAttribute("DhzPriorBreakJoints") == true,
					}
					rememberStates(swapPrior)
				end
			end
			BX.try("humanoid.reapply", function()
				hum.BreakJointsOnDeath = false
				hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
				hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
				hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			end)
			return true
		end
		local prior = {
			dead = hum:GetStateEnabled(Enum.HumanoidStateType.Dead),
			fallingDown = hum:GetStateEnabled(Enum.HumanoidStateType.FallingDown),
			ragdoll = hum:GetStateEnabled(Enum.HumanoidStateType.Ragdoll),
			breakJoints = hum.BreakJointsOnDeath,
		}
		local ok = BX.try("humanoid.swap", function()
			local healthScript = char:FindFirstChild("Health")
			if healthScript then
				healthScript:Destroy()
			end
			hum.BreakJointsOnDeath = false
			hum.Archivable = true
			local clone = hum:Clone()
			if not clone then
				error("clone failed")
			end
			clone.Name = "Humanoid"
			clone:SetAttribute(SWAP_ATTR, true)
			clone:SetAttribute("DhzPriorDead", prior.dead)
			clone:SetAttribute("DhzPriorFallingDown", prior.fallingDown)
			clone:SetAttribute("DhzPriorRagdoll", prior.ragdoll)
			clone:SetAttribute("DhzPriorBreakJoints", prior.breakJoints)
			clone:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
			clone:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
			clone:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			clone.Health = hum.MaxHealth
			if not clone:FindFirstChildOfClass("Animator") then
				Instance.new("Animator").Parent = clone
			end
			hum:Destroy()
			clone.Parent = char
			if workspace.CurrentCamera then
				workspace.CurrentCamera.CameraSubject = clone
			end
			local animate = char:FindFirstChild("Animate")
			if animate then
				local ac = animate:Clone()
				animate:Destroy()
				ac.Parent = char
				ac.Disabled = false
			end
			for _, d in ipairs(char:GetDescendants()) do
				if d:IsA("Motor6D") then
					d.Enabled = true
				end
			end
		end)
		if ok then
			rs.permanent("humanoid.swap", "Humanoid replaced and Health script destroyed - undone by respawn")
			swapPrior = prior
			rememberStates(prior)
			stats.swaps = stats.swaps + 1
			log.info("swapped (anticheat now holds a destroyed Humanoid)")
		else
			stats.failures = stats.failures + 1
			log.error("swap FAILED - teleports will be punished")
		end
		return ok and true or false
	end
	function M.isArmed()
		return sc ~= nil
	end
	function M.arm()
		if sc then
			return true
		end
		sc = BX.scope("features.humanoid")
		M.swap()
		ch.onSpawn(sc, "humanoid.reswap", function(char)
			swapPrior = nil
			M.swap(char)
		end)
		return true
	end
	function M.disarm()
		if not swapPrior then
			local hum = ch.humanoid()
			if hum and hum:GetAttribute(SWAP_ATTR) == true then
				local d = hum:GetAttribute("DhzPriorDead")
				swapPrior = {
					dead = (d == nil) and true or d,
					fallingDown = hum:GetAttribute("DhzPriorFallingDown") ~= false,
					ragdoll = hum:GetAttribute("DhzPriorRagdoll") ~= false,
					breakJoints = hum:GetAttribute("DhzPriorBreakJoints") == true,
				}
			end
		end
		if swapPrior then
			BX.try("humanoid.restoreStates", function()
				applyStates(swapPrior)
				log.info("death states restored (dead=%s fallingDown=%s " .. "ragdoll=%s breakJoints=%s) - the character can respawn " .. "normally again", tostring(swapPrior.dead), tostring(swapPrior.fallingDown), tostring(swapPrior.ragdoll), tostring(swapPrior.breakJoints))
			end)
		end
		if not sc then
			return
		end
		sc:destroy()
		sc = nil
		log.info("disarmed (%d swaps this session)", stats.swaps)
	end
	return M
end)
BX.module("features.jump", function(BX)
	local svc = BX.require("core.services")
	local ch = BX.require("core.character")
	local st = BX.require("core.state")
	local hsw = BX.require("features.humanoid")
	local log = BX.require("boot.log").for_module("jump")
	local M = {}
	local sc = nil
	local stats = {
		requests = 0,
		applied = 0,
		duringRun = 0,
		unswapped = 0,
		busy = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isArmed()
		return sc ~= nil
	end
	function M.arm()
		if sc then
			return true
		end
		sc = BX.scope("features.jump")
		sc:connect(svc.UserInputService.JumpRequest, function()
			stats.requests = stats.requests + 1
			if st.autoStealOn then
				stats.duringRun = stats.duringRun + 1
				return
			end
			local hum = ch.humanoid()
			if not hum then
				return
			end
			if hum:GetAttribute(hsw.SWAP_ATTR) ~= true then
				stats.unswapped = stats.unswapped + 1
				return
			end
			if hum.Health <= 0 then
				return
			end
			local state = hum:GetState()
			if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then
				stats.busy = stats.busy + 1
				return
			end
			hum.Jump = true
			stats.applied = stats.applied + 1
		end)
		log.info("armed - the player's jump reaches the live humanoid")
		return true
	end
	function M.disarm()
		if not sc then
			return
		end
		sc:destroy()
		sc = nil
		log.info("disarmed (%d requests, %d applied)", stats.requests, stats.applied)
	end
	return M
end)
BX.module("features.antideath", function(BX)
	local ch = BX.require("core.character")
	local svc = BX.require("core.services")
	local rs = BX.require("core.restore")
	local log = BX.require("boot.log").for_module("antideath")
	local M = {}
	local sc = nil
	local saved = nil
	local armedFor = nil
	local stats = {
		arms = 0,
		deathsBlocked = 0,
		restores = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	local function applyTo(char)
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum then
			return false
		end
		if armedFor == hum then
			return true
		end
		saved = {
			humanoid = hum,
			breakJoints = hum.BreakJointsOnDeath,
			deadEnabled = hum:GetStateEnabled(Enum.HumanoidStateType.Dead),
		}
		armedFor = hum
		BX.try("antideath.apply", function()
			rs.remember("antideath.breakJoints", function()
				return hum.BreakJointsOnDeath
			end, function(v)
				hum.BreakJointsOnDeath = v
			end)
			rs.remember("antideath.state.Dead", function()
				return hum:GetStateEnabled(Enum.HumanoidStateType.Dead)
			end, function(v)
				hum:SetStateEnabled(Enum.HumanoidStateType.Dead, v)
			end)
			hum.BreakJointsOnDeath = false
			hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
		end)
		sc:connect(hum.HealthChanged, function(hp)
			if hp <= 0 and hum.Parent then
				stats.deathsBlocked = stats.deathsBlocked + 1
				hum.Health = hum.MaxHealth
			end
		end)
		sc:connect(hum.StateChanged, function(_, new)
			if new == Enum.HumanoidStateType.Dead and hum.Parent then
				stats.deathsBlocked = stats.deathsBlocked + 1
				hum:ChangeState(Enum.HumanoidStateType.GettingUp)
				hum.Health = hum.MaxHealth
			end
		end)
		if hum.Health <= 0 then
			stats.deathsBlocked = stats.deathsBlocked + 1
			log.warn("armed on a humanoid already at 0 health - reviving it")
			hum.Health = hum.MaxHealth
		end
		stats.arms = stats.arms + 1
		log.trace("armed on humanoid (health %.0f/%.0f)", hum.Health, hum.MaxHealth)
		return true
	end
	local function restore()
		local s = saved
		saved, armedFor = nil, nil
		if not s or not s.humanoid or not s.humanoid.Parent then
			return
		end
		stats.restores = stats.restores + 1
		BX.try("antideath.restore", function()
			s.humanoid.BreakJointsOnDeath = s.breakJoints
			s.humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, s.deadEnabled)
		end)
	end
	function M.isArmed()
		return sc ~= nil
	end
	function M.arm()
		if sc then
			return true
		end
		sc = BX.scope("features.antideath")
		local ok = applyTo(ch.get())
		ch.onSpawn(sc, "antideath.rearm", function(char)
			saved, armedFor = nil, nil
			applyTo(char)
		end)
		log.info("armed (%s)", ok and "ok" or "no humanoid yet")
		return true
	end
	function M.disarm()
		if not sc then
			return
		end
		sc:destroy()
		sc = nil
		BX.try("antideath.reviveOnDisarm", function()
			local hum = ch.humanoid()
			if hum and hum.Parent and hum.Health <= 0 then
				log.warn("disarming on 0 health - reviving before restoring states")
				hum.Health = hum.MaxHealth
			end
		end)
		restore()
		log.info("disarmed (blocked %d deaths this session)", stats.deathsBlocked)
	end
	return M
end)
BX.module("features.guard", function(BX)
	local svc = BX.require("core.services")
	local data = BX.require("core.data")
	local ch = BX.require("core.character")
	local rs = BX.require("core.restore")
	local log = BX.require("boot.log").for_module("guard")
	local RunService = svc.RunService
	local M = {}
	local K = {
		RISE = 150,
		FLAT_MULT = 2.5,
		FLAT_MIN = 150,
		JOINT_GAP = 0.25,
		HOLD_MAX = 2.75,
		HOLD_GRACE = 0.25,
	}
	M.K = K
	local sc = nil
	local stats = {
		launchesCancelled = 0,
		standUps = 0,
		dropsRefused = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isRagdolled()
		local hum = ch.humanoid()
		if not hum then
			return false
		end
		if hum.PlatformStand then
			return true
		end
		local s = hum:GetState()
		return s == Enum.HumanoidStateType.Physics or s == Enum.HumanoidStateType.Ragdoll or s == Enum.HumanoidStateType.FallingDown
	end
	function M.waitForRecovery(seconds)
		local deadline = os.clock() + (seconds or 4)
		while os.clock() < deadline do
			if not M.isRagdolled() then
				return true
			end
			RunService.Heartbeat:Wait()
		end
		return false
	end
	local function applyAntiRagdoll(char)
		char = char or ch.get()
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum then
			return false
		end
		BX.try("guard.antiRagdoll", function()
			rs.remember("guard.state.Ragdoll", function()
				return hum:GetStateEnabled(Enum.HumanoidStateType.Ragdoll)
			end, function(v)
				hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, v)
			end)
			rs.remember("guard.state.FallingDown", function()
				return hum:GetStateEnabled(Enum.HumanoidStateType.FallingDown)
			end, function(v)
				hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, v)
			end)
			hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
			for _, d in ipairs(char:GetDescendants()) do
				if d:IsA("Motor6D") then
					d.Enabled = true
				end
			end
		end)
		return true
	end
	local dropOriginal, dropInstalled, eggStateRef = nil, false, nil
	local dropAllowed = false
	local function installDropBlock()
		if dropInstalled then
			return true
		end
		eggStateRef = eggStateRef or data.eggState()
		if not eggStateRef or type(eggStateRef.DropFieldEgg) ~= "function" then
			log.warn("cannot block egg drops - EggState.DropFieldEgg missing")
			return false
		end
		dropOriginal = eggStateRef.DropFieldEgg
		eggStateRef.DropFieldEgg = function(reason, ...)
			if not dropAllowed then
				stats.dropsRefused = stats.dropsRefused + 1
				log.trace("drop refused: %s", tostring(reason))
				return
			end
			return dropOriginal(reason, ...)
		end
		dropInstalled = true
		log.info("egg-drop block installed")
		return true
	end
	local function removeDropBlock()
		if not dropInstalled then
			return
		end
		BX.try("guard.restoreDrop", function()
			if eggStateRef and dropOriginal then
				eggStateRef.DropFieldEgg = dropOriginal
			end
		end)
		dropInstalled, dropOriginal = false, nil
	end
	function M.allowDrops(on)
		dropAllowed = on and true or false
	end
	local blocked, ups, jointAt = 0, 0, 0
	local function antiHitStep()
		local hum, hrp = ch.humanoid(), ch.root()
		if not hum or not hrp then
			return
		end
		local st = hum:GetState()
		if st == Enum.HumanoidStateType.Jumping then
			return
		end
		local v = hrp.AssemblyLinearVelocity
		local flat = (v * Vector3.new(1, 0, 1)).Magnitude
		local flatCap = math.max((hum.WalkSpeed or 16) * K.FLAT_MULT, K.FLAT_MIN)
		if v.Y > K.RISE or flat > flatCap then
			local keep = Vector3.zero
			if flat > 0.001 then
				keep = (v * Vector3.new(1, 0, 1)).Unit * math.min(flat, hum.WalkSpeed or 16)
			end
			hrp.AssemblyLinearVelocity = Vector3.new(keep.X, math.min(v.Y, 0), keep.Z)
			hrp.AssemblyAngularVelocity = Vector3.zero
			blocked = blocked + 1
			stats.launchesCancelled = blocked
		end
		if hum.PlatformStand or hum.Sit or st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.FallingDown or st == Enum.HumanoidStateType.PlatformStanding then
			pcall(function()
				hum.PlatformStand = false
				hum.Sit = false
				hum:ChangeState(Enum.HumanoidStateType.GettingUp)
			end)
			ups = ups + 1
			stats.standUps = ups
			local now = os.clock()
			if now - jointAt > K.JOINT_GAP then
				jointAt = now
				local char = ch.get()
				if char then
					for _, d in ipairs(char:GetDescendants()) do
						if d:IsA("Motor6D") and not d.Enabled then
							d.Enabled = true
						end
					end
				end
			end
		end
	end
	function M.ragdollRemaining()
		local left = 0
		BX.try("guard.ragdollRemaining", function()
			local plr = svc.LocalPlayer
			local t = plr and plr:GetAttribute("RagdollEndTime")
			if type(t) == "number" then
				left = math.max(left, t - workspace:GetServerTimeNow())
			end
		end)
		return math.max(0, left)
	end
	function M.waitForServerRelease(cancel)
		local held = M.ragdollRemaining()
		if held <= 0 then
			return 0
		end
		local t0 = os.clock()
		local deadline = os.clock() + math.min(held, K.HOLD_MAX)
		while os.clock() < deadline do
			if cancel and cancel() then
				break
			end
			task.wait(0.05)
			if M.ragdollRemaining() <= 0 then
				break
			end
		end
		task.wait(K.HOLD_GRACE)
		local waited = os.clock() - t0
		log.trace("server held us %.2fs - waited %.2fs", held, waited)
		return waited
	end
	function M.isArmed()
		return sc ~= nil
	end
	function M.arm()
		if sc then
			return true
		end
		sc = BX.scope("features.guard")
		blocked, ups, jointAt = 0, 0, 0
		dropAllowed = false
		applyAntiRagdoll()
		installDropBlock()
		sc:onFrame("antihit", RunService.Heartbeat, antiHitStep)
		ch.onSpawn(sc, "guard.respawn", function(char)
			applyAntiRagdoll(char)
		end)
		log.info("armed (anti-hit + anti-ragdoll + drop block)")
		return true
	end
	function M.disarm()
		if not sc then
			return
		end
		sc:destroy()
		sc = nil
		dropAllowed = true
		removeDropBlock()
		log.info("disarmed (%d launches cancelled, %d stand-ups, %d drops refused)", stats.launchesCancelled, stats.standUps, stats.dropsRefused)
	end
	return M
end)
BX.module("features.guardwatch", function(BX)
	local plot = BX.require("features.plot")
	local log = BX.require("boot.log").for_module("guardwatch")
	local M = {}
	local K = {
		BEHIND_OK = 60,
	}
	M.K = K
	local AT_HOME = {
		Sleeping = true,
		Waking = true
	}
	local stats = {
		checks = 0,
		blocked = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	local function guardOf(areaId)
		local g
		pcall(function()
			g = workspace.__OBJECTS.Areas.GuardAreas[areaId].Guard
		end)
		return g
	end
	local function rootOf(g)
		local r = g and (g:FindFirstChild("HumanoidRootPart") or g.PrimaryPart)
		return (r and r:IsA("BasePart")) and r or nil
	end
	function M.blocking(areaId, nestPos)
		stats.checks = stats.checks + 1
		if not areaId or typeof(nestPos) ~= "Vector3" then
			return nil
		end
		local g = guardOf(areaId)
		local root = rootOf(g)
		if not root then
			return nil
		end
		local state = tostring(g:GetAttribute("GuardState") or "")
		if AT_HOME[state] then
			return nil
		end
		local home = plot.safeZone()
		if typeof(home) ~= "Vector3" then
			return nil
		end
		local route = (home - nestPos) * Vector3.new(1, 0, 1)
		if route.Magnitude < 1 then
			return nil
		end
		local rel = (root.Position - nestPos) * Vector3.new(1, 0, 1)
		local along = rel:Dot(route.Unit)
		if along < - K.BEHIND_OK then
			return nil
		end
		stats.blocked = stats.blocked + 1
		return ("%s guard is %s %d studs up the route"):format( tostring(areaId), state:lower(), math.floor(math.max(along, 0)))
	end
	function M.blockedAreas()
		local out = {}
		local areas
		pcall(function()
			areas = workspace.__OBJECTS.Areas.GuardAreas:GetChildren()
		end)
		for _, a in ipairs(areas or {}) do
			local g = a:FindFirstChild("Guard")
			local bounds = a:FindFirstChild("Bounds")
			local state = g and tostring(g:GetAttribute("GuardState") or "")
			if g and bounds and bounds:IsA("BasePart") and not AT_HOME[state] then
				local why = M.blocking(a.Name, bounds.Position)
				if why then
					out[a.Name] = why
				end
			end
		end
		return out
	end
	return M
end)
BX.module("features.treadmill", function(BX)
	local svc = BX.require("core.services")
	local data = BX.require("core.data")
	local ch = BX.require("core.character")
	local dev = BX.require("core.device")
	local net = BX.require("core.net")
	local st = BX.require("core.state")
	local log = BX.require("boot.log").for_module("treadmill")
	local M = {}
	local K = {
		PAD = 6,
		Y_SLACK = 12,
		POLL = 1.5,
		AFTER_OFF = 2.0,
		PART_TTL = 30,
	}
	M.K = K
	local PlotState = data.plotState()
	local netCall = net.call
	M.netCall = netCall
	local partCache, partAt = nil, 0
	local function treadmillPart()
		local now = os.clock()
		if partCache and partCache.Parent then
			return partCache
		end
		if not partCache and partAt > 0 and (now - partAt) < K.PART_TTL then
			return nil
		end
		local found = nil
		BX.try("treadmill.resolvePart", function()
			local plot = PlotState and PlotState.ResolvePlot and PlotState.ResolvePlot()
			if type(plot) ~= "table" or not plot.PlotFolder then
				return
			end
			local p = plot.PlotFolder:FindFirstChild("TreadmillBottom", true)
			if p and p:IsA("BasePart") then
				found = p
			end
		end)
		partCache, partAt = found, now
		return found
	end
	function M.onBelt()
		local part = treadmillPart()
		local hrp = ch.root()
		if not part or not hrp then
			return false
		end
		local rel = part.CFrame:PointToObjectSpace(hrp.Position)
		local half = part.Size * 0.5
		return math.abs(rel.X) <= half.X + K.PAD and math.abs(rel.Z) <= half.Z + K.PAD and math.abs(rel.Y) <= K.Y_SLACK
	end
	local enabled = true
	local sc = nil
	local stats = {
		checks = 0,
		caught = 0,
		doffed = 0,
		refused = 0,
		yielded = 0,
		notWorn = 0
	}
	function M.worn()
		local hrp = ch.root()
		if hrp and hrp.Anchored then
			return true
		end
		local char = hrp and hrp.Parent
		local hp = char and char:FindFirstChild("Headphones")
		return hp ~= nil and hp:IsA("Accessory")
	end
	function M.stats()
		return table.clone(stats)
	end
	function M.isOn()
		return enabled
	end
	local function step()
		if not enabled then
			return
		end
		if st.stayOnTreadmill then
			stats.yielded = stats.yielded + 1
			return
		end
		stats.checks = stats.checks + 1
		if not M.onBelt() then
			return
		end
		if not M.worn() then
			stats.notWorn = stats.notWorn + 1
			return
		end
		stats.caught = stats.caught + 1
		local ok, msg = netCall("RF/Treadmill/AskDoff")
		if ok == true then
			stats.doffed = stats.doffed + 1
			log.info("standing on the belt - AskDoff accepted")
		else
			stats.refused = stats.refused + 1
			log.warn("standing on the belt - AskDoff refused: %s %s", tostring(ok), tostring(msg or ""))
		end
		task.wait(dev.scale(K.AFTER_OFF))
	end
	function M.arm()
		if sc then
			return true
		end
		sc = BX.scope("features.treadmill")
		sc:loop("watch", dev.scale(K.POLL), step)
		ch.onSpawn(sc, "treadmill.respawn", function()
			partCache, partAt = nil, 0
		end)
		log.info("armed (poll %.1fs, %s)", dev.scale(K.POLL), enabled and "enabled" or "disabled")
		return true
	end
	function M.disarm()
		if not sc then
			return
		end
		sc:destroy()
		sc = nil
		partCache, partAt = nil, 0
		log.info("disarmed (%d checks, %d caught, %d doffed)", stats.checks, stats.caught, stats.doffed)
	end
	function M.setEnabled(on)
		enabled = on and true or false
		log.info("anti treadmill %s", enabled and "ON" or "OFF")
		if enabled then
			M.arm()
		else
			M.disarm()
		end
	end
	return M
end)
BX.module("features.farm.filter", function(BX)
	local data = BX.require("core.data")
	local eggs = BX.require("features.eggs")
	local guardwatch = BX.require("features.guardwatch")
	local log = BX.require("boot.log").for_module("farm.filter")
	local M = {}
	local function AreasDir()
		return data.areasDir()
	end
	local function AssetsDir()
		return data.assetsDir()
	end
	local areas = {}
	local rarities = {}
	local targetBy = "Income"
	local function count(set)
		local n = 0
		for _ in pairs(set) do
			n = n + 1
		end
		return n
	end
	local function toSet(list)
		local set = {}
		if type(list) == "table" then
			for _, v in pairs(list) do
				if v ~= nil and v ~= "" then
					set[tostring(v)] = true
				end
			end
		elseif type(list) == "string" and list ~= "" then
			set[list] = true
		end
		return set
	end
	function M.areaOptions()
		local out = {}
		for id, entry in pairs(AreasDir() or {}) do
			out[# out + 1] = {
				id = tostring(id),
				label = tostring((type(entry) == "table" and entry.DisplayName) or id),
			}
		end
		table.sort(out, function(a, b)
			return a.label < b.label
		end)
		return out
	end
	function M.rarityOptions()
		local seen, rows = {}, {}
		for _, entry in pairs(AssetsDir() or {}) do
			local r = type(entry) == "table" and entry.Rarity or nil
			if type(r) == "table" then
				local id = tostring(r._id or r.DisplayName or "")
				if id ~= "" and not seen[id] then
					seen[id] = true
					rows[# rows + 1] = {
						id = id,
						label = tostring(r.DisplayName or id),
						num = tonumber(r.RarityNumber) or 0,
					}
				end
			end
		end
		table.sort(rows, function(a, b)
			if a.num ~= b.num then
				return a.num < b.num
			end
			return a.label < b.label
		end)
		return rows
	end
	function M.targetByOptions()
		return {
			"Income",
			"Weight"
		}
	end
	function M.setAreas(list)
		areas = toSet(list)
		log.info("areas: %s", count(areas) == 0 and "any" or tostring(count(areas)))
	end
	function M.setRarities(list)
		rarities = toSet(list)
		log.info("rarities: %s", count(rarities) == 0 and "any" or tostring(count(rarities)))
	end
	function M.setTargetBy(v)
		targetBy = (v == "Weight") and "Weight" or "Income"
		log.info("target by: %s", targetBy)
	end
	function M.selection()
		return {
			areas = areas,
			rarities = rarities,
			targetBy = targetBy
		}
	end
	function M.describe()
		return ("%s areas, %s rarities, by %s"):format( count(areas) == 0 and "all" or tostring(count(areas)), count(rarities) == 0 and "any" or tostring(count(rarities)), targetBy)
	end
	local function rarityOk(e)
		if count(rarities) == 0 then
			return true
		end
		local id = tostring(e.rarityId or e.rarity or "")
		local label = tostring(e.rarity or "")
		return rarities[id] == true or rarities[label] == true
	end
	local function wanted(e)
		if count(areas) > 0 and not areas[tostring(e.areaId)] then
			return false
		end
		return rarityOk(e)
	end
	local last = {
		text = "waiting for the first pass",
		n = 0,
		field = 0,
		degraded = nil
	}
	function M.status()
		return last
	end
	local function degradedFor(list)
		local anyArea, anyRarity = false, false
		for _, e in ipairs(list) do
			if e.areaId ~= nil then
				anyArea = true
			end
			if e.rarity and e.rarity ~= "?" then
				anyRarity = true
			end
			if anyArea and anyRarity then
				return nil
			end
		end
		if count(areas) > 0 and not anyArea then
			return "eggs carry no area on this executor - clear the Areas filter"
		end
		if count(rarities) > 0 and not anyRarity then
			return "eggs carry no rarity on this executor - clear the Rarities filter"
		end
		return nil
	end
	local blockedSince = nil
	local GUARD_WAIT_MAX = 3
	local overrideUntil = 0
	local OVERRIDE_FOR = 25
	function M.pick()
		local list = eggs.list()
		local field = list and # list or 0
		if field == 0 then
			last = {
				text = "no takeable eggs on the field",
				n = 0,
				field = 0
			}
			return nil, "field=0 (no takeable eggs listed)"
		end
		local afterArea, afterRarity = 0, 0
		local best, bestKey
		local overriding = os.clock() < overrideUntil
		local blocked = overriding and {} or guardwatch.blockedAreas()
		local skippedFor = {}
		for _, e in ipairs(list) do
			local areaOk = (count(areas) == 0) or areas[tostring(e.areaId)] == true
			if areaOk then
				afterArea = afterArea + 1
				if rarityOk(e) and blocked[tostring(e.areaId)] then
					skippedFor[tostring(e.areaId)] = true
				elseif rarityOk(e) then
					afterRarity = afterRarity + 1
					local key = (targetBy == "Weight") and (tonumber(e.kg) or 0) or (tonumber(e.value) or 0)
					if not best or key > bestKey then
						best, bestKey = e, key
					end
				end
			end
		end
		if best then
			blockedSince = nil
			last = {
				text = ("%d of %d eggs match  \u{B7}  next: %s"):format(afterRarity, field, tostring(best.name)),
				n = afterRarity,
				field = field
			}
			return best, nil, overriding
		end
		local waitingOn = {}
		for areaId in pairs(skippedFor) do
			waitingOn[# waitingOn + 1] = areaId
		end
		if # waitingOn > 0 then
			local now = os.clock()
			blockedSince = blockedSince or now
			if (now - blockedSince) >= GUARD_WAIT_MAX then
				local best2, key2
				for _, e in ipairs(list) do
					local areaOk = (count(areas) == 0) or areas[tostring(e.areaId)] == true
					if areaOk and rarityOk(e) then
						local key = (targetBy == "Weight") and (tonumber(e.kg) or 0) or (tonumber(e.value) or 0)
						if not best2 or key > key2 then
							best2, key2 = e, key
						end
					end
				end
				if best2 then
					log.info("guard still out after %.0fs - going anyway for %s", now - blockedSince, tostring(best2.name))
					blockedSince = nil
					overrideUntil = now + OVERRIDE_FOR
					last = {
						text = ("guard still out - going anyway  \u{B7}  next: %s"):format(tostring(best2.name)),
						n = 1,
						field = field
					}
					return best2, nil, true
				end
			end
			table.sort(waitingOn)
			local names = table.concat(waitingOn, ", ")
			last = {
				text = ("waiting for guards to go home: %s"):format(names),
				n = 0,
				field = field
			}
			return nil, "guards out: " .. names
		end
		local degraded = degradedFor(list)
		local why = ("all eggs discovered=%d area-matched=%d rarity-matched=%d target candidates=%d final eligible=0 (%s)") :format(field, afterArea, afterRarity, afterRarity, M.describe())
		if degraded then
			why = why .. " - " .. degraded
		end
		last = {
			text = degraded or ("0 of %d eggs match your filters  \u{B7}  waiting"):format(field),
			n = 0,
			field = field,
			degraded = degraded,
		}
		return nil, why
	end
	function M.matchCount()
		local list = eggs.list()
		local n = 0
		for _, e in ipairs(list or {}) do
			if wanted(e) then
				n = n + 1
			end
		end
		return n
	end
	return M
end)
BX.module("features.farm.treadmill_on", function(BX)
	local svc = BX.require("core.services")
	local data = BX.require("core.data")
	local ch = BX.require("core.character")
	local dev = BX.require("core.device")
	local net = BX.require("core.net")
	local st = BX.require("core.state")
	local log = BX.require("boot.log").for_module("farm.treadmill")
	local M = {}
	local K = {
		POLL = 1.0,
		DRIFT = 6,
		STEP_OFF = 14,
	}
	M.K = K
	local PlotState = data.plotState()
	local sc = nil
	local enabled = false
	local stats = {
		nudges = 0,
		paused = 0,
		doffed = 0,
		noSpot = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isOn()
		return enabled
	end
	function M.spot()
		local slot
		BX.try("farm.treadmill.slot", function()
			slot = PlotState and PlotState.ResolveLocalSlot and PlotState.ResolveLocalSlot()
		end)
		if not slot then
			return nil
		end
		local pos
		BX.try("farm.treadmill.spot", function()
			local folder = workspace:FindFirstChild("__ClientTreadmillRenders")
			local render = folder and folder:FindFirstChild("TreadmillRender_" .. tostring(slot))
			local root = render and render:FindFirstChild("Root")
			if root and root:IsA("BasePart") then
				pos = root.Position
				return
			end
			local plots = workspace:FindFirstChild("Plots")
			local plot = plots and plots:FindFirstChild(tostring(slot))
			local bottom = plot and plot:FindFirstChild("TreadmillBottom")
			if bottom and bottom:IsA("BasePart") then
				pos = bottom.Position + Vector3.new(0, 4, 0)
			end
		end)
		return pos
	end
	local function place(pos)
		local hrp = ch.root()
		if not hrp or not pos then
			return false
		end
		local ok = BX.try("farm.treadmill.place", function()
			hrp.CFrame = CFrame.new(pos)
		end)
		return ok and true or false
	end
	local function step()
		if not enabled then
			return
		end
		if st.autoStealOn then
			stats.paused = stats.paused + 1
			return
		end
		local pos = M.spot()
		if not pos then
			stats.noSpot = stats.noSpot + 1
			return
		end
		local hrp = ch.root()
		if not hrp then
			return
		end
		if (hrp.Position - pos).Magnitude > K.DRIFT then
			if place(pos) then
				stats.nudges = stats.nudges + 1
				log.trace("nudged back onto the belt")
			end
		end
	end
	function M.setEnabled(on)
		on = on and true or false
		if on == enabled then
			return true
		end
		if on then
			if st.autoStealOn then
				log.warn("refused - Auto Steal is running")
				return false, "Turn Auto Steal off first"
			end
			local pos = M.spot()
			if not pos then
				log.warn("refused - could not resolve your treadmill")
				return false, "Could not find your treadmill"
			end
			enabled = true
			st.stayOnTreadmill = true
			BX.require("core.motion").claim("hold")
			place(pos)
			sc = BX.scope("features.farm.treadmill_on")
			sc:loop("hold", dev.scale(K.POLL), step)
			ch.onSpawn(sc, "farm.treadmill.respawn", function()
				if enabled and not st.autoStealOn then
					place(M.spot())
				end
			end)
			log.info("holding on the belt (poll %.1fs)", dev.scale(K.POLL))
			return true
		end
		enabled = false
		st.stayOnTreadmill = false
		BX.require("core.motion").release("hold")
		if sc then
			sc:destroy()
			sc = nil
		end
		local ok, msg = net.call("RF/Treadmill/AskDoff")
		if ok == true then
			stats.doffed = stats.doffed + 1
		else
			log.warn("AskDoff refused: %s %s", tostring(ok), tostring(msg or ""))
		end
		local pos = M.spot()
		if pos then
			place(pos + Vector3.new(0, 3, K.STEP_OFF))
		end
		log.info("released (%d nudges, %d paused for a run)", stats.nudges, stats.paused)
		return true
	end
	BX.onTeardown("farm.treadmill_on", function()
		if enabled then
			M.setEnabled(false)
		end
	end)
	return M
end)
BX.module("features.farm.pets", function(BX)
	local net = BX.require("core.net")
	local log = BX.require("boot.log").for_module("farm.pets")
	local M = {}
	local stats = {
		asked = 0,
		equipped = 0,
		refused = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.equipBest()
		stats.asked = stats.asked + 1
		local ok, msg = net.call("RF/Haul/WearBest")
		if ok == true then
			stats.equipped = stats.equipped + 1
			log.info("equipped best pets")
			return true, "Equipped your best pets"
		end
		stats.refused = stats.refused + 1
		log.warn("WearBest refused: %s %s", tostring(ok), tostring(msg or ""))
		return false, "Refused: " .. tostring(msg or ok)
	end
	return M
end)
BX.module("features.farm.plotcare", function(BX)
	local svc = BX.require("core.services")
	local dev = BX.require("core.device")
	local st = BX.require("core.state")
	local data = BX.require("core.data")
	local eggs = BX.require("features.eggs")
	local log = BX.require("boot.log").for_module("farm.plotcare")
	local M = {}
	local K = {
		TICK = 5,
		HATCH_GAP = 1.5,
		FINISH_TRIES = 4,
		PLACE_GAP = 0.6,
		WEAR_WAIT = 1.5,
		SPACING = 7,
		MARGIN = 4,
		CLEARANCE = 5.5,
		SPOT_TRIES = 3,
		REFUSED_WAIT = 30,
		NEAR = 35,
		WALK_TIMEOUT = 8,
		RANGE_WAIT = 4,
	}
	M.K = K
	local placeOn, hatchOn = false, false
	local placeSc, hatchSc = nil, nil
	local busyPlace, busyHatch = false, false
	local placeCooldownUntil = 0
	local lastPlace, lastHatch = "off", "off"
	local stats = {
		placed = 0,
		placeRefused = 0,
		hatched = 0,
		hatchRefused = 0,
		finishRetries = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isPlacing()
		return placeOn
	end
	function M.isHatching()
		return hatchOn
	end
	local function me()
		local lp = svc.Players.LocalPlayer
		return lp and lp.UserId
	end
	local function ownedEggs()
		local ES = data.eggState()
		local recs = {}
		BX.try("plotcare.readOwner", function()
			recs = (ES and ES.ReadOwnerEggs and ES.ReadOwnerEggs(me())) or {}
		end)
		return recs, ES
	end
	local function inArena()
		local lp = svc.Players.LocalPlayer
		return lp ~= nil and lp:GetAttribute("InBossArena") == true
	end
	local function hatchOne(ES, uid)
		local ok, msg, result = false, nil, nil
		BX.try("plotcare.beginHatch", function()
			ok, msg, result = ES.BeginHatch(uid)
		end)
		if not ok then
			stats.hatchRefused = stats.hatchRefused + 1
			lastHatch = "refused: " .. tostring(msg or "no reason given")
			log.warn("BeginHatch refused for %s: %s", uid, tostring(msg))
			return false
		end
		for attempt = 1, K.FINISH_TRIES do
			task.wait(K.HATCH_GAP)
			if not hatchOn then
				return false
			end
			local fok, fmsg, granted = false, nil, nil
			BX.try("plotcare.finishHatch", function()
				fok, fmsg, granted = ES.FinishHatch(uid)
			end)
			if fok then
				stats.hatched = stats.hatched + 1
				lastHatch = ("hatched %d this session"):format(stats.hatched)
				log.info("hatched %s -> %s%s", uid, tostring(granted), result and (" (" .. tostring(result) .. ")") or "")
				return true
			end
			stats.finishRetries = stats.finishRetries + 1
			log.warn("FinishHatch %d/%d for %s: %s", attempt, K.FINISH_TRIES, uid, tostring(fmsg))
			lastHatch = "finishing: " .. tostring(fmsg or "waiting")
		end
		return false
	end
	local function hatchPass()
		if not hatchOn or busyHatch then
			return
		end
		if st.autoStealOn then
			lastHatch = "waiting for Auto Steal"
			return
		end
		busyHatch = true
		BX.try("plotcare.hatchPass", function()
			local recs, ES = ownedEggs()
			if not (ES and ES.IsReadyToHatch and ES.BeginHatch and ES.FinishHatch) then
				lastHatch = "hatch API unavailable"
				return
			end
			local placed, ready = 0, {}
			for uid, rec in pairs(recs) do
				if rec.Placement ~= nil then
					placed = placed + 1
					local isReady = false
					BX.try("plotcare.ready", function()
						isReady = ES.IsReadyToHatch(uid) == true
					end)
					if isReady then
						ready[# ready + 1] = uid
					end
				end
			end
			if # ready == 0 then
				lastHatch = placed == 0 and "nothing placed" or ("%d growing"):format(placed)
				return
			end
			for _, uid in ipairs(ready) do
				if not hatchOn or st.autoStealOn then
					break
				end
				hatchOne(ES, uid)
			end
		end)
		busyHatch = false
	end
	local function freeSpots(plot)
		local area, center = plot.PetArea, plot.CenterPoint
		if not (area and center and area:IsA("BasePart")) then
			return {}
		end
		local taken = {}
		local folder = workspace:FindFirstChild("PlacedEggRenders")
		local prefix = tostring(me()) .. "_"
		if folder then
			for _, m in ipairs(folder:GetChildren()) do
				if m:IsA("Model") and m.Name:sub(1, # prefix) == prefix then
					BX.try("plotcare.pivot", function()
						taken[# taken + 1] = m:GetPivot().Position
					end)
				end
			end
		end
		local half = area.Size * 0.5
		local spots = {}
		for x = - half.X + K.MARGIN, half.X - K.MARGIN, K.SPACING do
			for z = - half.Z + K.MARGIN, half.Z - K.MARGIN, K.SPACING do
				local world = (area.CFrame * CFrame.new(x, half.Y, z)).Position
				local clear = true
				for _, p in ipairs(taken) do
					local flat = Vector3.new(p.X - world.X, 0, p.Z - world.Z)
					if flat.Magnitude < K.CLEARANCE then
						clear = false
						break
					end
				end
				if clear then
					spots[# spots + 1] = center.CFrame:ToObjectSpace(CFrame.new(world))
				end
			end
		end
		return spots
	end
	local function wornEggToolUid(timeout)
		local lp = svc.Players.LocalPlayer
		local deadline = os.clock() + (timeout or 0)
		repeat
			local char = lp and lp.Character
			if char then
				for _, d in ipairs(char:GetChildren()) do
					if d:IsA("Tool") and d:GetAttribute("ItemType") == "AssetEgg" then
						local uid = d:GetAttribute("UID")
						if type(uid) == "string" and uid ~= "" then
							return uid
						end
					end
				end
			end
			if os.clock() >= deadline then
				break
			end
			task.wait(0.05)
		until false
		return nil
	end
	local function unplacedByValue(recs)
		local list = {}
		for uid, rec in pairs(recs) do
			if rec.Placement == nil then
				local v = 0
				BX.try("plotcare.value", function()
					v = eggs.value({
						Uid = uid,
						AssetCategory = rec.AssetCategory,
						AssetScale = rec.AssetScale,
						Mutations = rec.Mutations
					}) or 0
				end)
				list[# list + 1] = {
					uid = uid,
					value = tonumber(v) or 0,
					name = tostring(rec.AssetCategory)
				}
			end
		end
		table.sort(list, function(a, b)
			return a.value > b.value
		end)
		return list
	end
	local function placeOne(ES, plot, egg)
		local wok, wmsg = false, nil
		BX.try("plotcare.wear", function()
			wok, wmsg = ES.WearEggTool(egg.uid)
		end)
		if not wok then
			return false, "could not hold the egg: " .. tostring(wmsg or "refused")
		end
		local toolUid = wornEggToolUid(K.WEAR_WAIT) or egg.uid
		local spots = freeSpots(plot)
		if # spots == 0 then
			BX.try("plotcare.doff", function()
				ES.DoffEggTool(toolUid)
			end)
			return false, "no free space on the plot"
		end
		local lastMsg
		for i = 1, math.min(K.SPOT_TRIES, # spots) do
			local spot = spots[((stats.placed + i - 1) % # spots) + 1]
			local ok, msg = false, nil
			BX.try("plotcare.plant", function()
				ok, msg = ES.PlantEgg(toolUid, spot)
			end)
			if ok then
				stats.placed = stats.placed + 1
				log.info("placed %s (%s)", egg.name, toolUid)
				return true
			end
			lastMsg = msg
			log.warn("PlantEgg refused (%s): %s", egg.name, tostring(msg))
		end
		BX.try("plotcare.doff", function()
			ES.DoffEggTool(toolUid)
		end)
		return false, tostring(lastMsg or "refused")
	end
	local invited = false
	local nearNeeded = K.NEAR
	local function isRangeRefusal(msg)
		return type(msg) == "string" and msg:lower():find("closer", 1, true) ~= nil
	end
	local function walkToPlot(plot)
		local lp = svc.Players.LocalPlayer
		local char = lp and lp.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local anchor = plot.CenterPoint or plot.PetArea
		if not (hum and root and anchor and anchor:IsA("BasePart")) then
			return false, "no character or plot to walk to"
		end
		local target = anchor.Position
		local function flatDist()
			local d = root.Position - target
			return Vector3.new(d.X, 0, d.Z).Magnitude
		end
		if flatDist() <= nearNeeded then
			return true
		end
		if hum.Health <= 0 then
			return false, "character is dead"
		end
		lastPlace = "walking to your plot"
		log.info("walking to the plot to place (%.0f studs away)", flatDist())
		local deadline = os.clock() + K.WALK_TIMEOUT
		local lastIssue = 0
		while os.clock() < deadline do
			if not placeOn or (st.autoStealOn and not invited) or st.stayOnTreadmill or inArena() then
				return false, "interrupted"
			end
			if os.clock() - lastIssue >= 1 then
				lastIssue = os.clock()
				hum:MoveTo(target)
			end
			if flatDist() <= nearNeeded then
				hum:MoveTo(root.Position)
				return true
			end
			task.wait(0.1)
		end
		return false, "could not walk to your plot"
	end
	local function placePass()
		if not placeOn or busyPlace then
			return
		end
		if os.clock() < placeCooldownUntil and not invited then
			return
		end
		if st.autoStealOn and not invited then
			lastPlace = "waiting for Auto Steal"
			return
		end
		if st.stayOnTreadmill then
			lastPlace = "waiting for the treadmill hold"
			return
		end
		if inArena() then
			lastPlace = "waiting - in the boss arena"
			return
		end
		busyPlace = true
		BX.try("plotcare.placePass", function()
			local recs, ES = ownedEggs()
			local PS = data.plotState()
			if not (ES and ES.WearEggTool and ES.PlantEgg and ES.DoffEggTool and PS) then
				lastPlace = "place API unavailable"
				return
			end
			local plot
			BX.try("plotcare.plot", function()
				plot = PS.ResolvePlot()
			end)
			if type(plot) ~= "table" then
				lastPlace = "could not find your plot"
				return
			end
			local todo = unplacedByValue(recs)
			if # todo == 0 then
				lastPlace = "no eggs to place"
				return
			end
			local near, whyFar = walkToPlot(plot)
			if not near then
				lastPlace = "waiting: " .. tostring(whyFar)
				placeCooldownUntil = os.clock() + K.RANGE_WAIT
				return
			end
			for _, egg in ipairs(todo) do
				if not placeOn or (st.autoStealOn and not invited) or st.stayOnTreadmill then
					break
				end
				local ok, stop = placeOne(ES, plot, egg)
				if not ok then
					stats.placeRefused = stats.placeRefused + 1
					if isRangeRefusal(stop) then
						lastPlace = "getting closer to your plot"
						placeCooldownUntil = os.clock() + K.RANGE_WAIT
						if nearNeeded > 8 then
							nearNeeded = 8
							log.info("still out of range - walking to the plot centre from now on")
						end
					else
						lastPlace = "stopped: " .. tostring(stop)
						placeCooldownUntil = os.clock() + K.REFUSED_WAIT
					end
					break
				end
				lastPlace = ("placed %d this session"):format(stats.placed)
				task.wait(K.PLACE_GAP)
			end
		end)
		busyPlace = false
	end
	local function arm(name, pass)
		local sc = BX.scope("features.farm.plotcare." .. name)
		sc:loop(name, dev.scale(K.TICK), pass)
		BX.try("plotcare.watch." .. name, function()
			local ES = data.eggState()
			if ES and ES.OwnerRefreshed then
				sc:connect(ES.OwnerRefreshed, function(userId)
					if userId ~= me() then
						return
					end
					task.spawn(function()
						BX.try("plotcare.onOwner." .. name, pass)
					end)
				end)
			end
		end)
		task.spawn(function()
			BX.try("plotcare.first." .. name, pass)
		end)
		return sc
	end
	function M.placeNow()
		if not placeOn then
			return false
		end
		local t0 = os.clock()
		while busyPlace and os.clock() - t0 < 10 do
			task.wait(0.1)
		end
		for attempt = 1, 4 do
			local recs = ownedEggs()
			local any = false
			for _, rec in pairs(recs) do
				if rec.Placement == nil then
					any = true
					break
				end
			end
			if any then
				break
			end
			if attempt == 4 then
				return true
			end
			task.wait(0.5)
		end
		invited = true
		placeCooldownUntil = 0
		BX.try("plotcare.placeNow", placePass)
		invited = false
		return true
	end
	function M.setPlace(on)
		on = on and true or false
		if on == placeOn then
			return true
		end
		placeOn = on
		if placeSc then
			placeSc:destroy()
			placeSc = nil
		end
		if on then
			placeCooldownUntil = 0
			lastPlace = "starting"
			placeSc = arm("place", placePass)
		else
			lastPlace = "off"
		end
		log.info("auto place %s", on and "ON" or "OFF")
		return true
	end
	function M.setHatch(on)
		on = on and true or false
		if on == hatchOn then
			return true
		end
		hatchOn = on
		if hatchSc then
			hatchSc:destroy()
			hatchSc = nil
		end
		if on then
			lastHatch = "starting"
			hatchSc = arm("hatch", hatchPass)
		else
			lastHatch = "off"
		end
		log.info("auto hatch %s", on and "ON" or "OFF")
		return true
	end
	function M.preview()
		local recs, ES = ownedEggs()
		local out = {
			placed = 0,
			ready = 0,
			unplaced = 0,
			freeSpots = 0,
			nextEgg = nil
		}
		for uid, rec in pairs(recs) do
			if rec.Placement ~= nil then
				out.placed = out.placed + 1
				BX.try("plotcare.previewReady", function()
					if ES.IsReadyToHatch(uid) then
						out.ready = out.ready + 1
					end
				end)
			else
				out.unplaced = out.unplaced + 1
			end
		end
		local order = unplacedByValue(recs)
		out.nextEgg = order[1] and order[1].name or nil
		local PS = data.plotState()
		BX.try("plotcare.previewPlot", function()
			local plot = PS and PS.ResolvePlot()
			if type(plot) == "table" then
				out.freeSpots = # freeSpots(plot)
			end
		end)
		return out
	end
	function M.status()
		return ("Place: %s  \u{B7}  Hatch: %s"):format(lastPlace, lastHatch)
	end
	return M
end)
BX.module("features.esp.cards", function(BX)
	local svc = BX.require("core.services")
	local dev = BX.require("core.device")
	local log = BX.require("boot.log").for_module("esp.cards")
	local M = {}
	local K = {
		W = 190,
		H = 40,
		VIS_HZ = 12,
		MAX_DIST = 2200,
		FADE_BAND = 260,
		BASE_ALPHA = 0.42,
		BASE_STROKE = 0.55,
		BUILD_PER_FRAME = 3,
	}
	M.K = K
	local C = {
		bgTop = Color3.fromRGB(26, 26, 30),
		bgBot = Color3.fromRGB(14, 14, 17),
		accent = Color3.fromRGB(206, 206, 212),
		element = Color3.fromRGB(41, 41, 48),
		title = Color3.fromRGB(246, 242, 234),
		sub = Color3.fromRGB(168, 158, 144),
	}
	M.STYLE = {
		titleFont = Enum.Font.GothamBold,
		titleSize = 13,
		subFont = Enum.Font.GothamBold,
		subSize = 10,
	}
	M.COL = {
		income = "57F287",
		neutral = "F0F0F6",
		mutation = "F0BE5A",
		dim = "8A8A92",
		ready = "57F287",
	}
	M.SEP = "  \u{B7}  "
	function M.tint(col, text)
		return ('<font color="#%s">%s</font>'):format(col, text)
	end
	function M.hex(c)
		return ("%02X%02X%02X"):format( math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
	end
	local function scaleFor(dist)
		return math.clamp(1.25 - (tonumber(dist) or 0) / 800, 0.6, 1.25)
	end
	local sc, folder, handles = nil, nil, 0
	local pools = {}
	local build, apply
	local function ensure()
		if sc then
			return
		end
		sc = BX.scope("features.esp.cards")
		folder = Instance.new("Folder")
		folder.Name = "DhzESP"
		sc:own(folder)
		folder.Parent = workspace
		local acc, step = 0, 1 / K.VIS_HZ
		sc:onFrame("vis", svc.RunService.RenderStepped, function(dt)
			local budget = dev.budget(K.BUILD_PER_FRAME)
			for _, pool in pairs(pools) do
				if budget <= 0 then
					break
				end
				for i, d in pairs(pool.pending) do
					if budget <= 0 then
						break
					end
					local c = build()
					pool[i] = c
					pool.n = pool.n + 1
					if i > pool.high then
						pool.high = i
					end
					apply(c, d)
					pool.pending[i] = nil
					budget = budget - 1
				end
			end
			acc = acc + (dt or 0)
			if acc < step then
				return
			end
			acc = 0
			local cam = workspace.CurrentCamera
			if not cam then
				return
			end
			local eye = cam.CFrame.Position
			for _, pool in pairs(pools) do
				for i = 1, pool.shown do
					local c = pool[i]
					if c and c.anchor.Parent then
						local d = (c.pos - eye).Magnitude
						local show = d <= K.MAX_DIST
						if c.bb.Enabled ~= show then
							c.bb.Enabled = show
						end
						if show then
							local s = scaleFor(d)
							if math.abs(c.lastScale - s) > 0.01 or c.lastH ~= c.baseH then
								c.lastScale, c.lastH = s, c.baseH
								c.scale.Scale = s
								c.bb.Size = UDim2.fromOffset(K.W * s, c.baseH * s)
							end
							local fade = math.clamp((K.MAX_DIST - d) / K.FADE_BAND, 0, 1)
							if math.abs(c.lastFade - fade) > 0.02 then
								c.lastFade = fade
								c.frame.BackgroundTransparency = 1 - (1 - K.BASE_ALPHA) * fade
								c.title.TextTransparency = 1 - fade
								c.sub.TextTransparency = 1 - fade
								c.icon.ImageTransparency = 1 - fade
								c.stroke.Transparency = 1 - (1 - K.BASE_STROKE) * fade
							end
						end
					end
				end
			end
		end)
	end
	function build()
		local anchor = Instance.new("Part")
		anchor.Name = "EggAnchor"
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.CastShadow = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.Parent = folder
		local bb = Instance.new("BillboardGui")
		bb.Name = "EggCard"
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.MaxDistance = 1e6
		bb.Size = UDim2.fromOffset(K.W, K.H)
		bb.StudsOffset = Vector3.new(0, 3, 0)
		bb.Active = false
		bb.Adornee = anchor
		bb.Enabled = false
		bb.Parent = anchor
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(K.W, K.H)
		frame.BackgroundColor3 = Color3.new(1, 1, 1)
		frame.BackgroundTransparency = K.BASE_ALPHA
		frame.BorderSizePixel = 0
		frame.ClipsDescendants = true
		frame.Parent = bb
		Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 0)
		local grad = Instance.new("UIGradient", frame)
		grad.Color = ColorSequence.new(C.bgTop, C.bgBot)
		grad.Rotation = 90
		local scaleObj = Instance.new("UIScale")
		scaleObj.Scale = 1
		scaleObj.Parent = frame
		local stroke = Instance.new("UIStroke", frame)
		stroke.Color = Color3.new(1, 1, 1)
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Thickness = 1
		stroke.Transparency = K.BASE_STROKE
		local sg = Instance.new("UIGradient", stroke)
		sg.Color = ColorSequence.new(C.accent, C.element)
		sg.Rotation = 90
		local accent = Instance.new("Frame")
		accent.Name = "Accent"
		accent.Position = UDim2.fromOffset(3, 4)
		accent.Size = UDim2.new(0, 2, 1, - 8)
		accent.BorderSizePixel = 0
		accent.BackgroundColor3 = Color3.fromRGB(194, 142, 54)
		accent.Parent = frame
		Instance.new("UICorner", accent).CornerRadius = UDim.new(0, 0)
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.Position = UDim2.fromOffset(9, 8)
		icon.Size = UDim2.fromOffset(24, 24)
		icon.BackgroundTransparency = 1
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = ""
		icon.Parent = frame
		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.Position = UDim2.fromOffset(38, 3)
		title.Size = UDim2.new(1, - 44, 0, 15)
		title.BackgroundTransparency = 1
		title.Font = Enum.Font.GothamBold
		title.TextSize = 12
		title.TextColor3 = C.title
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.Text = ""
		title.Parent = frame
		local sub = Instance.new("TextLabel")
		sub.Name = "Sub"
		sub.Position = UDim2.fromOffset(38, 18)
		sub.Size = UDim2.new(1, - 44, 0, 20)
		sub.BackgroundTransparency = 1
		sub.Font = Enum.Font.GothamBold
		sub.TextSize = 10
		sub.TextColor3 = C.sub
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.TextYAlignment = Enum.TextYAlignment.Top
		sub.RichText = true
		sub.Text = ""
		sub.Parent = frame
		return {
			anchor = anchor,
			bb = bb,
			frame = frame,
			stroke = stroke,
			accent = accent,
			icon = icon,
			title = title,
			sub = sub,
			scale = scaleObj,
			pos = Vector3.zero,
			baseH = K.H,
			lastScale = - 1,
			lastFade = - 1,
			lastH = - 1,
			lastTitle = nil,
			lastSub = nil,
			lastIcon = nil,
			lastStyle = nil,
		}
	end
	function apply(c, d)
		if c.pos ~= d.pos then
			c.pos = d.pos
			c.anchor.CFrame = CFrame.new(d.pos)
		end
		local h = (d.lines and d.lines > 1) and (K.H + 12) or K.H
		if c.baseH ~= h then
			c.baseH = h
			c.frame.Size = UDim2.fromOffset(K.W, h)
			c.sub.Size = UDim2.new(1, - 44, 0, h - 20)
		end
		local titleText = (d.target and "\u{25B8} " or "") .. tostring(d.title or "")
		if titleText ~= c.lastTitle then
			c.lastTitle = titleText
			c.title.Text = titleText
		end
		if d.sub ~= c.lastSub then
			c.lastSub = d.sub
			c.sub.Text = tostring(d.sub or "")
		end
		if d.icon ~= c.lastIcon then
			c.lastIcon = d.icon
			c.icon.Image = tostring(d.icon or "")
		end
		if d.accent and d.accent ~= c.lastAccent then
			c.lastAccent = d.accent
			c.accent.BackgroundColor3 = d.accent
		end
		local st = d.style
		if st ~= c.lastStyle then
			c.lastStyle = st
			c.title.Font = (st and st.titleFont) or Enum.Font.GothamBold
			c.title.TextSize = (st and st.titleSize) or 12
			c.sub.Font = (st and st.subFont) or Enum.Font.Gotham
			c.sub.TextSize = (st and st.subSize) or 10
		end
	end
	local Handle = {}
	Handle.__index = Handle
	function Handle:show(i, d)
		local pool = pools[self.name]
		local c = pool[i]
		if not c then
			pool.pending[i] = d
			return
		end
		apply(c, d)
	end
	function Handle:shown(n)
		local pool = pools[self.name]
		pool.shown = n
		for i = n + 1, pool.high do
			local c = pool[i]
			if c and c.bb.Enabled then
				c.bb.Enabled = false
			end
		end
		for i in pairs(pool.pending) do
			if i > n then
				pool.pending[i] = nil
			end
		end
	end
	function Handle:count()
		local pool = pools[self.name]
		return pool.n, pool.shown
	end
	function Handle:close()
		local pool = pools[self.name]
		for i = 1, pool.high do
			local c = pool[i]
			if c then
				pcall(function()
					c.anchor:Destroy()
				end)
			end
		end
		pools[self.name] = nil
		handles = handles - 1
		if handles <= 0 then
			handles = 0
			if sc then
				sc:destroy()
				sc = nil
			end
			folder, pools = nil, {}
			log.info("released")
		end
	end
	function M.open(name)
		ensure()
		handles = handles + 1
		pools[name] = {
			shown = 0,
			pending = {},
			n = 0,
			high = 0
		}
		return setmetatable({
			name = name
		}, Handle)
	end
	function M.liveCount()
		local n = 0
		for _, pool in pairs(pools) do
			n = n + pool.n
		end
		return n
	end
	function M.pendingCount()
		local n = 0
		for _, pool in pairs(pools) do
			for _ in pairs(pool.pending) do
				n = n + 1
			end
		end
		return n
	end
	BX.profile.watch("esp.cards", M.liveCount)
	BX.profile.watch("esp.cards.queued", M.pendingCount)
	return M
end)
BX.module("features.esp.eggs", function(BX)
	local dev = BX.require("core.device")
	local eggs = BX.require("features.eggs")
	local data = BX.require("core.data")
	local cards = BX.require("features.esp.cards")
	local log = BX.require("boot.log").for_module("esp.eggs")
	local M = {}
	local K = {
		REFRESH = 1.0,
		MAX_CARDS = 40,
		LIFT_BASE = 2.2,
		LIFT_SCALE = 3.4,
	}
	M.K = K
	local sc, handle, enabled = nil, nil, false
	local stats = {
		updates = 0,
		listed = 0,
		shown = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isOn()
		return enabled
	end
	local STYLE, COL, SEP, tint, hex = cards.STYLE, cards.COL, cards.SEP, cards.tint, cards.hex
	local function rate(n)
		n = tonumber(n) or 0
		for _, u in ipairs({
			{
				1e12,
				"T"
			},
			{
				1e9,
				"B"
			},
			{
				1e6,
				"M"
			},
			{
				1e3,
				"K"
			}
		}) do
			if n >= u[1] then
				local v = n / u[1]
				local txt = (v < 10) and ("%.2f"):format(v) or ("%.1f"):format(v)
				return (txt:gsub("%.?0+$", "")) .. u[2]
			end
		end
		return tostring(math.floor(n))
	end
	local scratch = {}
	local DEFAULT_COLOUR = Color3.fromRGB(200, 200, 200)
	local textFor, textNext = {}, {}
	local slotData = {}
	local function buildText(e, dir)
		local d = e.assetCategory and dir and dir[e.assetCategory] or nil
		local colour = DEFAULT_COLOUR
		local rarityName = (e.rarity and e.rarity ~= "?") and e.rarity or nil
		if d and d.Rarity then
			if typeof(d.Rarity.Color) == "Color3" then
				colour = d.Rarity.Color
			end
			rarityName = rarityName or d.Rarity.DisplayName or d.Rarity._id
		end
		local bits = {
			tint(COL.income, "<b>" .. rate(e.value or 0) .. "/s</b>")
		}
		if rarityName then
			bits[# bits + 1] = tint(hex(colour), rarityName)
		end
		local kg = tonumber(e.kg) or 0
		if kg > 0 then
			bits[# bits + 1] = tint(COL.neutral, kg >= 100 and ("%.0fkg"):format(kg) or ("%.1fkg"):format(kg))
		end
		local sub = table.concat(bits, SEP)
		local lines = 1
		if type(e.mutations) == "table" and # e.mutations > 0 then
			local names = {}
			for _, mu in ipairs(e.mutations) do
				names[# names + 1] = tostring(type(mu) == "table" and (mu.DisplayName or mu._id or "?") or mu)
			end
			sub = sub .. "\n" .. tint(COL.mutation, table.concat(names, " \u{B7} "))
			lines = 2
		end
		return {
			sub = sub,
			lines = lines,
			colour = colour,
			icon = d and d.Icon or nil,
			lift = Vector3.new(0, K.LIFT_BASE + (tonumber(e.assetScale) or 1) * K.LIFT_SCALE, 0),
		}
	end
	local function update()
		if not enabled or not handle then
			return
		end
		stats.updates = stats.updates + 1
		local cam = workspace.CurrentCamera
		local list = eggs.list()
		if not cam or not list then
			return
		end
		local dir = data.assetsDir()
		local eye = cam.CFrame.Position
		for i = # scratch, 1, - 1 do
			scratch[i] = nil
		end
		for _, e in ipairs(list) do
			if e.pos and (e.pos - eye).Magnitude <= cards.K.MAX_DIST then
				scratch[# scratch + 1] = e
			end
		end
		stats.listed = # scratch
		local n = math.min(# scratch, K.MAX_CARDS)
		for i = 1, n do
			local e = scratch[i]
			local t = textFor[e.uid] or buildText(e, dir)
			textNext[e.uid] = t
			local sd = slotData[i]
			if not sd then
				sd = {
					style = STYLE
				}
				slotData[i] = sd
			end
			sd.pos = e.pos + t.lift
			sd.title = e.name
			sd.sub = t.sub
			sd.accent = t.colour
			sd.icon = t.icon
			sd.lines = t.lines
			sd.target = e.isTarget
			handle:show(i, sd)
		end
		textFor, textNext = textNext, textFor
		table.clear(textNext)
		handle:shown(n)
		stats.shown = n
	end
	function M.setEnabled(on)
		on = on and true or false
		if on == enabled then
			return true
		end
		enabled = on
		if not on then
			if handle then
				handle:close()
				handle = nil
			end
			if sc then
				sc:destroy()
				sc = nil
			end
			table.clear(textFor)
			table.clear(slotData)
			log.info("off")
			return true
		end
		handle = cards.open("eggs")
		sc = BX.scope("features.esp.eggs")
		sc:loop("update", dev.scale(K.REFRESH), update)
		log.info("on (max %d cards, %.2fs, range %d)", K.MAX_CARDS, dev.scale(K.REFRESH), cards.K.MAX_DIST)
		return true
	end
	return M
end)
BX.module("features.esp.plot", function(BX)
	local svc = BX.require("core.services")
	local dev = BX.require("core.device")
	local ch = BX.require("core.character")
	local data = BX.require("core.data")
	local util = BX.require("core.util")
	local eggs = BX.require("features.eggs")
	local cards = BX.require("features.esp.cards")
	local log = BX.require("boot.log").for_module("esp.plot")
	local M = {}
	local K = {
		RATE = 1.0,
		MAX_CARDS = 24,
		OWNER_TTL = 10
	}
	M.K = K
	local STYLE, COL, SEP, tint, hex = cards.STYLE, cards.COL, cards.SEP, cards.tint, cards.hex
	local sc, handle, enabled = nil, nil, false
	local stats = {
		updates = 0,
		eggs = 0,
		ready = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isOn()
		return enabled
	end
	local function timeLeft(seconds)
		seconds = math.max(0, math.floor(seconds))
		local h = math.floor(seconds / 3600)
		local m = math.floor(seconds / 60) % 60
		if h > 0 then
			return ("%dh %02dm"):format(h, m)
		end
		if m > 0 then
			return ("%dm %02ds"):format(m, seconds % 60)
		end
		return ("%ds"):format(seconds)
	end
	local recs, recsAt, recsDirty = nil, 0, true
	local staticFor = {}
	local slotData = {}
	local DEFAULT_COLOUR = Color3.fromRGB(190, 190, 200)
	local READY_TEXT = tint(COL.ready, "<b>READY</b>")
	local function ownerRecords(ES, me)
		local now = os.clock()
		if recs and not recsDirty and (now - recsAt) < K.OWNER_TTL then
			return recs
		end
		local ok, got = pcall(function()
			return ES and ES.ReadOwnerEggs and ES.ReadOwnerEggs(me)
		end)
		recs = (ok and type(got) == "table") and got or {}
		recsAt, recsDirty = now, false
		table.clear(staticFor)
		stats.ownerReads = (stats.ownerReads or 0) + 1
		return recs
	end
	local function buildStatic(uid, rec, dir)
		local d = rec and dir and dir[rec.AssetCategory] or nil
		local title = (d and d.DisplayName ~= "" and d.DisplayName) or (rec and tostring(rec.AssetCategory)) or "Egg"
		local rarity = d and d.Rarity and tostring(d.Rarity.DisplayName or d.Rarity._id or "") or ""
		local colour = (d and d.Rarity and typeof(d.Rarity.Color) == "Color3") and d.Rarity.Color or DEFAULT_COLOUR
		local muts = ""
		if rec and type(rec.Mutations) == "table" and # rec.Mutations > 0 then
			local names = {}
			for _, mu in ipairs(rec.Mutations) do
				names[# names + 1] = tostring(type(mu) == "table" and (mu.DisplayName or mu._id or "?") or mu)
			end
			muts = table.concat(names, " \u{B7} ")
		end
		local rate = nil
		if rec then
			local ok, v = pcall(eggs.value, {
				Uid = uid,
				AssetCategory = rec.AssetCategory,
				AssetScale = rec.AssetScale,
				Mutations = rec.Mutations,
			})
			if ok then
				rate = v
			end
		end
		local kg = d and d.Egg and tonumber(d.Egg.WeightKg)
		if kg then
			kg = kg * (tonumber(rec and rec.AssetScale) or 1)
		end
		if kg and kg <= 0 then
			kg = nil
		end
		local bits = {}
		if rate and rate > 0 then
			bits[# bits + 1] = tint(COL.income, "<b>" .. eggs.formatRate(rate) .. "/s</b>")
		end
		if rarity ~= "" then
			bits[# bits + 1] = tint(hex(colour), rarity)
		end
		if kg then
			bits[# bits + 1] = tint(COL.neutral, kg >= 100 and ("%.0fkg"):format(kg) or ("%.1fkg"):format(kg))
		end
		local grow = d and d.Egg and tonumber(d.Egg.GrowthTime)
		local placed = rec and rec.Placement and tonumber(rec.Placement.PlacedAt)
		local mult = math.max(tonumber(rec and rec.GrowthSpeedMultiplier) or 1, 0.01)
		return {
			title = title,
			colour = colour,
			icon = d and d.Icon or nil,
			head = table.concat(bits, SEP) .. "\n" .. ((muts ~= "") and (tint(COL.mutation, muts) .. SEP) or ""),
			readyAt = (grow and placed) and (placed + grow / mult) or nil,
			hasRec = rec ~= nil,
			lift = Vector3.new(0, 2.2 + (tonumber(rec and rec.AssetScale) or 1) * 3.4, 0),
		}
	end
	local function update()
		if not enabled or not handle then
			return
		end
		stats.updates = stats.updates + 1
		local rendered = workspace:FindFirstChild("PlacedEggRenders")
		if not rendered then
			handle:shown(0)
			stats.eggs = 0
			return
		end
		local ES = data.eggState()
		local dir = data.assetsDir()
		local me = svc.Players.LocalPlayer and svc.Players.LocalPlayer.UserId
		if not me then
			return
		end
		local prefix = tostring(me) .. "_"
		local plen = # prefix
		local owned = ownerRecords(ES, me)
		local isReady = ES and ES.IsReadyToHatch
		local nowT = os.time()
		local n, readyN = 0, 0
		for _, m in ipairs(rendered:GetChildren()) do
			local name = m.Name
			if string.find(name, prefix, 1, true) == 1 and m:IsA("Model") then
				local uid = string.sub(name, plen + 1)
				local okPos, pv = pcall(m.GetPivot, m)
				if okPos and pv then
					n = n + 1
					local s = staticFor[uid]
					if not s then
						local rec = owned[uid]
						s = buildStatic(uid, rec, dir)
						if rec then
							staticFor[uid] = s
						else
							recsDirty = true
						end
					end
					local ready = false
					if isReady then
						local okR, r = pcall(isReady, uid)
						ready = okR and r == true
					end
					local state
					if ready then
						readyN = readyN + 1
						state = READY_TEXT
					elseif s.readyAt then
						state = tint(COL.dim, timeLeft(s.readyAt - nowT))
					else
						state = tint(COL.dim, "growing")
					end
					local sd = slotData[n]
					if not sd then
						sd = {
							style = STYLE,
							lines = 2
						}
						slotData[n] = sd
					end
					sd.pos = pv.Position + s.lift
					sd.title = s.title
					sd.sub = s.head .. state
					sd.accent = s.colour
					sd.icon = s.icon
					sd.target = ready
					handle:show(n, sd)
				end
			end
		end
		handle:shown(n)
		stats.eggs, stats.ready = n, readyN
	end
	function M.setEnabled(on)
		on = on and true or false
		if on == enabled then
			return true
		end
		enabled = on
		if not on then
			if handle then
				handle:close()
				handle = nil
			end
			if sc then
				sc:destroy()
				sc = nil
			end
			recs, recsAt, recsDirty = nil, 0, true
			table.clear(staticFor)
			table.clear(slotData)
			log.info("off")
			return true
		end
		handle = cards.open("plot")
		sc = BX.scope("features.esp.plot")
		recsDirty = true
		BX.try("esp.plot.watchOwner", function()
			local ES = data.eggState()
			for _, name in ipairs({
				"OwnerRefreshed",
				"OwnerCleared"
			}) do
				local sig = ES and ES[name]
				if type(sig) == "table" and type(sig.Connect) == "function" then
					sc:connect(sig, function()
						recsDirty = true
					end)
				end
			end
		end)
		sc:loop("update", dev.scale(K.RATE), update)
		ch.onSpawn(sc, "esp.plot.respawn", function()
			if handle then
				handle:shown(0)
			end
		end)
		log.info("on (%.2fs)", dev.scale(K.RATE))
		return true
	end
	return M
end)
BX.module("features.misc.servers", function(BX)
	local svc = BX.require("core.services")
	local exec = BX.require("core.exec")
	local log = BX.require("boot.log").for_module("servers")
	local M = {}
	local K = {
		MAX_PAGES = 5,
		TRIES = 4,
		FAILED_FOR = 600,
		FAILED_MAX = 200,
		TP_SETTLE = 2.5,
	}
	M.K = K
	local searching = false
	local failed, failedN = {}, 0
	BX.profile.watch("servers.failed", function()
		return failedN
	end)
	local function pruneFailed()
		local now = os.clock()
		local live, n = {}, 0
		for id, at in pairs(failed) do
			if (now - at) > K.FAILED_FOR then
				failed[id] = nil
			else
				n = n + 1
				live[n] = id
			end
		end
		if n > K.FAILED_MAX then
			table.sort(live, function(a, b)
				return failed[a] < failed[b]
			end)
			for i = 1, n - K.FAILED_MAX do
				failed[live[i]] = nil
			end
			n = K.FAILED_MAX
		end
		failedN = n
	end
	local function markFailed(id)
		if not id then
			return
		end
		failed[id] = os.clock()
		pruneFailed()
	end
	local function canFetch()
		if exec.can.request then
			return true
		end
		local ok, f = pcall(function()
			return game.HttpGet
		end)
		return ok and type(f) == "function"
	end
	local function fetchPage(cursor)
		local url = ("https://games.roblox.com/v1/games/%d/servers/Public" .. "?sortOrder=Asc&limit=100"):format(game.PlaceId)
		if cursor then
			url = url .. "&cursor=" .. tostring(cursor)
		end
		local body, via, status
		if exec.can.request then
			local res
			BX.try("servers.fetch", function()
				res = exec.httpRequest({
					Url = url,
					Method = "GET"
				})
			end)
			body = res and (res.Body or res.body)
			status = res and (res.StatusCode or res.status_code)
			via = "request"
		end
		if not body then
			local ok, got = pcall(function()
				return game:HttpGet(url)
			end)
			if ok and type(got) == "string" then
				body, via = got, "HttpGet"
			elseif not ok then
				status = tostring(got)
			end
		end
		if not body then
			log.warn("server list: no response (via %s, %s)", tostring(via), tostring(status))
			return nil, "no response" .. (tostring(status):find("429") and " - rate limited, wait a few seconds" or "")
		end
		local decoded
		pcall(function()
			decoded = svc.HttpService:JSONDecode(body)
		end)
		if type(decoded) ~= "table" or type(decoded.data) ~= "table" then
			log.warn("server list: unreadable (via %s, status %s, %d bytes: %s)", tostring(via), tostring(status), # body, body:sub(1, 80))
			return nil, "unreadable list"
		end
		log.info("server list: page via %s, %d servers%s", via, # decoded.data, decoded.nextPageCursor and ", more pages" or "")
		return decoded
	end
	local function candidates()
		pruneFailed()
		local out, cursor = {}, nil
		local here = tostring(game.JobId)
		local listed, pages, why = 0, 0, nil
		for _ = 1, K.MAX_PAGES do
			local page, err = fetchPage(cursor)
			if not page then
				why = why or err
				break
			end
			pages = pages + 1
			for _, sv in ipairs(page.data) do
				listed = listed + 1
				local playing = tonumber(sv.playing) or 0
				local maxP = tonumber(sv.maxPlayers) or 0
				if sv.id and sv.id ~= here and not failed[sv.id] and maxP > 0 and playing < maxP then
					out[# out + 1] = {
						id = sv.id,
						playing = playing,
						maxPlayers = maxP,
						ping = tonumber(sv.ping) or 0,
					}
				end
			end
			cursor = page.nextPageCursor
			if not cursor then
				break
			end
		end
		log.info("candidates: %d of %d listed over %d page(s) (here=%s, failed cache=%d)", # out, listed, pages, here:sub(1, 8), failedN)
		return out, listed, why
	end
	local function teleport(sv)
		local failedWhy = nil
		local conn
		pcall(function()
			conn = svc.TeleportService.TeleportInitFailed:Connect(function(plr, result, msg)
				if plr == svc.Players.LocalPlayer then
					failedWhy = tostring(result) .. " " .. tostring(msg or "")
				end
			end)
		end)
		log.info("teleporting to %s (%d/%d players)", tostring(sv.id):sub(1, 8), sv.playing, sv.maxPlayers)
		pcall(function()
			BX.require("boot.log").flushNow()
		end)
		local ok, err = pcall(function()
			svc.TeleportService:TeleportToPlaceInstance(game.PlaceId, sv.id, svc.Players.LocalPlayer)
		end)
		if ok then
			local t0 = os.clock()
			while not failedWhy and (os.clock() - t0) < K.TP_SETTLE do
				task.wait(0.1)
			end
		end
		if conn then
			pcall(function()
				conn:Disconnect()
			end)
		end
		if not ok or failedWhy then
			markFailed(sv.id)
			log.warn("teleport to %s failed: %s", tostring(sv.id):sub(1, 8), tostring(failedWhy or err))
			return false, failedWhy or err
		end
		log.info("teleport requested: %s (%d/%d players)", tostring(sv.id):sub(1, 8), sv.playing, sv.maxPlayers)
		return true
	end
	local function go(order, what)
		if searching then
			return false, "Already searching"
		end
		if not canFetch() then
			log.warn("%s: no HTTP capability on this executor (request=%s)", what, tostring(exec.can.request))
			return false, "Server search is not supported by this executor"
		end
		searching = true
		log.info("%s: click", what)
		local okRun, ok, msg = pcall(function()
			local list, listed, why = candidates()
			if # list == 0 then
				if listed == 0 then
					return false, "Could not read the server list" .. (why and (" (" .. why .. ")") or "")
				end
				return false, ("All %d listed servers are full or recently refused us"):format(listed)
			end
			table.sort(list, order)
			local lastWhy
			for i = 1, math.min(# list, K.TRIES) do
				local sv = list[i]
				local tpOk, tpWhy = teleport(sv)
				if tpOk then
					log.info("%s: joining %d/%d players", what, sv.playing, sv.maxPlayers)
					return true, ("Joining a server with %d players"):format(sv.playing)
				end
				lastWhy = tpWhy
			end
			return false, "Teleport refused " .. math.min(# list, K.TRIES) .. " times" .. (lastWhy and (" (" .. tostring(lastWhy) .. ")") or "") .. " - press again"
		end)
		searching = false
		if not okRun then
			log.warn("%s: failed: %s", what, tostring(ok))
			return false, "Server search failed - see the log"
		end
		return ok, msg
	end
	function M.lowestServer()
		return go(function(a, b)
			if a.playing ~= b.playing then
				return a.playing < b.playing
			end
			local ap = a.ping > 0 and a.ping or math.huge
			local bp = b.ping > 0 and b.ping or math.huge
			return ap < bp
		end, "lowest")
	end
	function M.hop()
		return go(function(a, b)
			return a.playing < b.playing
		end, "hop")
	end
	function M.stats()
		pruneFailed()
		return {
			failedServers = failedN,
			searching = searching
		}
	end
	return M
end)
BX.module("features.misc.webhook", function(BX)
	local svc = BX.require("core.services")
	local exec = BX.require("core.exec")
	local util = BX.require("core.util")
	local log = BX.require("boot.log").for_module("webhook")
	local M = {}
	local K = {
		MIN_GAP = 3.0,
		TIMEOUT = 8
	}
	M.K = K
	local enabled = false
	local url = nil
	local lastSend = 0
	local stats = {
		sent = 0,
		failed = 0,
		dropped = 0,
		skipped = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isOn()
		return enabled
	end
	function M.hasUrl()
		return url ~= nil and url ~= ""
	end
	function M.redactedUrl()
		if not M.hasUrl() then
			return "not set"
		end
		local host = tostring(url):match("^https?://([^/]+)") or "?"
		return ("%s/...(%d chars)"):format(host, # url)
	end
	function M.setEnabled(on)
		enabled = on and true or false
		log.info("%s (url %s)", enabled and "enabled" or "disabled", M.redactedUrl())
		return true
	end
	function M.setUrl(v)
		v = tostring(v or ""):gsub("%s", "")
		if v == "" then
			url = nil
			log.info("url cleared")
			return true, "URL cleared"
		end
		if not v:match("^https://") then
			return false, "That does not look like a webhook URL"
		end
		url = v
		log.info("url set (%s)", M.redactedUrl())
		return true, "Webhook URL saved"
	end
	local function embedFor(e)
		local fields = {}
		local function add(name, value)
			if value == nil or value == "" then
				return
			end
			fields[# fields + 1] = {
				name = name,
				value = tostring(value),
				inline = true
			}
		end
		add("Income", (e.value and (util.short(e.value) .. "/s")) or nil)
		add("Weight", e.kg and e.kg > 0 and ("%.1f kg"):format(e.kg) or nil)
		add("Rarity", e.rarity ~= "?" and e.rarity or nil)
		add("Mutation", e.mutation)
		add("Area", e.areaId)
		return {
			username = "DHZ HUB",
			embeds = {
				{
					title = "Egg delivered",
					description = "**" .. tostring(e.name or "Egg") .. "**",
					color = 5814783,
					fields = fields,
					footer = {
						text = "DhzHub " .. tostring(BX.version)
					},
					timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
				}
			},
		}
	end
	local function post(payload, tag)
		if not exec.can.request then
			stats.skipped = stats.skipped + 1
			log.warn("no HTTP request capability - nothing sent")
			return false
		end
		local body
		local okEnc = pcall(function()
			body = svc.HttpService:JSONEncode(payload)
		end)
		if not okEnc or not body then
			stats.failed = stats.failed + 1
			return false
		end
		local res
		local ok = BX.try("webhook.post", function()
			res = exec.httpRequest({
				Url = url,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json"
				},
				Body = body,
			})
		end)
		local code = res and (res.StatusCode or res.status_code)
		if ok and code and code >= 200 and code < 300 then
			stats.sent = stats.sent + 1
			log.info("%s sent (HTTP %s)", tag, tostring(code))
			return true
		end
		stats.failed = stats.failed + 1
		log.warn("%s failed (HTTP %s)", tag, tostring(code or "no response"))
		return false
	end
	function M.onDelivered(e)
		if not enabled or not M.hasUrl() or type(e) ~= "table" then
			return
		end
		local now = os.clock()
		if now - lastSend < K.MIN_GAP then
			stats.dropped = stats.dropped + 1
			return
		end
		lastSend = now
		task.spawn(function()
			BX.try("webhook.delivered", function()
				post(embedFor(e), "delivery")
			end)
		end)
	end
	function M.test()
		if not M.hasUrl() then
			return false, "Set a webhook URL first"
		end
		task.spawn(function()
			BX.try("webhook.test", function()
				post({
					username = "DHZ HUB",
					embeds = {
						{
							title = "Test",
							description = "Webhook is working.",
							color = 5814783,
							footer = {
								text = "DhzHub " .. tostring(BX.version)
							},
							timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
						}
					},
				}, "test")
			end)
		end)
		return true, "Test sent"
	end
	return M
end)
BX.module("features.misc.appearance", function(BX)
	local svc = BX.require("core.services")
	local win = BX.require("ui.window")
	local log = BX.require("boot.log").for_module("appearance")
	local M = {}
	local K = {
		FADE = 0.35,
		CORNER = 12
	}
	M.K = K
	local sc = nil
	local current = {
		theme = nil,
		background = nil
	}
	local function themeApi()
		local lib = win.lib
		if type(lib) == "table" then
			for _, name in ipairs({
				"SetTheme",
				"ChangeTheme",
				"ApplyTheme"
			}) do
				if type(lib[name]) == "function" then
					return function(v)
						lib[name](lib, v)
					end, name
				end
			end
		end
		local w = win.window
		if type(w) == "table" then
			for _, name in ipairs({
				"SetTheme",
				"ChangeTheme"
			}) do
				if type(w[name]) == "function" then
					return function(v)
						w[name](w, v)
					end, name
				end
			end
		end
		return nil
	end
	function M.themeSupported()
		return (themeApi()) ~= nil
	end
	function M.themes()
		local lib = win.lib
		local names = {}
		if type(lib) == "table" and type(lib.Theme) == "table" then
			for k in pairs(lib.Theme) do
				names[# names + 1] = tostring(k)
			end
		end
		if # names == 0 then
			names = {
				"Default",
				"Amethyst",
				"Green",
				"Bloom",
				"DarkBlue",
				"Light",
				"Serenity"
			}
		end
		table.sort(names)
		return names
	end
	function M.setTheme(name)
		name = tostring(name or "")
		if name == "" then
			return false, "Pick a theme"
		end
		local apply, via = themeApi()
		if not apply then
			log.warn("direct UI has no external theme API")
			return false, "This menu build has no theme support"
		end
		if not BX.try("appearance.setTheme", function()
			apply(name)
		end) then
			return false, "That theme was refused"
		end
		current.theme = name
		log.info("theme set to %s (via %s)", name, tostring(via))
		return true, "Theme: " .. name
	end
	local bgLabel, savedFill, guardConn = nil, nil, nil
	local request = 0
	local function restoreWindowFill()
		if guardConn then
			pcall(function()
				guardConn:Disconnect()
			end)
			guardConn = nil
		end
		if bgLabel and savedFill ~= nil then
			pcall(function()
				local host = bgLabel.Parent
				if host then
					host.BackgroundTransparency = savedFill
				end
			end)
		end
		savedFill = nil
	end
	local function findHost()
		local gui = win.screen
		if not gui or not gui.Parent then
			return nil
		end
		local best, bestArea
		for _, f in ipairs(gui:GetChildren()) do
			if f:IsA("Frame") and f.Visible then
				local a = f.AbsoluteSize.X * f.AbsoluteSize.Y
				if not bestArea or a > bestArea then
					best, bestArea = f, a
				end
			end
		end
		return best
	end
	local function applyBackground(id)
		restoreWindowFill()
		if bgLabel then
			pcall(function()
				bgLabel:Destroy()
			end)
		end
		bgLabel = nil
		id = tostring(id or ""):gsub("%s", "")
		if id == "" then
			current.background = nil
			local bgSc = BX._scopes["features.misc.appearance.background"]
			if bgSc and not bgSc.dead then
				bgSc:destroy()
			end
			return true, "cleared"
		end
		if not id:match("^%d+$") then
			id = id:match("(%d+)") or ""
			if id == "" then
				return false, "that is not an image id"
			end
		end
		local host = findHost()
		if not host then
			return false, "could not find the hub window"
		end
		local bgSc = BX.scope("features.misc.appearance.background")
		local img = Instance.new("ImageLabel")
		img.Name = "DhzBackground"
		img.Size = UDim2.fromScale(1, 1)
		img.Image = "rbxassetid://" .. id
		img.ScaleType = Enum.ScaleType.Crop
		img.ImageTransparency = K.FADE
		img.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
		img.BackgroundTransparency = 0
		img.BorderSizePixel = 0
		img.ZIndex = 0
		Instance.new("UICorner", img).CornerRadius = UDim.new(0, 0)
		bgSc:own(img)
		img.Parent = host
		savedFill = host.BackgroundTransparency
		host.BackgroundTransparency = 1
		bgLabel = img
		current.background = id
		guardConn = bgSc:connect(host:GetPropertyChangedSignal("BackgroundTransparency"), function()
			if bgLabel == img and img.Parent == host and host.BackgroundTransparency ~= 1 then
				savedFill = host.BackgroundTransparency
				host.BackgroundTransparency = 1
			end
		end)
		local mine = request
		bgSc:spawn("bgLoad", function()
			for _ = 1, 5 do
				task.wait(0.2)
				if img.Parent == nil or request ~= mine then
					return
				end
				if img.IsLoaded then
					log.info("background loaded directly")
					return
				end
			end
			if img.Parent == nil or request ~= mine then
				return
			end
			img.Image = ("rbxthumb://type=Asset&id=%s&w=420&h=420"):format(id)
			for _ = 1, 25 do
				task.wait(0.2)
				if img.Parent == nil or request ~= mine then
					return
				end
				if img.IsLoaded then
					log.info("background loaded through the thumbnail endpoint")
					return
				end
			end
			if img.Parent then
				log.warn("id %s would not load either way", id)
				BX.try("appearance.bgNotify", function()
					win.notify("Appearance", "Roblox will not serve that id as an image", 4)
				end)
			end
		end)
		return true, "applied"
	end
	function M.setBackground(id)
		request = request + 1
		local mine = request
		local ok, why = applyBackground(id)
		if not ok and tostring(why):find("could not find the hub window") then
			sc = sc or BX.scope("features.misc.appearance")
			sc:spawn("bgWait", function()
				for _ = 1, 60 do
					task.wait(0.5)
					if request ~= mine then
						return
					end
					local ok2, why2 = applyBackground(id)
					if ok2 or not tostring(why2):find("could not find the hub window") then
						log.info("background: %s (once the window was up)", tostring(why2))
						return
					end
				end
				log.warn("gave up - the hub window never appeared")
			end)
			return true, "Waiting for the window"
		end
		if ok then
			log.info("background %s (id %s)", why, tostring(id))
		end
		return ok, ok and ("Background " .. why) or ("Background failed - " .. why)
	end
	function M.clearBackground()
		request = request + 1
		applyBackground("")
		return true, "Background cleared"
	end
	function M.currentBackground()
		return current.background
	end
	function M.read()
		return {
			theme = current.theme,
			background = current.background
		}
	end
	function M.apply(t)
		if type(t) ~= "table" then
			return
		end
		if t.theme then
			M.setTheme(t.theme)
		end
		if t.background and tostring(t.background) ~= "" then
			M.setBackground(t.background)
		end
	end
	function M.reset()
		restoreWindowFill()
		if sc then
			sc:destroy()
			sc = nil
		end
		bgLabel, guardConn = nil, nil
		current = {
			theme = nil,
			background = nil
		}
	end
	return M
end)
BX.module("features.gamethrottle", function(BX)
	local svc = BX.require("core.services")
	local st = BX.require("core.state")
	local exec = BX.require("core.exec")
	local log = BX.require("boot.log").for_module("gamethrottle")
	local M = {}
	local K = {
		PETS_HZ = 30,
		PROMPTS_HZ = 10,
	}
	M.K = K
	local env = (type(getgenv) == "function" and getgenv()) or _G
	local ENV_KEY = "__DHZ_THROTTLE"
	local enabled = false
	local stats = {
		pets = false,
		prompts = false,
		petSteps = 0,
		petSkips = 0,
		promptSteps = 0,
		promptSkips = 0
	}
	function M.isOn()
		return enabled
	end
	function M.stats()
		return table.clone(stats)
	end
	local function petsClass()
		local mod
		pcall(function()
			mod = svc.Players.LocalPlayer.PlayerScripts.Game.Plots .ActiveAssetsController.AssetMovementBatch
		end)
		if not (mod and mod:IsA("ModuleScript")) then
			return nil
		end
		local ok, cls = pcall(require, mod)
		if ok and type(cls) == "table" and type(rawget(cls, "_step")) == "function" then
			return cls
		end
		return nil
	end
	local function followerAdvance()
		local getups = (debug and debug.getupvalues) or rawget(env, "getupvalues")
		if type(getups) ~= "function" then
			return nil
		end
		local mod = svc.ReplicatedStorage:FindFirstChild("Client")
		mod = mod and mod:FindFirstChild("SmartProximityPrompt")
		mod = mod and mod:FindFirstChild("FollowerLoop")
		if not (mod and mod:IsA("ModuleScript")) then
			return nil
		end
		local ok, lib = pcall(require, mod)
		if not ok or type(lib) ~= "table" or type(lib.Add) ~= "function" then
			return nil
		end
		local okU, ups = pcall(getups, lib.Add)
		if not okU or type(ups) ~= "table" then
			return nil
		end
		for _, u in pairs(ups) do
			if type(u) == "function" then
				local okN, name = pcall(debug.info, u, "n")
				if okN and name == "advance" then
					return u
				end
			end
		end
		return nil
	end
	local function restore(rec, why)
		if type(rec) ~= "table" then
			return
		end
		if rec.cls and rec.step then
			pcall(rawset, rec.cls, "_step", rec.step)
		end
		if rec.advance and rec.advanceOrig and type(hookfunction) == "function" then
			pcall(hookfunction, rec.advance, rec.advanceOrig)
		end
		log.info("restored game loops (%s)", tostring(why))
	end
	if type(env[ENV_KEY]) == "table" then
		local stale = env[ENV_KEY]
		env[ENV_KEY] = nil
		BX.try("throttle.restoreStale", restore, stale, "previous copy")
	end
	function M.setEnabled(on)
		on = on and true or false
		if on == enabled then
			return true
		end
		if not on then
			enabled = false
			restore(env[ENV_KEY], "toggled off")
			env[ENV_KEY] = nil
			stats.pets, stats.prompts = false, false
			return true
		end
		enabled = true
		local rec = {}
		env[ENV_KEY] = rec
		BX.try("throttle.pets", function()
			local cls = petsClass()
			if not cls then
				log.info("pet movement batch not found - left alone")
				return
			end
			local orig = rawget(cls, "_step")
			local period = 1 / K.PETS_HZ
			local acc = setmetatable({}, {
				__mode = "k"
			})
			rec.cls, rec.step = cls, orig
			rawset(cls, "_step", function(self, dt)
				local a = (acc[self] or 0) + (tonumber(dt) or 0)
				if a < period then
					acc[self] = a
					stats.petSkips = stats.petSkips + 1
					return
				end
				acc[self] = 0
				stats.petSteps = stats.petSteps + 1
				return orig(self, a)
			end)
			stats.pets = true
		end)
		BX.try("throttle.prompts", function()
			if not exec.can.hooking or type(hookfunction) ~= "function" then
				log.info("no hookfunction - prompt follower left alone")
				return
			end
			local advance = followerAdvance()
			if not advance then
				log.info("prompt follower not found - left alone")
				return
			end
			local period = 1 / K.PROMPTS_HZ
			local acc = 0
			local orig
			local function throttled(dt)
				dt = tonumber(dt) or 0
				if st.autoStealOn then
					acc = 0
					return orig(dt)
				end
				acc = acc + dt
				if acc < period then
					stats.promptSkips = stats.promptSkips + 1
					return
				end
				local d = acc
				acc = 0
				stats.promptSteps = stats.promptSteps + 1
				return orig(d)
			end
			orig = hookfunction(advance, throttled)
			rec.advance, rec.advanceOrig = advance, orig
			stats.prompts = true
		end)
		log.info("on (pets %s @%dHz, prompts %s @%dHz)", tostring(stats.pets), K.PETS_HZ, tostring(stats.prompts), K.PROMPTS_HZ)
		return true
	end
	return M
end)
BX.module("features.fps", function(BX)
	local svc = BX.require("core.services")
	local log = BX.require("boot.log").for_module("fps")
	local M = {}
	local K = {
		MAX_TRACKED = 4000,
		CHUNK = 1200,
		PRUNE_EVERY = 30,
		DEFER = 2.0,
	}
	M.K = K
	local EFFECTS = {
		ParticleEmitter = true,
		Trail = true,
		Beam = true,
		Smoke = true,
		Fire = true,
		Sparkles = true,
	}
	local POST = {
		BloomEffect = true,
		BlurEffect = true,
		ColorCorrectionEffect = true,
		SunRaysEffect = true,
		DepthOfFieldEffect = true,
	}
	local env = (type(getgenv) == "function" and getgenv()) or _G
	local ENV_KEY = "__DHZ_FPS"
	local function newRecord()
		return {
			props = {},
			n = 0
		}
	end
	local function restoreRecord(rec, why)
		if type(rec) ~= "table" or type(rec.props) ~= "table" then
			return 0
		end
		local put = 0
		for i = # rec.props, 1, - 1 do
			local e = rec.props[i]
			if e and e.obj then
				local ok = pcall(function()
					e.obj[e.key] = e.was
				end)
				if ok then
					put = put + 1
				end
			end
			rec.props[i] = nil
		end
		rec.n = 0
		log.info("restored %d properties (%s)", put, tostring(why))
		return put
	end
	if type(env[ENV_KEY]) == "table" then
		local stale = env[ENV_KEY]
		env[ENV_KEY] = nil
		BX.try("fps.restoreStale", function()
			restoreRecord(stale, "previous copy, before re-applying")
		end)
	end
	BX.try("fps.throttleStale", function()
		BX.require("features.gamethrottle")
	end)
	local sc, rec, enabled, sweeping = nil, nil, false, false
	local stats = {
		effects = 0,
		props = 0,
		added = 0,
		pruned = 0,
		refused = 0,
		sweepMs = 0
	}
	function M.isOn()
		return enabled
	end
	function M.stats()
		local s = table.clone(stats)
		s.tracked = rec and rec.n or 0
		return s
	end
	BX.profile.watch("fps.tracked", function()
		return rec and rec.n or 0
	end)
	local function remember(obj, key, value)
		if not rec then
			return false
		end
		if rec.n >= K.MAX_TRACKED then
			stats.refused = stats.refused + 1
			if stats.refused == 1 then
				log.warn("tracking ceiling of %d reached - further effects left as they are", K.MAX_TRACKED)
			end
			return false
		end
		local was
		if not pcall(function()
			was = obj[key]
		end) then
			return false
		end
		if was == value then
			return false
		end
		if not pcall(function()
			obj[key] = value
		end) then
			return false
		end
		rec.n = rec.n + 1
		rec.props[rec.n] = {
			obj = obj,
			key = key,
			was = was
		}
		return true
	end
	local function offLimits(d)
		local espRoot = workspace:FindFirstChild("DhzESP")
		if espRoot and d:IsDescendantOf(espRoot) then
			return true
		end
		local char = svc.Players.LocalPlayer and svc.Players.LocalPlayer.Character
		if char and d:IsDescendantOf(char) then
			return true
		end
		return false
	end
	local function handle(d)
		local cls = d.ClassName
		if not (EFFECTS[cls] or POST[cls]) then
			return false
		end
		if EFFECTS[cls] and offLimits(d) then
			return false
		end
		if remember(d, "Enabled", false) then
			stats.effects = stats.effects + 1
			return true
		end
		return false
	end
	local function sweep()
		if sweeping then
			return
		end
		sweeping = true
		local t0 = os.clock()
		for _, d in ipairs(svc.Lighting:GetDescendants()) do
			BX.try("fps.sweepPost", handle, d)
		end
		local desc = workspace:GetDescendants()
		local total = # desc
		local i = 1
		while i <= total do
			local stop = math.min(i + K.CHUNK - 1, total)
			for j = i, stop do
				local d = desc[j]
				if d then
					BX.try("fps.sweepOne", handle, d)
				end
			end
			i = stop + 1
			svc.RunService.Heartbeat:Wait()
			if not enabled or not (sc and sc:alive()) then
				break
			end
		end
		stats.sweepMs = (os.clock() - t0) * 1000
		sweeping = false
		log.info("sweep: %d descendants, %d effects off, %.1fms", total, stats.effects, stats.sweepMs)
	end
	local function applyGlobals()
		remember(svc.Lighting, "GlobalShadows", false)
		local ter = workspace:FindFirstChildOfClass("Terrain")
		if ter then
			remember(ter, "Decoration", false)
			remember(ter, "WaterWaveSize", 0)
			remember(ter, "WaterWaveSpeed", 0)
			remember(ter, "WaterReflectance", 0)
		end
		BX.try("fps.quality", function()
			local r = settings().Rendering
			remember(r, "QualityLevel", Enum.QualityLevel.Level01)
		end)
		stats.props = rec and rec.n or 0
	end
	function M.setEnabled(on)
		on = on and true or false
		if on == enabled then
			return true
		end
		enabled = on
		if not on then
			if sc then
				sc:destroy()
				sc = nil
			end
			BX.try("fps.throttleOff", function()
				BX.require("features.gamethrottle").setEnabled(false)
			end)
			local put = restoreRecord(rec, "toggled off")
			rec = nil
			env[ENV_KEY] = nil
			stats.effects, stats.props = 0, 0
			log.info("off (%d properties restored)", put)
			return true
		end
		rec = newRecord()
		env[ENV_KEY] = rec
		sc = BX.scope("features.fps")
		applyGlobals()
		BX.try("fps.throttleOn", function()
			BX.require("features.gamethrottle").setEnabled(true)
		end)
		sc:spawn("sweep", sweep)
		sc:connect(workspace.DescendantAdded, BX.guard("fps.added", function(d)
			if not enabled then
				return
			end
			if handle(d) then
				stats.added = stats.added + 1
			end
		end))
		sc:connect(svc.Lighting.DescendantAdded, BX.guard("fps.addedPost", function(d)
			if not enabled then
				return
			end
			if handle(d) then
				stats.added = stats.added + 1
			end
		end))
		sc:loop("prune", K.PRUNE_EVERY, function()
			if not rec then
				return
			end
			local props, keep = rec.props, 0
			local dropped = 0
			for i = 1, rec.n do
				local e = props[i]
				local gone = false
				if e and e.obj then
					if typeof(e.obj) == "Instance" and e.obj.Parent == nil then
						gone = true
					end
				else
					gone = true
				end
				if gone then
					dropped = dropped + 1
				else
					keep = keep + 1
					props[keep] = e
				end
			end
			for i = keep + 1, rec.n do
				props[i] = nil
			end
			rec.n = keep
			if dropped > 0 then
				stats.pruned = stats.pruned + dropped
				log.trace("pruned %d destroyed effects (%d tracked)", dropped, keep)
			end
		end)
		log.info("on")
		return true
	end
	BX.onTeardown("fps", function()
		M.setEnabled(false)
	end)
	local armed = false
	function M.arm()
		if armed then
			return false
		end
		armed = true
		task.delay(K.DEFER, function()
			if not BX.alive() then
				return
			end
			if enabled then
				return
			end
			if M.userTurnedOff then
				return
			end
			BX.try("fps.armApply", function()
				M.setEnabled(true)
			end)
		end)
		return true
	end
	return M
end)
BX.module("features.boss", function(BX)
	local svc = BX.require("core.services")
	local dev = BX.require("core.device")
	local net = BX.require("core.net")
	local log = BX.require("boot.log").for_module("boss")
	local M = {}
	local K = {
		SNAP_TTL = 5,
		BACKSTOP = 30,
		ENTER_GAP = 1.0,
		RETRY = {
			5,
			10,
			20
		},
	}
	M.K = K
	local sc, enabled = nil, false
	local snap, snapAt = nil, 0
	local retryN, retryArmed = 0, false
	local autoEnter = false
	local stats = {
		asks = 0,
		enters = 0,
		entersRefused = 0,
		claims = 0,
		stateEvents = 0,
		autoEntered = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isOn()
		return enabled
	end
	function M.autoEnterOn()
		return autoEnter
	end
	local listeners = {}
	function M.onChange(fn)
		listeners[# listeners + 1] = fn
	end
	local function fireChange()
		for _, fn in ipairs(listeners) do
			task.spawn(function()
				BX.try("boss.onChange", fn)
			end)
		end
	end
	function M.snapshot(force)
		if not enabled then
			return nil
		end
		local now = os.clock()
		if not force and snap and (now - snapAt) < K.SNAP_TTL then
			return snap
		end
		stats.asks = stats.asks + 1
		local st = net.call("RF/BossEvent/AskSnapshot")
		snapAt = now
		if type(st) == "table" then
			snap = st
		end
		return snap
	end
	function M.isOpen()
		local s = M.snapshot()
		return (s and s.Open == true) or false
	end
	function M.held()
		return snap
	end
	local function clock(seconds)
		seconds = math.max(0, math.floor(seconds or 0))
		local h = math.floor(seconds / 3600)
		local m = math.floor(seconds / 60) % 60
		if h > 0 then
			return ("%dh %02dm"):format(h, m)
		end
		if m > 0 then
			return ("%dm %02ds"):format(m, seconds % 60)
		end
		return ("%ds"):format(seconds)
	end
	function M.status()
		if not enabled then
			return {
				title = "Abyss Overlord",
				body = "off"
			}
		end
		local s = snap
		if not s then
			return {
				title = "Abyss Overlord",
				body = (stats.asks > 0) and "Unavailable  \u{B7}  retrying" or "Reading..."
			}
		end
		local nowSrv = workspace:GetServerTimeNow()
		if s.Open == true then
			local left = (tonumber(s.ClosesAt) or 0) - nowSrv
			return {
				title = "Abyss Overlord",
				body = ("OPEN  \u{B7}  closes in %s"):format(clock(left))
			}
		end
		local until_ = (tonumber(s.OpensAt) or 0) - nowSrv
		if until_ > 0 then
			return {
				title = "Abyss Overlord",
				body = ("Closed  \u{B7}  opens in %s"):format(clock(until_))
			}
		end
		return {
			title = "Abyss Overlord",
			body = "Closed"
		}
	end
	function M.refresh()
		if not enabled then
			return false
		end
		task.spawn(function()
			BX.try("boss.refresh", function()
				M.snapshot(true)
				fireChange()
			end)
		end)
		return true
	end
	local function readOrRetry()
		local st = M.snapshot(true)
		if st then
			retryN = 0
			return st
		end
		if retryArmed or not sc then
			return nil
		end
		local wait = K.RETRY[retryN + 1]
		if not wait then
			return nil
		end
		retryArmed = true
		log.warn("boss read failed - retrying in %ds", wait)
		sc:delay("retry", dev.scale(wait), function()
			retryArmed = false
			retryN = retryN + 1
			if readOrRetry() then
				fireChange()
			end
		end)
		return nil
	end
	function M.enter()
		stats.enters = stats.enters + 1
		local accepted, msg = net.call("RF/BossEvent/AskEnter")
		log.info("AskEnter -> accepted=%s msg=%s", tostring(accepted), tostring(msg))
		if accepted == true then
			return true, "Entering the boss world"
		end
		stats.entersRefused = stats.entersRefused + 1
		if msg and tostring(msg):find("defeated") then
			return false, "Boss already defeated - waiting for the next one"
		end
		return false, tostring(msg or "Refused")
	end
	function M.setAutoEnter(on)
		autoEnter = on and true or false
		log.info("auto enter %s", autoEnter and "ON" or "OFF")
		if autoEnter and enabled and M.isOpen() then
			task.spawn(function()
				BX.try("boss.autoEnterNow", function()
					local ok, why = M.enter()
					if ok then
						stats.autoEntered = stats.autoEntered + 1
					end
					log.info("auto enter (already open) -> %s %s", tostring(ok), tostring(why))
				end)
			end)
		end
		return true
	end
	function M.claimMilestones()
		local BM
		local okReq = BX.try("boss.requireMastery", function()
			local mod = svc.ReplicatedStorage:FindFirstChild("Data")
			mod = mod and mod:FindFirstChild("BossMastery")
			if mod and mod:IsA("ModuleScript") then
				BM = require(mod)
			end
		end)
		if not okReq or type(BM) ~= "table" then
			log.warn("Data.BossMastery unavailable - cannot claim")
			return 0, "Could not read the mastery list"
		end
		local ids = {}
		for _, m in pairs(BM.Milestones or {}) do
			if type(m) == "table" and m.Id then
				ids[# ids + 1] = tostring(m.Id)
			end
		end
		if BM.InfiniteMilestoneId then
			ids[# ids + 1] = tostring(BM.InfiniteMilestoneId)
		end
		local claimed = 0
		for _, id in ipairs(ids) do
			local got, msg = net.call("RF/BossMastery/AskClaimMilestone", id)
			if got == true then
				claimed = claimed + 1
				log.info("claimed milestone %s", id)
			elseif msg and not tostring(msg):find("Not enough") then
				log.trace("milestone %s -> %s", id, tostring(msg))
			end
			task.wait(0.15)
		end
		stats.claims = stats.claims + claimed
		return claimed, claimed > 0 and ("Claimed " .. claimed) or "Nothing to claim yet"
	end
	function M.setEnabled(on)
		on = on and true or false
		if on == enabled then
			return true
		end
		if not on then
			enabled = false
			autoEnter = false
			if sc then
				sc:destroy()
				sc = nil
			end
			snap, snapAt = nil, 0
			retryN, retryArmed = 0, false
			log.info("off (%d snapshot reads this session)", stats.asks)
			fireChange()
			return true
		end
		sc = BX.scope("features.boss")
		enabled = true
		BX.try("boss.watchState", function()
			local re = net.find("RE/BossEvent/StateShifted")
			if not re then
				log.warn("RE/BossEvent/StateShifted not found - running on the backstop")
				return
			end
			sc:connect(re.OnClientEvent, function()
				stats.stateEvents = stats.stateEvents + 1
				task.spawn(function()
					BX.try("boss.stateShifted", function()
						local was = snap and snap.Open
						M.snapshot(true)
						local isOpen = snap and snap.Open
						log.info("state shifted: open %s -> %s", tostring(was), tostring(isOpen))
						fireChange()
						if autoEnter and isOpen == true and was ~= true then
							task.wait(K.ENTER_GAP)
							local ok, why = M.enter()
							if ok then
								stats.autoEntered = stats.autoEntered + 1
							end
							log.info("auto enter on open -> %s %s", tostring(ok), tostring(why))
						end
					end)
				end)
			end)
		end)
		sc:loop("backstop", dev.scale(K.BACKSTOP), function()
			local had, was = snap ~= nil, snap and snap.Open
			readOrRetry()
			if not had or (snap and snap.Open) ~= was then
				fireChange()
			end
		end)
		log.info("on (StateShifted event + %.0fs backstop)", dev.scale(K.BACKSTOP))
		return true
	end
	return M
end)
BX.module("features.rift", function(BX)
	local svc = BX.require("core.services")
	local dev = BX.require("core.device")
	local data = BX.require("core.data")
	local net = BX.require("core.net")
	local eggs = BX.require("features.eggs")
	local log = BX.require("boot.log").for_module("rift")
	local M = {}
	local K = {
		BACKSTOP = 30,
		SNAP_TTL = 5,
		STALE_MAX = 8,
		DEBOUNCE = 0.35,
		RETRY = {
			5,
			10,
			20
		},
		NONE_LABEL = "No pets spawned",
	}
	M.K = K
	local sc = nil
	local enabled = false
	local snap, snapAt, snapOkAt = nil, 0, 0
	local retryN, retryArmed = 0, false
	local fieldIds = nil
	local ownedHave, ownedMiss = nil, nil
	local pick = nil
	local labelToId = {}
	local dirty = false
	local stats = {
		askState = 0,
		askFailed = 0,
		repaints = 0,
		coalesced = 0,
		rotations = 0,
		pickCleared = 0,
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isOn()
		return enabled
	end
	local listeners = {}
	function M.onChange(fn)
		listeners[# listeners + 1] = fn
	end
	local function fireChange()
		stats.repaints = stats.repaints + 1
		for _, fn in ipairs(listeners) do
			task.spawn(function()
				BX.try("rift.onChange", fn)
			end)
		end
	end
	function M.petName(id)
		local dir = data.assetsDir()
		local cfg = dir and dir[id]
		return (cfg and cfg.DisplayName and tostring(cfg.DisplayName)) or tostring(id)
	end
	local function petNames(ids)
		local out = {}
		for _, id in ipairs(ids or {}) do
			out[# out + 1] = M.petName(id)
		end
		return out
	end
	function M.state(force)
		if not enabled then
			return nil
		end
		local now = os.clock()
		if not force and snap and (now - snapAt) < K.SNAP_TTL then
			return snap
		end
		stats.askState = stats.askState + 1
		local st = net.call("RF/Rift/AskState")
		snapAt = now
		if type(st) == "table" then
			snap, snapOkAt = st, now
			return snap
		end
		stats.askFailed = stats.askFailed + 1
		if (now - snapOkAt) > K.STALE_MAX then
			snap = nil
		end
		return snap
	end
	function M.requirements()
		local st = M.state()
		local reqs = st and st.Requirements
		if type(reqs) ~= "table" then
			return {}
		end
		return reqs
	end
	local function computeOwned()
		local reqs = M.requirements()
		if # reqs == 0 then
			ownedHave, ownedMiss = nil, nil
			return
		end
		local counts = nil
		BX.try("rift.readInventory", function()
			local mod = data.save()
			if type(mod) ~= "table" or type(mod.Get) ~= "function" then
				return
			end
			local profile = mod.Get(svc.LocalPlayer)
			local inv = profile and profile.Inventory
			if type(inv) ~= "table" then
				return
			end
			counts = {}
			for _, row in pairs(inv) do
				local cat = type(row) == "table" and row.Category or nil
				if cat then
					counts[cat] = (counts[cat] or 0) + 1
				end
			end
		end)
		if not counts then
			ownedHave, ownedMiss = nil, nil
			return
		end
		local have, missing = 0, {}
		for _, id in ipairs(reqs) do
			if (counts[id] or 0) > 0 then
				have = have + 1
			else
				missing[# missing + 1] = id
			end
		end
		ownedHave, ownedMiss = have, missing
	end
	function M.owned()
		if ownedHave == nil and ownedMiss == nil then
			computeOwned()
		end
		return ownedHave, ownedMiss
	end
	local function computeField()
		local reqs = M.requirements()
		if # reqs == 0 then
			fieldIds = nil
			return
		end
		local want = {}
		for _, id in ipairs(reqs) do
			want[id] = true
		end
		local list = eggs.list()
		if not list then
			fieldIds = nil
			return
		end
		local seen, out = {}, {}
		for _, e in ipairs(list) do
			local cat = e.assetCategory
			if cat and want[cat] and not seen[cat] then
				seen[cat] = true
				out[# out + 1] = cat
			end
		end
		fieldIds = out
	end
	function M.onField()
		if not enabled then
			return {}
		end
		if not fieldIds then
			computeField()
		end
		return fieldIds or {}
	end
	function M.petIsOut(id)
		if not id then
			return false
		end
		for _, out in ipairs(M.onField()) do
			if out == id then
				return true
			end
		end
		return false
	end
	function M.options()
		local out = {}
		labelToId = {}
		for _, id in ipairs(fieldIds or {}) do
			local label = M.petName(id)
			labelToId[label] = id
			out[# out + 1] = label
		end
		if # out == 0 then
			out[1] = K.NONE_LABEL
		end
		return out
	end
	function M.idForLabel(label)
		if type(label) ~= "string" or label == K.NONE_LABEL then
			return nil
		end
		return labelToId[label] or label
	end
	function M.pick()
		return pick
	end
	function M.setPick(id)
		pick = id
		if id then
			log.info("targeting %s", M.petName(id))
		else
			log.info("targeting any required rift pet")
		end
	end
	local function prunePick()
		if not pick then
			return false
		end
		if M.petIsOut(pick) then
			return false
		end
		stats.pickCleared = stats.pickCleared + 1
		log.info("%s is no longer out - clearing the pick", M.petName(pick))
		pick = nil
		return true
	end
	function M.status()
		if not enabled then
			return {
				title = "Rift",
				body = "off"
			}
		end
		local st = snap
		if not st then
			return {
				title = "Rift",
				body = (stats.askState > 0) and "Unavailable  \u{B7}  retrying" or "Reading..."
			}
		end
		if st.Unlocked == false then
			local need = tonumber(st.UnlockSpeedPower)
			return {
				title = "Rift",
				body = need and ("Unlocks at " .. eggs.formatRate(need) .. " speed") or "Locked",
			}
		end
		local reqs = st.Requirements or {}
		local have, missing = ownedHave, ownedMiss
		local banner = tostring(st.BannerDisplayName or st.BannerId or "Rift")
		local secs = (tonumber(st.SecondsUntilRotation) or 0) - (os.clock() - snapOkAt)
		local mins = math.max(0, math.floor(secs / 60))
		local title = have and ("%s  %d/%d"):format(banner, have, # reqs) or banner
		local extras = {}
		local pity, pityMax = tonumber(st.PityCount), tonumber(st.PityThreshold)
		if pity and pityMax then
			extras[# extras + 1] = ("pity %d/%d"):format(pity, pityMax)
		end
		local free = tonumber(st.FreeRefreshesRemaining)
		if free then
			extras[# extras + 1] = ("%d free"):format(free)
		end
		local tail = ("%dm"):format(mins)
		if # extras > 0 then
			tail = tail .. "  \u{B7}  " .. table.concat(extras, "  \u{B7}  ")
		end
		if have and # reqs > 0 and have >= # reqs then
			return {
				title = title,
				body = ("All pets ready  \u{B7}  new rift in %s"):format(tail)
			}
		end
		local want = (missing and # missing > 0) and missing or reqs
		if # want == 0 then
			return {
				title = title,
				body = ("New rift in %s"):format(tail)
			}
		end
		local outSet = {}
		for _, id in ipairs(fieldIds or {}) do
			outSet[id] = true
		end
		local ready = {}
		for _, id in ipairs(want) do
			if outSet[id] then
				ready[# ready + 1] = M.petName(id)
			end
		end
		local body
		if # ready > 0 then
			body = ("Steal %s now"):format(table.concat(ready, ", "))
		elseif # want == 1 then
			body = ("Need %s  \u{B7}  not spawned"):format(M.petName(want[1]))
		else
			body = ("Need %d: %s  \u{B7}  none spawned") :format(# want, table.concat(petNames(want), ", "))
		end
		return {
			title = title,
			body = ("%s  \u{B7}  %s"):format(body, tail)
		}
	end
	function M.eligible()
		if not enabled then
			return false
		end
		local have, missing = M.owned()
		if have and # M.requirements() > 0 and have >= # M.requirements() then
			return false
		end
		local need = {}
		for _, id in ipairs((missing and # missing > 0) and missing or M.requirements()) do
			need[id] = true
		end
		if pick then
			return M.petIsOut(pick) and need[pick] ~= nil
		end
		for _, id in ipairs(M.onField()) do
			if need[id] then
				return true
			end
		end
		return false
	end
	function M.pickTarget()
		if not enabled then
			return nil, "rift is off"
		end
		local have, missing = M.owned()
		local reqs = M.requirements()
		if # reqs == 0 then
			return nil, "rift has no requirements"
		end
		if have and have >= # reqs then
			return nil, "all rift pets owned"
		end
		local need = {}
		for _, id in ipairs((missing and # missing > 0) and missing or reqs) do
			need[id] = true
		end
		local list = eggs.list()
		if not list then
			return nil, "no egg list"
		end
		for _, e in ipairs(list) do
			local cat = e.assetCategory
			if cat and need[cat] then
				if pick then
					if cat == pick then
						return e
					end
				else
					return e
				end
			end
		end
		return nil, pick and ("%s is not on the field"):format(M.petName(pick)) or "no required rift pet is on the field"
	end
	local tradeSc, tradeOn, trading = nil, false, false
	local mark
	function M.autoTradeOn()
		return tradeOn
	end
	local function riftHave(reqs)
		if type(reqs) ~= "table" or # reqs == 0 then
			return nil
		end
		local out, okAny = {}, false
		for _, r in ipairs(reqs) do
			out[r] = out[r] or {
				owned = 0,
				uids = {}
			}
		end
		BX.try("rift.tradeInventory", function()
			local mod = data.save()
			local prof = type(mod) == "table" and mod.Get and mod.Get(svc.LocalPlayer)
			local inv = prof and prof.Inventory
			if type(inv) ~= "table" then
				return
			end
			okAny = true
			local FuseKernel, AssetItems
			pcall(function()
				FuseKernel = require(svc.ReplicatedStorage.Shared.Util.FuseKernel)
			end)
			pcall(function()
				AssetItems = require(svc.ReplicatedStorage.Shared.Util.AssetItems)
			end)
			local equipped = {}
			for _, u in pairs(prof.EquippedAssets or {}) do
				equipped[u] = true
			end
			local weight = {}
			for uid, row in pairs(inv) do
				local cat = type(row) == "table" and (row.Category or (row.ItemData and row.ItemData.Category))
				local slot = cat and out[cat]
				if slot then
					slot.owned = slot.owned + 1
					local may = not equipped[uid]
					if may and FuseKernel and FuseKernel.MayEnterRift then
						local ok, r = pcall(FuseKernel.MayEnterRift, uid, row)
						may = ok and r == true
					end
					if may then
						local w = math.huge
						if AssetItems then
							pcall(function()
								w = AssetItems.WeightKg(AssetItems.Decode(row))
							end)
						end
						weight[uid] = w
						slot.uids[# slot.uids + 1] = uid
					end
				end
			end
			for _, slot in pairs(out) do
				table.sort(slot.uids, function(a, b)
					return (weight[a] or 0) < (weight[b] or 0)
				end)
			end
		end)
		return okAny and out or nil
	end
	local function tryTrade()
		if trading then
			return nil
		end
		trading = true
		local result = nil
		BX.try("rift.tryTrade", function()
			local st = M.state(true)
			if type(st) ~= "table" then
				return
			end
			if st.PendingReward then
				net.call("RF/Rift/AskFinishReveal")
				result = "revealed"
				return
			end
			local reqs = st.Requirements
			if type(reqs) ~= "table" or # reqs < 3 then
				return
			end
			local have = riftHave(reqs)
			if not have then
				return
			end
			local uids, used = {}, {}
			for i = 1, 3 do
				local slot = have[reqs[i]]
				for _, u in ipairs(slot and slot.uids or {}) do
					if not used[u] then
						uids[i] = u
						used[u] = true
						break
					end
				end
				if not uids[i] then
					return
				end
			end
			local res, msg = net.call("RF/Rift/AskTradeIn", uids)
			if res ~= true then
				result = "refused: " .. tostring(msg or res)
				return
			end
			task.wait(1)
			net.call("RF/Rift/AskFinishReveal")
			result = "traded"
		end)
		trading = false
		if result then
			ownedHave, ownedMiss = nil, nil
			mark("traded")
		end
		return result
	end
	local tradeListeners = {}
	function M.onTrade(fn)
		tradeListeners[# tradeListeners + 1] = fn
	end
	function M.setAutoTrade(on)
		on = on and true or false
		if on == tradeOn then
			return true
		end
		tradeOn = on
		if not on then
			if tradeSc then
				tradeSc:destroy()
				tradeSc = nil
			end
			log.info("auto trade-in OFF")
			return true
		end
		if not enabled then
			M.setEnabled(true)
		end
		tradeSc = BX.scope("features.rift.trade")
		tradeSc:loop("trade", dev.scale(5), function()
			local r = tryTrade()
			if r == "traded" then
				log.info("traded the 3 pets in - Rift Egg claimed")
			elseif r == "revealed" then
				log.info("finished a pending reveal")
			elseif r then
				log.warn("trade-in %s", tostring(r))
			end
			if r then
				for _, fn in ipairs(tradeListeners) do
					task.spawn(function()
						BX.try("rift.onTrade", fn, r)
					end)
				end
			end
		end)
		log.info("auto trade-in ON (every 5s, lightest eligible pet of each kind, never equipped)")
		return true
	end
	local scheduleRetry
	local function recompute(why, full)
		dirty = false
		if full then
			snapAt = 0
			local st = M.state(true)
			if st then
				retryN = 0
			else
				scheduleRetry()
			end
		end
		if full or (ownedHave == nil and ownedMiss == nil) then
			computeOwned()
		end
		computeField()
		prunePick()
		log.trace("recomputed (%s)", tostring(why))
		fireChange()
	end
	scheduleRetry = function()
		if retryArmed or not sc then
			return
		end
		local wait = K.RETRY[retryN + 1]
		if not wait then
			return
		end
		retryArmed = true
		log.warn("rift read failed - retrying in %ds", wait)
		sc:delay("retry", dev.scale(wait), function()
			retryArmed = false
			retryN = retryN + 1
			recompute("retry " .. retryN, true)
		end)
	end
	M.refresh = function(why)
		if not enabled then
			return false
		end
		eggs.invalidate("rift refresh")
		recompute(why or "manual refresh", true)
		return true
	end
	mark = function(why)
		if dirty then
			stats.coalesced = stats.coalesced + 1
			return
		end
		dirty = true
		if not sc then
			return
		end
		sc:delay("recompute", K.DEBOUNCE, function()
			if dirty then
				recompute(why, false)
			end
		end)
	end
	function M.setEnabled(on)
		on = on and true or false
		if on == enabled then
			return true
		end
		if not on then
			enabled = false
			if sc then
				sc:destroy()
				sc = nil
			end
			snap, snapAt, snapOkAt = nil, 0, 0
			fieldIds, ownedHave, ownedMiss = nil, nil, nil
			labelToId, dirty = {}, false
			retryN, retryArmed = 0, false
			pick = nil
			log.info("off (%d state reads, %d repaints this session)", stats.askState, stats.repaints)
			fireChange()
			return true
		end
		sc = BX.scope("features.rift")
		enabled = true
		BX.try("rift.watchRotation", function()
			local re = net.find("RE/Rift/BannerRotated")
			if not re then
				log.warn("RE/Rift/BannerRotated not found - running on the backstop")
				return
			end
			sc:connect(re.OnClientEvent, function()
				stats.rotations = stats.rotations + 1
				log.info("banner rotated - re-reading")
				task.spawn(function()
					BX.try("rift.rotated", function()
						recompute("banner rotated", true)
					end)
				end)
			end)
		end)
		BX.try("rift.watchField", function()
			local ES = data.eggState()
			if not ES then
				return
			end
			for _, name in ipairs({
				"FieldRefreshed",
				"FieldGone",
				"FieldShifted"
			}) do
				local sig = ES[name]
				if sig and type(sig) == "table" and type(sig.Connect) == "function" then
					sc:connect(sig, function()
						mark("field " .. name)
					end)
				end
			end
		end)
		BX.try("rift.watchSave", function()
			local mod = data.save()
			local sig = type(mod) == "table" and mod.FieldChanged or nil
			if sig and type(sig) == "table" and type(sig.Connect) == "function" then
				sc:connect(sig, function(field)
					if field == nil or field == "Inventory" then
						ownedHave, ownedMiss = nil, nil
						mark("inventory changed")
					end
				end)
			end
		end)
		sc:loop("backstop", dev.scale(K.BACKSTOP), function()
			recompute(snap and "backstop" or "first read", true)
		end)
		log.info("on (rotation event + field signals, backstop %.0fs)", dev.scale(K.BACKSTOP))
		return true
	end
	return M
end)
BX.module("features.eggs", function(BX)
	local svc = BX.require("core.services")
	local dev = BX.require("core.device")
	local data = BX.require("core.data")
	local log = BX.require("boot.log").for_module("eggs")
	local M = {}
	local K = {
		CACHE_TTL = 0.5,
		MIN_REBUILD = 0.1,
		RAW_TTL = 0.25,
		FALLBACK_TTL = 5.0,
		STOLEN_FOR = 120,
		UNREACHABLE_FOR = 45,
		PARTIAL_FLOOR = 8,
		FULL_FIELD_MIN = 10,
		VALUE_CACHE_MAX = 600,
	}
	M.K = K
	local EggState, AssetEarnings, AssetsDir
	BX.try("eggs.resolveModules", function()
		EggState = data.eggState()
		AssetEarnings = data.assetEarnings()
		AssetsDir = data.assetsDir()
	end)
	M.ready = (EggState ~= nil)
	if not M.ready then
		log.error("EggState not found - is this Steal An Egg?")
	end
	local rawSnap, rawSnapAt = nil, 0
	local dirty, dirtyReason = false, nil
	local list, listAt = nil, 0
	local fallbackAt = 0
	local sawFullField = false
	local saidPartial = false
	local stolen = {}
	local unreachable = {}
	local valueCache = {}
	local valueCacheN = 0
	local stats = {
		scans = 0,
		cacheHits = 0,
		partialHeld = 0,
		fallbacks = 0,
		signals = 0,
		dirtyRebuilds = 0,
		lastScanMs = 0,
		lastConsidered = 0,
		lastKept = 0,
	}
	BX.profile.watch("eggs.list", function()
		return list and # list or 0
	end)
	BX.profile.watch("eggs.values", function()
		return valueCacheN
	end)
	BX.profile.watch("eggs.unreachable", function()
		local n = 0
		for _ in pairs(unreachable) do
			n = n + 1
		end
		return n
	end)
	BX.profile.watch("eggs.stolen", function()
		local n = 0
		for _ in pairs(stolen) do
			n = n + 1
		end
		return n
	end)
	function M.invalidate(reason)
		list, listAt = nil, 0
		rawSnap, rawSnapAt = nil, 0
		dirty = false
		if reason then
			log.trace("invalidated: %s", reason)
		end
	end
	function M.markDirty(reason)
		dirty = true
		dirtyReason = reason
		stats.signals = (stats.signals or 0) + 1
	end
	function M.markStolen(uid)
		if uid then
			stolen[tostring(uid)] = os.clock()
		end
	end
	function M.markUnreachable(uid)
		if uid then
			unreachable[tostring(uid)] = os.clock()
		end
	end
	function M.clearUnreachable(uid)
		if uid then
			unreachable[tostring(uid)] = nil
		end
	end
	local function pruneStolen()
		local now = os.clock()
		for uid, at in pairs(stolen) do
			if (now - at) > K.STOLEN_FOR then
				stolen[uid] = nil
			end
		end
		for uid, at in pairs(unreachable) do
			if (now - at) > K.UNREACHABLE_FOR then
				unreachable[uid] = nil
			end
		end
	end
	local function calcValue(rec)
		local uid = rec.Uid
		local hit = valueCache[uid]
		if hit then
			return hit
		end
		local item = {
			Category = rec.AssetCategory,
			Scale = tonumber(rec.AssetScale) or 1,
			Mutations = rec.Mutations or {},
		}
		local v = 0
		if AssetEarnings then
			local ok, rate = pcall(AssetEarnings.LiveRatePerSecond, item, nil, nil, svc.LocalPlayer)
			if ok and type(rate) == "number" then
				v = rate
			else
				ok, rate = pcall(AssetEarnings.MutationOnlyRatePerSecond, item)
				if ok and type(rate) == "number" then
					v = rate
				end
			end
		end
		if valueCacheN >= K.VALUE_CACHE_MAX then
			log.warn("value cache hit %d entries - clearing", valueCacheN)
			valueCache, valueCacheN = {}, 0
		end
		valueCache[uid] = v
		valueCacheN = valueCacheN + 1
		return v
	end
	M.value = calcValue
	local function displayName(rec)
		local dir = AssetsDir and AssetsDir[rec.AssetCategory]
		return (dir and dir.DisplayName) or rec.AssetCategory or ("Egg " .. tostring(rec.Uid or "?"):sub(1, 6))
	end
	local function rarityIdOf(rec)
		local dir = AssetsDir and AssetsDir[rec.AssetCategory]
		if dir and dir.Rarity then
			return dir.Rarity._id or dir.Rarity.DisplayName or "?"
		end
		return "?"
	end
	local function rarityOf(rec)
		local dir = AssetsDir and AssetsDir[rec.AssetCategory]
		if dir and dir.Rarity then
			return dir.Rarity.DisplayName or dir.Rarity._id or "?"
		end
		return "?"
	end
	local function weightOf(rec)
		local dir = AssetsDir and AssetsDir[rec.AssetCategory]
		local base = dir and dir.Egg and tonumber(dir.Egg.WeightKg)
		if not base then
			return 0
		end
		return base * (tonumber(rec.AssetScale) or 1)
	end
	function M.formatRate(n)
		n = tonumber(n) or 0
		for _, u in ipairs({
			{
				1e12,
				"T"
			},
			{
				1e9,
				"B"
			},
			{
				1e6,
				"M"
			},
			{
				1e3,
				"K"
			}
		}) do
			if n >= u[1] then
				local v = n / u[1]
				local txt = (v < 10) and string.format("%.2f", v) or string.format("%.1f", v)
				return (txt:gsub("%.?0+$", "")) .. u[2]
			end
		end
		return tostring(math.floor(n))
	end
	local function readField()
		local records = nil
		BX.try("eggs.readField", function()
			local data = EggState and EggState.ReadFieldEggs and EggState.ReadFieldEggs()
			if type(data) == "table" and type(data.Records) == "table" then
				records = data.Records
			end
		end)
		return records
	end
	local function readFallback()
		local now = os.clock()
		if (now - fallbackAt) < K.FALLBACK_TTL then
			return nil
		end
		fallbackAt = now
		stats.fallbacks = stats.fallbacks + 1
		local records = {}
		BX.try("eggs.fallback", function()
			local slots = workspace:FindFirstChild("AreaEggSlotsClient")
			if not slots then
				return
			end
			for _, m in ipairs(slots:GetChildren()) do
				if m:IsA("Model") then
					local uid = m:GetAttribute("Uid") or m:GetAttribute("EggUid") or m.Name
					local cf
					local hit = m:FindFirstChild("Hitbox")
					if hit and hit:IsA("BasePart") then
						cf = hit.CFrame
					else
						cf = m:GetPivot()
					end
					if uid and cf then
						records[# records + 1] = {
							Uid = tostring(uid),
							BoundsCFrame = cf,
							State = "Slot",
						}
					end
				end
			end
		end)
		log.info("fallback scan: %d records from AreaEggSlotsClient (no EggState - names and values unavailable)", # records)
		return # records > 0 and records or nil
	end
	local function snapshot(force)
		local now = os.clock()
		if not force and rawSnap and (now - rawSnapAt) < dev.scale(K.RAW_TTL) then
			return rawSnap
		end
		local records = readField()
		if not records or # records == 0 then
			records = readFallback() or records
		end
		if records then
			rawSnap, rawSnapAt = records, now
		end
		return rawSnap
	end
	function M.list(opts, force)
		opts = opts or {}
		local now = os.clock()
		local fresh = (now - listAt) < dev.scale(K.CACHE_TTL)
		local mayRebuild = (now - listAt) >= K.MIN_REBUILD
		if not force and list and fresh and not (dirty and mayRebuild) then
			stats.cacheHits = stats.cacheHits + 1
			return list
		end
		if dirty and mayRebuild then
			stats.dirtyRebuilds = (stats.dirtyRebuilds or 0) + 1
			dirty = false
		end
		local t0 = os.clock()
		local records = snapshot(force)
		local n = records and # records or 0
		if n > K.FULL_FIELD_MIN then
			sawFullField = true
		end
		if sawFullField and n > 0 and n <= K.PARTIAL_FLOOR and list and # list > 0 then
			if not saidPartial then
				saidPartial = true
				stats.partialHeld = stats.partialHeld + 1
				log.info("only %d records replicated - field still loading, keeping the last %d", n, # list)
			end
			return list
		end
		saidPartial = false
		if not records then
			list = list or {}
			listAt = now
			return list
		end
		pruneStolen()
		local TAKEABLE = opts.state or {
			Slot = true,
			Dropped = true
		}
		local out, seen = {}, {}
		local considered, dupes = 0, 0
		for _, rec in ipairs(records) do
			considered = considered + 1
			local uid = rec.Uid and tostring(rec.Uid)
			if uid and not seen[uid] then
				seen[uid] = true
				if not TAKEABLE[rec.State] then
				elseif stolen[uid] then
				elseif unreachable[uid] then
				else
					local value = calcValue(rec)
					local pos = rec.BoundsCFrame and rec.BoundsCFrame.Position
					if pos and (not opts.minValue or value >= opts.minValue) and (not opts.filter or opts.filter(rec, value)) then
						out[# out + 1] = {
							uid = uid,
							state = rec.State,
							pos = pos,
							value = value,
							name = displayName(rec),
							rarity = rarityOf(rec),
							rarityId = rarityIdOf(rec),
							assetCategory = rec.AssetCategory,
							icon = (function()
								local d = AssetsDir and rec.AssetCategory and AssetsDir[rec.AssetCategory]
								local i = d and d.Icon
								if type(i) == "number" then
									return "rbxassetid://" .. tostring(i)
								end
								if type(i) == "string" and i ~= "" then
									return i:match("^%d+$") and ("rbxassetid://" .. i) or i
								end
								return nil
							end)(),
							assetScale = rec.AssetScale,
							mutations = rec.Mutations,
							kg = weightOf(rec),
							guardHeld = (rec.State == "GuardCarried"),
							dropped = (rec.State == "Dropped"),
							areaId = rec.AreaId,
							nestId = rec.NestId,
						}
					end
				end
			elseif uid then
				dupes = dupes + 1
			end
		end
		table.sort(out, function(a, b)
			return a.value > b.value
		end)
		if valueCacheN > (# out * 2 + 50) then
			local keep, kept = {}, 0
			for _, e in ipairs(out) do
				local v = valueCache[e.uid]
				if v ~= nil then
					keep[e.uid] = v
					kept = kept + 1
				end
			end
			log.trace("value cache pruned %d -> %d (field %d)", valueCacheN, kept, # out)
			valueCache, valueCacheN = keep, kept
		end
		list, listAt = out, now
		stats.scans = stats.scans + 1
		stats.lastScanMs = (os.clock() - t0) * 1000
		stats.lastConsidered = considered
		stats.lastKept = # out
		log.trace("scan: %d records -> %d takeable (%d dupes) in %.1fms, best %s %s/s", considered, # out, dupes, stats.lastScanMs, out[1] and out[1].name or "-", out[1] and string.format("%.0f", out[1].value) or "-")
		return list
	end
	function M.best(opts)
		local l = M.list(opts)
		return l and l[1] or nil
	end
	function M.get(uid)
		if not uid then
			return nil
		end
		local rec
		BX.try("eggs.get", function()
			rec = EggState and EggState.ReadFieldEgg and EggState.ReadFieldEgg(uid)
		end)
		if not rec then
			return nil
		end
		return {
			uid = tostring(uid),
			state = rec.State,
			pos = rec.BoundsCFrame and rec.BoundsCFrame.Position,
			value = calcValue(rec),
			name = displayName(rec),
			rarity = rarityOf(rec),
			rarityId = rarityIdOf(rec),
			assetCategory = rec.AssetCategory,
			assetScale = rec.AssetScale,
			mutations = rec.Mutations,
			kg = weightOf(rec),
			areaId = rec.AreaId,
			nestId = rec.NestId,
		}
	end
	function M.carryingUid()
		local found
		local me = svc.Players.LocalPlayer and svc.Players.LocalPlayer.UserId
		BX.try("eggs.carryingUid", function()
			local data = EggState and EggState.ReadFieldEggs and EggState.ReadFieldEggs()
			for _, r in pairs(data and data.Records or {}) do
				if r.State == "Carried" and (r.CarrierUserId == nil or tonumber(r.CarrierUserId) == me) then
					found = tostring(r.Uid)
					break
				end
			end
		end)
		return found
	end
	function M.stillTakeable(uid, states)
		local r = M.get(uid)
		if not r then
			return false, "gone"
		end
		local ok = (states or {
			Slot = true,
			Dropped = true
		})[r.state]
		return ok and true or false, r.state
	end
	function M.stats()
		local s = table.clone(stats)
		s.listSize = list and # list or 0
		s.valueCache = valueCacheN
		s.sawFullField = sawFullField
		return s
	end
	local WATCH = {
		"CarryChanged",
		"FieldShifted",
		"FieldRefreshed",
		"FieldGone",
		"FieldClaimed",
		"SnapshotRefreshed",
	}
	local sc = BX.scope("features.eggs")
	local watched = 0
	if EggState then
		for _, name in ipairs(WATCH) do
			BX.try("eggs.watch." .. name, function()
				local sig = EggState[name]
				if sig and type(sig) == "table" and type(sig.Connect) == "function" then
					sc:connect(sig, function()
						M.markDirty(name)
					end)
					watched = watched + 1
				end
			end)
		end
	end
	log.info("watching %d/%d EggState signals", watched, # WATCH)
	BX.require("core.character").onSpawn(sc, "eggs.respawn", function()
		M.invalidate("respawn")
	end)
	return M
end)
BX.module("features.grab", function(BX)
	local svc = BX.require("core.services")
	local data = BX.require("core.data")
	local exec = BX.require("core.exec")
	local ch = BX.require("core.character")
	local dev = BX.require("core.device")
	local eggs = BX.require("features.eggs")
	local log = BX.require("boot.log").for_module("grab")
	local RunService = svc.RunService
	local M = {}
	local K = {
		PROMPT_CACHE = 30,
		PROMPT_NEAR = 14,
		PROMPT_WAIT = 0.6,
		STEP_INSIDE = 3,
		CONFIRM_WINDOW = 1.2,
		TRIES = 3,
		RETRY_GAP = 0.15,
		TP_PROMPT_WAIT = 1.2,
	}
	M.K = K
	local EggState = data.eggState()
	local prompts, promptsAt = nil, 0
	BX.profile.watch("grab.prompts", function()
		return prompts and # prompts or 0
	end)
	local function promptList()
		local now = os.clock()
		if prompts and (now - promptsAt) < K.PROMPT_CACHE then
			return prompts
		end
		local t0 = os.clock()
		local found = {}
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("ProximityPrompt") then
				local txt = string.lower(tostring(d.ActionText) .. " " .. tostring(d.ObjectText) .. " " .. d.Name)
				if txt:find("steal") or txt:find("carry") then
					found[# found + 1] = d
				end
			end
		end
		prompts, promptsAt = found, now
		log.trace("prompt cache rebuilt: %d prompts in %.1fms", # found, (os.clock() - t0) * 1000)
		return prompts
	end
	local function promptPos(p)
		local parent = p.Parent
		if not parent then
			return nil
		end
		if parent:IsA("BasePart") then
			return parent.Position
		end
		if parent:IsA("Model") then
			return parent:GetPivot().Position
		end
		return nil
	end
	function M.waitForPrompt(targetPos, cancel, seconds)
		if typeof(targetPos) ~= "Vector3" then
			return false
		end
		local listed = promptList()
		local t0 = os.clock()
		local until_ = t0 + dev.scale(seconds or K.TP_PROMPT_WAIT)
		repeat
			if cancel and cancel() then
				return false
			end
			for _, d in ipairs(listed) do
				if d.Parent and d.Enabled then
					local pos = promptPos(d)
					if pos and (pos - targetPos).Magnitude <= K.PROMPT_NEAR then
						log.trace("prompt arrived after %.2fs", os.clock() - t0)
						return true
					end
				end
			end
			task.wait(0.05)
		until os.clock() > until_
		log.trace("prompt never showed after %.2fs", os.clock() - t0)
		return false
	end
	function M.confirm(uid, baseWalkSpeed, carrySignal)
		if carrySignal then
			return true, "CarryChanged"
		end
		local hum = ch.humanoid()
		if hum and baseWalkSpeed and hum.WalkSpeed and hum.WalkSpeed < (baseWalkSpeed - 1) then
			return true, "walkspeed drop"
		end
		local char = ch.get()
		if char then
			for _, c in ipairs(char:GetChildren()) do
				if c:IsA("Tool") and c:GetAttribute("ItemType") == "AssetEgg" and tostring(c:GetAttribute("UID")) == tostring(uid) then
					return true, "egg tool in hand"
				end
			end
		end
		local rec = eggs.get(uid)
		if rec and rec.state == "Carried" then
			return true, "ReadFieldEgg"
		end
		local any
		BX.try("grab.confirmAll", function()
			local data = EggState and EggState.ReadFieldEggs and EggState.ReadFieldEggs()
			for _, r in pairs(data and data.Records or {}) do
				if r.State == "Carried" and tostring(r.Uid) == tostring(uid) then
					any = true
					break
				end
			end
		end)
		if any then
			return true, "ReadFieldEggs"
		end
		return false, rec and rec.state or "unknown"
	end
	local function fireAt(targetPos, cancel)
		if not exec.can.prompts then
			return false, "executor has no fireproximityprompt"
		end
		local hrp = ch.root()
		if not hrp then
			return false, "no root"
		end
		local listed = promptList()
		if typeof(targetPos) == "Vector3" then
			M.waitForPrompt(targetPos, cancel, K.PROMPT_WAIT)
			if cancel and cancel() then
				return false, "cancelled"
			end
		end
		local best, bestDist = nil, math.huge
		for _, d in ipairs(listed) do
			if d.Parent and d.Enabled then
				local pos = promptPos(d)
				if pos then
					local onTarget = (typeof(targetPos) ~= "Vector3") or ((pos - targetPos).Magnitude <= K.PROMPT_NEAR)
					local dist = (hrp.Position - pos).Magnitude
					if onTarget and dist <= (d.MaxActivationDistance + 8) and dist < bestDist then
						best, bestDist = d, dist
					end
				end
			end
		end
		if not best then
			return false, "no prompt for this egg"
		end
		local pos = promptPos(best)
		local limit = (best.MaxActivationDistance or 8) - K.STEP_INSIDE
		if pos and bestDist > limit then
			local from = hrp.Position
			local step = pos - from
			local want = pos - (step.Magnitude > 0.1 and step.Unit or Vector3.new(0, 0, 1)) * math.max(limit * 0.5, 2)
			pcall(function()
				hrp.CFrame = CFrame.new(Vector3.new(want.X, from.Y, want.Z))
				hrp.AssemblyLinearVelocity = Vector3.zero
			end)
			RunService.Heartbeat:Wait()
			local h2 = ch.root()
			if h2 then
				bestDist = (h2.Position - pos).Magnitude
			end
		end
		local wasHold, wasLoS = best.HoldDuration, best.RequiresLineOfSight
		pcall(function()
			best.HoldDuration = 0
			best.RequiresLineOfSight = false
		end)
		local fired = exec.firePrompt(best, 0)
		if fired then
			exec.firePrompt(best)
		end
		pcall(function()
			best.HoldDuration = wasHold
			best.RequiresLineOfSight = wasLoS
		end)
		return fired and true or false, fired and ("fired at %.1f studs"):format(bestDist) or "fireproximityprompt failed", bestDist
	end
	local stats = {
		attempts = 0,
		taken = 0,
		failed = 0,
		cancelled = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.take(uid, opts)
		opts = opts or {}
		local cancel = opts.cancel
		local tries = opts.tries or K.TRIES
		local targetPos = opts.pos
		stats.attempts = stats.attempts + 1
		local t0 = os.clock()
		local hum0 = ch.humanoid()
		local baseWS = (hum0 and hum0.WalkSpeed and hum0.WalkSpeed > 0) and hum0.WalkSpeed or nil
		local sc = BX.scope("features.grab.attempt")
		local carrySignal = false
		if EggState and EggState.CarryChanged then
			BX.try("grab.watchCarry", function()
				sc:connect(EggState.CarryChanged, function(info)
					if type(info) ~= "table" or info.Uid == nil or tostring(info.Uid) == tostring(uid) then
						carrySignal = true
					end
				end)
			end)
		end
		local function finish(ok, reason, attempt, fireDist)
			sc:destroy()
			local ms = (os.clock() - t0) * 1000
			if ok then
				stats.taken = stats.taken + 1
				eggs.markStolen(uid)
			elseif reason == "cancelled" then
				stats.cancelled = stats.cancelled + 1
			else
				stats.failed = stats.failed + 1
			end
			local level = ok and log.info or log.warn
			level("%s uid=%s after %d/%d tries in %.0fms (witness=%s dist=%s tier=%s)", ok and "TAKEN" or ("FAILED: " .. tostring(reason)), tostring(uid), attempt or 0, tries, ms, tostring(reason), fireDist and string.format("%.1f", fireDist) or "-", dev.tier)
			return ok, {
				reason = reason,
				attempts = attempt or 0,
				ms = ms,
				distance = fireDist,
			}
		end
		local have, witness = M.confirm(uid, baseWS, carrySignal)
		if have then
			return finish(true, witness, 0)
		end
		for attempt = 1, tries do
			if cancel and cancel() then
				return finish(false, "cancelled", attempt)
			end
			if not ch.root() then
				return finish(false, "no character", attempt)
			end
			local ok, state = eggs.stillTakeable(uid)
			if not ok and not carrySignal then
				return finish(false, "egg " .. tostring(state), attempt)
			end
			local fired, why, dist = fireAt(targetPos, cancel)
			if why == "cancelled" then
				return finish(false, "cancelled", attempt)
			end
			if fired then
				local until_ = os.clock() + dev.scale(K.CONFIRM_WINDOW)
				repeat
					if cancel and cancel() then
						return finish(false, "cancelled", attempt, dist)
					end
					local got, w = M.confirm(uid, baseWS, carrySignal)
					if got then
						return finish(true, w, attempt, dist)
					end
					RunService.Heartbeat:Wait()
				until os.clock() > until_
			end
			if attempt < tries then
				task.wait(dev.scale(K.RETRY_GAP))
			end
		end
		local got, w = M.confirm(uid, baseWS, carrySignal)
		if got then
			return finish(true, w, tries)
		end
		return finish(false, "no confirmation", tries)
	end
	function M.warmPrompts()
		local t0 = os.clock()
		local n = # promptList()
		return (os.clock() - t0) * 1000, n
	end
	function M.clearCache()
		prompts, promptsAt = nil, 0
	end
	return M
end)
BX.module("features.instant", function(BX)
	local svc = BX.require("core.services")
	local data = BX.require("core.data")
	local ch = BX.require("core.character")
	local dev = BX.require("core.device")
	local eggs = BX.require("features.eggs")
	local guard = BX.require("features.guard")
	local log = BX.require("boot.log").for_module("instant")
	local RunService = svc.RunService
	local M = {}
	local K = {
		TIMEOUT = 3,
		RACE_THREADS = 3,
		RACE_STAGGER = 0.05,
		LIFT = 2,
		PULLBACK_GAP = 25,
		FREE_CALLS = 12,
		SAME_MSG_GAP = 0.12,
		SAME_MSG_STOP = 30,
	}
	M.K = K
	local EggState, SlotIdentity = data.eggState(), data.slotIdentity()
	local function ensureModules()
		if not EggState then
			EggState = data.eggState()
		end
		if not SlotIdentity then
			SlotIdentity = data.slotIdentity()
		end
		M.ready = (EggState ~= nil and type(EggState.CarryFieldEgg) == "function")
		return M.ready
	end
	ensureModules()
	if not M.ready then
		log.warn("EggState.CarryFieldEgg unavailable - instant steal disabled until it resolves")
	end
	local holdGen = 0
	local stats = {
		runs = 0,
		won = 0,
		lost = 0,
		cancelled = 0,
		calls = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	local function slotKeyFor(uid, areaId, nestId)
		local key = nil
		BX.try("instant.slotKey", function()
			if SlotIdentity and SlotIdentity.LooksLikeFirstAreaUid and SlotIdentity.LooksLikeFirstAreaUid(uid) then
				key = SlotIdentity.SlotKey(areaId, nestId)
			end
		end)
		return key
	end
	function M.take(uid, eggPos, opts)
		opts = opts or {}
		local cancel = opts.cancel or function()
			return false
		end
		if not M.ready and not ensureModules() then
			return false, {
				reason = "no CarryFieldEgg"
			}
		end
		if typeof(eggPos) ~= "Vector3" then
			return false, {
				reason = "no egg position"
			}
		end
		local char = ch.get()
		if not char then
			return false, {
				reason = "no character"
			}
		end
		stats.runs = stats.runs + 1
		local t0 = os.clock()
		local target = CFrame.new(eggPos.X, eggPos.Y + K.LIFT, eggPos.Z)
		local slotKey = slotKeyFor(uid, opts.areaId, opts.nestId)
		local deadline = os.clock() + dev.scale(opts.timeout or K.TIMEOUT)
		local sc = BX.scope("features.instant.race")
		holdGen = holdGen + 1
		local myGen = holdGen
		local won, tries, lastMsg = false, 0, nil
		local sameMsg, sameCount = nil, 0
		local bailed = false
		BX.profile.mark("target_tp")
		sc:spawn("hold", function()
			while not won and holdGen == myGen and os.clock() < deadline and sc:alive() do
				local c = ch.get()
				if c then
					pcall(function()
						c:PivotTo(target)
					end)
				end
				local h = ch.root()
				if h then
					h.AssemblyLinearVelocity = Vector3.zero
					h.AssemblyAngularVelocity = Vector3.zero
				end
				RunService.Heartbeat:Wait()
			end
		end)
		local heldFor = guard.waitForServerRelease(cancel)
		if cancel() then
			holdGen = holdGen + 1
			sc:destroy()
			stats.cancelled = stats.cancelled + 1
			return false, {
				reason = "cancelled",
				ms = (os.clock() - t0) * 1000
			}
		end
		for i = 1, K.RACE_THREADS do
			sc:spawn("invoke" .. i, function()
				task.wait((i - 1) * K.RACE_STAGGER)
				while not won and not bailed and os.clock() < deadline and sc:alive() do
					if cancel() then
						return
					end
					tries = tries + 1
					stats.calls = stats.calls + 1
					local ok, res, msg = pcall(function()
						return EggState.CarryFieldEgg(uid, slotKey)
					end)
					if msg ~= nil then
						lastMsg = tostring(msg)
					end
					if type(msg) == "string" and msg:lower():find("downed") then
						local left = guard.ragdollRemaining()
						if left > 0 then
							task.wait(math.min(left, 0.25))
						end
					end
					if not won and type(msg) == "string" then
						if msg == sameMsg then
							sameCount = sameCount + 1
						else
							sameMsg, sameCount = msg, 1
						end
						if sameCount >= K.SAME_MSG_STOP then
							bailed = true
							return
						end
						if tries > K.FREE_CALLS and sameCount > 1 then
							task.wait(K.SAME_MSG_GAP)
						end
					end
					if ok and res == true and not won then
						won = true
						return
					end
					if won then
						return
					end
					RunService.Heartbeat:Wait()
				end
			end)
		end
		local cancelled = false
		while not won and not bailed and os.clock() < deadline do
			if cancel() then
				cancelled = true
				break
			end
			RunService.Heartbeat:Wait()
		end
		holdGen = holdGen + 1
		sc:destroy()
		local ms = (os.clock() - t0) * 1000
		local gap = (function()
			local h = ch.root()
			return h and (h.Position - eggPos).Magnitude or - 1
		end)()
		if cancelled then
			stats.cancelled = stats.cancelled + 1
			log.info("cancelled after %d calls in %.0fms", tries, ms)
			return false, {
				reason = "cancelled",
				calls = tries,
				ms = ms
			}
		end
		BX.profile.mark(won and "target_landed" or "target_lost")
		if won then
			stats.won = stats.won + 1
			eggs.markStolen(uid)
			log.info("WON uid=%s after %d calls in %.0fms (%d threads, gap %.1f, tier=%s)", tostring(uid), tries, ms, K.RACE_THREADS, gap, dev.tier)
			return true, {
				reason = "instant",
				calls = tries,
				ms = ms,
				gap = gap,
				heldFor = heldFor
			}
		end
		stats.lost = stats.lost + 1
		local rec = eggs.get(uid)
		local pulledBack = gap > K.PULLBACK_GAP
		local diag = ("localGap=%.1f eggState=%s eggMoved=%s pulledBack=%s%s"):format( gap, rec and tostring(rec.state) or "gone", rec and rec.pos and tostring((rec.pos - eggPos).Magnitude > 5) or "?", tostring(pulledBack), bailed and (" bailed after %d identical refusals"):format(sameCount) or "")
		log.warn("LOST uid=%s after %d calls in %.0fms (%s, last: %s, tier=%s)", tostring(uid), tries, ms, diag, tostring(lastMsg), dev.tier)
		return false, {
			reason = lastMsg or "no accept",
			calls = tries,
			ms = ms,
			gap = gap,
			pulledBack = pulledBack,
			eggState = rec and rec.state or "gone",
			eggGone = rec == nil,
			heldFor = heldFor,
		}
	end
	return M
end)
BX.module("features.plot", function(BX)
	local svc = BX.require("core.services")
	local data = BX.require("core.data")
	local log = BX.require("boot.log").for_module("plot")
	local M = {}
	local K = {
		HOME_TTL = 30,
		ARRIVE = 18,
	}
	M.K = K
	local PlotState = data.plotState()
	local cached, cachedAt, cachedVia = nil, 0, nil
	local function resolve()
		local pos, via
		if PlotState then
			BX.try("plot.findRespawn", function()
				local cf = PlotState.FindRespawnCFrame and PlotState.FindRespawnCFrame()
				if typeof(cf) == "CFrame" then
					pos, via = cf.Position, "PlotState.FindRespawnCFrame"
				end
			end)
		end
		if not pos and PlotState then
			BX.try("plot.resolveSlot", function()
				local slot = PlotState.ResolveLocalSlot and PlotState.ResolveLocalSlot()
				local plots = slot and workspace:FindFirstChild("Plots")
				local mine = plots and plots:FindFirstChild(tostring(slot))
				if mine then
					local cf = mine:GetPivot()
					if typeof(cf) == "CFrame" then
						pos, via = cf.Position, "plot " .. tostring(slot)
					end
				end
			end)
		end
		if not pos then
			BX.try("plot.spawnLocation", function()
				local sl = workspace:FindFirstChildOfClass("SpawnLocation")
				if sl and sl:IsA("BasePart") then
					pos, via = sl.Position + Vector3.new(0, 4, 0), "SpawnLocation"
				end
			end)
		end
		if not pos then
			BX.try("plot.spawnTarget", function()
				local st = workspace:FindFirstChild("SpawnTarget", true)
				if st and st:IsA("BasePart") then
					pos, via = st.Position + Vector3.new(0, 4, 0), "SpawnTarget"
				end
			end)
		end
		return pos, via
	end
	function M.home()
		local now = os.clock()
		if cached and (now - cachedAt) < K.HOME_TTL then
			return cached, cachedVia
		end
		local pos, via = resolve()
		if not pos then
			log.error("cannot resolve this player's plot - refusing to deliver " .. "(PlotState=%s)", tostring(PlotState ~= nil))
			return nil, "no plot resolved"
		end
		if via ~= cachedVia then
			log.info("home resolved via %s at %s", via, tostring(pos))
		end
		cached, cachedAt, cachedVia = pos, now, via
		return cached, cachedVia
	end
	function M.forget()
		cached, cachedAt = nil, 0
	end
	local szCache, szAt, szVia = nil, 0, nil
	function M.safeZone()
		local now = os.clock()
		if szCache and (now - szAt) < K.HOME_TTL then
			return szCache, szVia
		end
		local pos, via
		BX.try("plot.spawnLocationZone", function()
			local sl = workspace:FindFirstChildOfClass("SpawnLocation")
			if sl and sl:IsA("BasePart") then
				pos, via = sl.Position + Vector3.new(0, 4, 0), "SpawnLocation"
			end
		end)
		if not pos then
			BX.try("plot.spawnTargetZone", function()
				local st = workspace:FindFirstChild("SpawnTarget", true)
				if st and st:IsA("BasePart") then
					pos, via = st.Position + Vector3.new(0, 4, 0), "SpawnTarget"
				end
			end)
		end
		if not pos then
			local p, pvia = M.home()
			if p then
				pos, via = p, "plot fallback (" .. tostring(pvia) .. ")"
			end
		end
		if not pos then
			log.error("cannot resolve a safe zone - refusing to deliver")
			return nil, "unresolved"
		end
		if via ~= szVia then
			log.info("safe zone resolved via %s at %s", via, tostring(pos))
		end
		szCache, szAt, szVia = pos, now, via
		return szCache, szVia
	end
	function M.forgetSafeZone()
		szCache, szAt = nil, 0
	end
	local lastClaimAt, lastClaimName = 0, nil
	local listeners = {}
	function M.claimedSince(t)
		return lastClaimAt > (t or 0), lastClaimName
	end
	function M.onClaim(sc, label, fn)
		listeners[# listeners + 1] = {
			scope = sc,
			label = label,
			fn = fn
		}
	end
	local sc = BX.scope("features.plot")
	local EggState
	BX.try("plot.resolveEggState", function()
		local found = svc.ReplicatedStorage:FindFirstChild("EggState", true)
		if found and found:IsA("ModuleScript") then
			EggState = require(found)
		end
	end)
	if EggState and EggState.FieldClaimed then
		BX.try("plot.armClaimWatch", function()
			sc:connect(EggState.FieldClaimed, function(info)
				lastClaimAt = os.clock()
				lastClaimName = (type(info) == "table" and (info.DisplayName or info.AssetCategory)) or "egg"
				log.info("CLAIM: server claimed our egg -> %s", tostring(lastClaimName))
				for i = # listeners, 1, - 1 do
					local L = listeners[i]
					if not L.scope or L.scope.dead then
						table.remove(listeners, i)
					else
						BX.try("plot/" .. L.label, L.fn, lastClaimName)
					end
				end
			end)
		end)
	else
		log.warn("EggState.FieldClaimed unavailable - deliveries cannot be confirmed")
	end
	M._listeners = function()
		return # listeners
	end
	return M
end)
BX.module("features.regrab", function(BX)
	local svc = BX.require("core.services")
	local eggs = BX.require("features.eggs")
	local instant = BX.require("features.instant")
	local guard = BX.require("features.guard")
	local ch = BX.require("core.character")
	local dev = BX.require("core.device")
	local log = BX.require("boot.log").for_module("regrab")
	local RunService = svc.RunService
	local M = {}
	local K = {
		SETTLE = 0.08,
		WAIT = 8.0,
		POLL = 0.05,
		TRIES = 4,
		MAX_PER_STEAL = 2,
	}
	M.K = K
	local stats = {
		runs = 0,
		recovered = 0,
		banked = 0,
		gone = 0,
		failed = 0,
		cancelled = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	local function settledPos(uid)
		local r = eggs.get(uid)
		if not r then
			return nil, nil
		end
		return r.pos, r.state
	end
	function M.recover(uid, opts)
		opts = opts or {}
		local cancel = opts.cancel or function()
			return false
		end
		stats.runs = stats.runs + 1
		local t0 = os.clock()
		task.wait(K.SETTLE)
		if cancel() then
			stats.cancelled = stats.cancelled + 1
			return false, {
				reason = "cancelled",
				recovery = "cancelled"
			}
		end
		local deadline = os.clock() + dev.scale(K.WAIT)
		local pos, state, said
		repeat
			if cancel() then
				stats.cancelled = stats.cancelled + 1
				return false, {
					reason = "cancelled",
					recovery = "cancelled"
				}
			end
			pos, state = settledPos(uid)
			if state == "Claimed" then
				stats.banked = stats.banked + 1
				log.info("drop_recovery=banked uid=%s (the egg was claimed)", tostring(uid))
				return false, {
					reason = "claimed",
					recovery = "banked"
				}
			end
			if state == nil then
				stats.gone = stats.gone + 1
				log.warn("drop_recovery=failed uid=%s (record gone)", tostring(uid))
				return false, {
					reason = "gone",
					recovery = "failed"
				}
			end
			if state == "Slot" or state == "Dropped" then
				break
			end
			if state ~= said then
				said = state
				log.trace("egg is %s - waiting for it to settle", tostring(state))
			end
			task.wait(K.POLL)
		until os.clock() > deadline
		if state ~= "Slot" and state ~= "Dropped" then
			stats.failed = stats.failed + 1
			log.warn("drop_recovery=failed uid=%s (still %s after %.1fs)", tostring(uid), tostring(state), os.clock() - t0)
			return false, {
				reason = "never settled (" .. tostring(state) .. ")",
				recovery = "failed"
			}
		end
		for attempt = 1, K.TRIES do
			if cancel() then
				stats.cancelled = stats.cancelled + 1
				return false, {
					reason = "cancelled",
					recovery = "cancelled"
				}
			end
			local pNow, sNow = settledPos(uid)
			if sNow == "Claimed" then
				stats.banked = stats.banked + 1
				log.info("drop_recovery=banked uid=%s (claimed on the way)", tostring(uid))
				return false, {
					reason = "claimed",
					recovery = "banked"
				}
			end
			if not pNow then
				stats.gone = stats.gone + 1
				log.warn("drop_recovery=failed uid=%s (record gone on the way)", tostring(uid))
				return false, {
					reason = "gone",
					recovery = "failed"
				}
			end
			local hrp = ch.root()
			local gapBefore = hrp and (pNow - hrp.Position).Magnitude or - 1
			local got, info = instant.take(uid, pNow, {
				cancel = cancel,
				areaId = opts.areaId,
				nestId = opts.nestId,
			})
			if got then
				stats.recovered = stats.recovered + 1
				log.info("drop_recovery=tp uid=%s attempt %d/%d in %.2fs " .. "(was %.0f studs out, %d calls)", tostring(uid), attempt, K.TRIES, os.clock() - t0, gapBefore, info and info.calls or - 1)
				return true, {
					recovery = "tp",
					attempts = attempt,
					ms = (os.clock() - t0) * 1000
				}
			end
			if info and info.pulledBack then
				log.warn("drop_recovery=tp_refused uid=%s attempt %d/%d " .. "(landed %.0f studs off, reason=%s)", tostring(uid), attempt, K.TRIES, info.gap or - 1, tostring(info.reason))
			elseif info and type(info.reason) == "string" and (info.reason:lower():find("get closer", 1, true) or info.reason:lower():find("not currently trusted", 1, true)) then
				stats.rebait = (stats.rebait or 0) + 1
				log.info("drop_recovery=rebait uid=%s (in-knockdown pickup refused: %s, %.2fs)", tostring(uid), info.reason, os.clock() - t0)
				return false, {
					reason = "knockdown window missed",
					recovery = "rebait"
				}
			else
				log.trace("attempt %d/%d: %s (egg %s, %.0f studs)", attempt, K.TRIES, tostring(info and info.reason), tostring(sNow), gapBefore)
			end
			task.wait(dev.scale(K.POLL))
		end
		stats.failed = stats.failed + 1
		log.warn("drop_recovery=failed uid=%s after %d attempts in %.2fs", tostring(uid), K.TRIES, os.clock() - t0)
		return false, {
			reason = "no regrab",
			recovery = "failed"
		}
	end
	return M
end)
BX.module("features.carry", function(BX)
	local svc = BX.require("core.services")
	local move = BX.require("features.movement")
	local plot = BX.require("features.plot")
	local eggs = BX.require("features.eggs")
	local ch = BX.require("core.character")
	local dev = BX.require("core.device")
	local log = BX.require("boot.log").for_module("carry")
	local M = {}
	local K = {
		SPEED = 500,
		ARRIVE = 5,
		CLAIM_WAIT = 6,
	}
	M.K = K
	local stats = {
		runs = 0,
		delivered = 0,
		failed = 0,
		cancelled = 0,
		lost = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	local function holding(uid)
		local r = eggs.get(uid)
		if not r then
			return false, "gone"
		end
		return r.state == "Carried", r.state
	end
	function M.home(uid, opts)
		opts = opts or {}
		local outerCancel = opts.cancel
		stats.runs = stats.runs + 1
		local t0 = os.clock()
		local stages = {}
		local function stage(name, fn)
			local s0 = os.clock()
			local ok, info = fn()
			stages[# stages + 1] = {
				name = name,
				ms = (os.clock() - s0) * 1000,
				ok = ok and true or false,
			}
			return ok, info
		end
		local function report()
			local parts = {}
			for _, s in ipairs(stages) do
				parts[# parts + 1] = ("%s=%.0fms%s"):format(s.name, s.ms, s.ok and "" or "!")
			end
			return table.concat(parts, " ")
		end
		local function fail(why)
			stats.failed = stats.failed + 1
			log.warn("FAILED %s uid=%s after %.2fs [%s] tier=%s", why, tostring(uid), os.clock() - t0, report(), dev.tier)
			return false, {
				reason = why,
				stages = stages,
				elapsed = os.clock() - t0
			}
		end
		local dest, via = plot.safeZone()
		if not dest then
			return fail("no safe zone resolved")
		end
		if not ch.root() then
			return fail("no character")
		end
		local lastCheck, lastHeld = 0, true
		local function carryCancel()
			if outerCancel and outerCancel() then
				return true
			end
			local now = os.clock()
			if (now - lastCheck) >= 0.25 then
				lastCheck = now
				lastHeld = holding(uid)
			end
			return not lastHeld
		end
		local before = ch.root().Position
		local distance = (Vector3.new(dest.X, 0, dest.Z) - Vector3.new(before.X, 0, before.Z)).Magnitude
		log.info("carrying %s to the safe zone via %s (%.0f studs, tier=%s)", tostring(uid), tostring(via), distance, dev.tier)
		local arrived, moveInfo = stage("arc", function()
			return move.travel{
				to = dest,
				speed = K.SPEED,
				arrive = K.ARRIVE,
				carrying = true,
				cancel = carryCancel,
				tag = "carry home",
			}
		end)
		local stillOurs, state = holding(uid)
		if not stillOurs then
			stats.lost = stats.lost + 1
			local gone = ch.root()
			local travelled = gone and (gone.Position - before).Magnitude or - 1
			log.warn("carry ended mid-route: egg is %s after %.0f/%.0f studs (%.2fs)", tostring(state), travelled, distance, os.clock() - t0)
			return false, {
				reason = "dropped in transit (" .. tostring(state) .. ")",
				stages = stages,
				droppedAt = travelled,
				distance = distance,
			}
		end
		if outerCancel and outerCancel() then
			stats.cancelled = stats.cancelled + 1
			return false, {
				reason = "cancelled",
				stages = stages
			}
		end
		if not arrived then
			return fail("could not reach the safe zone (" .. tostring(moveInfo and moveInfo.reason) .. ")")
		end
		stage("descend", function()
			return move.descend("deliver"), nil
		end)
		local claimFrom = os.clock()
		local claimed = stage("claim", function()
			local until_ = os.clock() + dev.scale(K.CLAIM_WAIT)
			repeat
				if outerCancel and outerCancel() then
					return false, {
						reason = "cancelled"
					}
				end
				local got = plot.claimedSince(claimFrom)
				if got then
					return true, {
						reason = "claimed"
					}
				end
				svc.RunService.Heartbeat:Wait()
			until os.clock() > until_
			return false, {
				reason = "no claim"
			}
		end)
		if not claimed then
			local have, st = holding(uid)
			return fail(have and "arrived but never claimed" or ("lost at the door (" .. tostring(st) .. ")"))
		end
		stats.delivered = stats.delivered + 1
		log.info("DELIVERED uid=%s in %.2fs via %s [%s] tier=%s", tostring(uid), os.clock() - t0, tostring(via), report(), dev.tier)
		return true, {
			reason = "delivered",
			stages = stages,
			elapsed = os.clock() - t0
		}
	end
	return M
end)
BX.module("features.bait", function(BX)
	local svc = BX.require("core.services")
	local data = BX.require("core.data")
	local move = BX.require("features.movement")
	local ch = BX.require("core.character")
	local dev = BX.require("core.device")
	local log = BX.require("boot.log").for_module("bait")
	local RunService = svc.RunService
	local M = {}
	local K = {
		AREA_WAIT = 5,
		APPROACH = 1200,
		ARRIVE = 4,
		PICKUP_WAIT = 3,
		REHOPS = 2,
		HIT_WAIT = 4.0,
		WITNESS_HOLD = 0.35,
	}
	M.K = K
	local EggState, SlotIdentity = data.eggState(), data.slotIdentity()
	local areaCached = nil
	function M.firstAreaId(waitFor)
		if areaCached then
			return areaCached
		end
		if waitFor then
			local deadline = os.clock() + waitFor
			while os.clock() < deadline do
				local there = false
				pcall(function()
					there = workspace.__OBJECTS.Areas.GuardAreas:GetChildren()[1] ~= nil
				end)
				if there then
					break
				end
				task.wait(0.2)
			end
		end
		local best, bestX
		BX.try("bait.resolveArea", function()
			for _, a in ipairs(workspace.__OBJECTS.Areas.GuardAreas:GetChildren()) do
				local b = a:FindFirstChild("Bounds")
				if b and b:IsA("BasePart") then
					local x = b.Position.X - b.Size.X * 0.5
					if not best or x < bestX then
						best, bestX = a.Name, x
					end
				end
			end
		end)
		if best then
			areaCached = best
			log.info("first area resolved: %s (leftmost at x=%.0f)", best, bestX)
		else
			log.warn("guard areas have not streamed in - no bait area")
		end
		return areaCached
	end
	local function findGuard(areaId)
		if not areaId then
			return nil
		end
		local live = workspace:FindFirstChild("_Guards")
		if live then
			for _, g in ipairs(live:GetChildren()) do
				if g.Name == areaId or g:GetAttribute("AreaId") == areaId then
					return g
				end
			end
		end
		local a
		pcall(function()
			a = workspace.__OBJECTS.Areas.GuardAreas[areaId]
		end)
		return a and a:FindFirstChild("Guard") or nil
	end
	local function guardPart(guard)
		if not guard then
			return nil
		end
		local root = guard:FindFirstChild("HumanoidRootPart") or guard:FindFirstChild("Collider") or guard:FindFirstChild("Head")
		if root and root:IsA("BasePart") then
			return root
		end
		local best
		for _, d in ipairs(guard:GetDescendants()) do
			if d:IsA("BasePart") then
				local v = d.Size.X * d.Size.Y * d.Size.Z
				if not best or v > best.v then
					best = {
						p = d,
						v = v
					}
				end
			end
		end
		return best and best.p or nil
	end
	local stats = {
		runs = 0,
		hits = 0,
		noEgg = 0,
		noPickup = 0,
		noHit = 0,
		cancelled = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.prime(opts)
		opts = opts or {}
		local cancel = opts.cancel
		stats.runs = stats.runs + 1
		local t0 = os.clock()
		local areaId = M.firstAreaId(K.AREA_WAIT)
		if not areaId then
			return false, {
				reason = "no bait area"
			}
		end
		if not EggState then
			EggState = data.eggState()
			SlotIdentity = SlotIdentity or data.slotIdentity()
		end
		if not EggState then
			stats.noEgg = stats.noEgg + 1
			return false, {
				reason = "no EggState on this executor"
			}
		end
		local rec
		BX.try("bait.findEgg", function()
			for _, r in pairs(EggState.ReadFieldEggs().Records) do
				if r.AreaId == areaId and r.State == "Slot" and r.BoundsCFrame then
					rec = r
					break
				end
			end
		end)
		if not rec then
			stats.noEgg = stats.noEgg + 1
			local states = {}
			BX.try("bait.dumpNoEgg", function()
				for _, r in pairs(EggState.ReadFieldEggs().Records) do
					if r.AreaId == areaId then
						states[# states + 1] = ("%s=%s"):format(tostring(r.NestId), tostring(r.State))
					end
				end
			end)
			table.sort(states)
			log.warn("no Slot egg in %s | area: %s | untilReset=%s", tostring(areaId), # states > 0 and table.concat(states, " ") or "(no records)", tostring(data.secondsUntilReset() and math.floor(data.secondsUntilReset())))
			return false, {
				reason = "no bait egg"
			}
		end
		local pos = rec.BoundsCFrame.Position
		local movedAt = os.clock()
		move.travel{
			to = pos,
			speed = K.APPROACH,
			arrive = K.ARRIVE,
			carrying = false,
			cancel = cancel,
			tag = "bait approach"
		}
		if cancel and cancel() then
			stats.cancelled = stats.cancelled + 1
			return false, {
				reason = "cancelled"
			}
		end
		local slotKey = nil
		BX.try("bait.slotKey", function()
			if SlotIdentity and SlotIdentity.LooksLikeFirstAreaUid and SlotIdentity.LooksLikeFirstAreaUid(rec.Uid) then
				slotKey = SlotIdentity.SlotKey(rec.AreaId, rec.NestId)
			end
		end)
		local got = false
		local deadline = os.clock() + dev.scale(K.PICKUP_WAIT)
		local rehops, tries = 0, 0
		local lastMsg = nil
		local startPos = ch.root() and ch.root().Position
		while os.clock() < deadline and not got do
			if cancel and cancel() then
				stats.cancelled = stats.cancelled + 1
				return false, {
					reason = "cancelled"
				}
			end
			local here = ch.root()
			if not here then
				return false, {
					reason = "no character"
				}
			end
			if startPos and (here.Position - pos).Magnitude > 60 and rehops < K.REHOPS then
				rehops = rehops + 1
				log.trace("server pulled us back - hopping again (%d/%d)", rehops, K.REHOPS)
				move.travel{
					to = pos,
					speed = K.APPROACH,
					arrive = K.ARRIVE,
					carrying = false,
					cancel = cancel,
					tag = "bait rehop"
				}
				deadline = os.clock() + dev.scale(K.PICKUP_WAIT)
			end
			tries = tries + 1
			local ok, res, msg = pcall(function()
				return EggState.CarryFieldEgg(rec.Uid, slotKey)
			end)
			if ok and res == true then
				got = true
				break
			end
			if not ok then
				lastMsg = "error: " .. tostring(res)
			elseif msg ~= nil then
				lastMsg = tostring(msg)
			end
			RunService.Heartbeat:Wait()
		end
		if got then
			BX.profile.mark("bait_grab")
		end
		if not got then
			stats.noPickup = stats.noPickup + 1
			local states = {}
			BX.try("bait.dumpStates", function()
				for _, r in pairs(EggState.ReadFieldEggs().Records) do
					if r.AreaId == areaId then
						states[# states + 1] = ("%s=%s"):format(tostring(r.NestId), tostring(r.State))
					end
				end
			end)
			table.sort(states)
			local here = ch.root()
			log.warn("could not pick up in %s after %d tries, %d rehops (%.2fs) - last refusal: %s | chose %s (%s) dist=%.0f | area: %s | untilReset=%s", tostring(areaId), tries, rehops, os.clock() - t0, tostring(lastMsg), tostring(rec.NestId), tostring(rec.Uid), here and (here.Position - pos).Magnitude or - 1, table.concat(states, " "), tostring(data.secondsUntilReset() and math.floor(data.secondsUntilReset())))
			return false, {
				reason = "no pickup",
				tries = tries,
				rehops = rehops,
				msg = lastMsg
			}
		end
		BX.profile.mark("guard_contact")
		local guard = findGuard(areaId)
		local gpart = guardPart(guard)
		if gpart then
			local hh = ch.root()
			local char = ch.get()
			if hh and char then
				local gy = move.groundY(gpart.Position) or hh.Position.Y
				pcall(function()
					char:PivotTo(CFrame.new(gpart.Position.X, gy, gpart.Position.Z))
				end)
			end
		else
			log.warn("no guard found in %s", tostring(areaId))
		end
		local hrp = ch.root()
		local anchorCF = hrp and hrp.CFrame
		if hrp then
			pcall(function()
				hrp.Anchored = true
			end)
		end
		local hitAt, witnessAt = nil, nil
		local dl = os.clock() + dev.scale(K.HIT_WAIT)
		while os.clock() < dl do
			if cancel and cancel() then
				break
			end
			local hh = ch.root()
			if not hh then
				break
			end
			hh.AssemblyLinearVelocity = Vector3.zero
			hh.AssemblyAngularVelocity = Vector3.zero
			if anchorCF then
				pcall(function()
					hh.CFrame = anchorCF
				end)
			end
			local witnessed = false
			local hum = ch.humanoid()
			if hum and hum:GetState() == Enum.HumanoidStateType.Physics then
				witnessed = true
			end
			if not witnessed then
				local okR, r = pcall(EggState.ReadFieldEgg, rec.Uid)
				local st = okR and type(r) == "table" and r.State or nil
				witnessed = (st == "Dropped" or st == "GuardCarried")
			end
			if witnessed and not witnessAt then
				witnessAt = os.clock()
				log.info("witness seen @%.3f (+%.3fs into the prime)", witnessAt, witnessAt - t0)
			end
			if witnessAt and (os.clock() - witnessAt) >= K.WITNESS_HOLD then
				BX.profile.mark("hit_detected")
				hitAt = os.clock()
				log.info("HIT CONFIRMED @%.3f (+%.3fs into the prime, hold=%.3fs)", hitAt, hitAt - t0, hitAt - witnessAt)
				break
			end
			RunService.Heartbeat:Wait()
		end
		do
			local hh = ch.root()
			if hh then
				pcall(function()
					hh.Anchored = false
				end)
			end
			BX.profile.mark("unanchor")
		end
		local took = hitAt ~= nil
		if took then
			stats.hits = stats.hits + 1
		else
			stats.noHit = stats.noHit + 1
		end
		log.info("%s in %s after %.2fs (tries=%d rehops=%d witness=%s tier=%s)", took and "HIT TAKEN" or "no hit", tostring(areaId), os.clock() - t0, tries, rehops, witnessAt and "yes" or "no", dev.tier)
		return took, {
			reason = took and "hit" or "no hit",
			areaId = areaId,
			tries = tries,
			rehops = rehops,
			elapsed = os.clock() - t0,
		}
	end
	return M
end)
BX.module("features.autosteal", function(BX)
	local svc = BX.require("core.services")
	local dev = BX.require("core.device")
	local ch = BX.require("core.character")
	local st = BX.require("core.state")
	local eggs = BX.require("features.eggs")
	local grab = BX.require("features.grab")
	local move = BX.require("features.movement")
	local carry = BX.require("features.carry")
	local bait = BX.require("features.bait")
	local plot = BX.require("features.plot")
	local adeath = BX.require("features.antideath")
	local guard = BX.require("features.guard")
	local rs = BX.require("core.restore")
	local instant = BX.require("features.instant")
	local regrab = BX.require("features.regrab")
	local hswap = BX.require("features.humanoid")
	local data = BX.require("core.data")
	local guardwatch = BX.require("features.guardwatch")
	local motion = BX.require("core.motion")
	local log = BX.require("boot.log").for_module("autosteal")
	local M = {}
	local animationLocked = false
	local animationState = {}
	local function setAnimationsLocked(on)
		local char = ch.get()
		local hum = ch.humanoid()
		if not char then
			return
		end
		local animate = char:FindFirstChild("Animate")
		if on then
			if animationLocked then
				return
			end
			animationLocked = true
			animationState.animate = animate
			animationState.disabled = animate and animate.Disabled or false
			if animate then
				pcall(function()
					animate.Disabled = true
				end)
			end
			if hum then
				local animator = hum:FindFirstChildOfClass("Animator")
				if animator then
					for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
						pcall(function()
							track:Stop(0)
						end)
					end
				end
			end
		else
			if not animationLocked then
				return
			end
			animationLocked = false
			if animate and animate.Parent then
				pcall(function()
					animate.Disabled = animationState.disabled
				end)
			end
			table.clear(animationState)
		end
	end
	function M.setAnimationLocked(on)
		setAnimationsLocked(on and true or false)
	end
	local BACKOFF_BASE = 1.0
	local BACKOFF_CAP = 8.0
	local IDLE_WAIT = 0.4
	local SLOW_IDLE_WAIT = 2.0
	local RESET_LEAD = 30
	local INVENTORY_FULL = "egg inventory full"
	local GUARD_WAIT = "waiting for the guard to go home"
	local lastGuardWait = nil
	local idleNow = nil
	local function isInventoryFull(msg)
		return type(msg) == "string" and msg:lower():find("inventory is full", 1, true) ~= nil
	end
	local TRUST_WAIT = "movement not trusted by the server - cooling down"
	local NO_BAIT = "no bait egg in the Forest"
	local REBAIT = "egg back in its nest - re-baiting"
	local TRUST_FIRST, TRUST_MAX = 10, 60
	local trustUntil, trustCool = 0, 0
	local function isTrustRefusal(msg)
		if type(msg) ~= "string" then
			return false
		end
		local m = msg:lower()
		return m:find("not currently trusted", 1, true) ~= nil or m:find("get closer", 1, true) ~= nil
	end
	local function distrust(why)
		trustCool = math.min(math.max(trustCool * 2, TRUST_FIRST), TRUST_MAX)
		trustUntil = os.clock() + trustCool
		log.warn("server refused our movement (%s) - no teleports for %.0fs", tostring(why), trustCool)
	end
	function M.trustCooldown()
		return math.max(0, trustUntil - os.clock()), trustCool
	end
	local watch = {
		uid = nil,
		msg = nil,
		retries = 0,
		phase = nil,
		phaseAt = 0,
		reported = nil,
		passAt = 0
	}
	M.STATE = {
		PREP_DELIVER_HELD = "PREP_DELIVER_HELD",
		READY_TO_STEAL = "READY_TO_STEAL",
		BAIT_NOT_DONE = "BAIT_NOT_DONE",
		BAIT_DONE = "BAIT_DONE",
		AT_TARGET = "AT_TARGET",
		TARGET_GRAB_RETRY = "TARGET_GRAB_RETRY",
		CARRYING = "CARRYING",
		RETURNING = "RETURNING",
		DELIVERED = "DELIVERED",
	}
	local phases = {}
	local phaseRun = 0
	local function phase(token, name, detail)
		if token ~= phaseRun then
			phases, phaseRun = {}, token
		end
		if detail == nil and phases[# phases] == name then
			return
		end
		if watch.phase ~= name then
			watch.phase, watch.phaseAt, watch.reported = name, os.clock(), nil
		end
		phases[# phases + 1] = name
		if # phases > 200 then
			table.remove(phases, 1)
		end
		log.info("run %d: phase %s%s", token, name, detail and (" (" .. tostring(detail) .. ")") or "")
	end
	function M.phases()
		return table.clone(phases)
	end
	local TARGET_RETRIES = 2
	local RESPAWN_WAIT = 12
	local stopListeners = {}
	function M.onStop(fn)
		stopListeners[# stopListeners + 1] = fn
	end
	local betweenCycles = nil
	function M.setBetweenCycles(fn)
		betweenCycles = fn
	end
	local idleListeners = {}
	function M.onIdle(fn)
		idleListeners[# idleListeners + 1] = fn
	end
	local deliveredListeners = {}
	function M.onDelivered(fn)
		deliveredListeners[# deliveredListeners + 1] = fn
	end
	local carryingListeners = {}
	function M.onCarrying(fn)
		carryingListeners[# carryingListeners + 1] = fn
	end
	local function fireCarrying(target)
		if not target then
			return
		end
		for _, fn in ipairs(carryingListeners) do
			task.spawn(function()
				BX.try("autosteal.onCarrying", fn, target)
			end)
		end
	end
	local function fireDelivered(target)
		if not target then
			return
		end
		for _, fn in ipairs(deliveredListeners) do
			task.spawn(function()
				BX.try("autosteal.onDelivered", fn, target)
			end)
		end
	end
	local runToken = 0
	local running = false
	local cycles = 0
	local sc = nil
	local failures = 0
	local opts = {}
	local optsFor = {}
	local owner = nil
	local function snapshot()
		local h = BX.profile.health()
		local e = eggs.stats()
		return {
			scopes = h.scopes,
			conns = h.conns,
			insts = h.insts,
			threads = h.threads,
			eggList = e.listSize,
			eggValues = e.valueCache,
		}
	end
	local SNAP_KEYS = {
		"scopes",
		"conns",
		"insts",
		"threads",
		"eggList",
		"eggValues"
	}
	local function diff(a, b)
		local out = {}
		for _, k in ipairs(SNAP_KEYS) do
			local d = (b[k] or 0) - (a[k] or 0)
			if d ~= 0 then
				out[# out + 1] = ("%s %+d"):format(k, d)
			end
		end
		return # out > 0 and table.concat(out, " ") or "no change"
	end
	local function runCycle(token, cancel)
		local cycle = {
			t0 = os.clock(),
			stages = {}
		}
		watch.passAt = cycle.t0
		watch.uid, watch.msg, watch.retries = nil, nil, 0
		if os.clock() < trustUntil then
			return false, TRUST_WAIT, cycle
		end
		BX.profile.mark("cycle_start")
		local function stage(name, fn)
			if cancel() then
				return false, {
					reason = "cancelled"
				}
			end
			local s0 = os.clock()
			local ok, info = fn()
			cycle.stages[# cycle.stages + 1] = {
				name = name,
				ms = (os.clock() - s0) * 1000,
				ok = ok and true or false,
			}
			return ok, info
		end
		local held = eggs.carryingUid()
		if held then
			local isObjective = (opts.uid ~= nil) and (held == opts.uid)
			cycle.prep = not isObjective
			cycle.state = isObjective and M.STATE.RETURNING or M.STATE.PREP_DELIVER_HELD
			phase(token, cycle.state, "holding " .. tostring(held))
			cycle.recovered = held
			log.info("already carrying %s - %s", held, isObjective and "this is the selected egg, delivering to finish" or "not the selected egg, clearing our hands first")
			local ok2, info2 = stage("carry held", function()
				return carry.home(held, {
					cancel = cancel
				})
			end)
			if ok2 then
				cycle.target = {
					name = isObjective and "selected egg" or "held egg",
					uid = held
				}
				if isObjective then
					cycle.state = M.STATE.DELIVERED
					cycle.terminal = true
					phase(token, cycle.state, held)
					return true, "delivered", cycle
				end
				cycle.state = M.STATE.READY_TO_STEAL
				cycle.terminal = false
				phase(token, cycle.state, "hands clear after prep")
				return true, "prep: held egg delivered", cycle
			end
			return false, "held egg: " .. tostring(info2 and info2.reason), cycle
		end
		if cycle.state == nil then
			cycle.state = M.STATE.READY_TO_STEAL
			phase(token, cycle.state)
		end
		if data.fieldSealed() then
			return false, "field resetting", cycle
		end
		local untilReset = data.secondsUntilReset()
		if untilReset and untilReset < RESET_LEAD then
			return false, "field resetting", cycle
		end
		local invFull, invCount, invLimit = data.eggInventory()
		if invFull then
			cycle.inventory = ("%d/%d"):format(invCount, invLimit)
			return false, INVENTORY_FULL, cycle
		end
		idleNow = nil
		local preTarget = nil
		local guardOverride = false
		if opts.uid and not eggs.get(opts.uid) then
			return false, "selected egg is gone", cycle
		end
		if opts.pick and not opts.uid then
			local okPre, pre, whyPre, overPre = pcall(opts.pick)
			guardOverride = okPre and overPre == true
			if not okPre then
				return false, "target picker failed: " .. tostring(pre), cycle
			end
			if not pre then
				return false, "nothing to steal" .. (whyPre and (" (" .. tostring(whyPre) .. ")") or ""), cycle
			end
			preTarget = pre
		end
		do
			local aim = opts.uid and eggs.get(opts.uid) or preTarget
			local blockedBy = aim and not guardOverride and guardwatch.blocking(aim.areaId, aim.pos)
			if blockedBy then
				cycle.guardWait = blockedBy
				if blockedBy ~= lastGuardWait then
					lastGuardWait = blockedBy
					log.info("holding the steal: %s", blockedBy)
				end
				return false, GUARD_WAIT, cycle
			end
			lastGuardWait = nil
		end
		local firstArea = bait.firstAreaId(0)
		local inBaitArea = nil
		if opts.uid then
			local want = eggs.get(opts.uid)
			inBaitArea = want and firstArea and want.areaId == firstArea or false
		elseif preTarget then
			inBaitArea = firstArea ~= nil and preTarget.areaId == firstArea
		end
		local primed = false
		if inBaitArea then
			log.info("target is in the bait area (%s) - not priming, going straight for it (V3.1 rule)", tostring(firstArea))
			cycle.baitSkipped = true
		else
			local baitInfo
			primed, baitInfo = stage("bait", function()
				return bait.prime({
					cancel = cancel
				})
			end)
			if not primed and baitInfo and isInventoryFull(baitInfo.msg) then
				return false, INVENTORY_FULL, cycle
			end
			if not primed and baitInfo then
				local r = baitInfo.reason
				watch.msg = baitInfo.msg or r
				if cancel() then
					return false, "cancelled", cycle
				end
				if r == "no pickup" and isTrustRefusal(baitInfo.msg) then
					distrust("bait pickup: " .. tostring(baitInfo.msg))
					return false, TRUST_WAIT, cycle
				elseif r == "no bait egg" then
					return false, NO_BAIT, cycle
				elseif r == "no pickup" or r == "no hit" then
					return false, "bait not taken (" .. tostring(r) .. (baitInfo.msg and (": " .. tostring(baitInfo.msg)) or "") .. ")", cycle
				end
			end
		end
		cycle.primed = primed and true or false
		if cancel() then
			return false, "cancelled", cycle
		end
		local target
		if opts.uid then
			local want = eggs.get(opts.uid)
			if not want then
				return false, "selected egg is gone", cycle
			end
			local takeable = (want.state == "Slot" or want.state == "Dropped")
			if not takeable or not want.pos then
				return false, "waiting for the selected egg (" .. tostring(want.state) .. ")", cycle
			end
			target = want
		elseif opts.pick then
			local ok2, want, why2 = true, preTarget, nil
			if not (cycle.baitSkipped and preTarget) then
				ok2, want, why2 = pcall(opts.pick)
			end
			if not ok2 then
				return false, "target picker failed: " .. tostring(want), cycle
			end
			target = want
			if not target then
				return false, "nothing matches the filter" .. (why2 and (" (" .. tostring(why2) .. ")") or ""), cycle
			end
		else
			target = eggs.best()
		end
		if not target then
			return false, "nothing to steal", cycle
		end
		cycle.target = target
		watch.uid = target.uid
		local here = ch.root()
		cycle.distance = here and (target.pos - here.Position).Magnitude or - 1
		cycle.state = M.STATE.BAIT_DONE
		phase(token, cycle.state, cycle.primed and "primed" or (cycle.baitSkipped and "bait skipped: target in the bait area" or "no bait egg"))
		log.info("target uid=%s name=%s area=%s rarity=%s state=%s dist=%.0f primed=%s", tostring(target.uid), tostring(target.name), tostring(target.areaId), tostring(target.rarity), tostring(target.state), cycle.distance or - 1, tostring(cycle.primed))
		local took, inInfo
		local retries = 0
		for attempt = 0, TARGET_RETRIES do
			cycle.state = (attempt == 0) and M.STATE.AT_TARGET or M.STATE.TARGET_GRAB_RETRY
			phase(token, cycle.state, target.name)
			took, inInfo = stage(attempt == 0 and "instant" or ("regrab" .. attempt), function()
				return instant.take(target.uid, target.pos, {
					cancel = cancel,
					areaId = target.areaId,
					nestId = target.nestId,
				})
			end)
			watch.msg, watch.retries = inInfo and inInfo.reason, attempt
			if took or cancel() then
				break
			end
			if inInfo and type(inInfo.reason) == "string" and inInfo.reason:lower():find("not currently trusted", 1, true) then
				break
			end
			local st = inInfo and inInfo.eggState
			local retryable = inInfo and (inInfo.pulledBack or st == "Slot" or st == "Dropped")
			if not retryable or attempt == TARGET_RETRIES then
				break
			end
			local fresh = eggs.get(target.uid)
			if not fresh or not fresh.pos then
				break
			end
			target.pos = fresh.pos
			retries = retries + 1
			log.info("target retry %d/%d (reason=%s state=%s pulledBack=%s)", attempt + 1, TARGET_RETRIES, tostring(inInfo and inInfo.reason), tostring(st), tostring(inInfo and inInfo.pulledBack))
		end
		cycle.grabRetries = retries
		if cancel() then
			return false, "cancelled", cycle
		end
		if took then
			cycle.state = M.STATE.CARRYING
			phase(token, cycle.state, "instant")
			fireCarrying(target)
			cycle.transition = "tp"
			cycle.calls = inInfo and inInfo.calls
			cycle.tpGap = inInfo and inInfo.gap
		else
			cycle.transition = "arc_fallback"
			cycle.instantFail = inInfo and inInfo.reason
			if isInventoryFull(inInfo and inInfo.reason) then
				return false, INVENTORY_FULL, cycle
			end
			if inInfo and not inInfo.pulledBack and isTrustRefusal(inInfo.reason) then
				distrust("target pickup: " .. tostring(inInfo.reason))
				return false, TRUST_WAIT, cycle
			end
			cycle.instantDiag = inInfo
			local reached, moveInfo = stage("approach", function()
				return move.travel{
					to = target.pos,
					speed = move.outboundSpeed(),
					arrive = 4,
					carrying = false,
					cancel = cancel,
					tag = "approach",
				}
			end)
			if cancel() then
				return false, "cancelled", cycle
			end
			if not reached then
				return false, "approach: " .. tostring(moveInfo and moveInfo.reason), cycle
			end
			local grabbed, grabInfo = stage("grab", function()
				return grab.take(target.uid, {
					pos = target.pos,
					cancel = cancel
				})
			end)
			if cancel() then
				return false, "cancelled", cycle
			end
			if not grabbed then
				eggs.markUnreachable(target.uid)
				return false, "grab: " .. tostring(grabInfo and grabInfo.reason), cycle
			end
			cycle.state = M.STATE.CARRYING
			phase(token, cycle.state, "prompt")
			fireCarrying(target)
		end
		cycle.state = M.STATE.RETURNING
		phase(token, cycle.state, target.name)
		local delivered, carryInfo = stage("carry", function()
			return carry.home(target.uid, {
				cancel = cancel
			})
		end)
		local recoveries = 0
		while not delivered and not cancel() and carryInfo and carryInfo.reason and tostring(carryInfo.reason):find("dropped in transit", 1, true) and recoveries < regrab.K.MAX_PER_STEAL do
			svc.RunService.Heartbeat:Wait()
			recoveries = recoveries + 1
			cycle.recoveries = recoveries
			cycle.state = M.STATE.TARGET_GRAB_RETRY
			local back, rinfo = stage("recover" .. recoveries, function()
				return regrab.recover(target.uid, {
					cancel = cancel,
					areaId = target.areaId,
					nestId = target.nestId,
				})
			end)
			cycle.dropRecovery = rinfo and rinfo.recovery or "?"
			if not back then
				if rinfo and rinfo.recovery == "rebait" then
					return false, REBAIT, cycle
				end
				return false, "drop recovery: " .. tostring(rinfo and rinfo.reason), cycle
			end
			cycle.state = M.STATE.RETURNING
			delivered, carryInfo = stage("carry" .. recoveries, function()
				return carry.home(target.uid, {
					cancel = cancel
				})
			end)
		end
		if cancel() then
			return false, "cancelled", cycle
		end
		if not delivered then
			return false, "carry: " .. tostring(carryInfo and carryInfo.reason), cycle
		end
		cycle.state = M.STATE.DELIVERED
		cycle.terminal = true
		phase(token, cycle.state, target.name)
		trustCool = 0
		setAnimationsLocked(false)
		fireDelivered(target)
		return true, "delivered", cycle
	end
	local function reportCycle(ok, why, cycle, before, after)
		local parts = {}
		for _, s in ipairs(cycle.stages) do
			parts[# parts + 1] = ("%s=%.0fms%s"):format(s.name, s.ms, s.ok and "" or "!")
		end
		if not ok then
			local marks = BX.profile.marksSince(cycle.t0)
			if # marks > 0 then
				log.warn("timeline: %s", table.concat(marks, " | "))
			end
		end
		local level = ok and log.info or log.warn
		level("cycle %s in %.2fs [%s] target=%s dist=%.0f %s | %s", ok and "DELIVERED" or ("FAILED " .. tostring(why)), os.clock() - cycle.t0, table.concat(parts, " "), cycle.target and cycle.target.name or "-", cycle.distance or - 1, ("state=%s transition=%s calls=%s retries=%d recoveries=%d%s primed=%s%s"):format( cycle.state or "?", cycle.transition or "?", tostring(cycle.calls or "-"), cycle.grabRetries or 0, cycle.recoveries or 0, cycle.dropRecovery and (" drop_recovery=" .. cycle.dropRecovery) or "", tostring(cycle.primed), cycle.instantFail and (" instantFail=" .. tostring(cycle.instantFail) .. " pulledBack=" .. tostring(cycle.instantDiag and cycle.instantDiag.pulledBack) .. " eggState=" .. tostring(cycle.instantDiag and cycle.instantDiag.eggState)) or ""), diff(before, after))
	end
	local MAX_PREPS = 3
	local GONE_PASSES = 6
	local lastIdleWhy = nil
	local timedCycle = BX.profile.wrapLoop("features.autosteal/pass", IDLE_WAIT, runCycle)
	local function runLoop(token)
		log.info("run %d: begin (tier=%s)", token, dev.tier)
		phase(token, "START", "tier=" .. tostring(dev.tier))
		local preps = 0
		local goneStreak = 0
		lastIdleWhy = nil
		local isCancelled = function()
			return (not running) or token ~= runToken or (not BX.alive())
		end
		while running and token == runToken and BX.alive() do
			svc.RunService.Heartbeat:Wait()
			if not running or token ~= runToken then
				break
			end
			local before = snapshot()
			local ok, why, cycle = timedCycle(token, isCancelled)
			local after = snapshot()
			if why ~= "selected egg is gone" then
				goneStreak = 0
			end
			local idle = type(why) == "string" and (why:find("^nothing to steal") or why:find("^nothing matches the filter") or why == "field resetting" or why == INVENTORY_FULL or why == GUARD_WAIT or why == TRUST_WAIT or why == NO_BAIT or why == "selected egg is gone") or false
			if idle then
				idleNow = why
				if why ~= lastIdleWhy then
					lastIdleWhy = why
					log.info("idle: %s", why)
					local detail = why
					if why == INVENTORY_FULL then
						local _, n, lim = data.eggInventory()
						if n and lim then
							detail = ("%s (%d/%d)"):format(why, n, lim)
						end
					end
					for _, fn in ipairs(idleListeners) do
						task.spawn(function()
							BX.try("autosteal.onIdle", fn, detail, owner)
						end)
					end
				end
			else
				lastIdleWhy, idleNow = nil, nil
				if cycle then
					reportCycle(ok, why, cycle, before, after)
				end
			end
			if why == "cancelled" then
				break
			end
			if ok and not (cycle and cycle.terminal) then
				failures = 0
				preps = preps + 1
				if preps > MAX_PREPS then
					log.warn("%d preparation passes without a steal - stopping", preps)
					return "ended"
				end
				log.info("preparation complete (%s) - continuing the same run", tostring(why))
			elseif ok and opts.continuous then
				failures = 0
				cycles = cycles + 1
				log.info("delivered (%d this run) - continuing", cycles)
				if betweenCycles and running and token == runToken then
					BX.try("autosteal.betweenCycles", betweenCycles, owner)
				end
			elseif ok then
				failures = 0
				cycles = cycles + 1
				log.info("delivered - run complete")
				return "delivered"
			elseif why == "selected egg is gone" then
				goneStreak = goneStreak + 1
				if goneStreak >= GONE_PASSES then
					log.info("selected egg is gone (%d checks) - stopping", goneStreak)
					return "selected egg is gone"
				end
				task.wait(dev.scale(IDLE_WAIT))
			elseif why == REBAIT then
				failures = 0
				log.info("guard returned the egg to its nest - re-baiting now")
			elseif why == TRUST_WAIT then
				task.wait(math.max(IDLE_WAIT, trustUntil - os.clock()))
			elseif why == INVENTORY_FULL or why == "field resetting" or why == NO_BAIT then
				task.wait(dev.scale(SLOW_IDLE_WAIT))
			elseif (type(why) == "string" and why:find("^nothing to steal")) or why == "nothing matches the filter" or (type(why) == "string" and why:find("^nothing matches the filter")) or why == "field resetting" or why == INVENTORY_FULL or why == GUARD_WAIT or (type(why) == "string" and why:find("waiting for the selected egg", 1, true)) then
				task.wait(dev.scale(IDLE_WAIT))
			else
				failures = failures + 1
				local wait = math.min(BACKOFF_BASE * (2 ^ (failures - 1)), BACKOFF_CAP)
				wait = dev.scale(wait)
				log.warn("backing off %.1fs (failure %d)", wait, failures)
				task.wait(wait)
			end
		end
		log.info("run %d: ended", token)
		return "ended"
	end
	local function stop(reason)
		if not running then
			return
		end
		running = false
		runToken = runToken + 1
		st.autoStealOn = false
		motion.release("autosteal")
		if sc then
			sc:destroy()
			sc = nil
		end
		failures = 0
		local whose = owner
		owner = nil
		opts = {}
		BX.try("autosteal.antideath", adeath.disarm)
		BX.try("autosteal.humanoid", hswap.disarm)
		BX.try("autosteal.guard", guard.disarm)
		BX.try("autosteal.resetMovement", move.reset)
		BX.try("autosteal.unanchor", function()
			local hrp = ch.root()
			if hrp and hrp.Anchored then
				hrp.Anchored = false
			end
		end)
		local restored, skipped, failed = 0, 0, 0
		BX.try("autosteal.restore", function()
			restored, skipped, failed = rs.restoreAll()
		end)
		local leftovers = {}
		BX.try("autosteal.audit", function()
			leftovers = rs.audit()
		end)
		if # leftovers == 0 and failed == 0 then
			log.info("autosteal cleanup: PASS (%d restored, %d skipped)", restored, skipped)
		else
			log.warn("autosteal cleanup: %d restored, %d skipped, %d FAILED%s", restored, skipped, failed, # leftovers > 0 and (" | still modified: " .. table.concat(leftovers, "; ")) or "")
		end
		log.info("stopped (%s) after %d cycles", reason or "requested", cycles)
		phase(phaseRun, "STOP", reason or "requested")
		log.info("run %d trail: %s", phaseRun, table.concat(phases, " -> "))
		local why = reason or "requested"
		for _, fn in ipairs(stopListeners) do
			task.spawn(function()
				BX.try("autosteal.onStop", fn, why, whose)
			end)
		end
	end
	function M.capability()
		local exec = BX.require("core.exec")
		local paths = {}
		if instant.ready then
			paths[# paths + 1] = "instant (CarryFieldEgg)"
		end
		if exec.can.prompts then
			paths[# paths + 1] = "prompt (" .. tostring(exec.promptVia) .. ")"
		end
		if # paths == 0 then
			return false, "Auto Steal cannot run on this executor: no game-module require (" .. tostring(exec.gameRequireWhy) .. ") and no proximity prompt path"
		end
		return true, table.concat(paths, " + ")
	end
	local function start(src)
		if running then
			return
		end
		local okCap, capWhy = M.capability()
		if not okCap then
			log.error("%s", capWhy)
			return false, capWhy
		end
		owner = tostring(src or "main")
		opts = optsFor[owner] or {}
		log.info("run starting for %s - pickup via %s", owner, capWhy)
		if sc then
			sc:destroy()
		end
		runToken = runToken + 1
		running = true
		st.autoStealOn = true
		motion.claim("autosteal")
		sc = BX.scope("features.autosteal")
		local token = runToken
		ch.onSpawn(sc, "autosteal.respawn", function()
			if not running or token ~= runToken then
				return
			end
			failures = 0
			log.trace("respawn: run %d continues", token)
		end)
		local armed = {}
		for _, a in ipairs({
			{
				"humanoid",
				hswap.arm
			},
			{
				"guard",
				guard.arm
			},
			{
				"antideath",
				adeath.arm
			}
		}) do
			local ok = BX.try("autosteal.arm." .. a[1], a[2])
			armed[# armed + 1] = a[1] .. (ok and "=ok" or "=FAILED")
		end
		log.info("run %d: armed %s", token, table.concat(armed, " "))
		watch.phase, watch.phaseAt, watch.reported, watch.passAt = nil, os.clock(), nil, os.clock()
		local worker
		worker = sc:spawn("loop", function()
			log.info("run %d: worker thread started (owner=%s, options: %s)", token, tostring(owner), opts.uid and ("uid=" .. tostring(opts.uid)) or (opts.pick and ("picker" .. (opts.continuous and ", continuous" or "")) or "best value"))
			local reason = runLoop(token)
			if token == runToken then
				if reason == "delivered" then
					stop("delivered")
				elseif running then
					stop(reason or "ended")
				end
			end
		end)
		local LIMIT = {
			PREP_DELIVER_HELD = 40,
			READY_TO_STEAL = 30,
			BAIT_DONE = 12,
			AT_TARGET = 10,
			TARGET_GRAB_RETRY = 25,
			CARRYING = 5,
			RETURNING = 35
		}
		sc:loop("watchdog", 1, function()
			if not running or token ~= runToken then
				return
			end
			local now = os.clock()
			local okCo, status = pcall(coroutine.status, worker)
			if okCo and status == "dead" and running and token == runToken then
				log.error("run %d: worker thread is dead while the run is on - stopping cleanly", token)
				task.spawn(stop, "worker died")
				return
			end
			local ph = watch.phase
			local limit = ph and LIMIT[ph]
			local inPhase = now - (watch.phaseAt or now)
			local sinceStart = now - (watch.passAt or now)
			local waiting = idleNow ~= nil
			if limit and not waiting and inPhase > limit and watch.reported ~= ph then
				watch.reported = ph
				local hum, root = ch.humanoid(), ch.root()
				local full, n, lim = data.eggInventory()
				local tLeft = M.trustCooldown()
				log.warn("WATCHDOG run %d: %s for %.1fs (limit %ds) uid=%s | humanoid=%s hp=%s root=%s anchored=%s" .. " | ragdoll=%.1fs | movement owner=%s | last pickup=%s | retries=%d | inventory=%s/%s" .. " | trust cooldown=%.0fs | pass started %.1fs ago", token, ph, inPhase, limit, tostring(watch.uid), tostring(hum ~= nil and hum.Parent ~= nil), hum and ("%.0f"):format(hum.Health) or "-", tostring(root ~= nil), tostring(root and root.Anchored), guard.ragdollRemaining(), tostring(motion.owner()), tostring(watch.msg), watch.retries or 0, tostring(n), tostring(lim), tLeft, sinceStart)
			end
			if not waiting and sinceStart > 150 then
				log.error("run %d: no progress for %.0fs (phase %s) - stopping the run", token, sinceStart, tostring(ph))
				task.spawn(stop, "stalled: no progress for " .. math.floor(sinceStart) .. "s")
			end
		end)
	end
	BX.onTeardown("autosteal", function()
		if running then
			stop("hub unloaded")
		end
	end)
	function M.setOptions(src, o)
		if type(src) == "table" or src == nil then
			src, o = "main", src
		end
		src = tostring(src)
		optsFor[src] = o or {}
		if running and owner == src then
			opts = optsFor[src]
			log.info("%s updated its options mid-run", src)
		end
	end
	function M.setEnabled(on, src)
		src = tostring(src or "main")
		if on then
			setAnimationsLocked(true)
			local okStart, why = start(src)
			if okStart == false then
				setAnimationsLocked(false)
				return false, why
			end
		else
			if running and owner ~= nil and owner ~= src then
				log.info("%s asked to stop, but %s owns this run - ignored", src, owner)
				return false
			end
			stop("toggled off")
			setAnimationsLocked(false)
		end
		return true
	end
	function M.owner()
		return owner
	end
	function M.isRunning()
		return running
	end
	function M.runOnce(cancelFn)
		local before = snapshot()
		local ok, why, cycle = runCycle(runToken, cancelFn or function()
			return false
		end)
		local after = snapshot()
		if cycle then
			reportCycle(ok, why, cycle, before, after)
		end
		return ok, why, cycle, before, after
	end
	function M.status()
		return {
			running = running,
			token = runToken,
			cycles = cycles,
			failures = failures,
			idle = running and idleNow or nil,
			tier = dev.tier,
			scope = sc and sc:counts() or nil,
		}
	end
	M.stop = stop
	return M
end)
BX.module("features.bossfight", function(BX)
	local svc = BX.require("core.services")
	local dev = BX.require("core.device")
	local ch = BX.require("core.character")
	local net = BX.require("core.net")
	local boss = BX.require("features.boss")
	local mov = BX.require("features.movement")
	local auto = BX.require("features.autosteal")
	local motion = BX.require("core.motion")
	local log = BX.require("boot.log").for_module("bossfight")
	local M = {}
	local K = {
		TICK = 0.12,
		SWING_GAP = 0.65,
		REACH = 9,
		EQUIP_SETTLE = 0.25,
		RESPAWN_SETTLE = 0.6,
		HAND_REACH_Y = 30,
		HAND_CHASE_Y = 90,
		HAND_RISE_EPS = 2,
		HAND_COMMIT = 1.5,
		SURFACE_MARGIN = - 20,
		STEP_SPEED = 420,
		MAX_STEP = 14,
		MAX_DT = 0.05,
		SINK_MAX = 6,
		Y_TAU = 0.12,
		STUCK_TIME = 2.5,
		RIM_SWEEP = {
			25,
			50,
			75,
			100,
			125,
			150
		},
		RIM_LOOKAHEAD = 6,
		MOVE_ARRIVE = 1.5,
		SWING_SLACK = 4,
		AIM_COS = 0.906,
		AIM_EASE = 0.35,
		TRACK_TAU = 0.18,
		TRACK_JUMP = 60,
		WAIT_MAX = 2.5,
		FLING_UP = 60,
		FLING_MULT = 2.0,
		GROUND_BAND = 25,
		PROBE_UP = 40,
		PROBE_DOWN = 220,
		SOLID_STEPS = 8,
		IGNORE_TTL = 0.5,
		RING_STEP_DEG = 22,
		RING_RADII = {
			1.0,
			0.85,
			1.15,
			0.7,
			1.3
		},
		AROUND_ANGLES = {
			25,
			45,
			70,
			95,
			120,
			145
		},
		AROUND_FRAC = 0.55,
		AROUND_MIN_R = 90,
		HAZARD_CACHE = 0.1,
		HAZARD_CLEAR = 6,
		SLAM_CLEAR = 12,
		RING_CLEAR = 2,
		HOLE_CLEAR = 6,
		DODGE_GAP = 0.08,
		DODGE_POINTS = 16,
		DODGE = false,
		ORBIT_TRIGGER = 34,
		ORBIT_STEP = 0.55,
		VOID_GAP = 0.2,
		VOID_MISSES = 3,
		VOID_DROP_PROOF = 25,
		MAX_RISE = 8,
		HAND_BONES = {
			"UpperHand1.R",
			"UpperHand1.L",
			"LowerHand1.R",
			"LowerHand1.L"
		},
		WALK = true,
		WALK_LOOKAHEAD = 24,
		SNAP_GAP = 8,
		SNAPS = 3,
		SNAP_WINDOW = 4,
		BACKOFF_FIRST = 1,
		BACKOFF_MAX = 8,
		SKIP_AFTER = 4,
		SKIP_STUCK = 3,
		SKIP_FOR = 15,
		LEAVE_GAP = 3,
		LEAVE_TRIES = 5,
		TOWERS_TTL = 2,
	}
	M.K = K
	local sc, enabled = nil, false
	local stats = {
		swings = 0,
		dodges = 0,
		flings = 0,
		voidSaves = 0,
		rescues = 0,
		kills = 0
	}
	function M.stats()
		return table.clone(stats)
	end
	function M.isOn()
		return enabled
	end
	local S = nil
	local function fresh()
		return {
			goal = nil,
			dodge = nil,
			aim = nil,
			trackPos = nil,
			handY = {},
			handPick = nil,
			handPickAt = 0,
			lastSolid = nil,
			arenaFloorY = nil,
			stuckBest = nil,
			stuckSince = nil,
			stuckFlip = false,
			rimSide = 1,
			lastSwingAt = 0,
			batFor = nil,
			waitAt = nil,
			idlePhase = false,
			arena = nil,
			hazards = nil,
			hazardsAt = 0,
			ignore = nil,
			ignoreAt = 0,
			inArena = false,
			noclipped = false,
			left = false,
			settleUntil = 0,
			batAskedAt = 0,
			voidAnchor = nil,
			voidMisses = 0,
			lastLog = {},
			phase = nil,
			kind = nil,
			wrote = nil,
			snaps = {},
			holdUntil = 0,
			backoff = 0,
			backoffs = 0,
			sidesteps = 0,
			skip = {},
			goalKey = nil,
			killClaimed = false,
			leaveTries = 0,
			leaveAt = 0,
			towers = nil,
			towersAt = 0,
			stage = nil,
		}
	end
	local function trail(stage, detail)
		if not S or S.stage == stage then
			return
		end
		S.stage = stage
		log.info("fight: %s%s", stage, detail and (" (" .. tostring(detail) .. ")") or "")
	end
	local function every(key, secs, fmt, ...)
		local now = os.clock()
		if now - (S.lastLog[key] or 0) < secs then
			return
		end
		S.lastLog[key] = now
		log.info(fmt, ...)
	end
	local function inArena()
		return svc.LocalPlayer:GetAttribute("InBossArena") == true
	end
	M.inArena = inArena
	local function arena()
		local a = S.arena
		if a and a.Parent then
			return a
		end
		a = workspace:FindFirstChild("BossArena") or workspace:FindFirstChild("BossArena", true)
		S.arena = a
		return a
	end
	local function arenaFloor()
		local a = arena()
		local f = a and a:FindFirstChild("Floor", true)
		if f and f:IsA("BasePart") then
			return f
		end
		return nil
	end
	local function arenaCentre()
		local f = arenaFloor()
		if f then
			return f.Position
		end
		local a = arena()
		if a and a.PrimaryPart then
			return a.PrimaryPart.Position
		end
		return nil
	end
	local function bossModel()
		local a = arena()
		if not a then
			return nil
		end
		local b = a:FindFirstChild("Boss", true)
		if b and b:IsA("Model") then
			return b
		end
		return nil
	end
	local function phase()
		local b = bossModel()
		if not b then
			return nil
		end
		if b:GetAttribute("Spawning") then
			return nil
		end
		if b:GetAttribute("PhaseTwoAt") ~= nil then
			return "hands"
		end
		return "crystals"
	end
	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Exclude
	probeParams.IgnoreWater = true
	local function refreshIgnore()
		local now = os.clock()
		if S.ignore and (now - S.ignoreAt) < K.IGNORE_TTL then
			return
		end
		local ignore = {}
		for _, pl in ipairs(svc.Players:GetPlayers()) do
			if pl.Character then
				ignore[# ignore + 1] = pl.Character
			end
		end
		local a = arena()
		if a then
			for _, nm in ipairs({
				"CrystalTowers",
				"Boss",
				"SlamIndicator",
				"SlamArmHitbox",
				"SlamRestHitbox"
			}) do
				local d = a:FindFirstChild(nm, true)
				if d then
					ignore[# ignore + 1] = d
				end
			end
		end
		for _, nm in ipairs({
			"BossHazards",
			"BossBlackHole"
		}) do
			local d = workspace:FindFirstChild(nm)
			if d then
				ignore[# ignore + 1] = d
			end
		end
		probeParams.FilterDescendantsInstances = ignore
		S.ignore, S.ignoreAt = ignore, now
	end
	local function groundAt(pos)
		refreshIgnore()
		local top = pos.Y + K.PROBE_UP
		local f = arenaFloor()
		if f then
			top = math.max(top, f.Position.Y + K.PROBE_UP)
		end
		local reach = math.max(K.PROBE_DOWN, (top - pos.Y) + K.PROBE_DOWN)
		local r = workspace:Raycast(Vector3.new(pos.X, top, pos.Z), Vector3.new(0, - reach, 0), probeParams)
		if not r then
			return nil
		end
		if f and (r.Position.Y - f.Position.Y) > K.GROUND_BAND then
			return nil
		end
		return r.Position.Y
	end
	local function onFloor(pos)
		return groundAt(pos) ~= nil
	end
	local function lastSolidToward(from, to)
		local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		local dist = flat.Magnitude
		if dist < 1 then
			return nil
		end
		local dir = flat.Unit
		local best
		local step = math.max(dist / K.SOLID_STEPS, 20)
		for i = 1, K.SOLID_STEPS do
			local d = step * i
			if d > dist then
				break
			end
			local p = from + dir * d
			local gy = groundAt(Vector3.new(p.X, from.Y, p.Z))
			if not gy then
				break
			end
			best = Vector3.new(p.X, gy, p.Z)
		end
		return best
	end
	local function clearLine(a, b)
		local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		local dist = flat.Magnitude
		if dist < 1 then
			return true
		end
		local dir = flat.Unit
		local step = math.max(dist / K.SOLID_STEPS, 20)
		for i = 1, K.SOLID_STEPS do
			local d = step * i
			if d >= dist then
				break
			end
			local p = a + dir * d
			if not groundAt(Vector3.new(p.X, a.Y, p.Z)) then
				return false
			end
		end
		return true
	end
	local function ringWaypoint(from, to)
		local mid = arenaCentre()
		if not mid then
			return nil
		end
		local a = Vector3.new(from.X - mid.X, 0, from.Z - mid.Z)
		local b = Vector3.new(to.X - mid.X, 0, to.Z - mid.Z)
		if a.Magnitude < 20 or b.Magnitude < 20 then
			return nil
		end
		local ang1, ang2 = math.atan2(a.Z, a.X), math.atan2(b.Z, b.X)
		local diff = ang2 - ang1
		while diff > math.pi do
			diff = diff - 2 * math.pi
		end
		while diff < - math.pi do
			diff = diff + 2 * math.pi
		end
		local step = math.min(math.abs(diff), math.rad(K.RING_STEP_DEG))
		if diff < 0 then
			step = - step
		end
		local want = ang1 + step
		for _, mul in ipairs(K.RING_RADII) do
			local r = a.Magnitude * mul
			local p = Vector3.new(mid.X + math.cos(want) * r, from.Y, mid.Z + math.sin(want) * r)
			local gy = groundAt(p)
			if gy then
				local wp = Vector3.new(p.X, gy, p.Z)
				if clearLine(from, wp) then
					return wp, math.deg(step)
				end
			end
		end
		return nil
	end
	local function rotated(dir, a)
		return Vector3.new(dir.X * math.cos(a) - dir.Z * math.sin(a), 0, dir.X * math.sin(a) + dir.Z * math.cos(a))
	end
	local function detourAround(from, to)
		if clearLine(from, to) then
			return nil
		end
		local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		local dist = flat.Magnitude
		if dist < 1 then
			return nil
		end
		local dir = flat.Unit
		local r = math.max(dist * K.AROUND_FRAC, K.AROUND_MIN_R)
		for _, deg in ipairs(K.AROUND_ANGLES) do
			for _, sign in ipairs({
				1,
				- 1
			}) do
				local wp = from + rotated(dir, math.rad(deg) * sign) * r
				local gy = groundAt(Vector3.new(wp.X, from.Y, wp.Z))
				if gy then
					wp = Vector3.new(wp.X, gy, wp.Z)
					if clearLine(from, wp) and clearLine(wp, to) then
						return wp, deg * sign
					end
				end
			end
		end
		for _, deg in ipairs(K.AROUND_ANGLES) do
			for _, sign in ipairs({
				1,
				- 1
			}) do
				local wp = from + rotated(dir, math.rad(deg) * sign) * r
				local gy = groundAt(Vector3.new(wp.X, from.Y, wp.Z))
				if gy and clearLine(from, Vector3.new(wp.X, gy, wp.Z)) then
					return Vector3.new(wp.X, gy, wp.Z), deg * sign
				end
			end
		end
		return nil
	end
	local function hazardParts()
		local now = os.clock()
		if S.hazards and (now - S.hazardsAt) < K.HAZARD_CACHE then
			return S.hazards
		end
		local out = {}
		local folder = workspace:FindFirstChild("BossHazards")
		if folder then
			for _, d in ipairs(folder:GetDescendants()) do
				if d:IsA("BasePart") then
					out[# out + 1] = d
				end
			end
		end
		local a = arena()
		if a then
			for _, name in ipairs({
				"SlamIndicator",
				"SlamArmHitbox",
				"SlamRestHitbox"
			}) do
				local d = a:FindFirstChild(name)
				if d and d:IsA("BasePart") then
					out[# out + 1] = d
				end
			end
		end
		local bh = workspace:FindFirstChild("BossBlackHole")
		if bh and bh:IsA("BasePart") then
			out[# out + 1] = bh
		end
		S.hazards, S.hazardsAt = out, now
		return out
	end
	local function hazardClear(part)
		local n = part.Name
		if n == "BossBlackHole" then
			return K.HOLE_CLEAR
		end
		if n:find("Slam") then
			return K.SLAM_CLEAR
		end
		if n:find("Ring") then
			return K.RING_CLEAR
		end
		return K.HAZARD_CLEAR
	end
	local function inHazard(part, pos, extra)
		local clear = hazardClear(part) + (extra or 0)
		if part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
			local flat = Vector3.new(pos.X - part.Position.X, 0, pos.Z - part.Position.Z)
			return flat.Magnitude <= part.Size.Y * 0.5 + clear
		end
		local rel = part.CFrame:PointToObjectSpace(pos)
		local half = part.Size * 0.5
		return math.abs(rel.X) <= half.X + clear and math.abs(rel.Z) <= half.Z + clear and math.abs(rel.Y) <= half.Y + 8
	end
	local function inAnyHazard(pos, extra)
		if not K.DODGE then
			return nil
		end
		for _, part in ipairs(hazardParts()) do
			if inHazard(part, pos, extra) then
				return part
			end
		end
		return nil
	end
	local function dodgeScore(spot, here)
		local aim = S.aim
		if typeof(aim) == "Vector3" then
			return Vector3.new(spot.X - aim.X, 0, spot.Z - aim.Z).Magnitude
		end
		return Vector3.new(spot.X - here.X, 0, spot.Z - here.Z).Magnitude
	end
	local function dodgeHazards()
		if not K.DODGE then
			S.dodge = nil
			return false
		end
		local h = ch.root()
		if not h then
			return false
		end
		local parts = hazardParts()
		if # parts == 0 then
			S.dodge = nil
			return false
		end
		local hit = nil
		for _, part in ipairs(parts) do
			if inHazard(part, h.Position) then
				hit = part
				break
			end
		end
		if not hit then
			S.dodge = nil
			return false
		end
		local here = h.Position
		local cands = {}
		if hit:IsA("Part") and hit.Shape == Enum.PartType.Cylinder then
			local want = hit.Size.Y * 0.5 + K.HOLE_CLEAR + 4
			for i = 0, K.DODGE_POINTS - 1 do
				local ang = (2 * math.pi / K.DODGE_POINTS) * i
				cands[# cands + 1] = Vector3.new(hit.Position.X + math.cos(ang) * want, here.Y, hit.Position.Z + math.sin(ang) * want)
			end
		else
			local rel = hit.CFrame:PointToObjectSpace(here)
			local half = hit.Size * 0.5
			local clear = hazardClear(hit) + 4
			local outX = (rel.X >= 0 and 1 or - 1) * (half.X + clear)
			local outZ = (rel.Z >= 0 and 1 or - 1) * (half.Z + clear)
			local cf = hit.CFrame
			cands[# cands + 1] = cf:PointToWorldSpace(Vector3.new(rel.X, rel.Y, outZ))
			cands[# cands + 1] = cf:PointToWorldSpace(Vector3.new(outX, rel.Y, rel.Z))
			cands[# cands + 1] = cf:PointToWorldSpace(Vector3.new(rel.X, rel.Y, - outZ))
			cands[# cands + 1] = cf:PointToWorldSpace(Vector3.new(- outX, rel.Y, rel.Z))
			cands[# cands + 1] = cf:PointToWorldSpace(Vector3.new(outX, rel.Y, outZ))
			cands[# cands + 1] = cf:PointToWorldSpace(Vector3.new(- outX, rel.Y, outZ))
		end
		local best, bestScore
		for _, spot in ipairs(cands) do
			if onFloor(spot) and not inAnyHazard(spot, 0) then
				local scr = dodgeScore(spot, here)
				if not bestScore or scr < bestScore then
					best, bestScore = spot, scr
				end
			end
		end
		if not best then
			for _, spot in ipairs(cands) do
				if onFloor(spot) then
					local scr = dodgeScore(spot, here)
					if not bestScore or scr < bestScore then
						best, bestScore = spot, scr
					end
				end
			end
		end
		if not best then
			local mid = arenaCentre()
			if mid then
				local inward = Vector3.new(mid.X - here.X, 0, mid.Z - here.Z)
				if inward.Magnitude > 1 then
					best = here + inward.Unit * math.min(inward.Magnitude, 60)
				end
			end
		end
		if not best then
			return true
		end
		S.dodge = {
			pos = best
		}
		stats.dodges = stats.dodges + 1
		return true
	end
	local function orbitPoint(tpos, reach)
		local h = ch.root()
		local bh = workspace:FindFirstChild("BossBlackHole")
		if not h or not bh or not bh:IsA("BasePart") then
			return nil
		end
		local toHole = Vector3.new(bh.Position.X - h.Position.X, 0, bh.Position.Z - h.Position.Z)
		if toHole.Magnitude > K.ORBIT_TRIGGER then
			return nil
		end
		local rel = Vector3.new(h.Position.X - tpos.X, 0, h.Position.Z - tpos.Z)
		if rel.Magnitude < 1 then
			rel = Vector3.new(1, 0, 0)
		end
		local ang = math.atan2(rel.Z, rel.X)
		local r = math.max(reach, 6)
		local function at(a)
			return Vector3.new(tpos.X + math.cos(a) * r, h.Position.Y, tpos.Z + math.sin(a) * r)
		end
		local p1, p2 = at(ang + K.ORBIT_STEP), at(ang - K.ORBIT_STEP)
		local function fromHole(p)
			return Vector3.new(p.X - bh.Position.X, 0, p.Z - bh.Position.Z).Magnitude
		end
		local first, second = p1, p2
		if fromHole(p2) > fromHole(p1) then
			first, second = p2, p1
		end
		if onFloor(first) then
			return first
		end
		if onFloor(second) then
			return second
		end
		return nil
	end
	local function isBatTool(t)
		return t:IsA("Tool") and (t:GetAttribute("IsBat") == true or t.Name:find("Bat") ~= nil)
	end
	local function equipBat()
		local char = ch.get()
		if not char then
			return nil
		end
		for _, t in ipairs(char:GetChildren()) do
			if isBatTool(t) then
				return t
			end
		end
		local bp = svc.LocalPlayer:FindFirstChild("Backpack")
		if bp then
			for _, t in ipairs(bp:GetChildren()) do
				if isBatTool(t) then
					local hum = ch.humanoid()
					local ok = hum and pcall(function()
						hum:EquipTool(t)
					end)
					if not ok or t.Parent ~= char then
						t.Parent = char
					end
					log.info("equipped %s", t.Name)
					return t
				end
			end
		end
		return nil
	end
	local batSeq, batAnimTrack, batAnimFor = 0, nil, nil
	local function batSwing(bat)
		local ok = pcall(function()
			local rem = net.find("RE/BatSwing/Trigger")
			assert(rem, "no BatSwing remote")
			batSeq = batSeq + 1
			rem:FireServer(nil, ("%d:%d:%d"):format(svc.LocalPlayer.UserId, batSeq, math.floor(workspace:GetServerTimeNow() * 1000)))
		end)
		if not ok then
			pcall(function()
				bat:Activate()
			end)
			return
		end
		pcall(function()
			local anim = bat:FindFirstChild("HitAnim")
			local hum = ch.humanoid()
			local animator = hum and hum:FindFirstChildOfClass("Animator")
			if anim and animator then
				if batAnimFor ~= animator then
					batAnimTrack = animator:LoadAnimation(anim)
					batAnimFor = animator
				end
				batAnimTrack:Play()
			end
			local snd = bat:FindFirstChild("Slash", true)
			if snd and snd:IsA("Sound") then
				snd:Play()
			end
		end)
	end
	local function readyAfterRagdoll()
		local hm, h = ch.humanoid(), ch.root()
		if not hm or not h then
			return
		end
		hm.PlatformStand = false
		hm.Sit = false
		hm.AutoRotate = true
		local st = hm:GetState()
		if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.PlatformStanding or st == Enum.HumanoidStateType.FallingDown or st == Enum.HumanoidStateType.Ragdoll or st == Enum.HumanoidStateType.Seated then
			hm:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
		h.AssemblyLinearVelocity = Vector3.zero
		h.AssemblyAngularVelocity = Vector3.zero
	end
	local function antiFling()
		local h, hum = ch.root(), ch.humanoid()
		if not h or not hum then
			return
		end
		local v = h.AssemblyLinearVelocity
		local flat = (v * Vector3.new(1, 0, 1)).Magnitude
		local cap = math.max((hum.WalkSpeed or 16) * K.FLING_MULT, 120)
		if v.Y <= K.FLING_UP and flat <= cap then
			return
		end
		local keep = Vector3.zero
		if flat > 0.001 then
			keep = (v * Vector3.new(1, 0, 1)).Unit * math.min(flat, hum.WalkSpeed or 16)
		end
		h.AssemblyLinearVelocity = Vector3.new(keep.X, math.min(v.Y, 0), keep.Z)
		h.AssemblyAngularVelocity = Vector3.zero
		stats.flings = stats.flings + 1
		every("fling", 2, "cancelled a launch (up %.0f, flat %.0f) - %d so far", v.Y, flat, stats.flings)
	end
	local function targetReach(part)
		if typeof(part) == "Vector3" then
			return K.REACH
		end
		if not (part and part:IsA("BasePart")) then
			return K.REACH
		end
		local half = math.max(part.Size.X, part.Size.Z) * 0.5
		return math.max(K.REACH, half + K.SURFACE_MARGIN)
	end
	local function target()
		local h = ch.root()
		if not h then
			return nil
		end
		local ph = phase()
		if not ph then
			return nil
		end
		if ph == "crystals" then
			local now = os.clock()
			if not S.towers or (now - S.towersAt) > K.TOWERS_TTL then
				local a = arena()
				local towers = a and a:FindFirstChild("CrystalTowers", true)
				local list = {}
				if towers then
					for _, d in ipairs(towers:GetDescendants()) do
						if d:IsA("BasePart") and d.Name == "Hitbox" then
							list[# list + 1] = d
						end
					end
				end
				S.towers, S.towersAt = list, now
			end
			local best, bestD, skipped = nil, nil, nil
			for _, d in ipairs(S.towers) do
				if d.Parent then
					local hp = d:GetAttribute("Health")
					if type(hp) == "number" and hp > 0 then
						if (S.skip[d] or 0) > now then
							skipped = d
						else
							local dist = (d.Position - h.Position).Magnitude
							if not bestD or dist < bestD then
								best, bestD = d, dist
							end
						end
					end
				end
			end
			best = best or skipped
			if best then
				return best, "crystal"
			end
			return nil
		end
		local b = bossModel()
		if not b then
			return nil
		end
		local myY = h.Position.Y
		local low, lowD, any, anyD, anyUp
		for _, bn in ipairs(K.HAND_BONES) do
			local bone = b:FindFirstChild(bn, true)
			if bone and bone:IsA("Bone") then
				local pos
				pcall(function()
					pos = bone.TransformedWorldCFrame.Position
				end)
				pos = pos or bone.WorldPosition
				if pos then
					local prev = S.handY[bn]
					S.handY[bn] = pos.Y
					local rising = prev ~= nil and (pos.Y - prev) > K.HAND_RISE_EPS
					if not rising then
						local flat = Vector3.new(pos.X - h.Position.X, 0, pos.Z - h.Position.Z).Magnitude
						if not anyD or flat < anyD then
							any, anyD, anyUp = pos, flat, pos.Y - myY
						end
						if (pos.Y - myY) <= K.HAND_REACH_Y and (not lowD or flat < lowD) then
							low, lowD = pos, flat
						end
					end
				end
			end
		end
		local function landable(p)
			if not p then
				return nil
			end
			if onFloor(p) and clearLine(h.Position, p) then
				return p
			end
			local wp, ang = ringWaypoint(h.Position, p)
			if not wp then
				wp, ang = detourAround(h.Position, p)
			end
			if wp then
				every("pit", 2, "pit in the way - walking round the ring (%+.0f deg)", ang or 0)
				return wp
			end
			return lastSolidToward(h.Position, p)
		end
		low = landable(low)
		if any and (anyUp or 0) <= K.HAND_CHASE_Y then
			any = landable(any)
		else
			any = nil
		end
		local now = os.clock()
		if S.handPick and (now - S.handPickAt) < K.HAND_COMMIT then
			local keep = S.handPick
			if (low and (low - keep).Magnitude < 220) or (any and (any - keep).Magnitude < 220) then
				return keep, "hand"
			end
		end
		if low then
			S.handPick, S.handPickAt = low, now
			return low, "hand"
		end
		if any then
			S.handPick, S.handPickAt = any, now
			return any, "hand"
		end
		if anyUp then
			every("high", 2, "hands up: nearest is %.0f studs up (need <= %d) - holding for the slam", anyUp, K.HAND_REACH_Y)
		end
		return nil
	end
	local function leaveArena()
		local a = arena()
		local exit = a and a:FindFirstChild("BossArenaLeaveTeleport", true)
		local part = exit and (exit:IsA("BasePart") and exit or exit:FindFirstChild("Hitbox", true) or exit:FindFirstChildWhichIsA("BasePart", true))
		local c = ch.get()
		if not (part and c) then
			return false
		end
		c:MoveTo(part.Position + Vector3.new(0, 3, 0))
		return true
	end
	local function setNoclip(on)
		if on == S.noclipped then
			return
		end
		S.noclipped = on
		if on then
			mov.noclip(true)
		elseif not auto.isRunning() then
			mov.noclip(false)
		end
	end
	local function skipTarget(why)
		local key = S.goalKey
		if typeof(key) == "Instance" then
			S.skip[key] = os.clock() + K.SKIP_FOR
			log.warn("fight: NEXT TARGET - skipping this crystal for %ds (%s)", K.SKIP_FOR, why)
		else
			S.holdUntil = math.max(S.holdUntil, os.clock() + K.SKIP_FOR / 3)
			log.warn("fight: holding %ds before chasing the hands again (%s)", math.floor(K.SKIP_FOR / 3), why)
		end
		S.goal, S.goalKey, S.backoffs, S.sidesteps, S.backoff = nil, nil, 0, 0, 0
	end
	local function noteSnap(kind)
		if not S or not S.inArena then
			return
		end
		local now = os.clock()
		for i = # S.snaps, 1, - 1 do
			if now - S.snaps[i] > K.SNAP_WINDOW then
				table.remove(S.snaps, i)
			end
		end
		S.snaps[# S.snaps + 1] = now
		if # S.snaps < K.SNAPS then
			return
		end
		S.snaps = {}
		S.backoff = math.min(S.backoff > 0 and S.backoff * 2 or K.BACKOFF_FIRST, K.BACKOFF_MAX)
		S.backoffs = S.backoffs + 1
		S.holdUntil = now + S.backoff
		S.goal, S.wrote = nil, nil
		stats.snapBackoffs = (stats.snapBackoffs or 0) + 1
		log.warn("fight: movement interrupted (%s x%d in %ds) - holding %.0fs (backoff %d/%d)", tostring(kind), K.SNAPS, K.SNAP_WINDOW, S.backoff, S.backoffs, K.SKIP_AFTER)
		readyAfterRagdoll()
		if S.backoffs >= K.SKIP_AFTER then
			skipTarget("server kept moving us back")
		end
	end
	local function moverStep(dt)
		if not S.inArena or auto.isRunning() or motion.blockedBy("bossfight") then
			return
		end
		if S.settleUntil and os.clock() < S.settleUntil then
			return
		end
		if os.clock() < S.holdUntil then
			return
		end
		do
			local hh, hmn = ch.root(), ch.humanoid()
			if hh and S.wrote and (os.clock() - (S.wroteAt or 0)) < 0.2 then
				if (hh.Position - S.wrote).Magnitude > K.SNAP_GAP then
					S.wrote = nil
					noteSnap("snap")
					return
				end
			end
			if hh and S.walking and S.lastPos then
				local reachable = math.max((hmn and hmn.WalkSpeed or 16) * math.min(dt, 0.1) * 3, 25)
				if (hh.Position - S.lastPos).Magnitude > reachable then
					S.lastPos = hh.Position
					noteSnap("walk snap")
					return
				end
			end
			S.lastPos = hh and hh.Position or nil
		end
		antiFling()
		local dodging = S.dodge ~= nil
		local goal = S.dodge or S.goal
		local h, hum = ch.root(), ch.humanoid()
		if not goal then
			if S.walking and h and hum then
				hum:MoveTo(h.Position)
				S.walking = false
			end
			return
		end
		if not h or not hum then
			return
		end
		if groundAt(h.Position) then
			S.lastSolid = h.Position
		elseif S.lastSolid then
			local back = Vector3.new(S.lastSolid.X - h.Position.X, 0, S.lastSolid.Z - h.Position.Z)
			if back.Magnitude > 1 then
				local st2 = math.min(back.Magnitude, math.min(dt, K.MAX_DT) * K.STEP_SPEED, K.MAX_STEP)
				local nb = h.Position + back.Unit * st2
				local gyb = groundAt(nb) or S.lastSolid.Y
				hum.PlatformStand = false
				h.CFrame = CFrame.lookAt(Vector3.new(nb.X, gyb, nb.Z), Vector3.new(nb.X, gyb, nb.Z) + back.Unit)
				S.wrote, S.wroteAt = Vector3.new(nb.X, gyb, nb.Z), os.clock()
				h.AssemblyLinearVelocity = Vector3.zero
				stats.rescues = stats.rescues + 1
				every("rescue", 1, "no ground underneath - walking back to solid")
			end
			return
		end
		local flat = Vector3.new(goal.pos.X - h.Position.X, 0, goal.pos.Z - h.Position.Z)
		local reach = dodging and 0 or (goal.reach or K.REACH)
		local left = flat.Magnitude - reach
		if left <= K.MOVE_ARRIVE then
			if dodging then
				S.dodge = nil
			else
				S.goal = nil
			end
			S.backoff, S.backoffs, S.sidesteps = 0, 0, 0
			trail("ARRIVED")
			return
		end
		local now = os.clock()
		if not S.stuckBest or left < S.stuckBest - 2 then
			S.stuckBest, S.stuckSince = left, now
		end
		local dirUse = flat.Unit
		if S.stuckSince and (now - S.stuckSince) > K.STUCK_TIME then
			S.stuckFlip = not S.stuckFlip
			local sgn = S.stuckFlip and 1 or - 1
			dirUse = Vector3.new(- flat.Unit.Z * sgn, 0, flat.Unit.X * sgn)
			S.stuckSince, S.stuckBest = now, nil
			S.sidesteps = S.sidesteps + 1
			every("stuck", 2, "not making progress - sidestepping (%d/%d)", S.sidesteps, K.SKIP_STUCK)
			if S.sidesteps >= K.SKIP_STUCK then
				skipTarget("no progress after " .. S.sidesteps .. " sidesteps")
				return
			end
		end
		local step = math.min(left, math.min(dt, K.MAX_DT) * K.STEP_SPEED, K.MAX_STEP)
		local nxt = h.Position + dirUse * step
		if not dodging and inAnyHazard(nxt, 0) then
			return
		end
		local function groundFor(dir, dist)
			local probe = h.Position + dir * dist
			return groundAt(Vector3.new(probe.X, h.Position.Y, probe.Z))
		end
		local gy = groundFor(dirUse, step)
		if gy then
			S.arenaFloorY = gy
		elseif S.arenaFloorY and h.Position.Y < S.arenaFloorY - K.SINK_MAX then
			h.CFrame = CFrame.new(h.Position.X, S.arenaFloorY, h.Position.Z)
			S.wrote, S.wroteAt = Vector3.new(h.Position.X, S.arenaFloorY, h.Position.Z), os.clock()
			h.AssemblyLinearVelocity = Vector3.zero
			every("sink", 2, "dropped below the floor - lifted back onto it")
			return
		end
		if not gy then
			local found = nil
			for _, deg in ipairs(K.RIM_SWEEP) do
				for _, sgn in ipairs(S.rimSide == - 1 and {
					- 1,
					1
				} or {
					1,
					- 1
				}) do
					local d = rotated(dirUse, math.rad(deg * sgn))
					local g = groundFor(d, step)
					if g and groundFor(d, step + K.RIM_LOOKAHEAD) then
						found, gy = d, g
						S.rimSide = sgn
						break
					end
				end
				if found then
					break
				end
			end
			if not found then
				if dodging then
					S.dodge = nil
				else
					S.goal = nil
				end
				return
			end
			dirUse = found
			nxt = h.Position + dirUse * step
			S.stuckSince = now
			every("rim", 2, "hole in the way - following the rim round")
		end
		hum.PlatformStand = false
		if K.WALK then
			local aim = h.Position + dirUse * math.min(left + 2, K.WALK_LOOKAHEAD)
			hum:MoveTo(Vector3.new(aim.X, gy, aim.Z))
			S.walking, S.wrote, S.wroteAt = true, nil, os.clock()
			return
		end
		local curY = h.Position.Y
		local k = 1 - math.exp(- dt / K.Y_TAU)
		local dest = Vector3.new(nxt.X, curY + (gy - curY) * k, nxt.Z)
		hum:Move(Vector3.zero, false)
		h.CFrame = CFrame.lookAt(dest, dest + flat.Unit)
		S.wrote, S.wroteAt = dest, os.clock()
		h.AssemblyLinearVelocity = Vector3.new(0, h.AssemblyLinearVelocity.Y, 0)
		h.AssemblyAngularVelocity = Vector3.zero
	end
	local function fightTick()
		local inside = inArena()
		if inside ~= S.inArena then
			S.inArena = inside
			setNoclip(inside)
			S.goal, S.dodge, S.aim, S.trackPos, S.handPick = nil, nil, nil, nil, nil
			S.lastSolid, S.arenaFloorY, S.left = nil, nil, false
			S.voidAnchor, S.voidMisses = nil, 0
			S.snaps, S.holdUntil, S.backoff, S.backoffs, S.sidesteps = {}, 0, 0, 0, 0
			S.wrote, S.goalKey, S.killClaimed, S.leaveTries, S.stage = nil, nil, false, 0, nil
			if inside then
				S.settleUntil = os.clock() + K.RESPAWN_SETTLE
				readyAfterRagdoll()
				motion.claim("bossfight")
				trail("EVENT", "entered the arena")
			else
				motion.release("bossfight")
			end
			log.info(inside and "in the arena - fighting" or "left the arena")
		end
		if not inside or auto.isRunning() then
			return
		end
		if S.settleUntil and os.clock() < S.settleUntil then
			return
		end
		local bat = equipBat()
		if not bat then
			if os.clock() - (S.batAskedAt or 0) > 5 then
				S.batAskedAt = os.clock()
				local okW, msgW = net.call("RF/Codex/AskWearFieldBat")
				log.info("no bat - AskWearFieldBat -> %s %s", tostring(okW), tostring(msgW or ""))
			end
		elseif S.batFor ~= bat then
			S.batFor = bat
			task.wait(K.EQUIP_SETTLE)
		end
		local hmz = ch.humanoid()
		if hmz then
			local stt = hmz:GetState()
			if hmz.PlatformStand or stt == Enum.HumanoidStateType.Physics or stt == Enum.HumanoidStateType.PlatformStanding or stt == Enum.HumanoidStateType.None then
				readyAfterRagdoll()
			end
		end
		local inHaz = dodgeHazards()
		local snap = boss.snapshot()
		local dead = snap and tonumber(snap.BossHealth) and snap.BossHealth <= 0
		if dead then
			S.goal, S.aim = nil, nil
			if not S.killClaimed then
				S.killClaimed = true
				stats.kills = stats.kills + 1
				trail("BOSS UPDATE", "boss dead")
				local n = boss.claimMilestones()
				log.info("boss dead - claimed %d milestone(s)", n)
			end
			local now = os.clock()
			if S.leaveTries < K.LEAVE_TRIES and (now - S.leaveAt) >= K.LEAVE_GAP then
				S.leaveTries, S.leaveAt = S.leaveTries + 1, now
				S.wrote = nil
				local okLeave = leaveArena()
				log.info("walking out of the arena (try %d/%d) -> %s", S.leaveTries, K.LEAVE_TRIES, tostring(okLeave))
			elseif S.leaveTries >= K.LEAVE_TRIES then
				every("leavefail", 15, "boss dead but still in the arena after %d walk-outs - holding", S.leaveTries)
			end
			S.left = true
			return
		elseif S.left then
			S.left, S.killClaimed, S.leaveTries = false, false, 0
		end
		local newPhase = phase()
		if newPhase ~= S.phase then
			trail(S.phase == nil and "BOSS FOUND" or "BOSS UPDATE", "phase " .. tostring(newPhase or "spawning"))
		end
		S.phase = newPhase
		if os.clock() < S.holdUntil then
			return
		end
		local part, kind = target()
		if part ~= nil and (typeof(part) == "Instance" and part or "hand") ~= S.goalKey then
			S.goalKey = (typeof(part) == "Instance") and part or "hand"
			S.backoff, S.backoffs, S.sidesteps = 0, 0, 0
			trail("NEXT TARGET", tostring(kind))
		end
		if not part then
			S.goal, S.aim, S.kind = nil, nil, nil
			if S.idlePhase ~= S.phase then
				S.idlePhase = S.phase
				log.info("nothing to hit (phase=%s) - holding position", tostring(S.phase or "spawning"))
			end
			return
		end
		S.idlePhase, S.kind = false, kind
		local tpos = (typeof(part) == "Vector3") and part or part.Position
		local h = ch.root()
		if not h then
			return
		end
		local reach = targetReach(part)
		local flatDir = Vector3.new(tpos.X - h.Position.X, 0, tpos.Z - h.Position.Z)
		local d = flatDir.Magnitude
		local stand = h.Position + (d > 0.001 and flatDir.Unit * math.max(d - reach, 0) or Vector3.zero)
		if inAnyHazard(Vector3.new(stand.X, h.Position.Y, stand.Z), 0) then
			S.waitAt = S.waitAt or os.clock()
			if os.clock() - S.waitAt < K.WAIT_MAX then
				S.goal = nil
				return
			end
		else
			S.waitAt = nil
		end
		S.aim = tpos
		if d > reach + K.SWING_SLACK then
			local smooth = tpos
			if kind == "hand" then
				local prev = S.trackPos
				if prev and (prev - tpos).Magnitude < K.TRACK_JUMP then
					smooth = prev:Lerp(tpos, 1 - math.exp(- K.TICK / K.TRACK_TAU))
				end
				S.trackPos = smooth
			else
				S.trackPos = nil
			end
			S.goal = {
				pos = smooth,
				reach = reach
			}
			trail("MOVING", tostring(kind))
			return
		end
		local orbit = orbitPoint(tpos, reach)
		if orbit then
			S.goal = {
				pos = orbit,
				reach = 0
			}
			every("orbit", 3, "black hole is on us - orbiting the target")
		else
			S.goal = nil
		end
		if inHaz then
			return
		end
		local flat = Vector3.new(tpos.X - h.Position.X, 0, tpos.Z - h.Position.Z)
		if flat.Magnitude > 0.1 then
			local wantDir = flat.Unit
			local haveDir = h.CFrame.LookVector * Vector3.new(1, 0, 1)
			haveDir = haveDir.Magnitude > 0.001 and haveDir.Unit or wantDir
			if haveDir:Dot(wantDir) < K.AIM_COS then
				local cur = h.CFrame
				h.CFrame = cur:Lerp(CFrame.lookAt(cur.Position, cur.Position + wantDir), K.AIM_EASE)
			end
		end
		if not bat or not bat.Parent then
			return
		end
		if bat:GetAttribute("CooldownActive") == true then
			return
		end
		if os.clock() - S.lastSwingAt < K.SWING_GAP then
			return
		end
		S.lastSwingAt = os.clock()
		batSwing(bat)
		stats.swings = stats.swings + 1
		trail("ATTACKING", tostring(kind))
		S.backoff, S.backoffs, S.sidesteps = 0, 0, 0
		if stats.swings % 20 == 1 then
			log.info("swinging at the %s (%d swings)", tostring(kind), stats.swings)
		end
	end
	local function voidTick()
		if not S.inArena then
			return
		end
		local c, h = ch.get(), ch.root()
		if not (c and h) then
			return
		end
		local pos = h.Position
		local gy = groundAt(pos)
		if gy and math.abs(pos.Y - gy) <= K.MAX_RISE then
			S.voidAnchor = Vector3.new(pos.X, gy, pos.Z)
			S.voidMisses = 0
			return
		end
		if not gy then
			S.voidMisses = S.voidMisses + 1
		else
			S.voidMisses = 0
		end
		local falling = S.voidAnchor and (pos.Y < S.voidAnchor.Y - K.VOID_DROP_PROOF)
		if S.voidMisses >= K.VOID_MISSES and falling then
			S.voidMisses = 0
			local back = S.voidAnchor or arenaCentre()
			if back then
				stats.voidSaves = stats.voidSaves + 1
				h.AssemblyLinearVelocity = Vector3.zero
				h.AssemblyAngularVelocity = Vector3.zero
				c:MoveTo(back)
				h.CFrame = CFrame.new(back)
				S.wrote, S.wroteAt = back, os.clock()
				log.info("voidwatch: off the floor at (%.0f, %.0f, %.0f) - pulled back (#%d)", pos.X, pos.Y, pos.Z, stats.voidSaves)
				task.wait(0.3)
			end
		end
	end
	function M.status()
		if not enabled then
			return {
				title = "Auto fight",
				body = "off"
			}
		end
		if auto.isRunning() then
			return {
				title = "Auto fight",
				body = "ON  \u{B7}  waiting for Auto Steal to finish"
			}
		end
		if not S.inArena then
			local held = boss.held()
			if held and held.Open == true then
				return {
					title = "Auto fight",
					body = boss.autoEnterOn() and "ON  \u{B7}  boss open - entering" or "ON  \u{B7}  boss open - press Enter or turn on Auto enter"
				}
			end
			return {
				title = "Auto fight",
				body = "ON  \u{B7}  waiting for the boss world to open"
			}
		end
		if S.left then
			return {
				title = "Auto fight",
				body = "Boss dead  \u{B7}  leaving"
			}
		end
		local ph = S.phase
		if not ph then
			return {
				title = "Auto fight",
				body = "In the arena  \u{B7}  boss spawning"
			}
		end
		local what = S.kind and ("hitting the " .. S.kind) or "holding"
		return {
			title = "Auto fight",
			body = ("Fighting  \u{B7}  %s  \u{B7}  %s  \u{B7}  %d swings"):format(ph, what, stats.swings)
		}
	end
	function M.setEnabled(on)
		on = on and true or false
		if on == enabled then
			return true
		end
		if not on then
			enabled = false
			motion.release("bossfight")
			if sc then
				sc:destroy()
				sc = nil
			end
			if S then
				S.goal, S.dodge, S.aim = nil, nil, nil
				setNoclip(false)
				BX.try("bossfight.offRestore", readyAfterRagdoll)
			end
			S = nil
			log.info("off (%d swings, %d kills this session)", stats.swings, stats.kills)
			return true
		end
		if not boss.isOn() then
			boss.setEnabled(true)
		end
		S = fresh()
		sc = BX.scope("features.bossfight")
		enabled = true
		sc:onFrame("mover", svc.RunService.Heartbeat, moverStep)
		sc:loop("fight", K.TICK, fightTick)
		sc:loop("void", K.VOID_GAP, voidTick)
		if K.DODGE then
			sc:loop("dodge", K.DODGE_GAP, function()
				if S.inArena then
					dodgeHazards()
				end
			end)
		end
		ch.onSpawn(sc, "bossfight.respawn", function()
			if not S then
				return
			end
			setNoclip(false)
			S.goal, S.dodge, S.aim, S.trackPos, S.batFor = nil, nil, nil, nil, nil
			S.lastSolid, S.arenaFloorY, S.left = nil, nil, false
			S.voidAnchor, S.voidMisses = nil, 0
			S.inArena, S.noclipped = false, false
			S.snaps, S.holdUntil, S.backoff, S.backoffs, S.sidesteps = {}, 0, 0, 0, 0
			S.wrote, S.goalKey, S.stage = nil, nil, nil
			motion.release("bossfight")
			S.settleUntil = os.clock() + K.RESPAWN_SETTLE
		end)
		motion.onRejected(sc, function(kind)
			if S and S.inArena and S.wroteAt and (os.clock() - S.wroteAt) < 0.5 then
				noteSnap(kind)
			end
		end)
		log.info("on (tick %.2fs, swing %.2fs, dodge %s) - waiting for the arena", K.TICK, K.SWING_GAP, K.DODGE and "on" or "off")
		return true
	end
	BX.onTeardown("bossfight", function()
		M.setEnabled(false)
	end)
	return M
end)
BX.module("features.prewarm", function(BX)
	local svc = BX.require("core.services")
	local log = BX.require("boot.log").for_module("prewarm")
	local M = {}
	local sc = nil
	local steps = {}
	local done = false
	function M.report()
		return table.clone(steps)
	end
	function M.isDone()
		return done
	end
	local function record(name, ms, detail)
		steps[# steps + 1] = {
			name = name,
			ms = ms,
			detail = detail
		}
	end
	function M.start()
		if sc then
			return false
		end
		sc = BX.scope("features.prewarm")
		sc:spawn("warm", function()
			local t0 = os.clock()
			local grab = BX.require("features.grab")
			svc.RunService.Heartbeat:Wait()
			BX.try("prewarm.prompts", function()
				local ms, n = grab.warmPrompts()
				record("prompts", ms, n .. " prompts")
			end)
			local plot = BX.require("features.plot")
			svc.RunService.Heartbeat:Wait()
			BX.try("prewarm.safeZone", function()
				local s0 = os.clock()
				local _, via = plot.safeZone()
				record("safeZone", (os.clock() - s0) * 1000, tostring(via))
			end)
			svc.RunService.Heartbeat:Wait()
			BX.try("prewarm.plotHome", function()
				local s0 = os.clock()
				local _, via = plot.home()
				record("plotHome", (os.clock() - s0) * 1000, tostring(via))
			end)
			local bait = BX.require("features.bait")
			svc.RunService.Heartbeat:Wait()
			BX.try("prewarm.baitArea", function()
				local s0 = os.clock()
				local area = bait.firstAreaId(6)
				record("baitArea", (os.clock() - s0) * 1000, tostring(area))
			end)
			local move = BX.require("features.movement")
			local ch = BX.require("core.character")
			svc.RunService.Heartbeat:Wait()
			BX.try("prewarm.ground", function()
				local hrp = ch.root()
				if not hrp then
					record("ground", 0, "no character")
					return
				end
				local s0 = os.clock()
				local y = move.groundY(hrp.Position)
				record("ground", (os.clock() - s0) * 1000, y and ("y=" .. ("%.0f"):format(y)) or "no hit")
			end)
			done = true
			local parts = {}
			local total = 0
			for _, s in ipairs(steps) do
				parts[# parts + 1] = ("%s=%.1fms(%s)"):format(s.name, s.ms, s.detail)
				total = total + s.ms
			end
			log.info("prewarmed in %.0fms wall, %.1fms of work: %s", (os.clock() - t0) * 1000, total, table.concat(parts, " "))
		end)
		return true
	end
	function M.stop()
		if not sc then
			return
		end
		sc:destroy()
		sc = nil
	end
	return M
end)

-- =========================================================
-- DHZ MERGE: funções novas portadas do build mais recente
-- Mantém a GUI/Steal Panel antigo; somente adiciona extras.
-- =========================================================
BX.module("features.newextras", function(BX)
	local svc = BX.require("core.services")
	local net = BX.require("core.net")
	local data = BX.require("core.data")
	local log = BX.require("boot.log").for_module("newextras")
	local M = {}

	local state = {
		autoSellPets = false,
		autoSellEggs = false,
		autoFuse = false,
		autoFavoriteEquipped = false,
		autoBuyTrail = false,
		autoUpgradeBase = false,
		autoUpgradeTreadmill = false,
		autoClaim = false,
		infiniteJump = false,
		instantPrompts = false,
		antiAfk = false,
		autoRejoin = false,
	}
	M.state = state

	local last = {
		sellPets = 0,
		sellEggs = 0,
		fuse = 0,
		favorite = 0,
		trail = 0,
		base = 0,
		treadmill = 0,
		claim = 0,
		codex = 0,
		rejoin = 0,
	}
	local trailBlocked = {}
	local promptOriginal = setmetatable({}, {__mode = "k"})
	local sc = BX.scope("features.newextras")

	local function saveData()
		local save = data.save()
		if type(save) ~= "table" then return nil end
		local getter = type(save.Get) == "function" and save.Get or save.Peek
		if type(getter) ~= "function" then return nil end
		local ok, result = pcall(getter)
		return ok and type(result) == "table" and result or nil
	end

	local function requirePath(...)
		local node = svc.ReplicatedStorage
		for _, name in ipairs({...}) do
			node = node and node:FindFirstChild(name)
		end
		if not (node and node:IsA("ModuleScript")) then return nil end
		local ok, result = pcall(require, node)
		return ok and result or nil
	end

	local function rarityOf(category)
		local assets = data.assets()
		local directory = type(assets) == "table" and assets.Directory or nil
		local row = type(directory) == "table" and directory[tostring(category)] or nil
		local rarity = type(row) == "table" and row.Rarity or nil
		local n = type(rarity) == "table" and tonumber(rarity.RarityNumber or rarity.Rank) or nil
		return n or math.huge
	end

	local function hasMutation(item)
		if type(item) ~= "table" then return false end
		if type(item.BaseMutation) == "string" and item.BaseMutation ~= "" then
			return true
		end
		return type(item.Mutations) == "table" and next(item.Mutations) ~= nil
	end

	local function equippedSet(save)
		local out = {}
		for _, uid in pairs(type(save) == "table" and (save.EquippedAssets or {}) or {}) do
			out[uid] = true
		end
		return out
	end

	local function sendSell(assets, eggs)
		assets = type(assets) == "table" and assets or {}
		eggs = type(eggs) == "table" and eggs or {}
		if #assets == 0 and #eggs == 0 then return false, "nothing to sell" end
		local batch = 50
		local maxN = math.max(#assets, #eggs)
		for i = 1, maxN, batch do
			local a, e = {}, {}
			for j = i, math.min(i + batch - 1, maxN) do
				if assets[j] then a[#a + 1] = assets[j] end
				if eggs[j] then e[#e + 1] = eggs[j] end
			end
			local ok, why = net.fire("RE/PetSatchel/SellSelection", {Eggs = e, Assets = a})
			if not ok then return false, why end
			if i + batch <= maxN then task.wait(0.25) end
		end
		return true
	end

	function M.sellPetsNow()
		local save = saveData()
		if not save then return false, "save unavailable" end
		local equipped = equippedSet(save)
		local ids = {}
		for uid, item in pairs(save.Inventory or {}) do
			if type(item) == "table"
				and item.InFuse ~= true
				and item.IsFavorite ~= true
				and not equipped[uid]
				and not hasMutation(item)
				and rarityOf(item.Category) <= 3
			then
				ids[#ids + 1] = uid
			end
		end
		return sendSell(ids, {})
	end

	function M.sellEggsNow()
		local eggState = data.eggState()
		if type(eggState) ~= "table" or type(eggState.ReadOwnerEggs) ~= "function" then
			return false, "egg state unavailable"
		end
		local ok, owned = pcall(eggState.ReadOwnerEggs, svc.LocalPlayer.UserId)
		if not ok or type(owned) ~= "table" then
			return false, "egg inventory unavailable"
		end
		local carriedUid
		local character = svc.LocalPlayer.Character
		local tool = character and character:FindFirstChildWhichIsA("Tool")
		if tool then carriedUid = tool:GetAttribute("UID") end
		local ids = {}
		for uid, item in pairs(owned) do
			if type(item) == "table"
				and item.Placement == nil
				and uid ~= carriedUid
				and not hasMutation(item)
				and rarityOf(item.AssetCategory) <= 3
			then
				ids[#ids + 1] = uid
			end
		end
		return sendSell({}, ids)
	end

	function M.favoriteEquippedNow(value)
		local save = saveData()
		if not save then return false, "save unavailable" end
		local inventory = save.Inventory or {}
		local sent = 0
		for _, uid in pairs(save.EquippedAssets or {}) do
			local item = inventory[uid]
			if type(item) == "table" then
				if value == false or item.IsFavorite ~= true then
					local ok = net.fire("RE/PetSatchel/WriteFavourite", uid, value ~= false)
					if ok then sent += 1 end
					task.wait(0.08)
				end
			end
		end
		return sent > 0, sent
	end

	function M.fuseNow()
		local save = saveData()
		if not save then return false, "save unavailable" end
		if save.FusionLocked == true then
			if type(save.FusionEggReward) == "table" then
				local r = net.call("RF/Fusery/FinishReveal")
				return r ~= false, "finish reveal"
			end
			return false, "fusion busy"
		end
		local equipped = equippedSet(save)
		local groups = {}
		for uid, item in pairs(save.Inventory or {}) do
			if type(item) == "table"
				and item.InFuse ~= true
				and item.IsFavorite ~= true
				and not equipped[uid]
				and not hasMutation(item)
				and rarityOf(item.Category) <= 3
			then
				local cat = tostring(item.Category)
				groups[cat] = groups[cat] or {}
				groups[cat][#groups[cat] + 1] = uid
			end
		end
		local chosen
		for _, ids in pairs(groups) do
			if #ids >= 3 then chosen = ids break end
		end
		if not chosen then return false, "no 3 matching pets" end
		for i = 1, 3 do
			local r = net.call("RF/Fusery/LoadPet", chosen[i])
			if r == false then return false, "load pet failed" end
			task.wait(0.3)
		end
		local r = net.call("RF/Fusery/BeginFuse")
		return r ~= false, "fuse started"
	end

	function M.buyTrailNow()
		local save = saveData()
		if not save then return false, "save unavailable" end
		local trails = requirePath("Data", "Trails")
		local directory = type(trails) == "table" and trails.Directory or nil
		if type(directory) ~= "table" then return false, "trails unavailable" end
		local inv = type(save.TrailInventory) == "table" and save.TrailInventory or {}
		local money = tonumber(save.Money) or 0
		local rows = {}
		for key, row in pairs(directory) do
			if type(row) == "table" then
				rows[#rows + 1] = {id = tostring(row._id or key), price = tonumber(row.Price) or math.huge}
			end
		end
		table.sort(rows, function(a,b) return a.price < b.price end)
		for _, row in ipairs(rows) do
			if inv[row.id] ~= true and not trailBlocked[row.id] and row.price <= money then
				local r = net.call("RF/Trailwear/AskPurchase", row.id)
				if r ~= false then return true, row.id end
				trailBlocked[row.id] = true
				return false, "purchase refused"
			end
		end
		return false, "nothing affordable"
	end

	function M.upgradeBaseNow()
		local save = saveData()
		if not save then return false, "save unavailable" end
		local bases = data.bases() or requirePath("Data", "Bases")
		local rows = type(bases) == "table" and bases.BASES or nil
		if type(rows) ~= "table" then return false, "bases unavailable" end
		local level = tonumber(save.BaseUpgradeLevel) or 0
		local nextRow = rows[level + 1]
		local cost = type(nextRow) == "table" and tonumber(nextRow.Cost) or nil
		if not cost or (tonumber(save.Money) or 0) < cost then
			return false, "not affordable"
		end
		return net.fire("RE/Homestead/AskBaseTierRaise")
	end

	function M.upgradeTreadmillNow()
		local save = saveData()
		if not save then return false, "save unavailable" end
		local treadmills = requirePath("Data", "Treadmills")
		if type(treadmills) ~= "table" or type(treadmills.GetByUpgradeLevel) ~= "function" then
			return false, "treadmills unavailable"
		end
		local ok, row = pcall(treadmills.GetByUpgradeLevel, (tonumber(save.TreadmillUpgradeLevel) or 0) + 1)
		if not ok or type(row) ~= "table" then return false, "max level" end
		local id = row._id
		local price = tonumber(row.Price) or math.huge
		if type(id) ~= "string" or (tonumber(save.Money) or 0) < price then
			return false, "not affordable"
		end
		local r = net.call("RF/Treadmill/AskTierRaise", id)
		return r ~= false, id
	end

	function M.claimNow()
		local did = false
		local save = saveData()
		local pending = save and tonumber(save.PendingOfflineMoney) or nil
		if pending == nil then
			local r = net.call("RF/AwayEarnings/PendingCheck")
			pending = (r ~= false and r ~= nil) and 1 or 0
		end
		if pending and pending > 0 then
			local r = net.call("RF/AwayEarnings/AskCollect")
			did = did or r ~= false
		end
		local r1 = net.call("RF/Codex/AskRedeemAll")
		local r2 = net.call("RF/Codex/AskRedeemLimitedEgg")
		did = did or r1 ~= false or r2 ~= false
		return did
	end

	local function setPromptInstant(prompt)
		if not (prompt and prompt:IsA("ProximityPrompt")) then return end
		if promptOriginal[prompt] == nil then
			promptOriginal[prompt] = prompt.HoldDuration
		end
		pcall(function() prompt.HoldDuration = 0 end)
	end

	local function restorePrompts()
		for prompt, duration in pairs(promptOriginal) do
			if prompt and prompt.Parent then
				pcall(function() prompt.HoldDuration = duration end)
			end
		end
		table.clear(promptOriginal)
	end

	function M.set(key, value)
		if state[key] == nil then return false end
		value = value == true
		state[key] = value
		if key == "instantPrompts" then
			if value then
				for _, obj in ipairs(workspace:GetDescendants()) do
					if obj:IsA("ProximityPrompt") then setPromptInstant(obj) end
				end
			else
				restorePrompts()
			end
		elseif key == "autoBuyTrail" and value then
			table.clear(trailBlocked)
		end
		return true
	end

	function M.get(key)
		return state[key] == true
	end

	sc:connect(svc.UserInputService.JumpRequest, function()
		if not state.infiniteJump then return end
		local character = svc.LocalPlayer.Character
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 then
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
		end
	end)

	local ProximityPromptService = game:GetService("ProximityPromptService")
	sc:connect(ProximityPromptService.PromptShown, function(prompt)
		if state.instantPrompts then setPromptInstant(prompt) end
	end)

	sc:connect(svc.LocalPlayer.Idled, function()
		if not state.antiAfk then return end
		pcall(function()
			local vu = game:GetService("VirtualUser")
			vu:CaptureController()
			vu:ClickButton2(Vector2.new(0, 0))
		end)
	end)

	local GuiService = game:GetService("GuiService")
	sc:connect(GuiService.ErrorMessageChanged, function(msg)
		if not state.autoRejoin or type(msg) ~= "string" or msg == "" then return end
		if os.clock() - last.rejoin < 8 then return end
		last.rejoin = os.clock()
		task.delay(2, function()
			if state.autoRejoin and BX.alive() then
				pcall(function()
					svc.TeleportService:Teleport(game.PlaceId, svc.LocalPlayer)
				end)
			end
		end)
	end)

	sc:loop("workers", 0.8, function()
		local now = os.clock()
		if state.autoSellPets and now - last.sellPets >= 3 then
			last.sellPets = now
			pcall(M.sellPetsNow)
		end
		if state.autoSellEggs and now - last.sellEggs >= 3 then
			last.sellEggs = now
			pcall(M.sellEggsNow)
		end
		if state.autoFuse and now - last.fuse >= 4 then
			last.fuse = now
			pcall(M.fuseNow)
		end
		if state.autoFavoriteEquipped and now - last.favorite >= 2 then
			last.favorite = now
			pcall(M.favoriteEquippedNow, true)
		end
		if state.autoBuyTrail and now - last.trail >= 2 then
			last.trail = now
			pcall(M.buyTrailNow)
		end
		if state.autoUpgradeBase and now - last.base >= 2 then
			last.base = now
			pcall(M.upgradeBaseNow)
		end
		if state.autoUpgradeTreadmill and now - last.treadmill >= 2 then
			last.treadmill = now
			pcall(M.upgradeTreadmillNow)
		end
		if state.autoClaim and now - last.claim >= 5 then
			last.claim = now
			pcall(M.claimNow)
		end
	end)

	BX.onTeardown("newextras.restorePrompts", restorePrompts)
	return M
end)

BX.module("features.targetline", function(BX)
	local svc = BX.require("core.services")
	local ch = BX.require("core.character")
	local eggs = BX.require("features.eggs")
	local plot = BX.require("features.plot")
	local M = {}
	local sc, beam, p0, p1, a0, a1
	local selectedUid, returning = nil, false
	local function cleanup()
		if sc then
			pcall(function()
				sc:destroy()
			end)
			sc = nil
		end
		for _, x in ipairs({
			beam,
			p0,
			p1
		}) do
			if x then
				pcall(function()
					x:Destroy()
				end)
			end
		end
		beam, p0, p1, a0, a1 = nil, nil, nil, nil, nil
	end
	local function makePoint(name)
		local p = Instance.new("Part")
		p.Name = name;
		p.Size = Vector3.new(.2, .2, .2);
		p.Anchored = true
		p.CanCollide = false;
		p.CanTouch = false;
		p.CanQuery = false;
		p.Transparency = 1;
		p.Parent = workspace
		local a = Instance.new("Attachment");
		a.Parent = p
		return p, a
	end
	local function ensure()
		if beam and beam.Parent then
			return
		end
		p0, a0 = makePoint("DhzLineStart");
		p1, a1 = makePoint("DhzLineEnd")
		beam = Instance.new("Beam");
		beam.Name = "DhzSelectedEggLine"
		beam.Attachment0 = a0;
		beam.Attachment1 = a1;
		beam.FaceCamera = true
		beam.Color = ColorSequence.new(Color3.fromRGB(255, 0, 0));
		beam.Width0 = .12;
		beam.Width1 = .12
		beam.LightEmission = 1;
		beam.Transparency = NumberSequence.new(.05);
		beam.Parent = p0
	end
	function M.setSelected(uid)
		selectedUid = uid;
		returning = false;
		ensure()
	end
	function M.setReturning(on)
		returning = on and true or false;
		ensure()
	end
	function M.clear()
		selectedUid = nil;
		returning = false;
		cleanup()
	end
	local function update()
		if not selectedUid then
			return
		end
		ensure()
		local root = ch.root()
		if not root then
			beam.Enabled = false;
			return
		end
		local dest
		if returning then
			dest = select(1, plot.safeZone())
		else
			local e = eggs.get(selectedUid);
			dest = e and e.pos
		end
		if not dest then
			beam.Enabled = false;
			return
		end
		p0.CFrame = CFrame.new(root.Position);
		p1.CFrame = CFrame.new(dest);
		beam.Enabled = true
	end
	function M.start()
		if sc then
			return
		end
		sc = BX.scope("features.targetline")
		sc:onFrame("update", svc.RunService.Heartbeat, update)
	end
	M.start()
	BX.onTeardown("targetline", cleanup)
	return M
end)
do
	local logmod = BX.require("boot.log")
	logmod.level = BX.require("core.config").LOG_LEVEL
	local log = logmod.for_module("startup")
	logmod.session(("DhzHub %s build %s | generation %d") :format(BX.version, BX.build, BX.generation))
	local startup = {
		state = "BOOTING",
		stages = {},
		t0 = os.clock()
	}
	local env = (type(getgenv) == "function" and getgenv()) or _G
	env.DhzStartup = startup
	local function setState(s)
		startup.state = s
		log.info("state -> %s", s)
	end
	local function record(name, result, detail, ms)
		startup.stages[# startup.stages + 1] = {
			name = name,
			result = result,
			detail = detail,
			at = os.clock() - startup.t0,
			ms = ms,
		}
		local line = ("stage %-14s %6.0fms  %s%s"):format(name, ms or 0, result, detail and (": " .. tostring(detail)) or "")
		if result == "FAILED" then
			log.error("%s", line)
		elseif result == "FALLBACK" then
			log.warn("%s", line)
		else
			log.info("%s", line)
		end
	end
	local function stage(name, required, fn)
		local s0 = os.clock()
		local ok, res = pcall(fn)
		local ms = (os.clock() - s0) * 1000
		if ok then
			record(name, res == "FALLBACK" and "FALLBACK" or "OK", type(res) == "string" and res ~= "FALLBACK" and res or nil, ms)
			return true, res
		end
		record(name, "FAILED", res, ms)
		if required then
			startup.failedAt = name
			startup.error = tostring(res)
		end
		return false, res
	end
	setState("BOOTING")
	if not stage("services", true, function()
		BX.require("core.services")
	end) then
		warn("[DHZ] startup failed at services: " .. tostring(startup.error))
		warn("[DHZ] see DhzHub_trace.txt")
		return
	end
	stage("exec", false, function()
		BX.require("core.exec")
	end)
	stage("device", false, function()
		BX.require("core.device")
	end)
	stage("state", false, function()
		BX.require("core.state")
	end)
	stage("util", false, function()
		BX.require("core.util")
	end)
	stage("character", false, function()
		BX.require("core.character")
	end)
	setState("LOADING")
	local splash = {
		step = function()
		end,
		discord = function()
		end,
		fail = function()
		end,
		done = function()
		end,
		isWaitingForUser = function()
			return false
		end,
		whenClosed = function(fn)
			pcall(fn)
		end,
	}
	splash.step("Checking your game", 0.25)
	stage("eggs", false, function()
		local eggs = BX.require("features.eggs")
		if not eggs.ready then
			return "FALLBACK"
		end
	end)
	setState("UI_BUILDING")
	splash.step("Loading interface", 0.45)
	local win
	stage("direct ui", false, function()
		win = BX.require("ui.window")
		if not win.ok then
			return "FALLBACK"
		end
	end)
	stage("hide menu", false, function()
		if win and win.ok and type(win.hide) == "function" then
			if not win.hide() then
				return "FALLBACK"
			end
		end
	end)
	local dhzGui
	local function buildDhzPanel()
		if dhzGui and dhzGui.Parent then
			dhzGui:Destroy()
		end
		local Players = game:GetService("Players")
		local UIS = game:GetService("UserInputService")
		local TweenService = game:GetService("TweenService")
		local localPlayer = Players.LocalPlayer
		local parent = localPlayer:WaitForChild("PlayerGui")
		pcall(function()
			local ex = BX.require("core.exec")
			if type(ex) == "table" and type(ex.hiddenParent) == "function" then
				local hp = ex.hiddenParent()
				if hp then parent = hp end
			end
		end)
		local eggs = BX.require("features.eggs")
		local data = BX.require("core.data")
		local auto = BX.require("features.autosteal")
		local targetline = BX.require("features.targetline")
		local extras = BX.require("features.newextras")
		dhzGui = Instance.new("ScreenGui")
		dhzGui.Name = "DHZ_HUB_GUI"
		dhzGui.ResetOnSpawn = false
		dhzGui.IgnoreGuiInset = true
		dhzGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		dhzGui.Parent = parent

		-- DHZ HUB: portrait pet-list UI. Gameplay modules are preserved verbatim.
		local COLORS = {
			panel = Color3.fromRGB(15, 18, 20),
			panel2 = Color3.fromRGB(23, 26, 29),
			card = Color3.fromRGB(26, 30, 33),
			card2 = Color3.fromRGB(36, 32, 33),
			soft = Color3.fromRGB(23, 27, 29),
			accent = Color3.fromRGB(255, 72, 43),
			text = Color3.fromRGB(235, 237, 239),
			muted = Color3.fromRGB(123, 128, 133),
			green = Color3.fromRGB(109, 182, 144),
			red = Color3.fromRGB(239, 82, 63),
			stroke = Color3.fromRGB(90, 34, 30),
		}

		local SoundService = game:GetService("SoundService")
		local uiSound = Instance.new("Sound")
		uiSound.Name = "DHZ_UI_SFX"
		uiSound.SoundId = "rbxassetid://12221967"
		uiSound.Volume = 0.14
		uiSound.Parent = SoundService

		BX.onTeardown("dhz.ui.sfx", function()
			pcall(function()
				uiSound:Destroy()
			end)
		end)

		local function playUISound(speed, volume)
			pcall(function()
				uiSound:Stop()
				uiSound.TimePosition = 0
				uiSound.PlaybackSpeed = speed or 1
				uiSound.Volume = math.min(volume or 0.14, 0.18)
				uiSound:Play()
			end)
		end

		local panel = Instance.new("Frame")
		panel.Name = "DHZ_PET_LIST"
		panel.Size = UDim2.fromOffset(260, 414)
		panel.Position = UDim2.fromOffset(math.max(8, ((workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.X) or 800) - 402), math.max(8, math.min(104, ((workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y) or 600) - 280)))
		panel.BackgroundColor3 = COLORS.panel
		panel.BackgroundTransparency = 0
		panel.BorderSizePixel = 0
		panel.Active = true
		panel.ClipsDescendants = true
		panel.Parent = dhzGui

		local panelCorner = Instance.new("UICorner")
		panelCorner.CornerRadius = UDim.new(0, 13)
		panelCorner.Parent = panel

		local panelStroke = Instance.new("UIStroke")
		panelStroke.Color = COLORS.stroke
		panelStroke.Thickness = 2
		panelStroke.Transparency = 0.15
		panelStroke.Parent = panel

		local panelScale = Instance.new("UIScale")
		panelScale.Scale = 1
		panelScale.Parent = panel
		-- Image game area is 691 x 664; the panel is approximately 260 x 414.
		local function fittedScale()
			local view = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
			return math.max(0.1, math.min(1, view.Y / 664, (view.X - 24) / 260))
		end
		local baseScale = fittedScale()
		panelScale.Scale = baseScale
		do
			local view = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
			panel.Position = UDim2.fromOffset(math.max(8, view.X - 260 * baseScale - 24 * baseScale), math.max(8, 10 * baseScale))
		end

		local accentLine = Instance.new("Frame")
		accentLine.Size = UDim2.fromOffset(3, 34)
		accentLine.Position = UDim2.fromOffset(16, 27)
		accentLine.BackgroundColor3 = COLORS.accent
		accentLine.BorderSizePixel = 0
		accentLine.Visible = false
		accentLine.Parent = panel

		local accentCorner = Instance.new("UICorner")
		accentCorner.CornerRadius = UDim.new(1, 0)
		accentCorner.Parent = accentLine

		local header = Instance.new("Frame")
		header.Name = "DragHeader"
		header.Size = UDim2.new(1, -12, 0, 56)
		header.Position = UDim2.fromOffset(6, 6)
		header.BackgroundColor3 = COLORS.panel2
		header.BackgroundTransparency = 0
		header.BorderSizePixel = 0
		header.Active = true
		header.Parent = panel

		local headerCorner = Instance.new("UICorner")
		headerCorner.CornerRadius = UDim.new(0, 11)
		headerCorner.Parent = header
		do
			local edge = Instance.new("UIStroke")
			edge.Color = Color3.fromRGB(40, 43, 46)
			edge.Transparency = 0.4
			edge.Parent = header
		end

		local avatar = Instance.new("ImageLabel")
		avatar.Name = "ProfilePhoto"
		avatar.Size = UDim2.fromOffset(36, 36)
		avatar.Position = UDim2.new(1, -82, 0, 12)
		avatar.BackgroundColor3 = COLORS.soft
		avatar.BorderSizePixel = 0
		avatar.Image = "rbxassetid://81245576355054"
		avatar.ScaleType = Enum.ScaleType.Crop
		avatar.Visible = false
		avatar.Parent = header

		local avatarCorner = Instance.new("UICorner")
		avatarCorner.CornerRadius = UDim.new(0, 10)
		avatarCorner.Parent = avatar

		local title = Instance.new("TextLabel")
		title.Size = UDim2.new(1, 0, 0, 24)
		title.Position = UDim2.fromOffset(0, 9)
		title.BackgroundTransparency = 1
		title.Text = '<font color="#FF482B">DHZ</font> HUB'
		title.TextColor3 = COLORS.text
		title.TextSize = 18
		title.Font = Enum.Font.GothamBold
		title.TextXAlignment = Enum.TextXAlignment.Center
		title.RichText = true
		title.Parent = header

		local subtitle = Instance.new("TextLabel")
		subtitle.Size = UDim2.new(1, -76, 0, 11)
		subtitle.Position = UDim2.fromOffset(0, 6)
		subtitle.BackgroundTransparency = 1
		subtitle.Text = "PAINEL  /  01"
		subtitle.TextColor3 = COLORS.muted
		subtitle.TextSize = 12
		subtitle.Font = Enum.Font.GothamMedium
		subtitle.TextXAlignment = Enum.TextXAlignment.Left
		subtitle.Visible = false
		subtitle.Parent = header

		local closeBtn = Instance.new("TextButton")
		closeBtn.Size = UDim2.fromOffset(28, 36)
		closeBtn.Position = UDim2.new(1, -28, 0.5, -18)
		closeBtn.BackgroundColor3 = COLORS.soft
		closeBtn.BackgroundTransparency = 0.8
		closeBtn.BorderSizePixel = 0
		closeBtn.Text = "×"
		closeBtn.TextColor3 = COLORS.muted
		closeBtn.TextSize = 16
		closeBtn.Font = Enum.Font.GothamBold
		closeBtn.AutoButtonColor = false
		closeBtn.Visible = false
		closeBtn.Parent = header

		local closeCorner = Instance.new("UICorner")
		closeCorner.CornerRadius = UDim.new(0, 8)
		closeCorner.Parent = closeBtn

		local selectedCard = Instance.new("Frame")
		selectedCard.Name = "SelectedCard"
		selectedCard.Size = UDim2.new(1, -28, 0, 76)
		selectedCard.Position = UDim2.fromOffset(14, 86)
		selectedCard.BackgroundColor3 = COLORS.card
		selectedCard.BackgroundTransparency = 0.08
		selectedCard.BorderSizePixel = 0
		selectedCard.Visible = false
		selectedCard.Parent = panel

		local selectedCorner = Instance.new("UICorner")
		selectedCorner.CornerRadius = UDim.new(0, 10)
		selectedCorner.Parent = selectedCard

		local selectedPreview = Instance.new("ImageLabel")
		selectedPreview.Name = "SelectedPreview"
		selectedPreview.Size = UDim2.fromOffset(56, 56)
		selectedPreview.Position = UDim2.fromOffset(10, 10)
		selectedPreview.BackgroundColor3 = Color3.fromRGB(10, 7, 9)
		selectedPreview.BorderSizePixel = 0
		selectedPreview.ScaleType = Enum.ScaleType.Fit
		selectedPreview.Image = "rbxassetid://81245576355054"
		selectedPreview.Parent = selectedCard

		local selectedPreviewCorner = Instance.new("UICorner")
		selectedPreviewCorner.CornerRadius = UDim.new(0, 10)
		selectedPreviewCorner.Parent = selectedPreview

		local selectedName = Instance.new("TextLabel")
		selectedName.Size = UDim2.new(1, -184, 0, 19)
		selectedName.Position = UDim2.fromOffset(76, 31)
		selectedName.BackgroundTransparency = 1
		selectedName.Text = "No target"
		selectedName.TextColor3 = COLORS.text
		selectedName.TextSize = 15
		selectedName.Font = Enum.Font.GothamBold
		selectedName.TextXAlignment = Enum.TextXAlignment.Left
		selectedName.TextTruncate = Enum.TextTruncate.AtEnd
		selectedName.Parent = selectedCard

		local selectedRarity = Instance.new("TextLabel")
		selectedRarity.Size = UDim2.new(1, -178, 0, 13)
		selectedRarity.Position = UDim2.fromOffset(76, 51)
		selectedRarity.BackgroundTransparency = 1
		selectedRarity.Text = "choose a target"
		selectedRarity.TextColor3 = COLORS.muted
		selectedRarity.TextSize = 12
		selectedRarity.Font = Enum.Font.GothamMedium
		selectedRarity.TextXAlignment = Enum.TextXAlignment.Left
		selectedRarity.Parent = selectedCard

		local selectedValue = Instance.new("TextLabel")
		selectedValue.Size = UDim2.fromOffset(70, 18)
		selectedValue.Position = UDim2.new(1, -104, 0, 32)
		selectedValue.BackgroundTransparency = 1
		selectedValue.Text = "--"
		selectedValue.TextColor3 = COLORS.green
		selectedValue.TextSize = 14
		selectedValue.Font = Enum.Font.GothamBold
		selectedValue.TextXAlignment = Enum.TextXAlignment.Right
		selectedValue.Parent = selectedCard

		local listExpanded = true
		local listArrow = Instance.new("TextButton")
		listArrow.Name = "ListToggle"
		listArrow.Size = UDim2.fromOffset(26, 26)
		listArrow.Position = UDim2.new(1, -30, 0, 4)
		listArrow.BackgroundColor3 = COLORS.soft
		listArrow.BorderSizePixel = 0
		listArrow.AutoButtonColor = false
		listArrow.Text = ""
		listArrow.TextColor3 = COLORS.text
		listArrow.TextSize = 8
		listArrow.Font = Enum.Font.GothamBold
		listArrow.Parent = selectedCard

		local listArrowCorner = Instance.new("UICorner")
		listArrowCorner.CornerRadius = UDim.new(1, 0)
		listArrowCorner.Parent = listArrow

		local scroll = Instance.new("ScrollingFrame")
		scroll.Name = "TargetFeed"
		scroll.Position = UDim2.fromOffset(8, 68)
		scroll.Size = UDim2.new(1, -16, 0, 290)
		scroll.BackgroundColor3 = COLORS.card2
		scroll.BackgroundTransparency = 1
		scroll.BorderSizePixel = 0
		scroll.Visible = true
		scroll.ScrollBarThickness = 1
		scroll.ScrollBarImageColor3 = COLORS.accent
		scroll.CanvasSize = UDim2.new()
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
		scroll.Parent = panel

		local scrollCorner = Instance.new("UICorner")
		scrollCorner.CornerRadius = UDim.new(0, 2)
		scrollCorner.Parent = scroll

		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, 0)
		padding.PaddingBottom = UDim.new(0, 0)
		padding.PaddingLeft = UDim.new(0, 0)
		padding.PaddingRight = UDim.new(0, 0)
		padding.Parent = scroll

		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 4)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.Parent = scroll

		local footer = Instance.new("Frame")
		footer.Name = "ActionDock"
		footer.Size = UDim2.new(1, -12, 0, 44)
		footer.Position = UDim2.new(0, 6, 1, -50)
		footer.BackgroundTransparency = 1
		footer.BorderSizePixel = 0
		footer.BackgroundColor3 = COLORS.card
		footer.Parent = panel

		local status = Instance.new("TextLabel")
		status.Size = UDim2.new(1, -4, 0, 12)
		status.Position = UDim2.fromOffset(2, 34)
		status.BackgroundTransparency = 1
		status.Text = "Select target"
		status.TextColor3 = COLORS.muted
		status.TextSize = 9
		status.Font = Enum.Font.GothamMedium
		status.TextXAlignment = Enum.TextXAlignment.Center
		status.TextTruncate = Enum.TextTruncate.AtEnd
		status.Visible = false
		status.Parent = footer

		local function round(object, radius)
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, radius)
			corner.Parent = object
		end
		round(footer, 10)
		do
			local tile = Instance.new("Frame")
			tile.Name = "GuidedTile"
			tile.Visible = false
			tile.Size = UDim2.new(1, -124, 1, 0)
			tile.BackgroundColor3 = COLORS.card2
			tile.BorderSizePixel = 0
			tile.Parent = footer
			round(tile, 10)
		end
		local function label(parentObject, text, size, position, dimensions, color, font)
			local item = Instance.new("TextLabel")
			item.BackgroundTransparency = 1
			item.Text = text
			item.TextSize = size
			item.TextColor3 = color or COLORS.text
			item.Font = font or Enum.Font.GothamBold
			item.TextXAlignment = Enum.TextXAlignment.Left
			item.TextTruncate = Enum.TextTruncate.AtEnd
			item.Size = dimensions
			item.Position = position
			item.Parent = parentObject
			return item
		end
		label(selectedCard, "PET SELECIONADO", 11, UDim2.fromOffset(76, 10), UDim2.fromOffset(140, 13), COLORS.muted)

		local modeLabel = label(footer, "ONE SHOT", 12, UDim2.fromOffset(14, 46), UDim2.fromOffset(140, 18), COLORS.muted, Enum.Font.GothamMedium)
		modeLabel.Visible = false
		local loopEnabled, actionBusy = false, false
		local loopButton = Instance.new("TextButton")
		loopButton.Name = "LoopToggle"
		loopButton.Size = UDim2.fromOffset(166, 18)
		loopButton.Position = UDim2.new(0.5, -83, 0, 34)
		loopButton.BackgroundTransparency = 1
		loopButton.Text = ""
		loopButton.AutoButtonColor = false
		loopButton.BackgroundColor3 = COLORS.card2
		loopButton.BorderSizePixel = 0
		loopButton.Parent = header
		round(loopButton, 10)
		local loopBox = Instance.new("Frame")
		loopBox.Size = UDim2.fromOffset(22, 22)
		loopBox.Position = UDim2.fromOffset(45, 12)
		loopBox.BackgroundColor3 = COLORS.soft
		loopBox.BackgroundTransparency = 0.6
		loopBox.BorderSizePixel = 0
		loopBox.Visible = false
		loopBox.Parent = loopButton
		round(loopBox, 6)
		local loopStroke = Instance.new("UIStroke")
		loopStroke.Color = COLORS.muted
		loopStroke.Transparency = 0.3
		loopStroke.Thickness = 1.5
		loopStroke.Parent = loopBox
		local loopMark = label(loopBox, "✓", 16, UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1))
		loopMark.TextXAlignment = Enum.TextXAlignment.Center
		loopMark.Visible = false
		local loopCaption = label(loopButton, "LOOP: OFF", 9, UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1), COLORS.muted, Enum.Font.GothamMedium)
		loopCaption.TextXAlignment = Enum.TextXAlignment.Center
		local guidedButton = Instance.new("TextButton")
		guidedButton.Name = "GoButton"
		guidedButton.Size = UDim2.new(0.57, -2, 1, 0)
		guidedButton.Position = UDim2.fromOffset(0, 0)
		guidedButton.BackgroundTransparency = 0
		guidedButton.Text = "GO"
		guidedButton.AutoButtonColor = false
		guidedButton.BackgroundColor3 = COLORS.accent
		guidedButton.TextColor3 = COLORS.text
		guidedButton.TextSize = 16
		guidedButton.Font = Enum.Font.GothamBold
		guidedButton.BorderSizePixel = 0
		guidedButton.Parent = footer
		round(guidedButton, 8)
		local stopButton = Instance.new("TextButton")
		stopButton.Name = "StopButton"
		stopButton.Size = UDim2.new(0.43, -2, 1, 0)
		stopButton.Position = UDim2.new(0.57, 2, 0, 0)
		stopButton.Text = "STOP"
		stopButton.TextColor3 = Color3.fromRGB(255, 218, 214)
		stopButton.TextSize = 16
		stopButton.Font = Enum.Font.GothamBold
		stopButton.AutoButtonColor = false
		stopButton.BorderSizePixel = 0
		stopButton.BackgroundColor3 = COLORS.soft
		stopButton.Parent = footer
		round(stopButton, 8)
		local track = Instance.new("Frame")
		track.Name = "SwitchTrack"
		track.Size = UDim2.fromOffset(54, 28)
		track.Position = UDim2.new(1, -66, 0.5, -14)
		track.BackgroundColor3 = COLORS.soft
		track.BorderSizePixel = 0
		track.Visible = false
		track.Parent = guidedButton
		round(track, 14)
		local thumb = Instance.new("Frame")
		thumb.Name = "SwitchThumb"
		thumb.Size = UDim2.fromOffset(20, 20)
		thumb.Position = UDim2.fromOffset(4, 4)
		thumb.BackgroundColor3 = COLORS.muted
		thumb.BorderSizePixel = 0
		thumb.Parent = track
		round(thumb, 10)
		local switchTween, thumbTween
		local function refreshActionVisual()
			if not track.Parent then return end
			local enabled = auto.isRunning() and auto.owner() == "main"
			if switchTween then switchTween:Cancel() end
			if thumbTween then thumbTween:Cancel() end
			switchTween = TweenService:Create(track, TweenInfo.new(0.18), {BackgroundColor3 = enabled and COLORS.accent or COLORS.soft})
			thumbTween = TweenService:Create(thumb, TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Position = UDim2.fromOffset(enabled and 30 or 4, 4), BackgroundColor3 = enabled and COLORS.text or COLORS.muted})
			switchTween:Play()
			thumbTween:Play()
			loopCaption.Text = loopEnabled and "LOOP: ON" or "LOOP: OFF"
			loopMark.Visible = loopEnabled
			loopBox.BackgroundColor3 = loopEnabled and COLORS.accent or COLORS.soft
			loopBox.BackgroundTransparency = loopEnabled and 0 or 0.6
			loopStroke.Color = loopEnabled and COLORS.accent or COLORS.muted
			modeLabel.Text = loopEnabled and "LOOP" or "ONE SHOT"
		end

		-- Cosmetic input feedback only; action connections remain below, unchanged.
		local function bindButtonFX(button, normalColor, pressedColor)
			local scale = Instance.new("UIScale")
			scale.Parent = button
			local hovered, pressed = false, false
			local scaleTween, colorTween
			local function render(down)
				if scaleTween then scaleTween:Cancel() end
				if colorTween then colorTween:Cancel() end
				scaleTween = TweenService:Create(scale, TweenInfo.new(down and 0.09 or 0.19, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Scale = down and 0.96 or 1})
				scaleTween:Play()
				colorTween = TweenService:Create(button, TweenInfo.new(0.14), {BackgroundColor3 = (down or hovered) and pressedColor or normalColor})
				colorTween:Play()
			end
			button.MouseEnter:Connect(function() hovered = true; render(pressed) end)
			button.MouseLeave:Connect(function() hovered = false; pressed = false; render(false) end)
			button.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					pressed = true
					render(true)
				end
			end)
			button.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
					pressed = false
					render(false)
				end
			end)

		end
		bindButtonFX(listArrow, COLORS.soft, COLORS.card2)
		bindButtonFX(closeBtn, COLORS.soft, COLORS.card2)
		bindButtonFX(guidedButton, COLORS.accent, Color3.fromRGB(255, 102, 77))
		bindButtonFX(stopButton, COLORS.soft, Color3.fromRGB(44, 33, 34))

		-- Funções novas do build mais recente, sem substituir o Steal Panel antigo.
		local extrasButton = Instance.new("TextButton")
		extrasButton.Name = "ExtrasButton"
		extrasButton.Size = UDim2.fromOffset(28, 28)
		extrasButton.Position = UDim2.fromOffset(8, 14)
		extrasButton.BackgroundColor3 = COLORS.soft
		extrasButton.BackgroundTransparency = 0.15
		extrasButton.BorderSizePixel = 0
		extrasButton.Text = "+"
		extrasButton.TextColor3 = COLORS.text
		extrasButton.TextSize = 20
		extrasButton.Font = Enum.Font.GothamBold
		extrasButton.AutoButtonColor = false
		extrasButton.Parent = header
		round(extrasButton, 8)
		bindButtonFX(extrasButton, COLORS.soft, COLORS.card2)

		local extrasPanel = Instance.new("Frame")
		extrasPanel.Name = "NewFunctionsPanel"
		extrasPanel.Position = UDim2.fromOffset(8, 68)
		extrasPanel.Size = UDim2.new(1, -16, 0, 290)
		extrasPanel.BackgroundColor3 = COLORS.panel2
		extrasPanel.BackgroundTransparency = 0.02
		extrasPanel.BorderSizePixel = 0
		extrasPanel.Visible = false
		extrasPanel.ZIndex = 20
		extrasPanel.Parent = panel
		round(extrasPanel, 10)
		do
			local st = Instance.new("UIStroke")
			st.Color = COLORS.stroke
			st.Transparency = 0.35
			st.Parent = extrasPanel
		end

		local extrasTitle = label(extrasPanel, "NOVAS FUNÇÕES", 12, UDim2.fromOffset(10, 7), UDim2.new(1, -20, 0, 18), COLORS.text, Enum.Font.GothamBold)
		extrasTitle.ZIndex = 21

		local extrasScroll = Instance.new("ScrollingFrame")
		extrasScroll.Name = "ExtrasScroll"
		extrasScroll.Position = UDim2.fromOffset(6, 30)
		extrasScroll.Size = UDim2.new(1, -12, 1, -36)
		extrasScroll.BackgroundTransparency = 1
		extrasScroll.BorderSizePixel = 0
		extrasScroll.ScrollBarThickness = 2
		extrasScroll.ScrollBarImageColor3 = COLORS.accent
		extrasScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		extrasScroll.CanvasSize = UDim2.new()
		extrasScroll.ZIndex = 21
		extrasScroll.Parent = extrasPanel
		local exLayout = Instance.new("UIListLayout")
		exLayout.Padding = UDim.new(0, 4)
		exLayout.SortOrder = Enum.SortOrder.LayoutOrder
		exLayout.Parent = extrasScroll

		local function extraRow(text, callback, isToggle, key)
			local b = Instance.new("TextButton")
			b.Size = UDim2.new(1, -4, 0, 30)
			b.BackgroundColor3 = COLORS.card
			b.BorderSizePixel = 0
			b.AutoButtonColor = false
			b.TextSize = 11
			b.Font = Enum.Font.GothamMedium
			b.TextColor3 = COLORS.text
			b.ZIndex = 22
			b.Parent = extrasScroll
			round(b, 7)
			local function paint()
				if isToggle then
					local on = extras.get(key)
					b.Text = text .. (on and "  [ON]" or "  [OFF]")
					b.BackgroundColor3 = on and Color3.fromRGB(78, 38, 34) or COLORS.card
				else
					b.Text = text
				end
			end
			paint()
			b.MouseButton1Click:Connect(function()
				playUISound(1.08, 0.11)
				if isToggle then
					extras.set(key, not extras.get(key))
					paint()
				else
					task.spawn(function()
						local ok, a, b2 = pcall(callback)
						if ok then
							b.Text = tostring(a == false and (b2 or "não disponível") or "OK")
						else
							b.Text = "ERRO"
						end
						task.wait(0.8)
						if b.Parent then paint() end
					end)
				end
			end)
			return b
		end

		extraRow("Auto Sell Pets", nil, true, "autoSellPets")
		extraRow("Auto Sell Eggs", nil, true, "autoSellEggs")
		extraRow("Auto Fuse", nil, true, "autoFuse")
		extraRow("Auto Favorite Equipados", nil, true, "autoFavoriteEquipped")
		extraRow("Auto Buy Trail", nil, true, "autoBuyTrail")
		extraRow("Auto Upgrade Base", nil, true, "autoUpgradeBase")
		extraRow("Auto Upgrade Treadmill", nil, true, "autoUpgradeTreadmill")
		extraRow("Auto Claim / Index", nil, true, "autoClaim")
		extraRow("Infinite Jump", nil, true, "infiniteJump")
		extraRow("Instant Prompts", nil, true, "instantPrompts")
		extraRow("Anti AFK", nil, true, "antiAfk")
		extraRow("Auto Rejoin", nil, true, "autoRejoin")
		extraRow("Sell Pets Now", function() return extras.sellPetsNow() end, false)
		extraRow("Sell Eggs Now", function() return extras.sellEggsNow() end, false)
		extraRow("Fuse Now", function() return extras.fuseNow() end, false)
		extraRow("Favorite Equipados", function() return extras.favoriteEquippedNow(true) end, false)
		extraRow("Unfavorite Equipados", function() return extras.favoriteEquippedNow(false) end, false)
		extraRow("Claim Now", function() return extras.claimNow() end, false)

		local extrasOpen = false
		extrasButton.MouseButton1Click:Connect(function()
			extrasOpen = not extrasOpen
			extrasPanel.Visible = extrasOpen
			scroll.Visible = not extrasOpen
			extrasButton.Text = extrasOpen and "×" or "+"
			playUISound(extrasOpen and 1.12 or 0.96, 0.12)
		end)

		-- Quiet surface details, with no external icon dependencies.
		local chevron = Instance.new("Frame")
		chevron.Name = "Chevron"
		chevron.AnchorPoint = Vector2.new(0.5, 0.5)
		chevron.Position = UDim2.fromScale(0.5, 0.5)
		chevron.Size = UDim2.fromOffset(12, 8)
		chevron.BackgroundTransparency = 1
		chevron.Parent = listArrow
		do
			for i = 1, 2 do
				local line = Instance.new("Frame")
				line.AnchorPoint = Vector2.new(0.5, 0.5)
				line.Position = UDim2.fromOffset(i == 1 and 3 or 9, 4)
				line.Size = UDim2.fromOffset(8, 2)
				line.Rotation = i == 1 and 40 or -40
				line.BackgroundColor3 = COLORS.text
				line.BorderSizePixel = 0
				line.Parent = chevron
			end
			local gradient = Instance.new("UIGradient")
			gradient.Rotation = 105
			gradient.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(236, 192, 203))
			gradient.Enabled = false
			gradient.Parent = panel
			local border = Instance.new("UIStroke")
			border.Color = COLORS.stroke
			border.Transparency = 0.62
			border.Parent = selectedCard
			local portraitBorder = Instance.new("UIStroke")
			portraitBorder.Color = COLORS.accent
			portraitBorder.Transparency = 0.55
			portraitBorder.Parent = avatar
		end

		-- Hidden compatibility controls, retained for the original pet list.
		local genButton = Instance.new("TextButton")
		genButton.Visible = false
		genButton.Parent = panel

		local rarityButton = Instance.new("TextButton")
		rarityButton.Visible = false
		rarityButton.Parent = panel

		local sortTray = Instance.new("Frame")
		sortTray.Visible = false
		sortTray.Parent = panel

		local tabBar = sortTray

		local bubble = Instance.new("ImageButton")
		bubble.Name = "DHZ_BUBBLE"
		bubble.Size = UDim2.fromOffset(50, 50)
		bubble.Position = UDim2.fromOffset(18, math.max(6, ((workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y) or 600) * 0.5 - 25))
		bubble.BackgroundColor3 = COLORS.panel
		bubble.BorderSizePixel = 0
		bubble.Image = "rbxassetid://81245576355054"
		bubble.ImageColor3 = Color3.fromRGB(255, 255, 255)
		bubble.ImageTransparency = 0
		bubble.ScaleType = Enum.ScaleType.Crop
		bubble.AutoButtonColor = false
		bubble.Active = true
		bubble.ZIndex = 50
		bubble.Parent = dhzGui

		local bubbleCorner = Instance.new("UICorner")
		bubbleCorner.CornerRadius = UDim.new(1, 0)
		bubbleCorner.Parent = bubble

		local bubbleStroke = Instance.new("UIStroke")
		bubbleStroke.Color = COLORS.accent
		bubbleStroke.Thickness = 1.5
		bubbleStroke.Transparency = 0.35
		bubbleStroke.Parent = bubble

		local bubbleScale = Instance.new("UIScale")
		bubbleScale.Scale = 1
		bubbleScale.Parent = bubble

		do
			local viewportConnection
			local function resizeToViewport()
				if not panel.Parent then return end
				baseScale = fittedScale()
				panelScale.Scale = baseScale
				local view = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
				panel.Position = UDim2.fromOffset(
					math.clamp(panel.Position.X.Offset, 6, math.max(6, view.X - panel.Size.X.Offset * baseScale - 6)),
					math.clamp(panel.Position.Y.Offset, 6, math.max(6, view.Y - panel.Size.Y.Offset * baseScale - 6))
				)
			end
			local function observeCamera()
				if viewportConnection then viewportConnection:Disconnect() end
				local camera = workspace.CurrentCamera
				if camera then viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(resizeToViewport) end
				resizeToViewport()
			end
			local cameraConnection = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(observeCamera)
			BX.onTeardown("dhz.compact.viewport", function()
				if viewportConnection then viewportConnection:Disconnect() end
				cameraConnection:Disconnect()
			end)
			observeCamera()
		end
		local bubbleOpen = true
		local animSerial = 0

		local function showPanel()
			animSerial = animSerial + 1
			local serial = animSerial
			panel.Visible = true
			panelScale.Scale = baseScale * 0.96
			panel.BackgroundTransparency = 0
			playUISound(1.12, 0.16)

			TweenService:Create(
				panelScale,
				TweenInfo.new(0.24, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{Scale = baseScale}
			):Play()

			local fade = TweenService:Create(
				panel,
				TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{BackgroundTransparency = 0}
			)
			fade:Play()
			fade.Completed:Connect(function()
				if serial ~= animSerial then return end
				panel.BackgroundTransparency = 0
			end)
		end

		local function hidePanel()
			animSerial = animSerial + 1
			local serial = animSerial
			playUISound(0.88, 0.14)

			TweenService:Create(
				panelScale,
				TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{Scale = baseScale * 0.95}
			):Play()

			local fade = TweenService:Create(
				panel,
				TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{BackgroundTransparency = 0}
			)
			fade:Play()
			fade.Completed:Connect(function()
				if serial ~= animSerial then return end
				panel.Visible = false
				panelScale.Scale = baseScale or 1
				panel.BackgroundTransparency = 0
			end)
		end

		-- The panel itself is draggable and keeps its last position.
		local panelDragging = false
		local panelDragInput = nil
		local panelDragStart = nil
		local panelStartPos = nil

		local function clampPanelPosition(position)
			local camera = workspace.CurrentCamera
			local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
			local width = panel.AbsoluteSize.X > 0 and panel.AbsoluteSize.X or 380
			local height = panel.AbsoluteSize.Y > 0 and panel.AbsoluteSize.Y or 268
			local margin = 6
			local x = math.clamp(position.X.Offset, margin, math.max(margin, viewport.X - width - margin))
			local y = math.clamp(position.Y.Offset, margin, math.max(margin, viewport.Y - height - margin))
			return UDim2.fromOffset(x, y)
		end

		header.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				panelDragging = true
				panelDragInput = input
				panelDragStart = input.Position
				panelStartPos = panel.Position
			end
		end)

		header.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				panelDragInput = input
			end
		end)

		local bubbleDragging = false
		local bubbleDragged = false
		local bubbleDragStart = nil
		local bubbleStartPos = nil
		local bubbleInput = nil

		local function clampBubblePosition(position)
			local camera = workspace.CurrentCamera
			local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
			local size = 50
			local margin = 6
			local x = math.clamp(position.X.Offset, margin, math.max(margin, viewport.X - size - margin))
			local y = math.clamp(position.Y.Offset, margin, math.max(margin, viewport.Y - size - margin))
			return UDim2.fromOffset(x, y)
		end

		bubble.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				bubbleDragging = true
				bubbleDragged = false
				bubbleDragStart = input.Position
				bubbleStartPos = bubble.Position
				bubbleInput = input
			end
		end)

		bubble.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				bubbleInput = input
			end
		end)

		UIS.InputChanged:Connect(function(input)
			if panelDragging and input == panelDragInput and panelDragStart and panelStartPos then
				local delta = input.Position - panelDragStart
				panel.Position = clampPanelPosition(UDim2.fromOffset(
					panelStartPos.X.Offset + delta.X,
					panelStartPos.Y.Offset + delta.Y
				))
			end

			if bubbleDragging and input == bubbleInput and bubbleDragStart and bubbleStartPos then
				local delta = input.Position - bubbleDragStart
				if delta.Magnitude > 6 then
					bubbleDragged = true
				end
				bubble.Position = clampBubblePosition(UDim2.fromOffset(
					bubbleStartPos.X.Offset + delta.X,
					bubbleStartPos.Y.Offset + delta.Y
				))
			end
		end)

		UIS.InputEnded:Connect(function(input)
			if panelDragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
				panelDragging = false
				panelDragInput = nil
			end

			if bubbleDragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
				bubbleDragging = false
				bubbleInput = nil
				if not bubbleDragged then
					local down = TweenService:Create(bubbleScale, TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Scale = 0.90})
					local up = TweenService:Create(bubbleScale, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1})
					down:Play()
					down.Completed:Connect(function()
						if bubbleScale.Parent then up:Play() end
					end)

					bubbleOpen = not bubbleOpen
					if bubbleOpen then
						showPanel()
					else
						hidePanel()
					end
				else
					task.delay(0.05, function()
						bubbleDragged = false
					end)
				end
			end
		end)

		closeBtn.MouseButton1Click:Connect(function()
			bubbleOpen = false
			hidePanel()
		end)


		local currentSort = "GEN"
		local selectedUid = nil
		local cards = {}
		local refreshBusy = false
		local function applyListMode()
			-- List stays visible; scrolling reveals all existing targets.
			scroll.Visible = true
		end

		local rarityRank = {
			Common = 1,
			Uncommon = 2,
			Rare = 3,
			Epic = 4,
			Legendary = 5,
			Mythic = 6,
			Cosmic = 7,
			Divine = 8,
		}
		local function fmtRate(n)
			return eggs.formatRate(tonumber(n) or 0)
		end
		local function fmtKg(n)
			n = tonumber(n) or 0
			if n <= 0 then
				return "?"
			end
			return n >= 100 and ("%.0f"):format(n) or ("%.1f"):format(n)
		end
		local function assetInfo(e, dir)
			local d = e and e.assetCategory and dir and dir[e.assetCategory] or nil
			local icon = d and d.Icon or nil
			if type(icon) == "number" then
				icon = "rbxassetid://" .. tostring(icon)
			elseif type(icon) ~= "string" then
				icon = ""
			end
			local rarity = (e and e.rarity and e.rarity ~= "?") and tostring(e.rarity) or nil
			if not rarity and d and d.Rarity then
				rarity = tostring(d.Rarity.DisplayName or d.Rarity._id or "?")
			end
			local rarityColor = Color3.fromRGB(210, 205, 210)
			if d and d.Rarity and typeof(d.Rarity.Color) == "Color3" then
				rarityColor = d.Rarity.Color
			end
			return icon, rarity or "?", rarityColor
		end
		local function destroyCards()
			for _, c in ipairs(cards) do
				pcall(function()
					c:Destroy()
				end)
			end
			table.clear(cards)
		end
		local espCards = BX.require("features.esp.cards")
		local ESP_MAX_DIST = math.max(10000, tonumber(espCards.K.MAX_DIST) or 0)
		local ESP_MAX_CARDS = 40
		local function sortedEggs()
			local source = eggs.list()
			local cam = workspace.CurrentCamera
			local dir = data.assetsDir()
			if not cam or type(source) ~= "table" then
				return {}, dir
			end
			local eye = cam.CFrame.Position
			local list = {}
			for _, e in ipairs(source) do
				if e.pos and (e.pos - eye).Magnitude <= ESP_MAX_DIST then
					list[# list + 1] = e
					if # list >= ESP_MAX_CARDS then
						break
					end
				end
			end
			table.sort(list, function(a, b)
				if currentSort == "RARITY" then
					local _, ra = assetInfo(a, dir)
					local _, rb = assetInfo(b, dir)
					local ar = rarityRank[ra] or 0
					local br = rarityRank[rb] or 0
					if ar ~= br then
						return ar > br
					end
				end
				local av = tonumber(a.value) or 0
				local bv = tonumber(b.value) or 0
				if av ~= bv then
					return av > bv
				end
				return tostring(a.name or "") < tostring(b.name or "")
			end)
			return list, dir
		end
		local clickSound = Instance.new("Sound")
		clickSound.Name = "EggSelectClick"
		clickSound.SoundId = "rbxassetid://12221967"
		clickSound.Volume = 0.16
		clickSound.Parent = game:GetService("SoundService")
		BX.onTeardown("dhz.eggSelectClick", function()
			pcall(function()
				clickSound:Destroy()
			end)
		end)
		local function playEggClick()
			pcall(function()
				clickSound:Stop()
				clickSound.TimePosition = 0
				clickSound:Play()
			end)
		end
		local function selectEgg(e, card)
			if not e or not e.uid then
				return
			end
			selectedUid = e.uid
			targetline.setSelected(selectedUid)
			status.Text = "Target: " .. tostring(e.name or "target")
			playEggClick()

			local dir = data.assetsDir()
			local icon, rarity, rarityColor = assetInfo(e, dir)
			if icon and icon ~= "" then
				selectedPreview.Image = icon
			else
				selectedPreview.Image = "rbxassetid://81245576355054"
			end
			selectedName.Text = tostring(e.name or "Unknown")
			selectedRarity.Text = tostring(rarity or "?")
			selectedRarity.TextColor3 = rarityColor or Color3.fromRGB(106, 85, 255)
			selectedValue.Text = fmtRate(e.value)

			for _, other in ipairs(cards) do
				local os = other:FindFirstChild("CardStroke")
				if os then
					os.Color = COLORS.stroke
					os.Thickness = 1
					other.BackgroundColor3 = COLORS.card
				end
			end
			if card and card.Parent then
				local selectedStroke = card:FindFirstChild("CardStroke")
				if selectedStroke then
					selectedStroke.Color = COLORS.accent
					selectedStroke.Thickness = 1.5
				end
				card.BackgroundColor3 = COLORS.card2
			end
		end
		local function goSelected()
			if not selectedUid then
				status.Text = "Choose a target first"
				modeLabel.Text = "ESCOLHA UM PET"
				return false
			end
			auto.setOptions("main", {uid = selectedUid, continuous = loopEnabled})
			targetline.setSelected(selectedUid)
			targetline.setReturning(false)
			status.Text = "Route active"
			return auto.setEnabled(true, "main")
		end
		loopButton.MouseButton1Click:Connect(function()
			loopEnabled = not loopEnabled
			if auto.isRunning() and auto.owner() == "main" then
				auto.setOptions("main", {uid = selectedUid, continuous = loopEnabled})
			end
			playUISound(loopEnabled and 1.12 or 0.94, 0.13)
			refreshActionVisual()
		end)
		local function requestAction(stopping)
			if actionBusy then return end
			actionBusy = true
			playUISound(stopping and 0.86 or 1.15, 0.15)
			task.spawn(function()
				local ok, result, why = pcall(function()
					if stopping then
						local stopped = auto.setEnabled(false, "main")
						if stopped ~= false then targetline.clear() end
						status.Text = "Route stopped"
						return stopped
					end
					return goSelected()
				end)
				actionBusy = false
				refreshActionVisual()
				if not ok or result == false then
					status.Text = "Teleguiado: " .. tostring(ok and (why or "unavailable") or result)
					modeLabel.Text = not selectedUid and "ESCOLHA UM PET" or "NÃO FOI POSSÍVEL INICIAR"
					loopCaption.Text = modeLabel.Text
				end
			end)
		end
		guidedButton.MouseButton1Click:Connect(function() requestAction(false) end)
		stopButton.MouseButton1Click:Connect(function() requestAction(true) end)
		local rowCache = {}
		local function makeCard(e, dir, index)
			local icon, rarity, rarityColor = assetInfo(e, dir)
			local key = tostring(e.uid)
			local row = rowCache[key]
			if not row then
				local card = Instance.new("TextButton")
				card.Name = "Target_" .. key
				card.Size = UDim2.new(1, -2, 0, 54)
				card.BorderSizePixel = 0
				card.AutoButtonColor = false
				card.Text = ""
				card.Parent = scroll
				round(card, 2)
				local stroke = Instance.new("UIStroke")
				stroke.Name = "CardStroke"
				stroke.Thickness = 1
				stroke.Transparency = 0.7
				stroke.Parent = card
				local iconView = Instance.new("ImageLabel")
				iconView.Name = "PetIcon"
				iconView.Size = UDim2.fromOffset(36, 36)
				iconView.Position = UDim2.fromOffset(6, 9)
				iconView.BackgroundColor3 = Color3.fromRGB(13, 16, 18)
				iconView.BorderSizePixel = 0
				iconView.ScaleType = Enum.ScaleType.Fit
				iconView.Parent = card
				round(iconView, 5)
				row = {card = card, icon = iconView, stroke = stroke}
				row.name = label(card, "", 13, UDim2.fromOffset(50, 8), UDim2.fromOffset(88, 18), COLORS.text, Enum.Font.GothamMedium)
				row.rarity = label(card, "", 10, UDim2.fromOffset(50, 31), UDim2.fromOffset(98, 14), COLORS.muted, Enum.Font.GothamMedium)
				row.scale = label(card, "", 11, UDim2.fromOffset(140, 9), UDim2.fromOffset(44, 17), Color3.fromRGB(102, 167, 216), Enum.Font.GothamMedium)
				row.scale.TextXAlignment = Enum.TextXAlignment.Right
				row.value = label(card, "", 11, UDim2.new(1, -53, 0, 9), UDim2.fromOffset(47, 17), COLORS.green, Enum.Font.GothamMedium)
				row.value.TextXAlignment = Enum.TextXAlignment.Right
				rowCache[key] = row
				cards[#cards + 1] = card
				card.MouseButton1Click:Connect(function() selectEgg(row.data, card) end)
			end
			row.data, row.seen = e, true
			row.card.LayoutOrder = index
			row.card.BackgroundColor3 = e.uid == selectedUid and COLORS.card2 or COLORS.card
			row.stroke.Color = e.uid == selectedUid and COLORS.accent or Color3.fromRGB(20, 23, 25)
			row.icon.Image = (e.icon and e.icon ~= "") and e.icon or icon
			row.name.Text = tostring(e.name or "Unknown")
			row.rarity.Text = tostring(rarity or "?")
			row.rarity.TextColor3 = rarityColor
			local assetScale = tonumber(e.assetScale)
			row.scale.Text = assetScale and (string.format("%.2f", assetScale):gsub("0+$", ""):gsub("%.$", "") .. "x") or "--"
			row.value.Text = fmtRate(e.value)
		end
		local function rebuild()
			if refreshBusy or not scroll.Parent then
				return
			end
			refreshBusy = true
			local ok, list, dir = pcall(sortedEggs)
			if not ok or type(list) ~= "table" then
				status.Text = "Unable to read targets"
				refreshBusy = false
				return
			end
			local selectedStillExists = false
			if selectedUid then
				for _, e in ipairs(list) do
					if e.uid == selectedUid then
						selectedStillExists = true
						break
					end
				end
			end
			local selectionChanged = false
			if not selectedStillExists then
				selectedUid = list[1] and list[1].uid or nil
				selectionChanged = true
				if selectedUid then
					targetline.setSelected(selectedUid)
				else
					targetline.clear()
				end
			end
			for _, row in pairs(rowCache) do row.seen = false end
			local max = math.min(# list, ESP_MAX_CARDS)
			local visibleCount = 0
			if listExpanded then
				visibleCount = max
				for i = 1, visibleCount do
					makeCard(list[i], dir, i)
				end
			else
				local selectedData = nil
				if selectedUid then
					for _, e in ipairs(list) do
						if e.uid == selectedUid then
							selectedData = e
							break
						end
					end
				end
				selectedData = selectedData or list[1]
				if selectedData then
					visibleCount = 1
					makeCard(selectedData, dir, 1)
				end
			end
			-- Synchronize the visible summary without selecting again or playing a sound.
			local displayEgg
			for _, e in ipairs(list) do
				if e.uid == selectedUid then displayEgg = e; break end
			end
			if displayEgg then
				local icon, rarity, rarityColor = assetInfo(displayEgg, dir)
				selectedPreview.Image = icon ~= "" and icon or "rbxassetid://81245576355054"
				selectedName.Text = tostring(displayEgg.name or "Unknown")
				selectedRarity.Text = tostring(rarity or "?")
				selectedRarity.TextColor3 = rarityColor
				selectedValue.Text = fmtRate(displayEgg.value)
			else
				selectedPreview.Image = "rbxassetid://81245576355054"
				selectedName.Text = "No target"
				selectedRarity.Text = "choose a target"
				selectedRarity.TextColor3 = COLORS.muted
				selectedValue.Text = "--"
			end
			for key, row in pairs(rowCache) do
				if not row.seen then
					row.card:Destroy()
					rowCache[key] = nil
				end
			end
			table.clear(cards)
			for _, row in pairs(rowCache) do cards[#cards + 1] = row.card end
			scroll.CanvasSize = UDim2.fromOffset(0, math.max(0, visibleCount * 58 - 4))
			if selectionChanged and list[1] then
				status.Text = "Best: " .. tostring(list[1].name or "target")
			elseif not selectedUid then
				status.Text = ("%d targets  -  Select an egg"):format(max)
			end
			applyListMode()
			refreshBusy = false
		end
		local function setSort(mode)
			currentSort = "GEN"
			rebuild()
		end
		applyListMode()
		local dragging, dragStart, startPos
		title.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = panel.Position
			end
		end)
		UIS.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
		UIS.InputChanged:Connect(function(input)
			if not dragging then
				return
			end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local delta = input.Position - dragStart
			panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end)
		auto.onStop(function(why, whose)
			if whose and whose ~= "main" then
				return
			end
			refreshActionVisual()
			if status and status.Parent then
				if why == "delivered" then
					status.Text = "Delivered - press START again"
				else
					status.Text = "Stopped: " .. tostring(why)
				end
			end
		end)
		task.spawn(function()
			while dhzGui and dhzGui.Parent do
				rebuild()
				task.wait(0.5)
			end
		end)
		setSort("GEN")
		refreshActionVisual()
		showPanel()
		BX.onTeardown("dhz.panel", function()
			if dhzGui then
				pcall(function()
					dhzGui:Destroy()
				end)
			end
			dhzGui = nil
		end)
	end
	stage("dhz panel", true, buildDhzPanel)
	stage("webhook", false, function()
		local hook = BX.require("features.misc.webhook")
		BX.require("features.autosteal").onCarrying(function(e)
			targetline.setReturning(true)
		end)
		BX.require("features.autosteal").onDelivered(function(e)
			hook.onDelivered(e)
			targetline.setReturning(true)
		end)
	end)
	stage("treadmill", false, function()
		BX.require("features.treadmill").arm()
	end)
	stage("fps", false, function()
		BX.require("features.fps").arm()
	end)
	stage("jump", false, function()
		BX.require("features.jump").arm()
	end)
	stage("prewarm", false, function()
		BX.require("features.prewarm").start()
	end)
	splash.step("Almost ready", 0.90)
	stage("discord", false, function()
		splash.discord()
	end)
	stage("stats", false, function()
	end)
	splash.whenClosed(function()
		BX.try("startup.reveal", function()
			if dhzGui and dhzGui.Parent then
				dhzGui.Enabled = true
			end
			setState("READY")
			startup.readyAt = os.clock() - startup.t0
			log.info("ready in %.2fs (init %.2fs, loading screen %.2fs)", startup.readyAt, startup.initAt or 0, startup.readyAt - (startup.initAt or 0))
		end)
	end)
	splash.done()
	task.spawn(function()
		local deadline = os.clock() + 20
		while true do
			task.wait(1)
			if startup.state == "READY" then
				return
			end
			if not BX.alive() then
				return
			end
			local waiting = false
			BX.try("startup.splashWaiting", function()
				waiting = type(splash.isWaitingForUser) == "function" and splash.isWaitingForUser() or false
			end)
			if waiting then
				deadline = os.clock() + 20
			elseif os.clock() >= deadline then
				log.warn("loading never completed - revealing the menu anyway")
				BX.try("startup.forceReveal", function()
					if win and type(win.reveal) == "function" then
						win.reveal()
					end
					if dhzGui and dhzGui.Parent then
						dhzGui.Enabled = true
					end
					setState("READY")
				end)
				return
			end
		end
	end)
	BX.profile.start()
	BX.try("startup.sessionWatch", function()
		local ssc = BX.scope("core.sessionwatch")
		local GuiService = game:GetService("GuiService")
		ssc:connect(GuiService.ErrorMessageChanged, function(msg)
			if msg == nil or msg == "" then
				return
			end
			local code = "?"
			pcall(function()
				code = tostring(GuiService:GetErrorCode())
			end)
			log.error("ROBLOX ERROR PROMPT (code %s): %s", code, tostring(msg))
		end)
		local lp = game:GetService("Players").LocalPlayer
		if lp then
			ssc:connect(lp.OnTeleport, function(state, placeId)
				log.error("client teleport %s (place %s)", tostring(state), tostring(placeId))
			end)
		end
	end)
	env.DhzAudit = function()
		local h = BX.profile.health()
		print(("[DHZ] up %.0fs | mem %.0fMB (%+.0f since start) | %d modules") :format(h.uptime, h.mem, h.memGrow, h.loaded))
		print(("[DHZ] scopes=%d conns=%d insts=%d threads=%d") :format(h.scopes, h.conns, h.insts, h.threads))
		for _, line in ipairs(BX.scopeReport()) do
			print("[DHZ]   " .. line)
		end
		for _, line in ipairs(BX.profile.watched()) do
			print("[DHZ]   " .. line)
		end
		local rep = logmod.repeats()
		if # rep > 0 then
			print("[DHZ] repeated failures:")
			for _, r in ipairs(rep) do
				print("[DHZ]   " .. r)
			end
		end
		return h
	end
	env.DhzProfile = function()
		for _, line in ipairs(BX.profile.report()) do
			print("[DHZ] " .. line)
		end
	end
	env.DhzStages = function()
		print(("[DHZ] startup: %s in %.2fs"):format( startup.state, startup.readyAt or (os.clock() - startup.t0)))
		print("[DHZ]   stage          result      cost      at")
		for _, s in ipairs(startup.stages) do
			print(("[DHZ]   %-14s %-9s %7.0fms %6.2fs%s"):format( s.name, s.result, s.ms or 0, s.at, s.detail and ("  " .. tostring(s.detail)) or ""))
		end
		if startup.initAt then
			print(("[DHZ]   init %.2fs | loading screen %.2fs | total %.2fs"):format( startup.initAt, (startup.readyAt or startup.initAt) - startup.initAt, startup.readyAt or startup.initAt))
		end
	end
	startup.initAt = os.clock() - startup.t0
	logmod.session(("startup complete - all work done in %.2fs"):format(startup.initAt))
	local function diag()
		local rep = BX.require("core.exec").report()
		local lines = {
			("executor = %s  (DhzHub %s build %s, generation %d)") :format(tostring(rep.executor), tostring(BX.version), tostring(BX.build), BX.generation),
			("capabilities = %s"):format(# rep.have > 0 and table.concat(rep.have, ",") or "(none)"),
			("missing = %s"):format(# rep.missing > 0 and table.concat(rep.missing, ",") or "(none)"),
			("prompt path = %s  |  game require = %s (%s)%s"):format( tostring(rep.promptVia), tostring(BX.require("core.exec").can.gameRequire), tostring(rep.gameRequireWhy), # rep.denied > 0 and ("  |  SIMULATED DENIES = " .. table.concat(rep.denied, ",")) or ""),
		}
		local st, failed = {}, {}
		for _, s in ipairs(startup.stages) do
			st[# st + 1] = s.name .. ":" .. s.result
			if s.result == "FAILED" or s.result == "FALLBACK" then
				failed[# failed + 1] = s.name .. " = " .. tostring(s.detail or s.result)
			end
		end
		lines[# lines + 1] = ("startup stage = %s  |  %s"):format(startup.state, table.concat(st, " "))
		if # failed > 0 then
			for _, f in ipairs(failed) do
				local mod = tostring(f):match('module "([^"]+)" failed') or "-"
				lines[# lines + 1] = ("module failed = %s  |  error = %s"):format(mod, f)
			end
		else
			lines[# lines + 1] = "module failed = none"
		end
		for _, l in ipairs(lines) do
			log.info("diag %s", l)
			print("[DHZ diag] " .. l)
		end
		return lines
	end
	env.DhzDiag = diag
	BX.try("startup.diag", diag)
end
end, function(err)
	local msg = tostring(err)
	pcall(function()
		if debug and type(debug.traceback) == "function" then
			msg = debug.traceback(msg, 2)
		end
	end)
	return msg
end)

if not __DHZ_OK then
	warn("[DHZ/DELTA] Script stopped: " .. tostring(__DHZ_ERR))
end
