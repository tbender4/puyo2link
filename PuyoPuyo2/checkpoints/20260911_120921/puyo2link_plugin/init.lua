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
-- MAME processes (one per "cabinet") over a pair of local files acting
-- as a simple byte-stream transport.
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
--                     (defaults to PuyoPuyo2/link_ipc next to this repo)

local exports = {
	name = 'puyo2link',
	version = '0.3.0',
	description = 'Puyo Puyo 2 (arcade) 4-player link emulation',
	license = 'CC0',
	author = { name = 'reverse-engineered, see PuyoPuyo2/re_notes' } }

local puyo2link = exports

local BASE = 0x880100
local ADDR_MESSAGE_BASE = 0x880101   -- 8 rotating slots: +0,+2,+4,...,+14
local ADDR_RXCREDIT     = 0x880107
local ADDR_COMMAND      = 0x880111
local ADDR_CONTROL      = 0x880131
local IDENT_RESPONSE = { string.byte('PUYO2Z80', 1, 8) }

-- Local RAM ring buffers the 68000 program itself maintains (see
-- COMM_PROTOCOL_SPEC.md section 5.3). Rather than trying to replicate the
-- exact mailbox-level nibble/position-counter bookkeeping (ambiguous in
-- several places -- see the design note below do_frame()), we let the
-- 68000's own TX pump run against a simplified pass-through mailbox and
-- capture the actual outgoing bytes straight out of its TX ring buffer
-- by polling the tail index once per frame. For RX we force RxCredit to
-- always read 0 (so the built-in mailbox-driven RX copy never runs) and
-- instead inject peer bytes directly into the RX ring buffer ourselves.
-- This sidesteps a whole class of "which mailbox write is real payload
-- vs. internal bookkeeping" ambiguity entirely.
local RAM_TX_RING  = 0xffa800   -- 256-byte TX ring
local RAM_TX_TAIL  = 0xffa522   -- word: TX ring drain/tail index
local RAM_RX_RING  = 0xffa900   -- 256-byte RX ring
local RAM_RX_HEAD  = 0xffa528   -- word: RX ring fill/head index
local RAM_RX_PEND  = 0xffa52c   -- word: RX ring pending (unconsumed) count

-- All of these are file-scope locals on purpose -- see note above.
local read_tap, write_tap, frame_sub, stop_sub, prestart_sub, dbg_tap, dbg_tap2, dbg_tap3
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
	local s = {}
	for i = 0, 7 do s[i] = 0 end
	if v0 ~= nil then s[0] = v0 end
	return s
end

local g_space   -- cached maincpu program address_space, set in do_prestart

local slot = fresh_slots()
local current_bank = 'cmd'          -- 'cmd' | 'tx' | 'rx'
local auto_input_stage = 0
local auto_input_at = 0
local established_seen = false      -- true from a successful $FE until the next
                                     -- CommControl reset. NOTE: can't gate the
                                     -- RxCredit override on current_bank~='cmd'
                                     -- -- the real RxCredit read happens right
                                     -- after the pump writes $FF (idle marker)
                                     -- to CommCommand, which itself sets
                                     -- current_bank back to 'cmd' first. That
                                     -- made the override never actually apply
                                     -- during real runtime traffic, which was
                                     -- the real cause of the near-instant
                                     -- resets seen live -- not the $FF-filler
                                     -- theory from the previous pass.
local out_queue = {}                -- bytes captured from the TX ring, waiting to be flushed to file
local in_queue = {}                 -- bytes read from the peer's file, waiting to be injected into the RX ring
local in_pos = 0
local last_tx_tail = 0
local frame_count = 0
local stats = { tx_bytes = 0, rx_bytes = 0, cmd_fc = 0, cmd_fd = 0, cmd_fe = 0 }
local active = false
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
		-- NOTE (corrected after live test): the 68000 code treats a ZERO
		-- readback here as "not ready yet, keep retrying" and only
		-- proceeds (setting the $ffa500 bit7 established flag) on a
		-- NONZERO readback. Original spec had this inverted.
		-- Also clear slots 1-7: leftover handshake bytes (identity
		-- string / 0xFF fill) must not leak into the runtime TX/RX
		-- credit registers (slots 2 and 3, i.e. $880105/$880107) or
		-- the game reads a bogus nonzero "credit" on its first runtime
		-- pump call and resets the whole link.
		slot = fresh_slots(1)
		current_bank = 'cmd'
		established_seen = true
		stats.cmd_fe = stats.cmd_fe + 1
		log('CMD $FE (loopback test) -> answering OK (nonzero)')
	elseif byte == 0xFF then
		current_bank = 'cmd'
	elseif byte < 0x20 then
		if current_bank ~= 'tx' then log('-> TX burst, block=' .. byte) end
		current_bank = 'tx'
	else
		if current_bank ~= 'rx' then log('-> RX burst, block=' .. (byte - 0x20)) end
		current_bank = 'rx'
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
			fd_since_fc = 0
			established_seen = false

			-- The real 68000 code restarts its own TX/RX sequence
			-- counters ($ffa511, $ffa515) from 0 on every reset. If we
			-- don't ALSO discard whatever we'd queued/buffered from
			-- before this reset, stale bytes from a previous attempt
			-- can get delivered after the peer has already restarted
			-- its own expected-sequence counter at 0, causing an
			-- instant mismatch against ROM $018356's per-packet
			-- sequence check (which resets to $018236 on failure) --
			-- this was found live: the link was dropping within one
			-- frame of establishing once two real instances were
			-- actually exchanging bytes, not just self-looping.
			out_queue = {}
			in_queue = {}
			if g_space then
				last_tx_tail = g_space:read_u16(RAM_TX_TAIL) & 0xff
				-- The 68000's own reset path clears $ffa515 (expected
				-- receive sequence number) back to 0, but does NOT
				-- appear to clear $ffa52c (RX ring pending-byte count)
				-- or $ffa52a (RX consumer read index) -- so stale bytes
				-- left over from before this reset get immediately
				-- re-parsed as a "fresh" packet against the just-reset
				-- sequence expectation of 0, mismatch, instant reset.
				-- Found live: the link was dropping within a single
				-- frame of re-establishing, far too fast for a real
				-- peer round-trip. Clearing pending here gives the
				-- parser nothing to look at until we deliver bytes
				-- that actually belong to this fresh session.
				g_space:write_u16(RAM_RX_PEND, 0)
			end
			-- Skip our own read position on the peer's incoming file
			-- to its current end, discarding any backlog rather than
			-- delivering it into a freshly-reset receiver.
			local f = io.open(in_path, 'rb')
			if f then
				local size = f:seek('end')
				if size then in_pos = size end
				f:close()
			end
		end
		return nil
	end
	local idx = slot_index_for(addr)
	if idx ~= nil then
		slot[idx] = byte
	end
	return nil
end

local function on_read(offset, data, mem_mask)
	if (mem_mask & 0xff) == 0 then
		return nil
	end
	local addr = offset + 1
	if addr == ADDR_RXCREDIT and established_seen then
		-- Always report zero bytes available over the mailbox itself:
		-- we deliver peer data straight into the RX ring buffer instead
		-- (see do_frame), so the built-in mailbox-driven RX copy loop
		-- should never find anything to do and just exit immediately.
		--
		-- IMPORTANT: this same physical address ($880107) doubles as
		-- byte index 3 of the 8-byte mailbox window used during the
		-- boot handshake (signature/identity string comparisons), so
		-- this override must NOT apply during the boot handshake or it
		-- corrupts the 4th character of PUYO2Z80/PUYO268K.
		--
		-- Originally gated on current_bank~='cmd', which was WRONG: the
		-- real RxCredit read happens right after the pump writes $FF
		-- (idle marker) to CommCommand, which itself sets
		-- current_bank='cmd' first -- so that gate never actually
		-- applied during real runtime traffic, RxCredit fell through to
		-- stale pass-through storage, and the game read back garbage
		-- and reset almost every single cycle. Gating on "has $FE ever
		-- succeeded since the last reset" instead correctly separates
		-- boot-handshake use of this address from runtime-pump use.
		return 0
	end
	local idx = slot_index_for(addr)
	if idx == nil then
		return nil
	end
	return slot[idx]
end

local function flush_and_poll()
	if #out_queue > 0 then
		local f = io.open(out_path, 'ab')
		if f then
			local chars = {}
			for i, b in ipairs(out_queue) do chars[i] = string.char(b) end
			f:write(table.concat(chars))
			f:close()
		end
		out_queue = {}
	end

	local f = io.open(in_path, 'rb')
	if f then
		local size = f:seek('end')
		if size and size > in_pos then
			f:seek('set', in_pos)
			local chunk = f:read(size - in_pos)
			in_pos = size
			if chunk then
				for i = 1, #chunk do
					table.insert(in_queue, chunk:byte(i))
				end
			end
		end
		f:close()
	end
end

local function do_prestart()
	if emu.romname() ~= 'puyopuy2' then
		active = false
		return
	end

	side = os.getenv('PUYO2_LINK_SIDE') or 'A'
	peer_side = (side == 'A') and 'B' or 'A'
	link_dir = os.getenv('PUYO2_LINK_DIR') or 'C:/Users/tbend/mame/PuyoPuyo2/link_ipc'
	pcall(function() lfs.mkdir(link_dir) end)

	out_path = link_dir .. '/' .. side .. '_to_' .. peer_side .. '.bin'
	in_path = link_dir .. '/' .. peer_side .. '_to_' .. side .. '.bin'

	if logf then logf:close() end
	logf = io.open(link_dir .. '/proto_' .. side .. '.log', 'a')
	log('=== session start, side=' .. side .. ' ===')

	local outf = io.open(out_path, 'wb')
	if outf then outf:close() end
	in_pos = 0
	in_queue = {}
	out_queue = {}
	slot = fresh_slots()
	current_bank = 'cmd'
	established_seen = false
	frame_count = 0
	auto_input_stage = 0
	auto_input_at = 0
	stats = { tx_bytes = 0, rx_bytes = 0, cmd_fc = 0, cmd_fd = 0, cmd_fe = 0 }

	local cpu = manager.machine.devices[':maincpu']
	local space = cpu.spaces['program']
	g_space = space

	-- Do NOT assume last_tx_tail starts at 0 -- $ffa522 (and the ring at
	-- $ffa800, and $ffa511) hold whatever was left in RAM at cold boot,
	-- before the game has initialized anything. Found live: this made
	-- the very first poll_tx_ring call on a fresh process capture a huge
	-- burst of leftover boot-time RAM content as if it were real sent
	-- packets. Read the actual current value instead.
	last_tx_tail = space:read_u16(RAM_TX_TAIL) & 0xff

	write_tap = space:install_write_tap(BASE, BASE + 0x3f, 'puyo2link_w', on_write)
	read_tap = space:install_read_tap(BASE, BASE + 0x3f, 'puyo2link_r', on_read)

	dbg_tap = space:install_write_tap(0xffa500, 0xffa501, 'puyo2link_dbg', function(off, data, mask)
		local ok, pc = pcall(function() return manager.machine.devices[':maincpu'].state['PC'].value end)
		log(string.format('  [dbg] write $ffa500 = %02x (pc=%s)', data & 0xff, ok and string.format('%06x', pc) or 'err'))
		return nil
	end)

	-- Temporary: watching for what game state/screen actually sets the
	-- "offer linked play" flag ($ffa17f, ROM $019A62) -- see
	-- COMM_PROTOCOL_SPEC.md section 9 for context. Logs any write in
	-- $ffa170-$ffa17f.
	dbg_tap2 = space:install_write_tap(0xffa170, 0xffa17f, 'puyo2link_dbg2', function(off, data, mask)
		local addr = off
		if (mask & 0xff00) ~= 0 then addr = off elseif (mask & 0x00ff) ~= 0 then addr = off + 1 end
		local ok, pc = pcall(function() return manager.machine.devices[':maincpu'].state['PC'].value end)
		log(string.format('  [menu-state] write $%06x = %04x mask=%04x (pc=%s)',
			addr, data, mask, ok and string.format('%06x', pc) or 'err'))
		return nil
	end)

	-- Temporary: watch the outgoing header bytes ($ffa511-13) and the
	-- values derived from the peer's incoming header ($ffa515-17) for
	-- bit0/1/6 activity on $ffa513/$ffa517 -- see COMM_PROTOCOL_SPEC.md
	-- section 9 (the peer-presence / linked-play-request handshake).
	dbg_tap3 = space:install_write_tap(0xffa510, 0xffa517, 'puyo2link_dbg3', function(off, data, mask)
		local addr = off
		if (mask & 0xff00) ~= 0 then addr = off elseif (mask & 0x00ff) ~= 0 then addr = off + 1 end
		if addr == 0xffa513 or addr == 0xffa517 then
			local ok, pc = pcall(function() return manager.machine.devices[':maincpu'].state['PC'].value end)
			log(string.format('  [header-byte] write $%06x = %02x mask=%04x (pc=%s)',
				addr, data & 0xff, mask, ok and string.format('%06x', pc) or 'err'))
		end
		return nil
	end)

	active = true
	log('taps installed; out=' .. out_path .. ' in=' .. in_path)

	local ok, err = pcall(function()
		local port = manager.machine.ioport.ports[':SERVICE']
		local names = {}
		for name, _ in pairs(port.fields) do names[#names + 1] = name end
		log('SERVICE port fields: ' .. table.concat(names, ' | '))
	end)
	if not ok then log('SERVICE port enum failed: ' .. tostring(err)) end
end

local function poll_tx_ring()
	local space = manager.machine.devices[':maincpu'].spaces['program']
	local tx_tail = space:read_u16(RAM_TX_TAIL) & 0xff
	if not established_seen then
		-- Don't trust ring contents before the link has ever
		-- established this session -- just track where the tail is so
		-- we start from a clean baseline the moment it does.
		last_tx_tail = tx_tail
		return
	end
	local delta = (tx_tail - last_tx_tail) % 256
	if delta > 0 then
		local raw = {}
		for i = 0, delta - 1 do
			raw[#raw + 1] = space:read_u8(RAM_TX_RING + ((last_tx_tail + i) % 256))
		end
		-- Trim a trailing run of $FF: seen live to occasionally follow
		-- real packet bytes within a single frame's capture (e.g.
		-- "06 00 10 ff ff ff ...ff" -- 3 real bytes then ~230 bytes of
		-- ring filler). Relaying those $FF bytes as if they were more
		-- packets desyncs the receiver's rolling sequence-number check
		-- ($ffa515) almost instantly, since real sequence bytes are
		-- always small incrementing values. $ffa524 (the low-level
		-- pump's own "bytes still queued" count) evidently sometimes
		-- reports more pending than the application actually enqueued;
		-- exactly why is still unresolved (see COMM_PROTOCOL_SPEC.md
		-- section 9), but the ring's own filler byte is reliably $FF,
		-- so trimming a trailing run of it is a safe, well-evidenced
		-- filter without needing that root cause nailed down first.
		local keep = #raw
		while keep > 0 and raw[keep] == 0xff do
			keep = keep - 1
		end
		local trimmed = #raw - keep
		local bytes_logged = {}
		for i = 1, keep do
			table.insert(out_queue, raw[i])
			bytes_logged[#bytes_logged + 1] = raw[i]
		end
		if trimmed > 0 and stats.tx_bytes < 40 then
			log(string.format('  [capture] trimmed %d trailing $FF filler byte(s)', trimmed))
		end
		if stats.tx_bytes < 40 then
			local seq_ok, seq = pcall(function() return space:read_u8(0xffa511) end)
			local hex = {}
			for i, b in ipairs(bytes_logged) do hex[i] = string.format('%02x', b) end
			log(string.format('  [capture] sent=[%s] my_seq=%s',
				table.concat(hex, ' '), seq_ok and string.format('%02x', seq) or 'err'))
		end
		stats.tx_bytes = stats.tx_bytes + keep
		last_tx_tail = tx_tail
	end
end

local function inject_rx_ring()
	if #in_queue == 0 then return end
	if not established_seen then return end   -- don't write into $ffa900/$ffa52c before the game has initialized them this session
	local space = manager.machine.devices[':maincpu'].spaces['program']
	local pending = space:read_u16(RAM_RX_PEND) & 0xff
	local room = 256 - pending
	if room <= 0 then return end
	local n = math.min(room, #in_queue)
	local head = space:read_u16(RAM_RX_HEAD) & 0xff
	local bytes_logged = {}
	for i = 0, n - 1 do
		local b = table.remove(in_queue, 1)
		space:write_u8(RAM_RX_RING + ((head + i) % 256), b)
		bytes_logged[#bytes_logged + 1] = b
	end
	space:write_u16(RAM_RX_HEAD, (head + n) % 256)
	space:write_u16(RAM_RX_PEND, pending + n)
	if stats.rx_bytes < 40 then
		local expect_ok, expect = pcall(function() return space:read_u8(0xffa515) end)
		local hex = {}
		for i, b in ipairs(bytes_logged) do hex[i] = string.format('%02x', b) end
		log(string.format('  [inject] pending_before=%d wrote=[%s] expect_seq=%s',
			pending, table.concat(hex, ' '), expect_ok and string.format('%02x', expect) or 'err'))
	end
	stats.rx_bytes = stats.rx_bytes + n
end

local RAM_WATCHDOG = 0xffa504   -- word: ROM $018392 increments this every task
                                -- tick and force-drops the link at 1200 (ROM
                                -- $018398/$0183A4); it's ALSO reset to 0 by
                                -- real game code whenever a valid application
                                -- packet is successfully processed (ROM
                                -- $018434), so in a protocol-complete
                                -- implementation this resolves itself. Until
                                -- the $ffa502 application-packet dispatch is
                                -- validated, hold it at 0 ourselves so the
                                -- link stays up long enough to actually test
                                -- against -- remove this once packet-level
                                -- traffic is confirmed to keep it reset
                                -- naturally.
local function suppress_watchdog()
	local space = manager.machine.devices[':maincpu'].spaces['program']
	if (space:read_u8(0xffa500) & 0x80) ~= 0 then
		space:write_u16(RAM_WATCHDOG, 0)
	end
end

-- Temporary: auto-press Coin 1 then 1 Player Start once the link has been
-- established for a bit, so both cabinets reach the mode-select screen at
-- roughly the same time without needing precise human timing across two
-- windows. See COMM_PROTOCOL_SPEC.md section 9.
local function drive_auto_input()
	if auto_input_stage == 0 then
		if established_seen and frame_count > 180 then
			local ok, err = pcall(function()
				manager.machine.ioport.ports[':SERVICE'].fields['Coin 1']:set_value(1)
			end)
			log('auto-input: press Coin 1 ' .. (ok and 'ok' or ('FAILED: ' .. tostring(err))))
			auto_input_stage = 1
			auto_input_at = frame_count
		end
	elseif auto_input_stage == 1 and frame_count > auto_input_at + 3 then
		pcall(function() manager.machine.ioport.ports[':SERVICE'].fields['Coin 1']:clear_value() end)
		auto_input_stage = 2
		auto_input_at = frame_count
	elseif auto_input_stage == 2 and frame_count > auto_input_at + 30 then
		local ok, err = pcall(function()
			manager.machine.ioport.ports[':SERVICE'].fields['1 Player Start']:set_value(1)
		end)
		log('auto-input: press 1P Start ' .. (ok and 'ok' or ('FAILED: ' .. tostring(err))))
		auto_input_stage = 3
		auto_input_at = frame_count
	elseif auto_input_stage == 3 and frame_count > auto_input_at + 3 then
		pcall(function() manager.machine.ioport.ports[':SERVICE'].fields['1 Player Start']:clear_value() end)
		auto_input_stage = 4
	end
end

local function do_frame()
	if not active then return end
	frame_count = frame_count + 1
	poll_tx_ring()
	flush_and_poll()
	inject_rx_ring()
	suppress_watchdog()
	drive_auto_input()
	if (frame_count % 300) == 0 then
		local ok, linkflag = pcall(function()
			return manager.machine.devices[':maincpu'].spaces['program']:read_u8(0xffa500)
		end)
		log(string.format('heartbeat frame=%d tx=%d rx=%d fc=%d fd=%d fe=%d linkflag=%s',
			frame_count, stats.tx_bytes, stats.rx_bytes, stats.cmd_fc, stats.cmd_fd, stats.cmd_fe,
			ok and string.format('%02x', linkflag) or 'err'))
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

function puyo2link.startplugin()
	prestart_sub = emu.register_prestart(do_prestart)
	frame_sub = emu.add_machine_frame_notifier(do_frame)
	stop_sub = emu.add_machine_stop_notifier(do_stop)
end

return puyo2link
