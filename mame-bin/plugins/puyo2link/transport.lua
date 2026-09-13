-- Reset-aware IPC journal. Raw .bin files remain byte-stream diagnostics;
-- .bin.wire files are the authoritative, generation-tagged transport.
local transport = {}
local methods = {}
methods.__index = methods
local HEADER = 14
local LAN_LIMIT = 65536
local LAN_QUEUE = 4096

function transport.paths(directory, side, separator)
	separator = separator or package.config:sub(1, 1)
	directory = directory or 'puyo2-link'
	local prefix = directory .. (directory:sub(-1) == separator and '' or separator)
	local peer = side == 'A' and 'B' or 'A'
	return directory, prefix .. side .. '_to_' .. peer .. '.bin',
		prefix .. peer .. '_to_' .. side .. '.bin', prefix .. 'proto_' .. side .. '.log'
end

local function record(kind, epoch, peer, payload)
	payload = payload or ''
	return string.pack('>c4I4I4I2', 'P2' .. kind .. '1', epoch, peer, #payload) .. payload
end

function methods:fail(message)
	if self.failed then return end
	self.failed = true
	self.established_peer = 0
	self.log('[transport-error] ' .. message)
	self:progress()
end

function methods:progress()
	if not self.session then return end
	local position = self.in_pos - #self.buffer
	local text = string.format('P2P1 %s %d %d\n', self.session, position, self.failed and 1 or 0)
	if text == self.last_progress then return end
	-- A single-writer snapshot; the bridge ignores incomplete reads, with
	-- a bounded stall deadline. It never treats prefetch as consumption.
	local f = io.open(self.out_raw .. '.progress', 'wb')
	if not f then self:fail('cannot open LAN progress snapshot'); return end
	local wrote = f:write(text)
	local closed = f:close()
	if not wrote or not closed then self:fail('cannot write LAN progress snapshot'); return end
	self.last_progress = text
end

function methods:status()
	if not self.session then return end
	local f, open_error = io.open(self.out_raw .. '.status', 'rb')
	if not f and self.status_ready and not self.failed then
		self.status_misses = (self.status_misses or 0) + 1
		if self.status_misses == 1 then
			self.log('[transport-retry] LAN status temporarily unreadable: ' .. tostring(open_error))
		end
		-- Windows can deny open while the bridge atomically replaces the
		-- snapshot. Keep the last credit boundary; never block a frame.
		if self.status_misses < 120 then return end
	end
	local text, read_error
	if f then text, read_error = f:read(256) end
	if f then f:close() end
	local session, state, handled = (text or ''):match('^P2S1 (%x+) (%a+) (%d+)\n$')
	self.bridge_down = session == self.session and state == 'down'
	if self.failed then return end
	if self.bridge_down then
		self.log('[transport-stop] LAN supervisor requested shutdown; see bridge.log for the reason')
		self.failed, self.established_peer = true, 0
		self:progress()
		return
	end
	handled = tonumber(handled)
	if session ~= self.session or state ~= 'up' or not handled
		or handled < self.handled or handled > self.out_pos then
		self:fail(string.format('LAN bridge unavailable or invalid status (open=%s read=%s snapshot=%q handled=%s previous=%d written=%d); restart both launchers',
			tostring(open_error), tostring(read_error), text or '', tostring(handled), self.handled, self.out_pos))
		return
	end
	self.handled = handled
	if (self.status_misses or 0) > 0 then self.log('[transport-recovered] LAN status readable') end
	self.status_ready, self.status_misses = true, 0
end

function methods:room(length)
	return not self.failed and (not self.session or self.out_pos - self.handled + length <= LAN_LIMIT)
end

function methods:append_control(kind, peer)
	if not self:room(HEADER) then return false end
	local f = io.open(self.out_wire, 'ab')
	if not f then
		if self.session then self:fail('cannot open LAN control journal'); return false end
		if not self.control_open_failed then
			self.log('[transport-retry] cannot open control journal; handshake waiting')
			self.control_open_failed = true
		end
		return false
	end
	self.control_open_failed = false
	local wrote, err = f:write(record(kind, self.epoch, peer))
	local closed, close_err = f:close()
	if not wrote or not closed then
		self:fail('control append failed: ' .. tostring(err or close_err))
		return false
	end
	self.out_pos = self.out_pos + HEADER
	return true
end

function methods:publish_reset()
	if self.failed or self.epoch == 0 then return false end
	if self.published_epoch == self.epoch then return true end
	if not self:append_control('R', 0) then return false end
	self.published_epoch = self.epoch
	return true
end

function methods:reset()
	if self.failed then return end
	self.log(string.format('[epoch-reset] local=%d peer=%d queued_rx=%d',
		self.epoch + 1, self.peer_epoch, #self.queue))
	self.discarded = self.discarded + #self.queue
	self.queue = {}
	self.epoch = self.epoch + 1
	self.ready_peer, self.established_peer = 0, 0
	self:publish_reset()
end

function methods:valid()
	return not self.failed and self.epoch > 0 and self.peer_epoch > 0
		and self.established_peer == self.peer_epoch
		and self.ready_peer == self.peer_epoch and self.peer_ready == self.epoch
end

function methods:handshake()
	if not self:publish_reset() or self.peer_epoch == 0 then return false end
	if self.ready_peer ~= self.peer_epoch then
		if not self:append_control('F', self.peer_epoch) then return false end
		self.ready_peer = self.peer_epoch
	end
	if self.peer_ready ~= self.epoch then return false end
	if self.established_peer ~= self.peer_epoch then
		self.log(string.format('[epoch-ready] local=%d peer=%d', self.epoch, self.peer_epoch))
	end
	self.established_peer = self.peer_epoch
	return true
end

function methods:poll()
	self:status()
	if self.failed then return end
	self:progress()
	self:publish_reset()
	if self.failed then return end
	local f = io.open(self.in_wire, 'rb')
	if not f then
		if self.session then self:fail('cannot open LAN incoming journal') end
		return
	end
	local size = f:seek('end')
	if size and size < self.in_pos then
		f:close()
		self:fail('peer journal truncated; start a fresh process pair/directory')
		return
	end
	if size and size > self.in_pos then
		f:seek('set', self.in_pos)
		local chunk = f:read(math.min(size - self.in_pos, 65536))
		if chunk then
			self.in_pos = self.in_pos + #chunk
			self.buffer = self.buffer .. chunk
		end
	end
	f:close()
	local pos = 1
	while #self.buffer - pos + 1 >= HEADER do
		local magic, epoch, peer, length = string.unpack('>c4I4I4I2', self.buffer, pos)
		if epoch == 0 or length > 255
			or (magic ~= 'P2R1' and magic ~= 'P2F1' and magic ~= 'P2D1')
			or (magic == 'P2R1' and (length ~= 0 or peer ~= 0))
			or (magic == 'P2F1' and (length ~= 0 or peer == 0))
			or (magic == 'P2D1' and (length == 0 or peer == 0)) then
			self:fail('invalid peer journal record')
			return
		end
		if #self.buffer - pos + 1 < HEADER + length then break end
		if magic == 'P2R1' then
			if epoch < self.peer_epoch then
				self:fail('peer generation went backwards')
				return
			end
			if epoch ~= self.peer_epoch then
				self.log(string.format('[peer-reset] old=%d new=%d local=%d queued_rx=%d',
					self.peer_epoch, epoch, self.epoch, #self.queue))
				self.discarded = self.discarded + #self.queue
				self.queue = {}
				self.peer_epoch, self.peer_ready = epoch, 0
				self.ready_peer, self.established_peer = 0, 0
			end
		elseif magic == 'P2F1' then
			if epoch == self.peer_epoch then self.peer_ready = peer end
		elseif epoch == self.peer_epoch and peer == self.epoch
			and self.ready_peer == epoch and self.peer_ready == peer then
			if self.session and #self.queue + length > LAN_QUEUE then
				self:fail('LAN RX queue limit exceeded; restart both launchers')
				return
			end
			-- A peer can finish FE slightly earlier. Preserve its first
			-- packet while our own FE has not yet returned successfully.
			for i = pos + HEADER, pos + HEADER + length - 1 do
				self.queue[#self.queue + 1] = self.buffer:byte(i)
			end
		else
			self.discarded = self.discarded + length
			self.log(string.format('[stale-data] sender=%d receiver=%d bytes=%d local=%d peer=%d',
				epoch, peer, length, self.epoch, self.peer_epoch))
		end
		pos = pos + HEADER + length
	end
	self.buffer = self.buffer:sub(pos)
	self:progress()
end

function methods:send(payload)
	if not self:valid() or #payload == 0 then return 0 end
	assert(#payload <= 255, 'TX credit invariant exceeded')
	if not self:room(HEADER + #payload) then return 0 end
	-- Open both before writing either: an open failure is safely retryable.
	local raw = io.open(self.out_raw, 'ab')
	if not raw then
		if self.session then self:fail('cannot open LAN raw audit') end
		return 0
	end
	local wire = io.open(self.out_wire, 'ab')
	if not wire then
		raw:close()
		if self.session then self:fail('cannot open LAN outgoing journal') end
		return 0
	end
	local wrote, err = wire:write(record('D', self.epoch, self.peer_epoch, payload))
	local closed, close_err = wire:close()
	if not wrote or not closed then
		raw:close()
		self:fail('data append failed: ' .. tostring(err or close_err))
		return 0
	end
	self.out_pos = self.out_pos + HEADER + #payload
	wrote, err = raw:write(payload)
	closed, close_err = raw:close()
	if not wrote or not closed then
		-- The wire record is committed; never send it a second time.
		self:fail('raw diagnostic append failed: ' .. tostring(err or close_err))
	end
	return #payload
end

function transport.new(out_raw, in_raw, log, session)
	if session and (#session ~= 32 or not session:match('^%x+$')) then
		return nil, 'invalid PUYO2_LINK_SESSION'
	end
	local self = setmetatable({
		out_raw = out_raw, out_wire = out_raw .. '.wire', in_wire = in_raw .. '.wire',
		log = log, epoch = 0, published_epoch = 0, peer_epoch = 0, peer_ready = 0,
		ready_peer = 0, established_peer = 0, in_pos = 0, buffer = '',
		queue = {}, discarded = 0, failed = false,
		session = session, out_pos = 0, handled = 0,
	}, methods)
	local f = io.open(self.out_wire, 'ab')
	if not f then return nil, 'cannot open outgoing journal' end
	local size = f:seek('end')
	f:close()
	if size ~= 0 then return nil, 'existing journal requires a fresh PUYO2_LINK_DIR' end
	self:status()
	if self.failed then return nil, 'LAN bridge status unavailable' end
	self:progress()
	return self
end

return transport
