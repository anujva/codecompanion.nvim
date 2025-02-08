local credentials = require("codecompanion.aws-sdk.core.credentials")
local crypto = require("codecompanion.aws-sdk.core.request_signer")
local log = require("codecompanion.utils.log")

---@class AWS.Utils
local M = {}

local AWS_ALGORITHM = "AWS4-HMAC-SHA256"
local AWS_REQUEST = "aws4_request"

-- URL-encode helper
function M.url_encode(str)
  if not str then
    return ""
  end
  str = string.gsub(str, "([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return str
end

-- Sign request
function M.sign_request(method, url, region, service, headers, body, access_key, secret_key, session_token)
  local host = url:match("https?://([^/]+)")
  local timestamp = os.date("!%Y%m%dT%H%M%SZ")
  local date_stamp = timestamp:sub(1, 8)

  headers = vim.deepcopy(headers) or {}
  headers["Authorization"] = nil

  headers["X-Amz-Date"] = timestamp
  headers["Host"] = host
  if session_token then
    headers["X-Amz-Security-Token"] = session_token
  end

  credentials.set(access_key, secret_key, session_token)
  local auth_headers = crypto.sign("v4", method, url, body, headers, service, region)
  headers["Authorization"] = auth_headers

  log:debug("Auth headers: " .. vim.inspect(auth_headers))
  return headers
end

return M
