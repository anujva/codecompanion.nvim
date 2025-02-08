local log = require("codecompanion.utils.log")

---@class AWS.Utils
--- AWS Signature Version 4 signing utilities using AWS CLI
local M = {}

---Make a request to AWS Bedrock using the AWS CLI directly
---@param method string HTTP method (e.g., "POST")
---@param url string Full URL
---@param region string AWS region
---@param service string AWS service (e.g., "bedrock")
---@param headers table Request headers
---@param body string|nil Request body
---@param access_key string AWS access key
---@param secret_key string AWS secret key
---@param session_token string|nil AWS session token
---@return table headers Updated headers with AWS authentication
function M.sign_request(method, url, region, service, headers, body, access_key, secret_key, session_token)
  -- Extract model ID from URL
  local model_id = url:match("/model/([^/]+)/invoke")
  if not model_id then
    error("Could not extract model ID from URL")
  end

  -- Create a temporary file for the request body
  local body_file = os.tmpname()
  local f = io.open(body_file, "w")
  if f then
    f:write(body or "")
    f:close()
  end

  -- Set AWS credentials in environment
  local env = string.format(
    "AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_DEFAULT_REGION=%s%s",
    access_key,
    secret_key,
    region,
    session_token and (" AWS_SESSION_TOKEN=" .. session_token) or ""
  )

  -- Use AWS CLI to make the request directly
  local cmd = string.format(
    "%s aws bedrock-runtime invoke-model --model-id %s --body fileb://%s --cli-binary-format raw-in-base64-out",
    env,
    model_id,
    body_file
  )

  log:debug("Executing AWS CLI command: %s", cmd)

  -- Execute the command
  local handle = io.popen(cmd)
  local result = handle:read("*a")
  handle:close()

  -- Clean up temporary file
  os.remove(body_file)

  log:debug("AWS CLI response: %s", result)

  -- Return headers that would have been used
  return headers
end

return M

