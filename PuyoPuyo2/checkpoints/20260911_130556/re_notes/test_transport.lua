-- Run with the existing Lua 5.3 GENie host, without MAME or dependencies:
-- .\src\3rdparty\bx\tools\bin\windows\genie.exe --file=PuyoPuyo2\re_notes\test_transport.lua
-- Exercises the actual plugin callbacks. The ROM pump below follows
-- $186e0-$18788; this is NOT a substitute for paired emulator/gameplay tests.
local files, failures = {}, {}
local root = (_WORKING_DIR or '.'):gsub('/', '\\')
local plugin_path = root .. '\\plugins\\puyo2link\\init.lua'
local checks = 0
local function check(value, message)
	assert(value, message)
	checks = checks + 1
end

local rom_file = assert(io.open(root .. '\\PuyoPuyo2\\puyopuy2_merged.bin', 'rb'))
local rom = rom_file:read('*a')
rom_file:close()
local function opcode(address, hex)
	local bytes = hex:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end)
	check(rom:sub(address + 1, address + #bytes) == bytes, string.format('ROM premise changed at %06x', address))
end
opcode(0x005d4, '4eb9000186e0') -- Interrupt invokes pump directly.
opcode(0x0a38e, '41f900ffa580') -- Dedicated parser/handshake TCB.
opcode(0x0a400, '41f900ffa5c0') -- Dedicated builder TCB.
opcode(0x0a3a0, '41f900ffd000303c007f') -- DBRA dispatches 128 slots.
opcode(0x0a49c, '303c003a') -- Allocation scans 59, not 58 slots.
opcode(0x0a500, '215f0002') -- Yield saves continuation from stack.
opcode(0x06374, '0c39008200ffa500') -- Role-dependent game setup.
opcode(0x064b2, '0c39008200ffa500')
opcode(0x197c6, '0c39008200ffa500')
opcode(0x181f0, '427900ffa522') -- Reset clears drain pointer before CONTROL.
opcode(0x18208, '427900ffa52c') -- Reset clears RX pending too.
opcode(0x1866e, '523900ffa525') -- TX enqueue increments low byte.
opcode(0x186b2, '533900ffa52d') -- RX dequeue decrements low byte.
opcode(0x18724, '9f7900ffa524') -- TX pump subtracts full pending WORD.
opcode(0x1871e, '5307') -- TX overflow clamp leaves one slot unused.
opcode(0x187a4, '5307') -- RX overflow clamp also leaves one slot unused.
opcode(0x18778, 'db2a0004') -- TX commit is ADD.B D5,control credit.

local function open_file(path, mode)
	if failures[path] == 'open' then return nil, 'test open failure' end
	if mode == 'rb' and not files[path] then return nil end
	files[path] = files[path] or ''
	local pos = mode == 'ab' and #files[path] or 0
	return {
		seek = function(_, how, offset)
			pos = (how == 'end' and #files[path] or 0) + (offset or 0)
			return pos
		end,
		read = function(_, count)
			local result = files[path]:sub(pos + 1, pos + count)
			pos = pos + #result
			return result
		end,
		write = function(self, text)
			if failures[path] == 'write' then return nil, 'test write failure' end
			files[path] = files[path] .. text
			pos = #files[path]
			return self
		end,
		flush = function() return true end,
		close = function() return true end,
	}
end

local function cabinet(side, directory)
	local c = { ram = {}, taps = {}, side = side }
	c.out = directory .. '\\' .. side .. '_to_' .. (side == 'A' and 'B' or 'A') .. '.bin'
	c.log = directory .. '\\proto_' .. side .. '.log'
	local space = {}
	function space:read_u8(a) return c.ram[a] or 0 end
	function space:read_u16(a) return self:read_u8(a) * 256 + self:read_u8(a + 1) end
	function space:read_u32(a) return self:read_u16(a) * 65536 + self:read_u16(a + 2) end
	function space:write_u8(a, n) c.ram[a] = n & 255 end
	function space:write_u16(a, n) self:write_u8(a, n >> 8); self:write_u8(a + 1, n) end
	function space:install_write_tap(_, _, name, callback) c.taps[name] = callback; return {} end
	function space:install_read_tap(_, _, name, callback) c.taps[name] = callback; return {} end
	c.space = space
	c.cpu = { spaces = { program = space }, state = { PC = { value = 0 } } }
	local env = setmetatable({
		io = { open = open_file },
		os = { getenv = function(key)
			if key == 'PUYO2_LINK_SIDE' then return side end
			if key == 'PUYO2_LINK_DIR' then return directory end
			if key == 'PUYO2_AUTO_INPUT' then return '0' end
		end },
		lfs = { mkdir = function() return true end },
		manager = { machine = {
			devices = { [':maincpu'] = c.cpu },
			ioport = { ports = { [':SERVICE'] = { fields = {} } } },
		} },
		emu = {
			time = function() return 0 end,
			romname = function() return 'puyopuy2' end,
			register_prestart = function(f) c.prestart = f; return {} end,
			add_machine_frame_notifier = function(f) c.frame = f; return {} end,
			add_machine_stop_notifier = function(f) c.stop = f; return {} end,
		},
	}, { __index = _G })
	local plugin = assert(loadfile(plugin_path, 't', env))()
	plugin.startplugin()
	c.prestart()
	function c:w(a, value, mask)
		return self.taps.puyo2link_w(a & ~1, value, mask or 255)
	end
	function c:r(a)
		return self.taps.puyo2link_r(a & ~1, 65535, 255)
	end
	function c:command(value) self:w(0x880111, value) end
	function c:reset()
		for a = 0xffa520, 0xffa52c, 2 do self.space:write_u16(a, 0) end
		self:w(0x880131, 1)
	end
	function c:boot()
		self:reset()
		self:command(0xfc)
		local signature = {}
		for i = 0, 7 do signature[#signature + 1] = string.char(self:r(0x880101 + i * 2)) end
		check(table.concat(signature) == 'PUYO2Z80', 'signature was corrupted')
		self:command(0xfd)
		check(self:r(0x880101) == 0, 'CRC response')
		self:command(0xfd)
		for i = 0, 7 do check(self:r(0x880101 + i * 2) == 255, 'identity ACK') end
		self:command(0xfe)
		local role = side == 'A' and 1 or 2
		check(self:r(0x880101) == role, 'distinct cabinet role')
		self.space:write_u8(0xffa500, role | 0x80)
	end
	function c:enqueue(text)
		local head = self.space:read_u16(0xffa520)
		local pending = self.space:read_u16(0xffa524)
		assert(pending + #text <= 255)
		for i = 1, #text do
			self.space:write_u8(0xffa800 + head, text:byte(i))
			head = (head + 1) & 255
		end
		self.space:write_u16(0xffa520, head)
		self.space:write_u16(0xffa524, pending + #text)
	end
	function c:pump(hook)
		local s = self.space
		local n = s:read_u16(0xffa524)
		if n > 0 then
			self:command(255)
			n = math.min(n, 32, 255 - self:r(0x880105))
			if n > 0 then
				s:write_u16(0xffa524, s:read_u16(0xffa524) - n)
				local tail, pos = s:read_u16(0xffa522), self:r(0x880101)
				self:command(pos >> 3)
				for i = 1, n do
					self:w(0x880101 + (pos & 7) * 2, s:read_u8(0xffa800 + tail))
					tail, pos = (tail + 1) & 255, (pos + 1) & 255
					if (pos & 7) == 0 then self:command(pos >> 3) end
					if hook then hook('payload', i) end
				end
				self:command(255)
				self:w(0x88010f, 1)
				self:w(0x880101, pos)
				s:write_u16(0xffa522, tail)
				local credit = self:r(0x880105)
				if hook then hook('credit-read', n) end
				self:w(0x880105, (credit + n) & 255)
			end
		end
		self:command(255)
		check(self:r(0x880107) == 0, 'mailbox RX must stay disabled')
	end
	function c:consume(n)
		local s, result = self.space, {}
		local tail = s:read_u16(0xffa52a)
		n = n or s:read_u16(0xffa52c)
		assert(n <= s:read_u16(0xffa52c))
		for i = 1, n do
			result[i] = string.char(s:read_u8(0xffa900 + tail))
			tail = (tail + 1) & 255
		end
		s:write_u16(0xffa52a, tail)
		s:write_u16(0xffa52c, s:read_u16(0xffa52c) - n)
		return table.concat(result)
	end
	c:boot()
	return c
end

local a, b = cabinet('A', 'roundtrip'), cabinet('B', 'roundtrip')
local expected, received, reverse_expected, reverse_received = {}, {}, {}, {}
for batch = 0, 31 do
	local bytes = {}
	for i = 0, 31 do bytes[#bytes + 1] = string.char((batch * 32 + i) & 255) end
	local text = table.concat(bytes)
	expected[#expected + 1] = text
	a:enqueue(text); a:pump(); a.frame()
	b.frame(); b:enqueue(text:reverse()); b:pump(); received[#received + 1] = b:consume()
	reverse_expected[#reverse_expected + 1] = text:reverse()
	b.frame(); a.frame(); a:pump(); reverse_received[#reverse_received + 1] = a:consume()
end
check(files[a.out] == table.concat(expected), 'TX altered bytes or lost bank wraps / trailing FF')
check(table.concat(received) == table.concat(expected), 'RX altered bytes across ring wraps')
check(files[b.out] == table.concat(reverse_expected), 'reverse TX stream differs')
check(table.concat(reverse_received) == table.concat(reverse_expected), 'reverse RX stream differs')

local q = cabinet('A', 'backpressure')
q:enqueue(string.rep('\255', 255))
for i = 1, 8 do q:pump() end
check(q:r(0x880105) == 255, 'TX capacity must be 255')
q:enqueue('x'); q:pump()
check(q.space:read_u16(0xffa524) == 1, 'full TX must stall without underflow')
failures[q.out] = 'open'; q.frame()
check(q:r(0x880105) == 255, 'failed output open must retain credit and bytes')
failures[q.out] = nil; q.frame(); q:pump(); q.frame()
check(files[q.out] == string.rep('\255', 255) .. 'x', 'TX retry lost bytes')

local race = cabinet('A', 'frame-race')
race:enqueue('old'); race:pump()
race:enqueue('new')
race:pump(function(phase, i)
	if phase == 'payload' and i == 1 then
		race.frame()
		check(files[race.out] == 'old', 'partial burst leaked to transport')
	end
end)
check(race:r(0x880105) == 3, 'partial burst ACK damaged occupancy')
race:enqueue('end')
race:pump(function(phase)
	if phase == 'credit-read' then race.frame() end
end)
check(race:r(0x880105) == 3, 'RMW write reused stale pre-ACK credit')
race.frame()
check(files[race.out] == 'oldnewend', 'mid-RMW frame duplicated or lost bytes')
race.space:write_u16(0xffa522, 0); race.frame()
check(files[race.out] == 'oldnewend', 'reset tail movement captured RAM garbage')
race.space:write_u16(0xffa504, 777); race.frame()
check(race.space:read_u16(0xffa504) == 777, 'watchdog was masked')

local rx = cabinet('B', 'rx-capacity')
files['rx-capacity\\A_to_B.bin'] = 'abc'
rx.space:write_u16(0xffa52c, 254)
rx.space:write_u16(0xffa528, 254)
rx.frame()
check(rx.space:read_u16(0xffa52c) == 254, 'frame callback injected during arbitrary ROM instruction')
rx:pump()
check(rx.space:read_u16(0xffa52c) == 255, 'RX exceeded 255')
rx:consume(1); rx:pump()
check(rx.space:read_u16(0xffa52c) == 255, 'RX backpressure lost a queued byte')
rx:consume(); rx:pump()
check(rx:consume() == 'c', 'RX did not retain backlog')
rx.space:write_u16(0xffa52c, 256)
files['rx-capacity\\A_to_B.bin'] = 'abcd'; rx.frame(); rx:pump()
check(rx.space:read_u16(0xffa52c) == 256, 'invalid count was silently masked and overwritten')
check(files[rx.log]:find('[ring-error]', 1, true), 'invalid RX count was not diagnosed')

local bad = cabinet('A', 'io-failure')
bad:enqueue('abc'); bad:pump()
failures[bad.out] = 'write'; bad.frame()
failures[bad.out] = nil; bad.frame()
check(files[bad.out] == '', 'ambiguous append failure was retried')
check(files[bad.log]:find('[transport-error]', 1, true), 'append failure was not diagnosed')

race.cpu.state.PC.value = 0x1845c
race.space:write_u8(0xffa516, 0x3c)
race.taps.puyo2link_packets(0xffa514, 1, 255)
check(files[race.log]:find('[packet-accepted] total=1 seq=00 flags=3c', 1, true), 'ROM parser instrumentation')
for i = 1, 60 do race.frame() end
check(files[race.log]:find('payload2=1 payload3=1 payload4=1 payload5=1', 1, true), 'payload counters')
check(files[race.log]:find('ffa580=', 1, true) and files[race.log]:find('ffa5c0=', 1, true), 'dedicated TCBs omitted')
race:w(0x880111, 0xfc00, 0xff00)
check(race:r(0x880105) == 0, 'upper bus lane changed mailbox')
local before_reset = files[race.out]
race.prestart(); race:boot()
race:enqueue('reset'); race:pump(); race.frame()
check(files[race.out] == before_reset .. 'reset', 'machine reset truncated stream or refused to restart')
local old_stream = files[race.out]
-- No taps should be installed when prestart refuses the existing stream.
local ok = pcall(function() cabinet('A', 'frame-race') end)
check(not ok and files[race.out] == old_stream, 'existing stream was overwritten')
check(files[race.log]:find('Refusing to overwrite', 1, true), 'existing-stream refusal not diagnosed')

print(string.format('PASS: %d callback assertions (%s); no MAME/gameplay execution', checks, _VERSION))
os.exit(0)
