local request_signer = require("codecompanion.aws-sdk.core.request_signer")

---@class Crypto.Utils
local M = {}

---Calculate HMAC-SHA256 (returns hex string)
---@param key string
---@param msg string
---@return string
function M.hmac_sha256(key, msg)
  return request_signer.sign(key, msg)
end

return M
