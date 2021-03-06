local singletons = require "kong.singletons"
local url = require "socket.url"
local cache = require "kong.tools.database_cache"

--Trevor: mru cache for speed up
local mru_cache = require "kong.tools.mru_cache"

local stringy = require "stringy"
local constants = require "kong.constants"
local responses = require "kong.tools.responses"

local table_insert = table.insert
local table_sort = table.sort
local string_match = string.match
local string_find = string.find
local string_format = string.format
local string_sub = string.sub
local string_gsub = string.gsub
local string_len = string.len
local ipairs = ipairs
local unpack = unpack
local type = type

local _M = {}

local MRU_CACHE_TIMEOUT = 600  -- 600 secs

-- Take a request_host and make it a pattern for wildcard matching.
-- Only do so if the request_host actually has a wildcard.
local function create_wildcard_pattern(request_host)
  if string_find(request_host, "*", 1, true) then
    local pattern = string_gsub(request_host, "%.", "%%.")
    pattern = string_gsub(pattern, "*", ".+")
    pattern = string_format("^%s$", pattern)
    return pattern
  end
end

-- Handles pattern-specific characters if any.
local function create_strip_request_path_pattern(request_path)
  return string_gsub(request_path, "[%(%)%.%%%+%-%*%?%[%]%^%$]", function(c) return "%"..c end)
end

local function get_upstream_url(api)
  local result = api.upstream_url

  -- Checking if the target url ends with a final slash
  local len = string_len(result)
  if string_sub(result, len, len) == "/" then
    -- Remove one slash to avoid having a double slash
    -- Because ngx.var.request_uri always starts with a slash
    result = string_sub(result, 0, len - 1)
  end

  return result
end

local function get_host_from_upstream_url(val)
  local parsed_url = url.parse(val)

  local port
  if parsed_url.port then
    port = parsed_url.port
  elseif parsed_url.scheme == "https" then
    port = 443
  end

  return parsed_url.host..(port and ":"..port or "")
end

-- Load all APIs in memory.
-- Sort the data for faster lookup: dictionary per request_host and an array of wildcard request_host.

--Trevor: count the calls to load_apis_in_memory()
local count_load_apis_in_memory = 0

function _M.load_apis_in_memory()

  count_load_apis_in_memory = count_load_apis_in_memory + 1

  if (count_load_apis_in_memory % 100 ==0) then
    ngx.log(ngx.DEBUG, "Trevor:Call load_apis_in_memory() for "..count_load_apis_in_memory.." times")
  end

  local apis, err = singletons.dao.apis:find_all()
  if err then
    return nil, err
  end

  -- build dictionnaries of request_host:api for efficient O(1) lookup.
  -- we only do O(n) lookup for wildcard request_host and request_path that are in arrays.
  local dns_dic, dns_wildcard_arr, request_path_arr = {}, {}, {}
  for _, api in ipairs(apis) do
    if api.request_host then
      local pattern = create_wildcard_pattern(api.request_host)
      if pattern then
        -- If the request_host is a wildcard, we have a pattern and we can
        -- store it in an array for later lookup.
        table_insert(dns_wildcard_arr, {pattern = pattern, api = api})
      else
        -- Keep non-wildcard request_host in a dictionary for faster lookup.
        dns_dic[api.request_host] = api
      end
    end
    if api.request_path then
      table_insert(request_path_arr, {
        api = api,
        request_path = api.request_path,
        strip_request_path_pattern = create_strip_request_path_pattern(api.request_path)
      })
    end
  end

  -- Sort request_path_arr by descending specificity.
  table_sort(request_path_arr, function (first, second)
    return first.request_path > second.request_path
  end)

  return {
    by_dns = dns_dic,
    request_path_arr = request_path_arr, -- all APIs with a request_path
    wildcard_dns_arr = dns_wildcard_arr -- all APIs with a wildcard request_host
  }
end



function _M.find_api_by_request_host(req_headers, apis_dics)
  local hosts_list = {}
  for _, header_name in ipairs({"Host", constants.HEADERS.HOST_OVERRIDE}) do
    local hosts = req_headers[header_name]
    if hosts then
      if type(hosts) == "string" then
        hosts = {hosts}
      end
      -- for all values of this header, try to find an API using the apis_by_dns dictionnary
      for _, host in ipairs(hosts) do
        host = unpack(stringy.split(host, ":"))
        table_insert(hosts_list, host)
        if apis_dics.by_dns[host] then
          return apis_dics.by_dns[host], host
        else
          -- If the API was not found in the dictionary, maybe it is a wildcard request_host.
          -- In that case, we need to loop over all of them.
          for _, wildcard_dns in ipairs(apis_dics.wildcard_dns_arr) do
            if string_match(host, wildcard_dns.pattern) then
              return wildcard_dns.api
            end
          end
        end
      end
    end
  end

  return nil, nil, hosts_list
end

function _M.find_api_by_request_host_support_mru(req_headers, apis_dics)
  local hosts_list = {}
  for _, header_name in ipairs({"Host", constants.HEADERS.HOST_OVERRIDE}) do
    local hosts = req_headers[header_name]
    if hosts then
      if type(hosts) == "string" then
        hosts = {hosts}
      end
      -- for all values of this header, try to find an API using the apis_by_dns dictionnary
      for _, host in ipairs(hosts) do
        host = unpack(stringy.split(host, ":"))
        table_insert(hosts_list, host)
        if apis_dics.by_dns[host] then
          return apis_dics.by_dns[host], host
        else
          -- If the API was not found in the dictionary, maybe it is a wildcard request_host.
          -- In that case, we need to loop over all of them.
          for _, wildcard_dns in ipairs(apis_dics.wildcard_dns_arr) do
            if string_match(host, wildcard_dns.pattern) then
              return wildcard_dns.api, host
            end
          end
        end
      end
    end
  end

  return nil, nil, hosts_list
end


--Trevor: use the host as the key to get the api from mru cache directly
function _M.find_api_by_request_host_with_mru(req_headers)
  local hosts_list = {}
  for _, header_name in ipairs({"Host", constants.HEADERS.HOST_OVERRIDE}) do
    local hosts = req_headers[header_name]
    if hosts then
      if type(hosts) == "string" then
        hosts = {hosts}
      end
      -- for all values of this header, try to find an API using the apis_by_dns dictionnary
      for _, host in ipairs(hosts) do
        host = unpack(stringy.split(host, ":"))
        table_insert(hosts_list, host)
        -- Check mru cache
        local mru_cache_key = mru_cache.api_key(host)
        local mc_api = mru_cache.get(mru_cache_key)
        if mc_api then 
          ngx.log(ngx.DEBUG, "Trevor: find an entry in mru_cache for host "..host)
          return mc_api, host
        end
        --else
          --Lookup the wildcard entry in mru_cache 
          --return nil, nil, hosts_list
      end
    end
  end
  return nil, nil, hosts_list
end

function _M.find_api_by_request_host_with_mru_and_wildcard(req_headers)
  local hosts_list = {}
  for _, header_name in ipairs({"Host", constants.HEADERS.HOST_OVERRIDE}) do
    local hosts = req_headers[header_name]
    if hosts then
      if type(hosts) == "string" then
        hosts = {hosts}
      end
      -- for all values of this header, try to find an API using the apis_by_dns dictionnary
      for _, host in ipairs(hosts) do
        host = unpack(stringy.split(host, ":"))
        table_insert(hosts_list, host)
        -- Check mru cache
        local mru_cache_key = mru_cache.api_key(host)
        local mc_api = mru_cache.get(mru_cache_key)
        if mc_api then 
          ngx.log(ngx.DEBUG, "Trevor: find an entry in mru_cache for host "..host)
          return mc_api, host
        else
          --Lookup the wildcard entry in mru_cache 
          --return nil, nil, hosts_list
          local wildcard_api_key = mru_cache.wildcard_apis_by_dict_key()
          local wildcard_apis = mru_cache.get(wildcard_api_key)
          if wildcard_apis then
            for _, wildcard_dns in ipairs(wildcard_apis) do
              if string_match(host, wildcard_dns.pattern) then
                ngx.log(ngx.DEBUG, "Trevor: find an wildcard entry in mru_cache for host "..host)
                return wildcard_dns.api
              end
            end
          end          
        end
      end
    end
  end
  return nil, nil, hosts_list
end



--Trevor: find the api from mru cache apis by the host directly
function _M.find_api_by_request_host_with_mru2(req_headers)
  local hosts_list = {}
  local mc_api_dics_key = mru_cache.all_apis_by_dict_key()
  local api_dics = mru_cache.get(mc_api_dics_key)

  if api_dics == nil then
    return nil, nil, hosts_list
  end

  for _, header_name in ipairs({"Host", constants.HEADERS.HOST_OVERRIDE}) do
    local hosts = req_headers[header_name]
    if hosts then
      if type(hosts) == "string" then
        hosts = {hosts}
      end
      -- for all values of this header, try to find an API using the apis_by_dns dictionnary
      for _, host in ipairs(hosts) do
        host = unpack(stringy.split(host, ":"))
        table_insert(hosts_list, host)
        -- Check mru cache
        if apis_dics[host] then
          ngx.log(ngx.DEBUG, "Trevor: find an entry in mru_cache for host "..host)
          return apis_dics[host], host
        end
        --else
          --Lookup the wildcard entry in mru_cache 
          --return nil, nil, hosts_list
      end
    end
  end
  return nil, nil, hosts_list
end


-- To do so, we have to compare entire URI segments (delimited by "/").
-- Comparing by entire segment allows us to avoid edge-cases such as:
-- uri = /mockbin-with-pattern/xyz
-- api.request_path regex = ^/mockbin
-- ^ This would wrongfully match. Wether:
-- api.request_path regex = ^/mockbin/
-- ^ This does not match.

-- Because we need to compare by entire URI segments, all URIs need to have a trailing slash, otherwise:
-- uri = /mockbin
-- api.request_path regex = ^/mockbin/
-- ^ This would not match.
-- @param  `uri` The URI for this request.
-- @param  `request_path_arr`    An array of all APIs that have a request_path property.
function _M.find_api_by_request_path(uri, request_path_arr)
  if not stringy.endswith(uri, "/") then
    uri = uri.."/"
  end

  for _, item in ipairs(request_path_arr) do
    local m, err = ngx.re.match(uri, "^"..(item.request_path == "/" and "/" or item.request_path.."/"))
    if err then
      ngx.log(ngx.ERR, "[resolver] error matching requested request_path: "..err)
    elseif m then
      return item.api, item.strip_request_path_pattern
    end
  end
end

-- Replace `/request_path` with `request_path`, and then prefix with a `/`
-- or replace `/request_path/foo` with `/foo`, and then do not prefix with `/`.
function _M.strip_request_path(uri, strip_request_path_pattern, upstream_url_has_path)
  local uri = string_gsub(uri, strip_request_path_pattern, "", 1)

  -- Sometimes uri can be an empty string, and adding a slash "/"..uri will lead to a trailing slash
  -- We don't want to add a trailing slash in one specific scenario, when the upstream_url already has
  -- a path (so it's not root, like http://hello.com/, but http://hello.com/path) in order to avoid
  -- having an unnecessary trailing slash not wanted by the user. Hence the "upstream_url_has_path" check.
  if string_sub(uri, 0, 1) ~= "/" and not upstream_url_has_path then
    uri = "/"..uri
  end
  return uri
end

-- Find an API from a request made to nginx. Either from one of the Host or X-Host-Override headers
-- matching the API's `request_host`, either from the `uri` matching the API's `request_path`.
--
-- To perform this, we need to query _ALL_ APIs in memory. It is the only way to compare the `uri`
-- as a regex to the values set in DB, as well as matching wildcard dns.
-- We keep APIs in the database cache for a longer time than usual.
-- @see https://github.com/Mashape/kong/issues/15 for an improvement on this.
--
-- @param  `uri`          The URI for this request.
-- @return `err`          Any error encountered during the retrieval.
-- @return `api`          The retrieved API, if any.
-- @return `matched_host` The host that was matched for this API, if matched.
-- @return `hosts`        The list of headers values found in Host and X-Host-Override.
-- @return `strip_request_path_pattern` If the API was retrieved by request_path, contain the pattern to strip it from the URI.
local function find_api(uri, headers)
  local api, matched_host, hosts_list, strip_request_path_pattern

  -- Retrieve all APIs


  local apis_dics, err = cache.get_or_set(cache.all_apis_by_dict_key(), _M.load_apis_in_memory)
  if err then
    return err
  end

  -- Find by Host header
  api, matched_host, hosts_list = _M.find_api_by_request_host(headers, apis_dics)
  -- If it was found by Host, return
  if api then
    ngx.req.set_header(constants.HEADERS.FORWARDED_HOST, matched_host)
    return nil, api, matched_host, hosts_list
  end

  -- Otherwise, we look for it by request_path. We have to loop over all APIs and compare the requested URI.
  api, strip_request_path_pattern = _M.find_api_by_request_path(uri, apis_dics.request_path_arr)

  return nil, api, nil, hosts_list, strip_request_path_pattern
end


local function find_api_with_mru(uri, headers)
  local api, matched_host, hosts_list, strip_request_path_pattern


  -- Try to get API from mru cache first
  -- Find by host header
  api, matched_host, hosts_list = _M.find_api_by_request_host_with_mru(headers)
  -- If it was found by Host, return
  if api then
    ngx.req.set_header(constants.HEADERS.FORWARDED_HOST, matched_host)
    return nil, api, matched_host, hosts_list
  end

  -- Retrieve all APIs

  local apis_dics, err = cache.get_or_set(cache.all_apis_by_dict_key(), _M.load_apis_in_memory)
  if err then
    return err
  end

  -- Find by Host header
  --api, matched_host, hosts_list = _M.find_api_by_request_host(headers, apis_dics)
  api, matched_host, hosts_list = _M.find_api_by_request_host_support_mru(headers, apis_dics)
  -- If it was found by Host, return
  if api then
    ngx.req.set_header(constants.HEADERS.FORWARDED_HOST, matched_host)
    --Add the matched api to mru_cache
    --Trevor: See if it is a wildcard 
    local api_host = matched_host
    local mc_api_key
    if api_host then
      mc_api_key = mru_cache.api_key(api_host)
    else
      api_host = ngx.req.get_headers()["host"]
      mc_api_key = mru_cache.api_key(api_host)
    end
    ngx.log(ngx.DEBUG, "Trevor: Add an entry in mru_cache for host "..api_host)
    --mru_cache.set(mc_api_key, api)
    mru_cache.set_with_expiry(mc_api_key, api, MRU_CACHE_TIMEOUT)   --expire in 600 secs
   --Add end
    return nil, api, matched_host, hosts_list
  end

  -- Otherwise, we look for it by request_path. We have to loop over all APIs and compare the requested URI.
  api, strip_request_path_pattern = _M.find_api_by_request_path(uri, apis_dics.request_path_arr)

  return nil, api, nil, hosts_list, strip_request_path_pattern
end


local function find_api_with_mru_and_wildcard(uri, headers)
  local api, matched_host, hosts_list, strip_request_path_pattern


  -- Try to get API from mru cache first
  -- Find by host header
  api, matched_host, hosts_list = _M.find_api_by_request_host_with_mru_and_wildcard(headers)
  -- If it was found by Host, return
  if api then
    ngx.req.set_header(constants.HEADERS.FORWARDED_HOST, matched_host)
    return nil, api, matched_host, hosts_list
  end

  -- Retrieve all APIs

  local apis_dics, err = cache.get_or_set(cache.all_apis_by_dict_key(), _M.load_apis_in_memory)
  if err then
    return err
  end

  -- Find by Host header
  api, matched_host, hosts_list = _M.find_api_by_request_host(headers, apis_dics)
  -- If it was found by Host, return
  if api then
    ngx.req.set_header(constants.HEADERS.FORWARDED_HOST, matched_host)
    --Add the matched api to mru_cache
    --Trevor: See if it is a wildcard api

    if api.request_host then
      local pattern = create_wildcard_pattern(api.request_host)
      if pattern then
        -- If the request_host is a wildcard, we have a pattern and we can
        -- store it in an array for later lookup.
       local wildcard_api_key = mru_cache.wildcard_apis_by_dict_key()
       local dns_wildcard_arr = mru_cache.get(wildcard_api_key)
       if dns_wildcard_arr then
         table_insert(dns_wildcard_arr, {pattern = pattern, api = api})
       else
         dns_wildcard_arr = {}
         table_insert(dns_wildcard_arr, {pattern = pattern, api = api})
       end
       ngx.log(ngx.DEBUG, "Trevor: Add an wildcard entry in mru_cache")
       mru_cache.set_with_expiry(wildcard_api_key, dns_wildcard_arr, MRU_CACHE_TIMEOUT)
      else
        local mc_api_key = mru_cache.api_key(matched_host)
        ngx.log(ngx.DEBUG, "Trevor: Add an entry in mru_cache for host "..matched_host)
        --mru_cache.set(mc_api_key, api)
        mru_cache.set_with_expiry(mc_api_key, api, MRU_CACHE_TIMEOUT)   --expire in 300 secs
        --Add end
      end
    end
    return nil, api, matched_host, hosts_list
  end

  -- Otherwise, we look for it by request_path. We have to loop over all APIs and compare the requested URI.
  api, strip_request_path_pattern = _M.find_api_by_request_path(uri, apis_dics.request_path_arr)

  return nil, api, nil, hosts_list, strip_request_path_pattern
end




--Trevor: Set all APIs in a single cache key: CACHE_KEYS.ALL_APIS_BY_DIC
local function find_api_with_mru2(uri, headers)
  local api, matched_host, hosts_list, strip_request_path_pattern


  -- Try to get API from mru cache first
  -- Find by host header
  api, matched_host, hosts_list = _M.find_api_by_request_host_with_mru2(headers)
  -- If it was found by Host, return
  if api then
    ngx.req.set_header(constants.HEADERS.FORWARDED_HOST, matched_host)
    return nil, api, matched_host, hosts_list
  end

  -- Retrieve all APIs

  local apis_dics, err = cache.get_or_set(cache.all_apis_by_dict_key(), _M.load_apis_in_memory)
  if err then
    return err
  end

  -- Find by Host header
  api, matched_host, hosts_list = _M.find_api_by_request_host(headers, apis_dics)
  -- If it was found by Host, return
  if api then
    ngx.req.set_header(constants.HEADERS.FORWARDED_HOST, matched_host)
    --Add the matched api to mru_cache
    local mc_all_apis_key = mru_cache.all_apis_by_dict_key()
    local mc_all_apis = mru_cache.get(mc_all_apis_key)
    if mc_all_apis == nil then
      mc_all_apis = {}
      mc_all_apis[api.request_host] = api
    else
      mc_all_apis[api.request_host] = api
    end
    mru_cache.set_with_expiry(mc_all_apis_key, mc_all_apis, MRU_CACHE_TIMEOUT)   --expire in 600 secs
    ngx.log(ngx.DEBUG, "Trevor: Add an entry in mru_cache of key all_apis for host "..matched_host)
    --mru_cache.set(mc_api_key, api)
    mru_cache.set_with_expiry(mc_api_key, api, MRU_CACHE_TIMEOUT)   --expire in 600 secs
   --Add end
    return nil, api, matched_host, hosts_list
  end

  -- Otherwise, we look for it by request_path. We have to loop over all APIs and compare the requested URI.
  api, strip_request_path_pattern = _M.find_api_by_request_path(uri, apis_dics.request_path_arr)

  return nil, api, nil, hosts_list, strip_request_path_pattern
end

local function url_has_path(url)
  local _, count_slashes = string_gsub(url, "/", "")
  return count_slashes > 2
end


--Trevor: debug for exec time
local find_api_exec_times = 0
local total_exec_time_for_find_api = 0.0

function _M.execute(request_uri, request_headers)
  local uri = unpack(stringy.split(request_uri, "?"))

  --local begin = ngx.now()

  --Trevor: Use mru cache
  --local err, api, matched_host, hosts_list, strip_request_path_pattern = find_api(uri, request_headers)
  local err, api, matched_host, hosts_list, strip_request_path_pattern = find_api_with_mru(uri, request_headers)
  --local err, api, matched_host, hosts_list, strip_request_path_pattern = find_api_with_mru_and_wildcard(uri, request_headers)

  --local exec_end = ngx.now()
  if err then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  elseif not api then
    return responses.send_HTTP_NOT_FOUND {
      message = "API not found with these values",
      request_host = hosts_list,
      request_path = uri
    }
  end

  local upstream_host
  local upstream_url = get_upstream_url(api)

  -- If API was retrieved by request_path and the request_path needs to be stripped
  if strip_request_path_pattern and api.strip_request_path then
    uri = _M.strip_request_path(uri, strip_request_path_pattern, url_has_path(upstream_url))
    ngx.req.set_header(constants.HEADERS.FORWARDED_PREFIX, api.request_path)
  end

  upstream_url = upstream_url..uri

  if api.preserve_host then
    upstream_host = matched_host or ngx.req.get_headers()["host"]
  end

  if upstream_host == nil then
    upstream_host = get_host_from_upstream_url(upstream_url)
  end

  return api, upstream_url, upstream_host
end

return _M
