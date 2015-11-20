--[[

local log = require 'syslog' {
	facility = 'local0',
	ident    = 'tarantool',
}

log:info( 'message: %s','arg' )

]]

print("loading ",...)


local obj = require 'obj'
local M = obj.class( {}, 'syslog' )

M.LOG_EMERG   = 0
M.LOG_ALERT   = 1
M.LOG_CRIT    = 2
M.LOG_ERR     = 3
M.LOG_WARNING = 4
M.LOG_NOTICE  = 5
M.LOG_INFO    = 6
M.LOG_DEBUG   = 7

local methods = {
	emerg     = M.LOG_EMERG,
	alert     = M.LOG_ALERT,
	crit      = M.LOG_CRIT,
	critical  = M.LOG_CRIT,
	err       = M.LOG_ERR,
	error     = M.LOG_ERR,
	warning   = M.LOG_WARNING,
	warn      = M.LOG_WARNING,
	notice    = M.LOG_NOTICE,
	info      = M.LOG_INFO,
	debug     = M.LOG_DEBUG,
	trace     = M.LOG_DEBUG,
}

M.LOG_KERN     = 0
M.LOG_USER     = 8
M.LOG_MAIL     = 16
M.LOG_DAEMON   = 24
M.LOG_AUTH     = 32
M.LOG_SYSLOG   = 40
M.LOG_LPR      = 48
M.LOG_NEWS     = 56
M.LOG_UUCP     = 64
M.LOG_CRON     = 72
M.LOG_AUTHPRIV = 80
M.LOG_FTP      = 88
M.LOG_LOCAL0   = 128
M.LOG_LOCAL1   = 136
M.LOG_LOCAL2   = 144
M.LOG_LOCAL3   = 152
M.LOG_LOCAL4   = 160
M.LOG_LOCAL5   = 168
M.LOG_LOCAL6   = 176
M.LOG_LOCAL7   = 184

local facility = {
	kern      = M.LOG_KERN,
	user      = M.LOG_USER,
	mail      = M.LOG_MAIL,
	daemon    = M.LOG_DAEMON,
	auth      = M.LOG_AUTH,
	syslog    = M.LOG_SYSLOG,
	lpr       = M.LOG_LPR,
	news      = M.LOG_NEWS,
	uucp      = M.LOG_UUCP,
	cron      = M.LOG_CRON,
	authpriv  = M.LOG_AUTHPRIV,
	ftp       = M.LOG_FTP,
	local0    = M.LOG_LOCAL0,
	local1    = M.LOG_LOCAL1,
	local2    = M.LOG_LOCAL2,
	local3    = M.LOG_LOCAL3,
	local4    = M.LOG_LOCAL4,
	local5    = M.LOG_LOCAL5,
	local6    = M.LOG_LOCAL6,
	local7    = M.LOG_LOCAL7,
}

local rfacility = {}
for k,v in pairs(facility) do rfacility[ v ] = k end

local ffi = require 'ffi'
local io = require 'io'

function M:_init( args )
	if not args then args = {} end
	if type(args) ~= 'table' then error("Arguments to syslog be a table", 3) end

	self.facility = args.facility or 'user'
	self._facility = facility[self.facility]
	if not self._facility then error("Unknown facility `".. self.facility .."'", 3) end
	self.ident    = args.ident or 'tarantool'

	local st,err
	if args.socket then
		local r,e = io.open(args.socket,'r')
		if not r and box.errno() == box.errno.EOPNOTSUPP then
			-- it's ok
		elseif(r) then
			error(args.socket..": Not a socket", 3)
		else
			error(args.socket..": "..box.errno.strerror(box.errno()),3)
		end
		self.socket = args.socket
		-- if not st then error() end
	else
		local sock
		for _,v in ipairs({ "/dev/log", "/var/run/syslog" }) do
			local r,e = io.open(v,'r')
			if not r and box.errno() == box.errno.EOPNOTSUPP then
				sock = v
				break
			elseif(r) then
				-- print(v..": Not a socket")
			else
				-- print(v..": "..box.errno.strerror(box.errno()))
			end
		end
		if not sock then
			error("Can't find log socket",3)
		end
		self.socket = sock
	end

	if args.hires == nil then
		if ffi.os:lower() == 'linux' then
			args.hires = true
		end
	end

	if args.hires then
		self._date = self._date_rfc
	else
		self._date = self._date_iso
	end

	self.connect_order = {
		{'AF_UNIX', 'SOCK_STREAM', 0},
		{'AF_UNIX', 'SOCK_DGRAM', 0},
	}

	self.ch = box.ipc.channel(1)

	self.maxqueue = args.maxqueue or 1000
	self.wlen = 1
	self.wbuf = {}
	self.last = self.wbuf

	print("init ", self.facility, " ", self.ident, " via ", self.socket )
	self.fiber = box.fiber.wrap(function()
		while true do
			box.fiber.sleep(0.3)
			for _,socktype in pairs(self.connect_order) do
				local s = box.socket(unpack(socktype))
				if not s then
					print(box.errno.strerror(box.errno()))
					box.fiber.sleep(1)
				else
					if s:sysconnect( "unix/", self.socket ) then
						-- print("connected")
						if _ ~= 1 then
							table.remove( self.connect_order, _ )
							table.insert( self.connect_order, 1, socktype )
						end

						if socktype[2] == 'SOCK_DGRAM' then
							self.dgram = true
							local val = s:getsockopt('SOL_SOCKET','SO_SNDBUF')
							if val then
								self.maxbuf = val
								-- print("max buf size = ",self.maxbuf)
							else
								print('getsockopt failed: '..box.errno.strerror(box.errno()))
								self.maxbuf = nil
							end
						else
							self.dgram = false
							self.maxbuf = nil
						end

						self.s = s
						break;
					elseif box.errno() == box.errno.ENOPROTOOPT then
						-- next
					else
						print(box.errno(), " ",box.errno.strerror(box.errno()))
					end
				end
			end

			if self.s then
				-- print("connected")
				while true do
					if not self.wbuf.pre then
						-- print("switch to wait")
						self.ch:get()
					end

					while self.wbuf.pre do
						if not self.s then break end
						local msg = self.wbuf.pre .. self.wbuf.msg .. "\n\0"
						-- print("sending ",self.wbuf.pre .. self.wbuf.msg)
						if self.s:syswrite(msg) then
							-- print("sent successfully")
							self.wbuf = self.wbuf.next
							self.wlen = self.wlen - 1
							if not self.wbuf then break end
						else
							if box.errno() == box.errno.EMSGSIZE then
								print(string.format("Message size %d to long for syslog: '%s'",#msg,msg))
								self.wbuf = self.wbuf.next
								self.wlen = self.wlen - 1
							elseif box.errno() == box.errno.EAGAIN then
								-- print("not writable")
								self.s:writable(0.1)
							elseif box.errno() == box.errno.EINTR then
							else
								print("Failed to send: "..box.errno.strerror(box.errno()))
								self.s:close()
								self.s = nil
							end
						end
					end

					if not self.wbuf then
						self.wbuf = {}
						self.last = self.wbuf
						self.wlen = 1
					end

					if not self.s then break end
				end
			else
				print("no connection")
				box.fiber.sleep(1)
			end
		end
		return;
	end)
end

ffi.cdef[[
	struct timeval {
		uint64_t      tv_sec;
		uint64_t      tv_usec;
	};
	int gettimeofday(struct timeval *tv, struct timezone *tz);
]]
local timeval = ffi.typeof("struct timeval");
local C = ffi.C
local math = require 'math'

local function timepair()
	local tv = timeval();
	C.gettimeofday(tv,nil);	
	return
		tonumber(tv.tv_sec),
		math.floor(tonumber(tv.tv_usec)/1e3);
end

function M:_date_iso(t,m)
	local t,m = timepair()
	return os.date('%b %e %H:%M:%S',t)
end

function M:_date_rfc(t,m)
	local t,m = timepair()
	return os.date('%Y-%m-%dT%H:%M:%S',t)..'.'..string.format('%03d',m)
end

M._date = M._date_iso

for method,level in pairs(methods) do
	M[method] = function (self,f,...)
		local msg  = string.format(f,...)
		local date = self:_date()
		local pre = string.format('<%d>%s %s: ',
			level + self._facility,
			date,
			self.ident
		)

		if self.wlen >= self.maxqueue then
			print("Discard message '"..date.." "..msg.."' because of queue overflow")
			return false
		end

		-- print(pre..msg)

		if self.maxbuf then
			local left = self.maxbuf - #pre - 2
			if #msg > self.maxbuf then
				for x = 1, #msg, left do
					self.last.next = {
						pre = pre,
						msg = string.sub(msg, x, x + left - 1),
					}
					self.last = self.last.next
					self.wlen = self.wlen + 1
				end
			else
				self.last.next = {
					pre = pre,
					msg = msg,
				}
				self.last = self.last.next
				self.wlen = self.wlen + 1
			end
		else
			self.last.next = {
				pre = pre,
				msg = msg,
			}
			self.last = self.last.next
			self.wlen = self.wlen + 1
		end
		if not self.wbuf.pre then
			self.wbuf = self.wbuf.next
			self.wlen = self.wlen - 1
		end

		if self.ch:has_readers() then
			-- print("call put")
			self.ch:put(true)
		end

		return true
	end
end


return M
