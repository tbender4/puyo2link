-- Optional input-only live exercise; never writes emulated memory.
-- Launch with -autoboot_script PuyoPuyo2\re_notes\exercise_link.lua
-- Screenshots and input records identify what
-- actually happened; this is not an assertion that linked play succeeded.
-- PUYO2_EXERCISE_RANDOM_ONLY=1 on B replaces the exercise with random
-- Left/Right/Button 1 on both local players, only while pieces are active.
-- Coin/start, menus and Down remain manual; no screenshots are taken.
local machine = manager.machine
local side = os.getenv('PUYO2_LINK_SIDE') or 'A'
local dir = assert(os.getenv('PUYO2_LINK_DIR'))
local random_only = os.getenv('PUYO2_EXERCISE_RANDOM_ONLY') == '1'
assert(not random_only or side == 'B', 'random-only input is restricted to cabinet B')
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
local random_plans = {}
local reset_frame = tonumber(os.getenv('PUYO2_EXERCISE_RESET_FRAME') or '0')
local reset_count = tonumber(os.getenv('PUYO2_EXERCISE_RESET_COUNT') or '1')
local difficulty_choice = tonumber(os.getenv('PUYO2_EXERCISE_DIFFICULTY') or '')
assert(not difficulty_choice or (difficulty_choice >= 0 and difficulty_choice <= 2
	and difficulty_choice % 1 == 0), 'difficulty menu index must be 0, 1 or 2')
local function input(port, name, value)
	local p = machine.ioport.ports[port]
	local field = p and p.fields[name]
	assert(field, 'Missing exercise input: ' .. port .. ' ' .. name)
	if value then field:set_value(1) else field:clear_value() end
end
if not random_only then
	for _, name in ipairs({ 'Coin 1', '1 Player Start', '2 Players Start' }) do
		input(':SERVICE', name, false)
	end
end
for _, player in ipairs({ 'P1', 'P2' }) do
	local names = random_only and { 'Left', 'Right', 'Button 1' }
		or { 'Left', 'Right', 'Down', 'Button 1' }
	for _, name in ipairs(names) do
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
local function active_players()
	local s = machine.devices[':maincpu'].spaces.program
	local active = {}
	for task = 0xffd100, 0xffefc0, 64 do
		if s:read_u8(task) ~= 0 and s:read_u32(task + 2) == 0x7944 then
			active[s:read_u8(task + 0x2a)] = task
		end
	end
	return active
end

local function random_play()
	local active = active_players()
	for player = 0, 1 do
		local name = 'P' .. (player + 1)
		local plan = random_plans[player]
		if active[player] then
			if not plan then
				plan = { move_at = 0, turn_at = 0, direction = 0, turn_until = 0 }
				random_plans[player] = plan
			end
			if frame >= plan.move_at then
				plan.direction = math.random(-1, 1)
				plan.move_at = frame + math.random(10, 30)
				log:write(string.format('random frame=%d player=%d direction=%d\n',
					frame, player + 1, plan.direction))
			end
			if frame >= plan.turn_at then
				plan.turn_until = frame + 3
				plan.turn_at = frame + math.random(12, 45)
				log:write(string.format('random frame=%d player=%d rotate\n', frame, player + 1))
			end
			input(':' .. name, name .. ' Left', plan.direction == -1)
			input(':' .. name, name .. ' Right', plan.direction == 1)
			input(':' .. name, name .. ' Button 1', frame < plan.turn_until)
		else
			random_plans[player] = nil
			for _, button in ipairs({ 'Left', 'Right', 'Button 1' }) do
				input(':' .. name, name .. ' ' .. button, false)
			end
		end
	end
	log:flush()
end

local function play()
	local s = machine.devices[':maincpu'].spaces.program
	local active = active_players()
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
-- Optional original menu selection, not a write to the difficulty variable.
-- Role A owns the selector at $241ac; B sends input requests to that task.
local function choose_difficulty()
	if not difficulty_choice then return false end
	local s = machine.devices[':maincpu'].spaces.program
	for task = 0xffd100, 0xffefc0, 64 do
		local pc = s:read_u32(task + 2)
		if s:read_u8(task) ~= 0 and pc >= 0x241ac and pc <= 0x2437e then
			if side == 'A' and pc == 0x241de and frame % 12 == 0
				and s:read_u8(task + 0x26) == s:read_u8(task + 0x27) then
				local choice = s:read_u8(task + 0x26)
				log:write(string.format('difficulty frame=%d current=%d target=%d\n',
					frame, choice, difficulty_choice)); log:flush()
				press(':P1', choice == difficulty_choice and 'P1 Button 1' or 'P1 Left')
			end
			return true
		end
	end
	return false
end
local function tick()
	frame = frame + 1
	if random_only then
		random_play()
		return
	end
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
	local selecting_difficulty = choose_difficulty()
	if frame > start + 180 and frame < 1200 and frame % 90 == 0 and not selecting_difficulty then
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
	if frame >= 1200 and not selecting_difficulty then play() end
end
-- Keep notifier handles live for the entire script.
puyo2_exercise_frame = emu.add_machine_frame_notifier(tick)
puyo2_exercise_stop = emu.add_machine_stop_notifier(function()
	if random_only then
		for _, name in ipairs({ 'P1', 'P2' }) do
			for _, button in ipairs({ 'Left', 'Right', 'Button 1' }) do
				input(':' .. name, name .. ' ' .. button, false)
			end
		end
	end
	log:close()
end)
