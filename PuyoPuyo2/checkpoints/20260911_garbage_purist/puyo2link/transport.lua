-- Reset-aware IPC journal. Raw .bin files remain byte-stream diagnostics;
-- .bin.wire files are the authoritative, generation-tagged transport.
local transport = {}
local methods = {}
methods.__index = methods
local HEADER = 14

local function record(kind, epoch, peer, payload)
	payload = payload or ''
	return string.pack('>c4I4I4I2', 'P2' .. kind .. '1', epoch, peer, #payload) .. payload
end

function methods:fail(message)
	self.failed = true
	self.established_peer = 0
	self.log('[transport-error] ' .. message)
end

function methods:append_control(kind, peer)
	local f = io.open(self.out_wire, 'ab')
	if not f then
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
	if self.failed then return end
	self:publish_reset()
	if self.failed then return end
	local f = io.open(self.in_wire, 'rb')
	if not f then return end
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
end

function methods:send(payload)
	if not self:valid() or #payload == 0 then return 0 end
	assert(#payload <= 255, 'TX credit invariant exceeded')
	-- Open both before writing either: an open failure is safely retryable.
	local raw = io.open(self.out_raw, 'ab')
	if not raw then return 0 end
	local wire = io.open(self.out_wire, 'ab')
	if not wire then raw:close(); return 0 end
	local wrote, err = wire:write(record('D', self.epoch, self.peer_epoch, payload))
	local closed, close_err = wire:close()
	if not wrote or not closed then
		raw:close()
		self:fail('data append failed: ' .. tostring(err or close_err))
		return 0
	end
	wrote, err = raw:write(payload)
	closed, close_err = raw:close()
	if not wrote or not closed then
		-- The wire record is committed; never send it a second time.
		self:fail('raw diagnostic append failed: ' .. tostring(err or close_err))
	end
	return #payload
end

function transport.new(out_raw, in_raw, log)
	local self = setmetatable({
		out_raw = out_raw, out_wire = out_raw .. '.wire', in_wire = in_raw .. '.wire',
		log = log, epoch = 0, published_epoch = 0, peer_epoch = 0, peer_ready = 0,
		ready_peer = 0, established_peer = 0, in_pos = 0, buffer = '',
		queue = {}, discarded = 0, failed = false,
	}, methods)
	local f = io.open(self.out_wire, 'ab')
	if not f then return nil, 'cannot open outgoing journal' end
	local size = f:seek('end')
	f:close()
	if size ~= 0 then return nil, 'existing journal requires a fresh PUYO2_LINK_DIR' end
	return self
end

return transport
