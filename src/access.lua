local JSON = require "kong.plugins.middleman.json"
local cjson = require "cjson"
local url = require "socket.url"

local string_format = string.format

local kong_response = kong.response

local get_headers = ngx.req.get_headers
local get_uri_args = ngx.req.get_uri_args
local read_body = ngx.req.read_body
local get_body = ngx.req.get_body_data
local get_method = ngx.req.get_method
local ngx_re_match = ngx.re.match
local ngx_re_find = ngx.re.find

local HTTP = "http"
local HTTPS = "https"

local _M = {}

local function parse_url(host_url)
  print("parse_url function")
  local parsed_url = url.parse(host_url)
  if not parsed_url.port then
    print("parsed_url.port not present")
    if parsed_url.scheme == HTTP then
      parsed_url.port = 80
      print("parsed_url.port set to 80")
     elseif parsed_url.scheme == HTTPS then
      parsed_url.port = 443
      print("parsed_url.port set to 443")
     end
  end
  if not parsed_url.path then
    print("no parsed_url.path")
    parsed_url.path = "/"
  end
  return parsed_url
end

function _M.execute(conf)
  if not conf.run_on_preflight and get_method() == "OPTIONS" then
    return
  end

  local name = "[middleman] "
  local ok, err
  local parsed_url = parse_url(conf.url)
  local host = parsed_url.host
  local port = tonumber(parsed_url.port)
  local payload = _M.compose_payload(parsed_url)

  local sock = ngx.socket.tcp()
  sock:settimeout(conf.timeout)

  print("call sock connect")
  print("host is " .. host)
  print("port is " .. port)
  ok, err = sock:connect(host, port)
  if not ok then
    ngx.log(ngx.ERR, name .. "failed to connect to " .. host .. ":" .. tostring(port) .. ": ", err)
    return
  end

  print("call sock sslhandshake")
  if parsed_url.scheme == HTTPS then
    local _, err = sock:sslhandshake(true, host, false)
    if err then
      ngx.log(ngx.ERR, name .. "failed to do SSL handshake with " .. host .. ":" .. tostring(port) .. ": ", err)
    end
  end

  print("call sock send payload")
  ok, err = sock:send(payload)
  if not ok then
    print("send payload failed")
    ngx.log(ngx.ERR, name .. "failed to send data to " .. host .. ":" .. tostring(port) .. ": ", err)
  end

  print("received all lines")
  local line, err = sock:receive("*l")
  print(line)

  if err then 
    ngx.log(ngx.ERR, name .. "failed to read response status from " .. host .. ":" .. tostring(port) .. ": ", err)
    return
  end

  local status_code = tonumber(string.match(line, "%s(%d%d%d)%s"))
  print("status code is " .. status_code)
  local headers = {}

  repeat
    print("in repeat block")
    line, err = sock:receive("*l")
    if err then
      ngx.log(ngx.ERR, name .. "failed to read header " .. host .. ":" .. tostring(port) .. ": ", err)
      return
    end

    local pair = ngx_re_match(line, "(.*):\\s*(.*)", "jo")

    if pair then
      headers[string.lower(pair[1])] = pair[2]
    end
  until ngx_re_find(line, "^\\s*$", "jo")

  local body, err = sock:receive(tonumber(headers['content-length']))
  print("content-length converted in sock receive")
  if err then
    ngx.log(ngx.ERR, name .. "failed to read body " .. host .. ":" .. tostring(port) .. ": ", err)
    return
  end

  print("sock keepalive")
  ok, err = sock:setkeepalive(conf.keepalive)
  if not ok then
    ngx.log(ngx.ERR, name .. "failed to keepalive to " .. host .. ":" .. tostring(port) .. ": ", err)
    return
  end

  if status_code > 299 then
    print("status_code greater than 299")
    if err then 
      ngx.log(ngx.ERR, name .. "failed to read response from " .. host .. ":" .. tostring(port) .. ": ", err)
    end

    local response_body
    if conf.response == "table" then 
      print("response_body table")
      response_body = JSON:decode(string.match(body, "%b{}"))
    else
      print("response_body string")
      response_body = string.match(body, "%b{}")
    end
    print("about to send response kong_response.send")
    return kong_response.send(status_code, response_body)
  end

end

function _M.compose_payload(parsed_url)
    local headers = get_headers()
    local uri_args = get_uri_args()
    local next = next
    
    read_body()
    local body_data = get_body()

    headers["target_uri"] = ngx.var.request_uri
    headers["target_method"] = ngx.var.request_method

    local url
    if parsed_url.query then
    print("url has query params")
      url = parsed_url.path .. "?" .. parsed_url.query
    else
    print("no query params")
      url = parsed_url.path
    end
    
    local raw_json_headers = JSON:encode(headers)
    local raw_json_body_data = JSON:encode(body_data)

    local raw_json_uri_args
    if next(uri_args) then
    print("setting raw json uri args")
      raw_json_uri_args = JSON:encode(uri_args) 
    else
    print("setting empty object")
      -- Empty Lua table gets encoded into an empty array whereas a non-empty one is encoded to JSON object.
      -- Set an empty object for the consistency.
      raw_json_uri_args = "{}"
    end

    local payload_body = [[{"headers":]] .. raw_json_headers .. [[,"uri_args":]] .. raw_json_uri_args.. [[,"body_data":]] .. raw_json_body_data .. [[}]]
    
    local payload_headers = string_format(
      "GET %s HTTP/1.1\r\nHost: %s:31662\r\nConnection: Keep-Alive\r\nContent-Type: application/json\r\nContent-Length: %s\r\nAuthorization: eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsIng1dCI6Ik4tbEMwbi05REFMcXdodUhZbkhRNjNHZUNYYyIsImtpZCI6Ik4tbEMwbi05REFMcXdodUhZbkhRNjNHZUNYYyJ9.eyJhdWQiOiI5ZTViZDhiZi0zZmQyLTQ0NGMtYmEzNy0yNTQ5ZTZkYzhmOGUiLCJpc3MiOiJodHRwczovL3N0cy53aW5kb3dzLm5ldC82ZWRkZDE4NS03YWQ3LTRlZTMtOTQ4MS0wNDY0NGI5ZjQzYTIvIiwiaWF0IjoxNTUzMDE2MDU4LCJuYmYiOjE1NTMwMTYwNTgsImV4cCI6MTU1MzAxOTk1OCwiYWlvIjoiQVNRQTIvOEtBQUFBQlhmUjhoeUxTN1ZyN3JNajFkSEN4SzJmMlFHbjAyVmtKWEUyb1R3LzZGTT0iLCJhbXIiOlsid2lhIl0sImZhbWlseV9uYW1lIjoiTU9OREFMIiwiZ2l2ZW5fbmFtZSI6IlNVU0hPQkhBTiIsImluX2NvcnAiOiJ0cnVlIiwiaXBhZGRyIjoiMjE2LjIwLjE3Ni4yIiwibmFtZSI6Ik1PTkRBTCwgU1VTSE9CSEFOIiwibm9uY2UiOiIzOWRhOTE1Zi1iMWQ0LTRmMTgtOTMxNi1lOGViN2Y3MmM2NGYiLCJvaWQiOiI4OTZlMWQ2YS02Nzg0LTQzYTktYTY5Mi0zOGFjYTE2OTIyMDAiLCJvbnByZW1fc2lkIjoiUy0xLTUtMjEtMTM2Mzg4MjAyMC0zMDc2NDU2NjA4LTIyODAwNjYwNjItMTAzMjk5MDUiLCJzdWIiOiJpYmltTVZEM1JGaDBUOGlRVmVRVWFrV2tSZ3doR1phdXJnT2FVdmRvNThRIiwidGlkIjoiNmVkZGQxODUtN2FkNy00ZWUzLTk0ODEtMDQ2NDRiOWY0M2EyIiwidW5pcXVlX25hbWUiOiJzdXNob2JoYW5tb25kYWxAbm1jb3AuY29tIiwidXBuIjoic3VzaG9iaGFubW9uZGFsQG5tY29wLmNvbSIsInV0aSI6IkxtU2xPR3dwSWtPX3NYaTN0UGpTQUEiLCJ2ZXIiOiIxLjAifQ.o38-Udetlm1MAB21FE2NyWKREyUL9MVYC5lEh7aEcQqe88feXRjBLFQ3wxTUKau0ya6IcwiT-SmKdLrMWtvs6JCEJobRaHIem6Bqwbkm4IGj13oH8xJvwS9rd926MZTyeieC18V2DHJPnyxGQJZOPPyBpZpHRcCSW-Rzwj0Wffly7_B-rNi-xbtwD8GpphqScIeIhsFbXFtEpEHhVKu5W8CMeivpmsj0S9IhPzymDV8qS-E-ZrkmyOJrtvznCnpATcRcWikWSVZzRCKm8Wgt4jF8xehQRv7ibiADrAMFNwSbyC87yfMKYXjU-9iz6_-3Kbh1fPjMKWOeolVRJfMpCA\r\n",
      url, parsed_url.host, #payload_body)
    print("Printing payload header and body below")
    print(string_format("%s\r\n%s", payload_headers, payload_body))
  
    return string_format("%s\r\n%s", payload_headers, payload_body)
end

return _M
