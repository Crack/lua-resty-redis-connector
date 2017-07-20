local redis = require "resty.redis"
redis.add_commands("sentinel")
local sentinel = require "resty.redis.sentinel"


local ipairs, setmetatable, pcall = ipairs, setmetatable, pcall
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_re_match = ngx.re.match
local tbl_remove = table.remove
local tbl_sort = table.sort

local ok, tbl_new = pcall(require, "table.new")
if not ok then
    tbl_new = function (narr, nrec) return {} end
end


-- A metatable which prevents undefined fields from being created / accessed
local fixed_field_metatable = {
    __index =
        function(t, k)
            error("field " .. tostring(k) .. " does not exist", 3)
        end,
    __newindex =
        function(t, k, v)
            error("attempt to create new field " .. tostring(k), 3)
        end,
}


-- Returns a new table, recursively copied from the one given, retaining
-- metatable assignment.
--
-- @param   table   table to be copied
-- @return  table
local function tbl_copy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == "table" then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[tbl_copy(orig_key)] = tbl_copy(orig_value)
        end
        setmetatable(copy, tbl_copy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end


-- Returns a new table, recursively copied from the combination of the given
-- table `t1`, with any missing fields copied from `defaults`.
--
-- If `defaults` is of type "fixed field" and `t1` contains a field name not
-- present in the defults, an error will be thrown.
--
-- @param   table   t1
-- @param   table   defaults
-- @return  table   a new table, recursively copied and merged
local function tbl_copy_merge_defaults(t1, defaults)
    if t1 == nil then t1 = {} end
    if defaults == nil then defaults = {} end
    if type(t1) == "table" and type(defaults) == "table" then
        local mt = getmetatable(defaults)
        local copy = {}
        for t1_key, t1_value in next, t1, nil do
            copy[tbl_copy(t1_key)] = tbl_copy_merge_defaults(
                t1_value, tbl_copy(defaults[t1_key])
            )
        end
        for defaults_key, defaults_value in next, defaults, nil do
            if t1[defaults_key] == nil then
                copy[tbl_copy(defaults_key)] = tbl_copy(defaults_value)
            end
        end
        return copy
    else
        return t1 -- not a table
    end
end


local DEFAULTS = setmetatable({
    connect_timeout = 100,
    read_timeout = 1000,
    connection_options = {}, -- pool, etc

    keepalive_timeout = 60000,
    keepalive_poolsize = 30,
    host = "127.0.0.1",
    port = 6379,
    path = "", -- /tmp/redis.sock
    password = "",
    db = 0,

    url = "", -- DSN url

    master_name = "mymaster",
    role = "master",  -- master | slave | any
    sentinels = {},

    cluster_startup_nodes = {},  -- TODO remove this until implemented?
}, fixed_field_metatable)


local _M = {
    _VERSION = '0.03',
}

local mt = { __index = _M }


function _M.new(config)
    local ok, config = pcall(tbl_copy_merge_defaults, config, DEFAULTS)
    if not ok then
        return nil, config  -- err
    else
        return setmetatable({
            config = setmetatable(config, fixed_field_metatable)
        }, mt)
    end
end


function _M.set_connect_timeout(self, timeout)
    self.config.connect_timeout = timeout
end


function _M.set_read_timeout(self, timeout)
    self.config.read_timeout = timeout
end


function _M.set_connection_options(self, options)
    self.config.connection_options = options
end


local function parse_dsn(params)
    local url = params.url
    if url and url ~= "" then
        local url_pattern = [[^(?:(redis|sentinel)://)(?:([^@]*)@)?([^:/]+)(?::(\d+|[msa]+))/?(.*)$]]

        local m, err = ngx_re_match(url, url_pattern, "oj")
        if not m then
            return nil, "could not parse DSN: " .. tostring(err)
        end

        local fields
        if m[1] == "redis" then
            fields = { "password", "host", "port", "db" }
        elseif m[1] == "sentinel" then
            fields = { "password", "master_name", "role", "db" }
        end

        -- password may not be present
        if #m < 5 then tbl_remove(fields, 1) end

        local roles = { m = "master", s = "slave", a = "any" }

        for i,v in ipairs(fields) do
            params[v] = m[i + 1]
            if v == "role" then
                params[v] = roles[params[v]]
            end
        end
    end

    return true, nil
end
_M.parse_dsn = parse_dsn


function _M.connect(self, params)
    local params = tbl_copy_merge_defaults(params, self.config)

    if params.url then
        local ok, err = parse_dsn(params)
        if not ok then ngx_log(ngx_ERR, err) end
    end

    if #params.sentinels > 0 then
        return self:connect_via_sentinel(params)
    else
        return self:connect_to_host(params)
    end
end


local function sort_by_localhost(a, b)
    if a.host == "127.0.0.1" and b.host ~= "127.0.0.1" then
        return true
    else
        return false
    end
end


function _M.connect_via_sentinel(self, params)
    local sentinels = params.sentinels
    local master_name = params.master_name
    local role = params.role
    local db = params.db
    local password = params.password

    local sentnl, err, previous_errors = self:try_hosts(sentinels)
    if not sentnl then
        return nil, err, previous_errors
    end

    if role == "master" or role == "any" then
        local master, err = sentinel.get_master(sentnl, master_name)
        if master then
            master.db = db
            master.password = password

            local redis, err = self:connect_to_host(master)
            if redis then
                sentnl:set_keepalive()
                return redis, err
            else
                if role == "master" then
                    return nil, err
                end
            end
        end
    end

    -- We either wanted a slave, or are failing over to a slave "any"
    local slaves, err = sentinel.get_slaves(sentnl, master_name)
    sentnl:set_keepalive()

    if not slaves then
        return nil, err
    end

    -- Put any slaves on 127.0.0.1 at the front
    tbl_sort(slaves, sort_by_localhost)

    if db or password then
        for i,slave in ipairs(slaves) do
            slave.db = db
            slave.password = password
        end
    end

    local slave, err, previous_errors = self:try_hosts(slaves)
    if not slave then
        return nil, err, previous_errors
    else
        return slave
    end
end


-- In case of errors, returns "nil, err, previous_errors" where err is
-- the last error received, and previous_errors is a table of the previous errors.
function _M.try_hosts(self, hosts)
    local errors = tbl_new(#hosts, 0)

    for i, host in ipairs(hosts) do
        local r, err = self:connect_to_host(host)
        if r and not err then
            return r, nil, errors
        else
            errors[i] = err
        end
    end

    return nil, "no hosts available", errors
end


function _M.connect_to_host(self, host)
    local r = redis.new()
    local config = self.config
    r:set_timeout(config.connect_timeout)

    local ok, err
    local path = host.path
    local opts = config.connection_options
    if path and path ~= "" then
        if opts then
            ok, err = r:connect(path, config.connection_options)
        else
            ok, err = r:connect(path)
        end
    else
        if opts then
            ok, err = r:connect(host.host, host.port, config.connection_options)
        else
            ok, err = r:connect(host.host, host.port)
        end
    end

    if not ok then
        return nil, err
    else
        r:set_timeout(self, config.read_timeout)

        local password = host.password
        if password and password ~= "" then
            local res, err = r:auth(password)
            if err then
                ngx_log(ngx_ERR, err)
                return res, err
            end
        end

        if host.db ~= nil then
            r:select(host.db)
        end
        return r, nil
    end
end


local function set_keepalive(self, redis)
    -- Restore connection to "NORMAL" before putting into keepalive pool,
    -- ignoring any errors.
    redis:discard()

    local config = self.config
    return redis:set_keepalive(
        config.keepalive_timeout, config.keepalive_poolsize
    )
end
_M.set_keepalive = set_keepalive


return setmetatable(_M, fixed_field_metatable)
