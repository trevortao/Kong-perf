local cjson = require "cjson"
local cache = ngx.shared.cache

local CACHE_KEYS = {
  APIS = "apis",
  ALL_APIS_BY_DIC = "ALL_APIS_BY_DIC",
  WILDCARD_APIS = "wildcard_apis",
  REQUEST_PATH_APIS = "request_path_apis"
}

local _M = {}

function _M.rawset(key, value)
  return cache:set(key, value)
end

function _M.rawset_with_expiry(key, value, expiry)
  return cache:set(key, value, expiry)
end

function _M.set(key, value)
  if value then
    value = cjson.encode(value)
  end
  return _M.rawset(key, value)
end


function _M.set_with_expiry(key, value, expiry)
  if value then
    value = cjson.encode(value)
  end
  return _M.rawset_with_expiry(key, value, expiry)
end

function _M.rawget(key)
  return cache:get(key)
end

function _M.get(key)
  local value, flags = _M.rawget(key)
  if value then
    value = cjson.decode(value)
  end
  return value, flags
end

function _M.incr(key, value)
  return cache:incr(key, value)
end

function _M.delete(key)
  cache:delete(key)
end

function _M.delete_all()
  cache:flush_all() -- This does not free up the memory, only marks the items as expired
  cache:flush_expired() -- This does actually remove the elements from the memory
end



function _M.api_key(host)
  return CACHE_KEYS.APIS..":"..host
end

function _M.all_apis_by_dict_key()
  return CACHE_KEYS.ALL_APIS_BY_DIC
end

function _M.wildcard_apis_by_dict_key()
  return CACHE_KEYS.WILDCARD_APIS
end

function _M.get_or_set(key, cb)
  local value, err
  -- Try to get
  value = _M.get(key)
  if not value then
    -- Get from closure
    value, err = cb()
    if err then
      return nil, err
    elseif value then
      local ok, err = _M.set(key, value)
      if not ok then
        ngx.log(ngx.ERR, err)
      end
    end
  end
  return value
end

return _M

