local bit = require("bit")
local ffi = require("ffi")

---@class Crypto.Utils
local M = {}

-- FFI declarations for OpenSSL functions
ffi.cdef[[
typedef struct EVP_MD_CTX EVP_MD_CTX;
typedef struct EVP_MD EVP_MD;
typedef struct HMAC_CTX HMAC_CTX;

EVP_MD_CTX *EVP_MD_CTX_new(void);
void EVP_MD_CTX_free(EVP_MD_CTX *ctx);
const EVP_MD *EVP_sha256(void);
int EVP_DigestInit_ex(EVP_MD_CTX *ctx, const EVP_MD *type, void *impl);
int EVP_DigestUpdate(EVP_MD_CTX *ctx, const void *data, size_t count);
int EVP_DigestFinal_ex(EVP_MD_CTX *ctx, unsigned char *md, unsigned int *s);

HMAC_CTX *HMAC_CTX_new(void);
void HMAC_CTX_free(HMAC_CTX *ctx);
int HMAC_Init_ex(HMAC_CTX *ctx, const void *key, int key_len, const EVP_MD *md, void *impl);
int HMAC_Update(HMAC_CTX *ctx, const unsigned char *data, size_t len);
int HMAC_Final(HMAC_CTX *ctx, unsigned char *md, unsigned int *len);
]]

-- Load OpenSSL library
local libcrypto = ffi.load("crypto")

---Convert bytes to hex string
---@param str string
---@return string
local function bytes_to_hex(str)
  return (str:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

---Calculate SHA256 hash of a string
---@param str string
---@return string
function M.sha256(str)
  local ctx = libcrypto.EVP_MD_CTX_new()
  if ctx == nil then
    error("Failed to create EVP_MD_CTX")
  end

  local md = libcrypto.EVP_sha256()
  if libcrypto.EVP_DigestInit_ex(ctx, md, nil) ~= 1 then
    libcrypto.EVP_MD_CTX_free(ctx)
    error("Failed to initialize SHA256")
  end

  if libcrypto.EVP_DigestUpdate(ctx, str, #str) ~= 1 then
    libcrypto.EVP_MD_CTX_free(ctx)
    error("Failed to update SHA256")
  end

  local digest = ffi.new("unsigned char[32]")
  local digest_len = ffi.new("unsigned int[1]")
  if libcrypto.EVP_DigestFinal_ex(ctx, digest, digest_len) ~= 1 then
    libcrypto.EVP_MD_CTX_free(ctx)
    error("Failed to finalize SHA256")
  end

  libcrypto.EVP_MD_CTX_free(ctx)
  return bytes_to_hex(ffi.string(digest, 32))
end

---Calculate HMAC-SHA256
---@param key string
---@param msg string
---@return string
function M.hmac_sha256(key, msg)
  local ctx = libcrypto.HMAC_CTX_new()
  if ctx == nil then
    error("Failed to create HMAC_CTX")
  end

  local md = libcrypto.EVP_sha256()
  if libcrypto.HMAC_Init_ex(ctx, key, #key, md, nil) ~= 1 then
    libcrypto.HMAC_CTX_free(ctx)
    error("Failed to initialize HMAC")
  end

  if libcrypto.HMAC_Update(ctx, msg, #msg) ~= 1 then
    libcrypto.HMAC_CTX_free(ctx)
    error("Failed to update HMAC")
  end

  local hmac = ffi.new("unsigned char[32]")
  local hmac_len = ffi.new("unsigned int[1]")
  if libcrypto.HMAC_Final(ctx, hmac, hmac_len) ~= 1 then
    libcrypto.HMAC_CTX_free(ctx)
    error("Failed to finalize HMAC")
  end

  libcrypto.HMAC_CTX_free(ctx)
  return bytes_to_hex(ffi.string(hmac, 32))
end

return M