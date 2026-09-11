-- puyo2link/init.lua
--
-- Software emulation of the Puyo Puyo 2 (arcade, Sega System C2) 4-player
-- link daughterboard, built purely from reverse-engineering the 68000
-- program ROM (no real daughterboard hardware was available). See
-- ../../PuyoPuyo2/re_notes/COMM_PROTOCOL_SPEC.md for the full write-up.
--
-- This does NOT touch MAME's C++ source. It uses Lua memory taps
-- (space:install_read_tap / install_write_tap) to intercept the CN4
-- mailbox window at $880100-$88013F on the 68000 program bus and
-- substitute our own emulated register file for it, then bridges two
-- MAME processes (one per "cabinet") over generation-tagged local journals.
-- Separate raw .bin files retain committed payload bytes for analysis.
--
-- IMPORTANT Lua/GC note: every handle whose lifetime must span the
-- whole session (tap handles, notifier subscriptions) MUST be stored
-- in a variable at FILE (module) scope, not as a local declared inside
-- startplugin()'s own call frame. MAME's Lua bindings return RAII-style
-- userdata for install_read_tap/install_write_tap/add_machine_*_notifier
-- whose C++ destructor unsubscribes it; if nothing keeps a Lua
-- reference to that userdata after startplugin() returns, the garbage
-- collector reclaims it within the first few frames and everything
-- silently stops working with no error printed. (This exact bug was
-- hit and fixed during development of this plugin.)
--
-- Empirically confirmed on this MAME build (0.289): the m68000 core
-- presents byte accesses to this space with `offset` as the EVEN
-- (word-aligned) base address and mem_mask=0x00ff selecting the low
-- byte lane (this hardware is only wired to D0-D7, matching the
-- driver's own umask16(0x00ff)). So the real target byte address is
-- always `offset + 1`, and the byte value is `data & 0xff` for writes.
--
-- Environment variables (set before launching mame.exe):
--   PUYO2_LINK_SIDE = "A" or "B"   (which cabinet this instance is)
--   PUYO2_LINK_DIR  = shared folder both instances can read/write
--                     (use a fresh folder for each process pair)
--   PUYO2_LINK_DEBUG = "1" enables detailed game/protection/packet traces

local exports = {
	name = 'puyo2link',
	version = '0.6.2',
	description = 'Puyo Puyo 2 (arcade) 4-player link emulation',
	license = 'CC0',
	author = { name = 'reverse-engineered, see PuyoPuyo2/re_notes' } }

local transport_factory = require('puyo2link.transport')
local link

local BASE = 0x880100
local ADDR_MESSAGE_BASE = 0x880101   -- 8 rotating slots: +0,+2,+4,...,+14
local ADDR_RXCREDIT     = 0x880107
local ADDR_COMMAND      = 0x880111
local ADDR_CONTROL      = 0x880131
local IDENT_RESPONSE = { string.byte('PUYO2Z80', 1, 8) }

-- TX payload is captured only while a TX bank is selected ($18740-$18764).
-- $FF selects separate control registers: payload must never overwrite credit
-- or stream positions. RX banks feed the ROM's own copy loop ($18784-$1880e);
-- only the CPU writes its software ring and occupancy.
local RAM_TX_TAIL  = 0xffa522   -- word: TX ring drain/tail index
local RAM_RX_RING  = 0xffa900   -- 256-byte RX ring
local RAM_RX_HEAD  = 0xffa528   -- word: RX ring fill/head index
local RAM_RX_PEND  = 0xffa52c   -- word: RX ring pending (unconsumed) count

-- All of these are file-scope locals on purpose -- see note above.
local read_tap, write_tap, frame_sub, stop_sub, prestart_sub, dbg_tap, dbg_tap2, dbg_tap3
local packet_tap, gameplay_tap, protection_tap, checksum_tap, attack_tap, divisor_tap
local logf
local side, peer_side, link_dir, out_path, in_path
-- NOTE: table LITERALS like {0,0,0,0,0,0,0,0} are 1-indexed in Lua (keys
-- 1..8), but slot_index_for() below hands out 0-based indices (0..7) to
-- match the hardware's own $880101+0, +2, ... +14 offsets. Always build
-- the slot table through this helper, never a bare {..} literal, or
-- slot[0] silently ends up nil (this bit us once already: the FE
-- loopback handler looked fine but slot[0] was never actually set,
-- so the game read back garbage/unmapped forever instead of our answer).
local function fresh_slots(v0)
	return { [0] = v0 or 0, 0, 0, 0, 0, 0, 0, 0 }
end

local slot = fresh_slots()
local tx_bank = {}
local tx_burst = {}
local rx_bank = {}
local rx_write, rx_count, rx_ack = 0, 0, 0
local bank_block = 0
local current_bank = 'cmd'          -- 'cmd' | 'tx' | 'rx'
local diagnostics_enabled = false
-- FE success, rather than bank alone, separates handshake responses from
-- runtime credit: the ROM selects CONTROL ($FF) immediately before RxCredit.
local established_seen = false
local out_queue = {}                -- exact mailbox payload bytes, waiting for durable file output
local frame_count = 0
local stats = {}
local last_tasks, last_gameplay
local io_error_seen = false
local active = false
local started = false
local fd_since_fc = 0   -- see on_command_write's $FD handling: the 1st $FD after
                        -- an $FC is a CRC-status display read (0 = no error),
                        -- every $FD after that is the loop-echo verification
                        -- (expects Slot[]=$FF filled) -- same command byte,
                        -- two different meanings, confirmed via the actual
                        -- in-game "(CRC ERROR)" text tracing back to $ffa509.

local function log(msg)
	if logf then
		logf:write(string.format('[%8.3f] %s\n', emu.time(), msg))
		logf:flush()
	end
end

local function slot_index_for(addr)
	local rel = addr - ADDR_MESSAGE_BASE
	if rel < 0 or rel > 14 or (rel % 2) ~= 0 then
		return nil
	end
	return rel // 2
end

local function on_command_write(byte)
	if byte == 0xFC then
		for i = 0, 7 do slot[i] = IDENT_RESPONSE[i + 1] end
		current_bank = 'cmd'
		stats.cmd_fc = stats.cmd_fc + 1
		fd_since_fc = 0
	elseif byte == 0xFD then
		fd_since_fc = fd_since_fc + 1
		if fd_since_fc == 1 then
			-- CRC-status display read: $ffa509 (== Slot[0]) must be 0 for
			-- the test menu to show "BORD IS OK" with no "(CRC ERROR)"
			-- suffix (confirmed by tracing the display code at ROM $35f6).
			slot[0] = 0x00
		else
			-- loop-echo verification: the handshake expects all 8 slots
			-- to read back $FF here (ROM $018316-$018328).
			for i = 0, 7 do slot[i] = 0xFF end
		end
		current_bank = 'cmd'
		stats.cmd_fd = stats.cmd_fd + 1
	elseif byte == 0xFE then
		-- $18334 installs the retry continuation before this query.
		-- Returning zero leaves the ROM waiting safely until both reset
		-- generations are ready; it does not advance either sequence.
		link:poll()
		if not link:handshake() then
			slot = fresh_slots()
			current_bank = 'cmd'
			return
		end
		-- NOTE (corrected after live test): the 68000 code treats a ZERO
		-- readback here as "not ready yet, keep retrying" and only
		-- proceeds (setting the $ffa500 bit7 established flag) on a
		-- NONZERO readback. Original spec had this inverted.
		-- Also clear slots 1-7: leftover handshake bytes (identity
		-- string / 0xFF fill) must not leak into the runtime TX/RX
		-- credit registers (slots 2 and 3, i.e. $880105/$880107) or
		-- the game reads a bogus nonzero "credit" on its first runtime
		-- pump call and resets the whole link.
		-- This is identity, not just a boolean: $6374/$64b2/$197c6
		-- explicitly compare $ffa500 with $82 to select the other role.
		slot = fresh_slots(side == 'A' and 1 or 2)
		current_bank = 'cmd'
		established_seen = true
		stats.cmd_fe = stats.cmd_fe + 1
		log(string.format('CMD $FE -> cabinet role=%d (ROM linkflag=%02x)',
			slot[0], slot[0] | 0x80))
	elseif byte == 0xFF then
		current_bank = 'cmd'
	elseif byte < 0x20 then
		if current_bank ~= 'tx' then stats.tx_bursts = stats.tx_bursts + 1 end
		current_bank = 'tx'
		bank_block = byte
	elseif byte < 0x40 then
		current_bank = 'rx'
		bank_block = byte - 0x20
	else
		log(string.format('[mailbox] unexpected command=%02x', byte))
	end
end

local function on_write(offset, data, mem_mask)
	if (mem_mask & 0xff) == 0 then
		return nil
	end
	local addr = offset + 1
	local byte = data & 0xff

	if addr == ADDR_COMMAND then
		on_command_write(byte)
		return nil
	end
	if addr == ADDR_CONTROL then
		if byte == 1 then
			local ok, pc = pcall(function()
				return manager.machine.devices[':maincpu'].state['PC'].value
			end)
			log(string.format('CONTROL reset pulse start (pc=%s, prev_bank=%s)',
				ok and string.format('%06x', pc) or 'err', current_bank))
			current_bank = 'cmd'
			slot = fresh_slots()
			tx_bank = {}
			tx_burst = {}
			rx_bank = {}
			rx_write, rx_count, rx_ack = 0, 0, 0
			fd_since_fc = 0
			established_seen = false

			-- ROM $181ea-$18208 already clears ALL ring bookkeeping.
			-- Only discard plugin queues here, never repair game RAM.
			log(string.format('[reset] discarded tx=%d rx=%d', #out_queue, #link.queue))
			out_queue = {}
			link:reset()
		end
		return nil
	end
	local idx = slot_index_for(addr)
	if idx ~= nil then
		if current_bank == 'tx' and established_seen then
			tx_bank[bank_block * 8 + idx] = byte
			tx_burst[#tx_burst + 1] = byte
			stats.tx_bytes = stats.tx_bytes + 1
		elseif current_bank == 'cmd' and idx == 2 and established_seen then
			-- $18778 commits the burst by adding its length to TxCredit.
			-- A frame callback can occur mid-burst or even between this
			-- RMW's read/write. Derive occupancy from committed bytes,
			-- never from a possibly stale bus value after an async ACK.
			for _, b in ipairs(tx_burst) do out_queue[#out_queue + 1] = b end
			tx_burst = {}
		elseif current_bank == 'cmd' and idx == 1 and established_seen then
			rx_ack = rx_ack + ((byte - slot[1]) & 255)
			slot[1] = byte
		elseif current_bank == 'cmd' and idx == 3 and established_seen then
			-- $18804 publishes the consumer position; $1880e commits it.
			-- Derive the ACK from that position, not a stale SUB.B bus value:
			-- a frame callback can publish more bytes between its read/write.
			if rx_ack > rx_count then
				link:fail('RX acknowledgement exceeds published occupancy')
				return nil
			end
			rx_count = rx_count - rx_ack
			stats.rx_bytes = stats.rx_bytes + rx_ack
			rx_ack = 0
		else
			slot[idx] = byte
		end
	end
	return nil
end

local function on_read(offset, data, mem_mask)
	if (mem_mask & 0xff) == 0 then
		return nil
	end
	local addr = offset + 1
	local function low(value) return (data & 0xff00) | value end
	if addr == ADDR_RXCREDIT and established_seen and current_bank == 'cmd' then
		stats.pump_reads = stats.pump_reads + 1
		return low(link:valid() and rx_count or 0)
	end
	local idx = slot_index_for(addr)
	if idx == nil then
		return nil
	end
	if current_bank == 'tx' and established_seen then
		return low(tx_bank[bank_block * 8 + idx] or 0)
	end
	if current_bank == 'rx' and established_seen then
		return low(rx_bank[bank_block * 8 + idx] or 0)
	end
	if current_bank == 'cmd' and idx == 2 and established_seen then
		return low(link:valid() and #out_queue or 255)
	end
	return low(slot[idx])
end

local function flush_and_poll()
	link:poll()
	if link.failed then active = false; return end
	if #out_queue > 0 and link:valid() then
		local sent = link:send(string.char(table.unpack(out_queue)))
		if sent > 0 then
			stats.flushed = stats.flushed + sent
			-- TxCredit reads committed, unflushed occupancy directly.
			out_queue = {}
			io_error_seen = false
		elseif not io_error_seen then
			log('[transport-error] cannot open output; retaining bytes and TX credit')
			io_error_seen = true
		end
	end
	if link.failed then active = false end
end

local function do_prestart()
	-- A reset reuses this Lua module. Replacing a handle only makes it
	-- eligible for GC; its old tap can still fire meanwhile, duplicating
	-- payload writes and CONTROL resets. Uninstall synchronously first.
	for _, tap in pairs({ read_tap, write_tap, dbg_tap, dbg_tap2, dbg_tap3,
		packet_tap, gameplay_tap, protection_tap, checksum_tap, attack_tap, divisor_tap }) do
		tap:remove()
	end
	if emu.romname() ~= 'puyopuy2' then
		active = false
		return
	end

	diagnostics_enabled = os.getenv('PUYO2_LINK_DEBUG') == '1'
	side = os.getenv('PUYO2_LINK_SIDE') or 'A'
	if side ~= 'A' and side ~= 'B' then error('PUYO2_LINK_SIDE must be A or B') end
	peer_side = (side == 'A') and 'B' or 'A'
	link_dir = os.getenv('PUYO2_LINK_DIR') or 'C:\\Users\\tbend\\mame\\PuyoPuyo2\\link_ipc'
	pcall(function() lfs.mkdir(link_dir) end)

	out_path = link_dir .. '\\' .. side .. '_to_' .. peer_side .. '.bin'
	in_path = link_dir .. '\\' .. peer_side .. '_to_' .. side .. '.bin'

	if logf then logf:close() end
	logf = assert(io.open(link_dir .. '\\proto_' .. side .. '.log', 'a'))
	log('=== session start, version=' .. exports.version .. ' side=' .. side
		.. ' debug=' .. tostring(diagnostics_enabled) .. ' ===')

	local outf = assert(io.open(out_path, 'ab'))
	local existing = outf:seek('end')
	outf:close()
	-- register_prestart also runs on MACHINE_NOTIFY_RESET, not just
	-- process startup. Preserve append offsets across service/F3 resets.
	if existing ~= 0 and not started then
		log('Refusing to overwrite an existing stream; use a fresh PUYO2_LINK_DIR')
		active = false
		return
	end
	if not link then
		local err
		link, err = transport_factory.new(out_path, in_path, log)
		if not link then
			log('[transport-error] ' .. tostring(err))
			active = false
			return
		end
	end
	started = true
	out_queue = {}
	slot = fresh_slots()
	tx_bank = {}
	tx_burst = {}
	rx_bank = {}
	rx_write, rx_count, rx_ack = 0, 0, 0
	bank_block = 0
	current_bank = 'cmd'
	established_seen = false
	frame_count = 0
	stats = { tx_bytes = 0, rx_bytes = 0, flushed = 0, tx_bursts = 0,
		pump_reads = 0, accepted = 0, payloads = { [2] = 0, [3] = 0, [4] = 0, [5] = 0 },
		cmd_fc = 0, cmd_fd = 0, cmd_fe = 0 }
	last_tasks, last_gameplay = nil, nil
	io_error_seen = false

	local cpu = manager.machine.devices[':maincpu']
	local space = cpu.spaces['program']
	if diagnostics_enabled then
		log(string.format('[rom-guards] cpld_compare=%04x garbage_divisor=%04x,%04x',
			space:read_u16(0xd76), space:read_u16(0x7850), space:read_u16(0x7852)))
	end

	write_tap = space:install_write_tap(BASE, BASE + 0x3f, 'puyo2link_w', on_write)
	read_tap = space:install_read_tap(BASE, BASE + 0x3f, 'puyo2link_r', on_read)

	dbg_tap = diagnostics_enabled and space:install_write_tap(0xffa500, 0xffa501, 'puyo2link_dbg', function(off, data, mask)
		local ok, pc = pcall(function() return manager.machine.devices[':maincpu'].state['PC'].value end)
		log(string.format('[link-state] data=%04x mask=%04x pc=%s watchdog=%d expect=%02x rxhead=%04x rxtail=%04x rxpend=%04x',
			data, mask, ok and string.format('%06x', pc) or 'err',
			space:read_u16(0xffa504), space:read_u8(0xffa515),
			space:read_u16(RAM_RX_HEAD), space:read_u16(0xffa52a), space:read_u16(RAM_RX_PEND)))
		return nil
	end) or nil

	-- Trace the "offer linked play" flag and surrounding menu state.
	dbg_tap2 = diagnostics_enabled and space:install_write_tap(0xffa170, 0xffa17f, 'puyo2link_dbg2', function(off, data, mask)
		local addr = off
		if (mask & 0xff00) ~= 0 then addr = off elseif (mask & 0x00ff) ~= 0 then addr = off + 1 end
		local ok, pc = pcall(function() return manager.machine.devices[':maincpu'].state['PC'].value end)
		log(string.format('  [menu-state] write $%06x = %04x mask=%04x (pc=%s)',
			addr, data, mask, ok and string.format('%06x', pc) or 'err'))
		return nil
	end) or nil

	-- Watch the outgoing header bytes ($ffa511-13) and the
	-- values derived from the peer's incoming header ($ffa515-17) for
	-- bit0/1/6 activity on $ffa513/$ffa517 -- see COMM_PROTOCOL_SPEC.md
	-- section 9 (the peer-presence / linked-play-request handshake).
	dbg_tap3 = diagnostics_enabled and space:install_write_tap(0xffa510, 0xffa517, 'puyo2link_dbg3', function(off, data, mask)
		local addr = off
		if (mask & 0xff00) ~= 0 then addr = off elseif (mask & 0x00ff) ~= 0 then addr = off + 1 end
		if addr == 0xffa513 or addr == 0xffa517 then
			local ok, pc = pcall(function() return manager.machine.devices[':maincpu'].state['PC'].value end)
			log(string.format('  [header-byte] write $%06x = %02x mask=%04x (pc=%s)',
				addr, data & 0xff, mask, ok and string.format('%06x', pc) or 'err'))
		end
		return nil
	end) or nil

	-- Count the ROM's successful parser path, not merely delivered bytes.
	-- PC may reflect instruction start or the core's prefetched end.
	packet_tap = space:install_write_tap(0xffa514, 0xffa515, 'puyo2link_packets', function(off, data, mask)
		local pc = cpu.state['PC'].value
		-- MAME 0.289 reports $1845e for ADDQ.B at $18456 (prefetch).
		if (mask & 0xff) ~= 0 and pc >= 0x18456 and pc <= 0x1845e then
			stats.accepted = stats.accepted + 1
			local flags = space:read_u8(0xffa516)
			for bit = 2, 5 do
				if (flags & (1 << bit)) ~= 0 then
					stats.payloads[bit] = stats.payloads[bit] + 1
				end
			end
			if diagnostics_enabled and ((flags & 0x3c) ~= 0 or stats.accepted <= 4 or (stats.accepted % 60) == 0) then
				local payload = ''
				if (flags & 4) ~= 0 then
					local tail = space:read_u16(0xffa52a)
					payload = string.format(' command=%02x arg=%02x',
						space:read_u8(RAM_RX_RING + tail),
						space:read_u8(RAM_RX_RING + ((tail + 1) & 255)))
				end
				if (flags & 8) ~= 0 then
					local tail = (space:read_u16(0xffa52a) + ((flags & 4) ~= 0 and 2 or 0)) & 255
					local function word(i)
						return space:read_u8(RAM_RX_RING + ((tail + i) & 255)) * 256
							+ space:read_u8(RAM_RX_RING + ((tail + i + 1) & 255))
					end
					payload = payload .. string.format(' attack=%04x,%04x', word(0), word(2))
				end
				log(string.format('[packet-accepted] total=%d seq=%02x flags=%02x status=%02x pc=%06x%s',
					stats.accepted, ((data & 0xff) - 1) & 0xff, flags,
					space:read_u8(0xffa517), pc, payload))
			end
		end
		return nil
	end)

	gameplay_tap = diagnostics_enabled and space:install_write_tap(0xffa530, 0xffa531, 'puyo2link_gameplay', function(off, data, mask)
		if (space:read_u16(off) & mask) ~= (data & mask) then
			log(string.format('[game-command] data=%04x mask=%04x pc=%06x requests=%02x',
				data, mask, cpu.state['PC'].value, space:read_u8(0xffa502)))
		end
		return nil
	end) or nil

	protection_tap = diagnostics_enabled and space:install_write_tap(0xffa020, 0xffa027, 'puyo2link_protection', function(off, data, mask)
		if (space:read_u16(off) & mask) ~= (data & mask) then
			log(string.format('[protection-state] address=%06x data=%04x mask=%04x pc=%06x',
				off, data, mask, cpu.state['PC'].value))
		end
		return nil
	end) or nil
	checksum_tap = diagnostics_enabled and space:install_write_tap(0xffa0b2, 0xffa0b3, 'puyo2link_checksum', function(off, data, mask)
		log(string.format('[protection-checksum] data=%04x mask=%04x pc=%06x',
			data, mask, cpu.state['PC'].value))
		return nil
	end) or nil
	attack_tap = diagnostics_enabled and space:install_write_tap(0xffa7e0, 0xffa7ff, 'puyo2link_attacks', function(off, data, mask)
		if (space:read_u16(off) & mask) ~= (data & mask) then
			log(string.format('[attack-state] address=%06x data=%04x mask=%04x pc=%06x protection=%02x',
				off, data, mask, cpu.state['PC'].value, space:read_u8(0xffa026)))
		end
		return nil
	end) or nil
	divisor_tap = diagnostics_enabled and space:install_read_tap(0xffa026, 0xffa027, 'puyo2link_divisor', function(off, data, mask)
		local pc = cpu.state['PC'].value
		if pc >= 0x7848 and pc <= 0x7850 then
			log(string.format('[garbage-calculation] protection=%02x score=%04x divisor=%04x task=%06x pc=%06x players=%d rule=%02x split_remainder=%02x base=%d margin=%d seconds=%d mode=%02x participants=%02x chain=%d difficulty=%d preset=%d',
				(data >> 8) & 255, cpu.state['D0'].value & 65535,
				cpu.state['D1'].value & 65535, cpu.state['A0'].value, pc,
				space:read_u8(0xffa143), space:read_u8(0xff480c),
				space:read_u8(cpu.state['A0'].value + 0x23),
				space:read_u8(0xff480d), space:read_u16(0xff4802),
				space:read_u16(0xffa064), space:read_u8(0xffa130),
				space:read_u8(0xffa13f), space:read_u8(cpu.state['A0'].value + 9),
				space:read_u8(0xffa105), space:read_u8(0xff4804)))
		end
		return nil
	end) or nil

	active = true
	log('taps installed; out=' .. out_path .. ' in=' .. in_path)
end

local function fill_rx_banks()
	local in_queue = link.queue
	if #in_queue == 0 then return end
	if not established_seen then return end
	if not link:valid() then return end
	local n = math.min(255 - rx_count, #in_queue)
	for i = 1, n do
		rx_bank[rx_write] = table.remove(in_queue, 1)
		rx_write = (rx_write + 1) & 255
	end
	rx_count = rx_count + n
end

local function do_frame()
	if not active then return end
	frame_count = frame_count + 1
	flush_and_poll()
	if not active then return end
	fill_rx_banks()
	if not diagnostics_enabled then
		if (frame_count % 300) == 0 then
			log(string.format('[transport] captured=%d flushed=%d received=%d accepted=%d ready=%s txcredit=%d rxcredit=%d',
				stats.tx_bytes, stats.flushed, stats.rx_bytes, stats.accepted,
				tostring(link:valid()), link:valid() and #out_queue or 255, rx_count))
		end
		return
	end
	if (frame_count % 60) == 0 then
		local ok, info = pcall(function()
			local cpu = manager.machine.devices[':maincpu']
			local space = cpu.spaces['program']
			return {
				linkflag = space:read_u8(0xffa500),
				pc = cpu.state['PC'].value,
				a502 = space:read_u8(0xffa502),
				a524 = space:read_u16(0xffa524),
				a525 = space:read_u8(0xffa525),
				a170 = space:read_u8(0xffa170),
				a17f = space:read_u8(0xffa17f),
				txtail = space:read_u16(RAM_TX_TAIL),
				rxpend = space:read_u16(RAM_RX_PEND),
			}
		end)
		if ok then
			log(string.format(
				'heartbeat frame=%d tx=%d rx=%d fc=%d fd=%d fe=%d linkflag=%02x pc=%06x a502=%02x a524=%04x a525=%02x a170=%02x a17f=%02x txtail=%04x rxpend=%04x',
				frame_count, stats.tx_bytes, stats.rx_bytes, stats.cmd_fc, stats.cmd_fd, stats.cmd_fe,
				info.linkflag, info.pc, info.a502, info.a524, info.a525, info.a170, info.a17f, info.txtail, info.rxpend))
			local space = manager.machine.devices[':maincpu'].spaces['program']
			log(string.format('[transport] captured=%d flushed=%d received=%d accepted=%d payload2=%d payload3=%d payload4=%d payload5=%d pump_reads=%d bursts=%d txcredit=%d outq=%d inq=%d watchdog=%d txseq=%02x rxseq=%02x rxcredit=%d protection=%02x checks=%04x',
				stats.tx_bytes, stats.flushed, stats.rx_bytes, stats.accepted,
				stats.payloads[2], stats.payloads[3], stats.payloads[4], stats.payloads[5],
				stats.pump_reads, stats.tx_bursts, link:valid() and #out_queue or 255, #out_queue, #link.queue,
				space:read_u16(0xffa504), space:read_u8(0xffa511), space:read_u8(0xffa515),
				rx_count, space:read_u8(0xffa026), space:read_u16(0xffa0b2)))
			log(string.format('[epochs] local=%d peer=%d ready=%s discarded_rx=%d',
				link.epoch, link.peer_epoch, tostring(link:valid()), link.discarded))
			local game = string.format('a142=%02x a13e=%02x a13f=%02x a530=%04x a506=%02x a507=%02x a508=%02x a7b0=%04x a7a6=%04x script=%06x mode=%02x rule=%02x base=%d margin=%d difficulty=%d preset=%d',
				space:read_u8(0xffa142), space:read_u8(0xffa13e), space:read_u8(0xffa13f),
				space:read_u16(0xffa530), space:read_u8(0xffa506), space:read_u8(0xffa507),
				space:read_u8(0xffa508), space:read_u16(0xffa7b0), space:read_u16(0xffa7a6),
				space:read_u32(0xffa050), space:read_u8(0xffa130),
				space:read_u8(0xff480c), space:read_u8(0xff480d),
				space:read_u16(0xff4802), space:read_u8(0xffa105),
				space:read_u8(0xff4804))
			if game ~= last_gameplay then
				log('[game-state] ' .. game)
				last_gameplay = game
			end
			-- $a38e/$a400 separately dispatch the two comm TCBs; $a3a0
			-- scans 128 general blocks. +2 is a saved continuation, not
			-- a stable task ID. The low-level pump is an interrupt call
			-- ($5d4 -> $186e0), NOT a task in either table.
			local tok, tlist = pcall(function()
				local space = manager.machine.devices[':maincpu'].spaces['program']
				local entries = {}
				local function describe(base)
					return string.format('%06x=%04x->%06x sleep=%d local26=%04x',
						base, space:read_u16(base), space:read_u32(base + 2),
						space:read_u16(base + 0x24), space:read_u16(base + 0x26))
				end
				entries[#entries + 1] = describe(0xffa580)
				entries[#entries + 1] = describe(0xffa5c0)
				for i = 0, 127 do
					local base = 0xffd000 + i * 0x40
					if space:read_u8(base) ~= 0 then
						entries[#entries + 1] = describe(base)
					end
				end
				return table.concat(entries, ' ')
			end)
			if not tok or tlist ~= last_tasks then
				log('[tcb-continuations] ' .. (tok and tlist or ('scan FAILED: ' .. tostring(tlist))))
				last_tasks = tlist
			end
		else
			log(string.format('heartbeat frame=%d tx=%d rx=%d fc=%d fd=%d fe=%d linkflag=err (%s)',
				frame_count, stats.tx_bytes, stats.rx_bytes, stats.cmd_fc, stats.cmd_fd, stats.cmd_fe, tostring(info)))
		end
	end
end

local function do_stop()
	if logf then
		log('=== session stop ===')
		logf:close()
		logf = nil
	end
	active = false
end

function exports.startplugin()
	prestart_sub = emu.register_prestart(do_prestart)
	frame_sub = emu.add_machine_frame_notifier(do_frame)
	stop_sub = emu.add_machine_stop_notifier(do_stop)
end

return exports
