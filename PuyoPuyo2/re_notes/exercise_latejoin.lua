-- Isolated, input-only late-join investigation. No game-memory writes.
-- Both cabinets boot together; B coins only after A has active pieces.
local m = manager.machine
local s = m.devices[':maincpu'].spaces.program
local side = assert(os.getenv('PUYO2_LINK_SIDE'))
local dir = assert(os.getenv('PUYO2_LINK_DIR'))
local choice = os.getenv('PUYO2_LATEJOIN_CHOICE') or 'yes'
local recruit_delay = tonumber(os.getenv('PUYO2_LATEJOIN_RECRUIT_DELAY') or '420')
assert(({yes=true, yes_timeout=true, start1=true, start2=true, button1=true, button2=true})[choice],
	'unknown late-join input case')
local log = assert(io.open(dir .. '\\latejoin_' .. side .. '.log', 'w'))
local frame, start, invite, last = 0, side == 'A' and 60 or nil, nil, ''
local held, plans = {}, {}
local signalled = false
local function record(text)
	log:write(string.format('%d %.3f %s\n', frame, emu.time(), text)); log:flush()
end
local function input(port, name, value)
	local field = assert(m.ioport.ports[port].fields[name], name)
	field:set_value(value and 1 or 0)
end
local function press(port, name)
	input(port, name, true)
	held[#held + 1] = {port, name, frame + 3}
	record('input ' .. port .. ' ' .. name)
end
local function snapshot(tag)
	for _, screen in pairs(m.screens) do
		screen:snapshot(string.format('%s\\latejoin_%s_%04d_%s.png', dir, side, frame, tag))
	end
	local f = assert(io.open(string.format('%s\\latejoin_%s_%04d_%s.bin', dir, side, frame, tag), 'wb'))
	local bytes = {}
	for a = 0xff8000, 0xffefff do bytes[#bytes + 1] = string.char(s:read_u8(a)) end
	f:write(table.concat(bytes)); f:close()
end
for _, port in ipairs({':SERVICE', ':P1', ':P2'}) do
	for name, field in pairs(m.ioport.ports[port].fields) do
		-- Keep unrelated physical keyboard/controller input out of this test.
		field:set_value(0)
		record('mapping ' .. port .. ' ' .. name .. ' ' ..
			m.input:seq_to_tokens(field:input_seq('standard')))
	end
end
latejoin_tap = s:install_write_tap(0xffd06a, 0xffd06b, 'latejoin_choice',
	function(offset, data, mask)
		record(string.format('menu-write pc=%06x data=%04x mask=%04x oldchoice=%d done=%d',
			m.devices[':maincpu'].state.PC.value, data, mask, s:read_u8(0xffd06a), s:read_u8(0xffd06b)))
	end)
latejoin_peer_tap = s:install_read_tap(0xffa7a6, 0xffa7a7, 'latejoin_recruit_peer',
	function(offset, data, mask)
		local pc = m.devices[':maincpu'].state.PC.value
		if pc >= 0x18bd4 and pc <= 0x18be2 then
			record(string.format('recruit-peer-read pc=%06x data=%04x mask=%04x localmask=%02x',
				pc, data, mask, s:read_u8(0xffa13f)))
		end
	end)
latejoin_frame = emu.add_machine_frame_notifier(function()
	frame = frame + 1
	for i = #held, 1, -1 do
		if frame >= held[i][3] then input(held[i][1], held[i][2], false); table.remove(held, i) end
	end
	local active = {}
	for task = 0xffd100, 0xffefc0, 64 do
		if s:read_u8(task) ~= 0 and s:read_u32(task + 2) == 0x7944 then
			active[s:read_u8(task + 0x2a)] = task
		end
	end
	if side == 'A' and not signalled and start and frame > start + 600
		and (active[0] or active[1]) and s:read_u8(0xffa142) == 2
		and s:read_u8(0xffa13f) == 3 then
		signalled = true
		record('A actual local gameplay; releasing B join schedule')
		snapshot('prejoin_active')
		local f = assert(io.open(dir .. '\\A_active', 'w')); f:write(frame); f:close()
	end
	if side == 'B' and not start then
		local f = io.open(dir .. '\\A_active', 'r')
		if f then f:close(); start = frame + 180; record('B saw A active; delayed coin schedule') end
	end
	if start then
		local t = frame - start
		if t == 0 or t == 15 or t == 30 or t == 45 then press(':SERVICE', 'Coin 1') end
		if t == 90 or (side == 'A' and t == 150)
			or (side == 'B' and not invite and t > 90 and t % 60 == 30) then
			press(':SERVICE', '1 Player Start')
		end
		if side == 'A' and (t == 210 or t == 270) then press(':SERVICE', '2 Players Start') end
	end
	local menupc = s:read_u32(0xffd042)
	local selecting = s:read_u8(0xffd040) ~= 0 and menupc == 0x19c6e
	if side == 'B' and selecting and not invite then
		invite = frame; record('invitation ready choice=' .. choice); snapshot('invite_default')
	end
	if invite then
		local t = frame - invite
		local player = s:read_u8(0xffa17d) == 0 and 'P1' or 'P2'
		if t == 12 then
			if choice == 'yes' or choice == 'yes_timeout' then press(':' .. player, player .. ' Down')
			elseif choice == 'start1' then press(':SERVICE', '1 Player Start')
			elseif choice == 'start2' then press(':SERVICE', '2 Players Start')
			elseif choice == 'button1' then press(':' .. player, player .. ' Button 1')
			elseif choice == 'button2' then press(':' .. player, player .. ' Button 2') end
		end
		if t == 24 then snapshot('invite_after_input') end
		if t == 30 and choice == 'yes' then press(':' .. player, player .. ' Button 1') end
		if t == 90 or t == 180 or t == 300 then snapshot('join_progress') end
		if t == recruit_delay or t == recruit_delay + 60 or t == recruit_delay + 120 then
			press(':SERVICE', '2 Players Start')
		end
	end
	-- Confirm subsequent native recruitment/difficulty screens, never the invitation.
	if start and frame > start + 180 and frame % 90 == 0 and not selecting
		and (side == 'A' or (invite and frame > invite + 360)) then
		press(':P1', 'P1 Button 1'); press(':P2', 'P2 Button 1')
	end
	for player = 0, 1 do
		local task, name = active[player], 'P' .. (player + 1)
		if task then
			local count = s:read_u16(0xff85a6 + player * 0x800)
			local plan = plans[player]
			if not plan or plan.count ~= count then
				plan = {count = count, target = (count + player * 3) % 6}
				plans[player] = plan
				record(string.format('piece player=%d count=%d mode=%d match=%d mask=%02x',
					player, count, s:read_u8(0xffa130), s:read_u8(0xffa142), s:read_u8(0xffa13f)))
			end
			local x = s:read_u16(task + 0x1a)
			input(':' .. name, name .. ' Left', x > plan.target)
			input(':' .. name, name .. ' Right', x < plan.target)
		else
			input(':' .. name, name .. ' Left', false)
			input(':' .. name, name .. ' Right', false)
		end
	end
	local state = string.format('mode=%02x match=%02x mask=%02x players=%d command=%04x peer=%04x script=%08x flow=%08x menu=%08x flags=%02x offer=%02x header=%02x/%02x choice=%d done=%d selector=%d active=%s/%s',
		s:read_u8(0xffa130), s:read_u8(0xffa142), s:read_u8(0xffa13f), s:read_u8(0xffa13e),
		s:read_u16(0xffa530), s:read_u16(0xffa7a2), s:read_u32(0xffa050), s:read_u32(0xffa174),
		menupc, s:read_u8(0xffa170), s:read_u8(0xffa17f), s:read_u8(0xffa513), s:read_u8(0xffa517),
		s:read_u8(0xffd06a), s:read_u8(0xffd06b), s:read_u8(0xffa17d), tostring(active[0] ~= nil), tostring(active[1] ~= nil))
	if state ~= last then record(state); last = state end
	if frame % 600 == 0 then snapshot('periodic') end
end)
latejoin_stop = emu.add_machine_stop_notifier(function()
	for _, port in ipairs({':SERVICE', ':P1', ':P2'}) do
		for _, field in pairs(m.ioport.ports[port].fields) do field:clear_value() end
	end
	log:close()
end)
