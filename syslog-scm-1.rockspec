package = 'obj'
version = 'scm-1'
source  = {
    url    = 'git://github.com/Mons/lua-syslog.git',
    branch = 'master',
}
description = {
    summary  = "Async syslog for tarantool",
    homepage = 'https://github.com/Mons/lua-syslog.git',
    license  = 'BSD',
}
dependencies = {
    'lua >= 5.1'
}
build = {
    type = 'builtin',
    modules = {
        ['syslog'] = 'syslog.lua'
    }
}

-- vim: syntax=lua
