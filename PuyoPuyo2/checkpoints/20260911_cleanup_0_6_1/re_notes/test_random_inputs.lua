-- Run with the existing GENie Lua host, from the MAME directory.
local root = (_WORKING_DIR or '.'):gsub('/', '\\')
local exercise = assert(loadfile(root .. '\\PuyoPuyo2\\re_notes\\exercise_link.lua'))
local original_open, original_getenv = io.open, os.getenv
local side, playing = 'B', false
local tick, stop
local fields, counts = {}, {}
local ports = {}
for _, player in ipairs({ 'P1', 'P2' }) do
	ports[':' .. player] = { fields = {} }
	for _, button in ipairs({ 'Left', 'Right', 'Down', 'Button 1' }) do
		local name = player .. ' ' .. button
		counts[name] = 0
		ports[':' .. player].fields[name] = {
			set_value = function(_, value)
				assert(value == 1)
				fields[name] = true
				counts[name] = counts[name] + 1
			end,
			clear_value = function() fields[name] = false end,
		}
	end
end
-- No SERVICE port or memory-write methods: using either must fail.
local space = {
	read_u8 = function(_, address)
		if address == 0xffd12a then return 0 end
		if address == 0xffd16a then return 1 end
		if playing and (address == 0xffd100 or address == 0xffd140) then return 1 end
		return 0
	end,
	read_u32 = function(_, address)
		if address == 0xffd102 or address == 0xffd142 then return 0x7944 end
		return 0
	end,
}
manager = { machine = { ioport = { ports = ports },
	devices = { [':maincpu'] = { spaces = { program = space } } } } }
local handles, logs = {}, {}
local function handle()
	local h = { removed = false }
	function h:unsubscribe() self.removed = true end
	handles[#handles + 1] = h
	return h
end
emu = {
	add_machine_frame_notifier = function(fn) tick = fn; return handle() end,
	add_machine_stop_notifier = function(fn) stop = fn; return handle() end,
}
os.getenv = function(name)
	if name == 'PUYO2_LINK_SIDE' then return side end
	if name == 'PUYO2_LINK_DIR' then return 'mock' end
	if name == 'PUYO2_EXERCISE_RANDOM_ONLY' then return '1' end
end
io.open = function()
	local f = { closed = false }
	function f:write() assert(not self.closed) end
	function f:flush() assert(not self.closed) end
	function f:close() self.closed = true end
	logs[#logs + 1] = f
	return f
end
math.randomseed(31)
exercise()
for _ = 1, 60 do tick() end
for _, n in pairs(counts) do assert(n == 0, 'Input pressed in a menu') end
playing = true
for _ = 1, 600 do
	tick()
	for _, player in ipairs({ 'P1', 'P2' }) do
		assert(not (fields[player .. ' Left'] and fields[player .. ' Right']))
		assert(not fields[player .. ' Down'])
	end
end
for _, player in ipairs({ 'P1', 'P2' }) do
	for _, button in ipairs({ 'Left', 'Right', 'Button 1' }) do
		assert(counts[player .. ' ' .. button] > 0, 'Missing random input')
	end
end
playing = false
tick()
for _, held in pairs(fields) do assert(not held, 'Input stuck after gameplay') end
exercise()
assert(handles[1].removed and handles[2].removed and logs[1].closed)
playing = true
tick()
stop()
for _, held in pairs(fields) do assert(not held, 'Input stuck after stop') end
assert(logs[2].closed)
side = 'A'
local ok, err = pcall(exercise)
assert(not ok and tostring(err):find('restricted to cabinet B', 1, true))
io.open, os.getenv = original_open, original_getenv
print('PASS: random inputs, menu gating, cabinet restriction, reset and stop cleanup')
os.exit(0)
