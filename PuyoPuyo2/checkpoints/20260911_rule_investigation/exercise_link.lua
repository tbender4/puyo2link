-- Optional input-only live exercise; never writes emulated memory.
-- Launch with -autoboot_script PuyoPuyo2\re_notes\exercise_link.lua
-- and PUYO2_AUTO_INPUT=0. Screenshots and input records identify what
-- actually happened; this is not an assertion that linked play succeeded.
local machine = manager.machine
local side = os.getenv('PUYO2_LINK_SIDE') or 'A'
local dir = assert(os.getenv('PUYO2_LINK_DIR'))
if puyo2_exercise_frame then puyo2_exercise_frame:unsubscribe() end
if puyo2_exercise_stop then puyo2_exercise_stop:unsubscribe() end
if puyo2_exercise_log then puyo2_exercise_log:close() end
local log = assert(io.open(dir .. '\\exercise_' .. side .. '.log', 'a'))
puyo2_exercise_log = log
puyo2_exercise_generation = (puyo2_exercise_generation or 0) + 1
local generation = puyo2_exercise_generation
local frame = 0
local held = {}
local plans = {}
local reset_frame = tonumber(os.getenv('PUYO2_EXERCISE_RESET_FRAME') or '0')
local reset_count = tonumber(os.getenv('PUYO2_EXERCISE_RESET_COUNT') or '1')
local function input(port, name, value)
	local p = machine.ioport.ports[port]
	local field = p and p.fields[name]
	if not field then return end
	if value then field:set_value(1) else field:clear_value() end
end
for _, name in ipairs({ 'Coin 1', '1 Player Start', '2 Players Start' }) do
	input(':SERVICE', name, false)
end
for _, player in ipairs({ 'P1', 'P2' }) do
	for _, name in ipairs({ 'Left', 'Right', 'Down', 'Button 1' }) do
		input(':' .. player, player .. ' ' .. name, false)
	end
end
for port, p in pairs(machine.ioport.ports) do
	for name in pairs(p.fields) do log:write(port .. ' ' .. name .. '\n') end
end
log:flush()
local function press(port, name)
	input(port, name, true)
	held[#held + 1] = { port, name, frame + 3 }
	log:write(string.format('%d %s %s\n', frame, port, name))
	log:flush()
end
-- Use ordinary joystick inputs to place vertical pairs. The only RAM
-- inspection is the field/task state confirmed at $1911a/$788e/$7944.
-- No field, score, protection flag or game task is ever written.
local function play()
	local s = machine.devices[':maincpu'].spaces.program
	local active = {}
	for task = 0xffd100, 0xffefc0, 64 do
		if s:read_u8(task) ~= 0 and s:read_u32(task + 2) == 0x7944 then
			active[s:read_u8(task + 0x2a)] = task
		end
	end
	for player = 0, 1 do
		local name = 'P' .. (player + 1)
		local task = active[player]
		local left, right, down = false, false, false
		if task then
			local count = s:read_u16(0xff85a6 + player * 0x800)
			local plan = plans[player]
			if not plan or plan.count ~= count then
				local base = 0xff8000 + player * 0x800
				local colors = { s:read_u8(task + 8) + 8,
					s:read_u8(s:read_u32(task + 0x36) + 8) + 8 }
				local board = {}
				for y = 0, 13 do
					for x = 0, 5 do board[y * 6 + x] = s:read_u8(base + y * 12 + x * 2) >> 4 end
				end
				local best, target = -math.huge, 2
				for j = 0, 5 do
					local x = (j + count + player + (side == 'A' and 0 or 3)) % 6
					local y = 13
					while y >= 0 and board[y * 6 + x] ~= 0 do y = y - 1 end
					if y >= 1 then
						local b = {}
						for k, v in pairs(board) do b[k] = v end
						b[y * 6 + x], b[(y - 1) * 6 + x] = colors[1], colors[2]
						local seen, score = {}, y * 3
						for cell = 0, 83 do
							if not seen[cell] and b[cell] >= 8 and b[cell] <= 13 then
								local group, q = { cell }, 1
								seen[cell] = true
								while q <= #group do
									local c = group[q]
									local neighbors = {}
									if c % 6 > 0 then neighbors[#neighbors + 1] = c - 1 end
									if c % 6 < 5 then neighbors[#neighbors + 1] = c + 1 end
									if c >= 6 then neighbors[#neighbors + 1] = c - 6 end
									if c < 78 then neighbors[#neighbors + 1] = c + 6 end
									for _, n in ipairs(neighbors) do
										if not seen[n] and b[n] == b[c] then seen[n] = true; group[#group + 1] = n end
									end
									q = q + 1
								end
								score = score + (#group >= 4 and 100 * #group or #group * #group)
							end
						end
						if score > best then best, target = score, x end
					end
				end
				plan = { count = count, target = target }
				plans[player] = plan
				log:write(string.format('placement frame=%d player=%d pair=%d colors=%x,%x target=%d\n',
					frame, player + 1, count, colors[1], colors[2], target)); log:flush()
			end
			local x = s:read_u16(task + 0x1a)
			left, right, down = x > plan.target, x < plan.target, x == plan.target
		end
		input(':' .. name, name .. ' Left', left)
		input(':' .. name, name .. ' Right', right)
		input(':' .. name, name .. ' Down', down)
	end
end
local function tick()
	frame = frame + 1
	if reset_frame > 0 and frame == reset_frame and (puyo2_exercise_resets or 0) < reset_count then
		puyo2_exercise_resets = (puyo2_exercise_resets or 0) + 1
		log:write('hardware soft reset at frame ' .. frame .. '\n'); log:flush()
		machine:soft_reset()
	end
	for i = #held, 1, -1 do
		if frame >= held[i][3] then
			input(held[i][1], held[i][2], false)
			table.remove(held, i)
		end
	end
	local start = side == 'A' and 60 or 420
	if frame == start or frame == start + 15 or frame == start + 30 or frame == start + 45 then
		press(':SERVICE', 'Coin 1')
	end
	if frame == start + 90 or frame == start + 150 then
		press(':SERVICE', '1 Player Start')
	end
	if frame == start + 210 or frame == start + 270 or frame == start + 900 then
		press(':SERVICE', '2 Players Start')
	end
	if frame > start + 180 and frame < 1200 and frame % 90 == 0 then
		press(':P1', 'P1 Button 1')
		press(':P2', 'P2 Button 1')
	end
	if frame % 600 == 0 then
		for _, screen in pairs(machine.screens) do
			screen:snapshot(string.format('%s\\exercise_%s_g%d_%04d.png', dir, side, generation, frame))
		end
		local s = machine.devices[':maincpu'].spaces.program
		local dump = assert(io.open(string.format('%s\\ram_%s_g%d_%04d.bin', dir, side, generation, frame), 'wb'))
		local bytes = {}
		for a = 0xff8000, 0xffefff do bytes[#bytes + 1] = string.char(s:read_u8(a)) end
		dump:write(table.concat(bytes)); dump:close()
		log:write(string.format('state frame=%d mode=%02x match=%02x command=%04x protection=%02x\n',
			frame, s:read_u8(0xffa130), s:read_u8(0xffa142), s:read_u16(0xffa530), s:read_u8(0xffa026)))
		log:flush()
	end
	if frame >= 1200 then play() end
end
-- Keep notifier handles live for the entire script.
puyo2_exercise_frame = emu.add_machine_frame_notifier(tick)
puyo2_exercise_stop = emu.add_machine_stop_notifier(function() log:close() end)
