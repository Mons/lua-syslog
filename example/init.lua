local log = require 'syslog' {
	facility = 'local0',
	ident    = 'tarantool',
	maxqueue = 10,
}

box.fiber.wrap(function()
	local seq = 0
	while true do
		seq = seq + 1
		log:warn( 'message: %s %d','arg ',seq )
		box.fiber.sleep(0.01)
	end
end)
