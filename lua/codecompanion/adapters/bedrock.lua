local aws = require("codecompanion.utils.aws")
local log = require("codecompanion.utils.log")
local tokens = require("codecompanion.utils.tokens")
local utils = require("codecompanion.utils.adapters")

local input_tokens = 0
local output_tokens = 0

-- AWS Profile handling utilities
local function read_aws_credentials(profile)
  log:debug("Reading AWS credentials for profile: %s", profile)

  local home = os.getenv("HOME")
  if not home then
    return nil, "HOME environment variable not set"
  end

  local credentials_path = home .. "/.aws/credentials"
  log:debug("Looking for credentials file at: %s", credentials_path)

  local file = io.open(credentials_path, "r")
  if not file then
    return nil, string.format("Could not open AWS credentials file: %s", credentials_path)
  end

  local current_profile = nil
  local credentials = {}
  local found_profile = false

  for line in file:lines() do
    -- Remove leading/trailing whitespace
    line = line:match("^%s*(.-)%s*$")

    if line ~= "" and not line:match("^#") then -- Skip empty lines and comments
      local profile_match = line:match("^%[([^%]]+)%]$")
      if profile_match then
        current_profile = profile_match:gsub("^profile%s+", "") -- Remove 'profile ' prefix if present
        credentials[current_profile] = {}
        if current_profile == profile then
          found_profile = true
        end
      elseif current_profile and current_profile == profile then
        local key, value = line:match("^([^=]+)%s*=%s*(.+)$")
        if key and value then
          credentials[current_profile][key:match("^%s*(.-)%s*$")] = value:match("^%s*(.-)%s*$")
        end
      end
    end
  end
  file:close()

  if not found_profile then
    return nil, string.format("Profile '%s' not found in AWS credentials file", profile)
  end

  return credentials[profile]
end

---@class Bedrock.Adapter: CodeCompanion.Adapter
return {
  name = "bedrock",
  formatted_name = "AWS Bedrock",
  roles = {
    llm = "assistant",
    user = "user",
  },
  features = {
    tokens = true,
    text = true,
    vision = false, -- TODO: Add vision support when available
  },
  url = "https://bedrock-runtime.us-east-1.amazonaws.com/model/${model_id}/invoke",
  env = {
    aws_profile = "shared", -- Empty string means use default profile
    aws_region = "us-east-1", -- Empty string means use region from profile
    model_id = "anthropic.claude-3-sonnet-20240229-v1:0",
  },
  headers = {
    ["content-type"] = "application/json",
  },
  parameters = {
    stream = true,
  },
  opts = {
    stream = true,
    method = "POST",
  },
  handlers = {
    --- Set up AWS authentication before the request
    ---@param self CodeCompanion.Adapter
    ---@return boolean
    setup = function(self)
      -- Initialize env_replaced if it doesn't exist
      self.env_replaced = self.env_replaced or {}

      -- Determine profile: first check env_replaced, then env table, defaulting to "default"
      local profile = self.env_replaced.aws_profile or self.env.aws_profile
      if not profile or profile == "" or type(profile) == "table" then
        profile = "default"
      end
      log:debug("Using AWS profile: %s", profile)

      local credentials = require("codecompanion.aws-sdk.core.credentials")
      local creds, err = read_aws_credentials(profile)
      if creds then
        credentials.set(creds.aws_access_key_id, creds.aws_secret_access_key, creds.aws_session_token)
        -- Store region for later use; if not specified in env, fall back to credentials if available.
        self.region = creds.region or self.env.aws_region or "us-east-1"
        log:debug("Successfully loaded AWS credentials from profile")
        return true
      end

      -- If profile credentials failed, try environment variables
      local access_key = os.getenv("AWS_ACCESS_KEY_ID")
      local secret_key = os.getenv("AWS_SECRET_ACCESS_KEY")
      local session_token = os.getenv("AWS_SESSION_TOKEN")

      if access_key and secret_key then
        credentials.set(access_key, secret_key, session_token)
        self.region = self.env.aws_region or "us-east-1"
        log:debug("Successfully loaded AWS credentials from environment")
        return true
      end

      log:error(
        "AWS credentials not found in profile or environment variables: %s",
        err or "No environment variables set"
      )
      return false
    end,

    --- Build the parameters for the request (without signing)
    ---@param self CodeCompanion.Adapter
    ---@param params table
    ---@param messages table
    ---@return table
    form_parameters = function(self, params, messages)
      -- Initialize env_replaced if needed
      self.env_replaced = self.env_replaced or {}

      -- Ensure required headers exist
      self.headers = vim.tbl_deep_extend("force", {
        ["content-type"] = "application/json",
        ["accept"] = "application/json",
      }, self.headers or {})

      -- Determine AWS region: prefer env_replaced, then env, then stored region
      local region = self.env_replaced.aws_region or self.env.aws_region or self.region or "us-east-1"
      if type(region) ~= "string" then
        region = "us-east-1"
      end
      log:debug("Using AWS region: %s (type: %s)", region, type(region))

      -- Determine model_id
      local model_id = self.parameters.model
        or self.env_replaced.model_id
        or self.env.model_id
        or "anthropic.claude-3-sonnet-20240229-v1:0"
      -- URL encode the model id and normalize the region
      model_id = aws.url_encode(model_id)
      region = aws.url_encode(region:lower())

      -- Replace placeholders in the URL
      self.url = self.url
        :gsub("%$%{model_id%}", function()
          return model_id
        end)
        :gsub("%$%{aws_region%}", function()
          return region
        end)

      -- Merge any extra parameters (if needed) and include headers.
      local formatted_params = self.handlers.form_messages(self, messages)
      if not formatted_params then
        log:error("Failed to format messages")
        return params
      end

      return vim.tbl_extend("force", formatted_params, {
        headers = self.headers, -- These will later be updated by sign_request.
      })
    end,

    --- Format the messages into the proper structure for the request body.
    ---@param self CodeCompanion.Adapter
    ---@param messages table
    ---@return table
    form_messages = function(self, messages)
      -- Initialize env_replaced if needed
      self.env_replaced = self.env_replaced or {}

      -- Concatenate all system messages (if any)
      local system = vim
        .iter(messages)
        :filter(function(msg)
          return msg.role == "system"
        end)
        :map(function(msg)
          return msg.content
        end)
        :totable()
      system = next(system) and table.concat(system, "\n") or nil

      -- Filter out system messages and keep only user/assistant messages
      local filtered_messages = vim
        .iter(messages)
        :filter(function(msg)
          return msg.role ~= "system"
        end)
        :totable()

      -- For Claude models, only include user messages
      if vim.startswith(self.env_replaced.model_id or "", "anthropic.claude") then
        filtered_messages = vim
          .iter(filtered_messages)
          :filter(function(msg)
            return msg.role == "user"
          end)
          :totable()
      end

      messages = utils.merge_messages(filtered_messages)

      local model_id = self.env_replaced.model_id or "anthropic.claude-3-sonnet-20240229-v1:0"
      if vim.startswith(model_id, "anthropic.claude") then
        return {
          anthropic_version = "bedrock-2023-05-31",
          messages = messages,
          system = system,
        }
      elseif vim.startswith(model_id, "amazon.titan") then
        return {
          inputText = system and (system .. "\n\n" .. messages[#messages].content) or messages[#messages].content,
          textGenerationConfig = {
            maxTokenCount = self.parameters.max_tokens or 4096,
            temperature = self.parameters.temperature or 0,
            topP = self.parameters.top_p,
            stopSequences = self.parameters.stop_sequences,
          },
        }
      else
        log:error("Unsupported model: %s", model_id)
        return messages
      end
    end,

    --- AWS signing handler: updates request options with the Authorization header.
    --- This handler is invoked in Client:request (after the body is written).
    ---@param self CodeCompanion.Adapter
    ---@param payload table The original payload (if needed)
    ---@param request_opts table The current request options
    ---@return table The updated request options with signed headers
    sign_request = function(self, payload, request_opts)
      local method = (self.opts and self.opts.method) or "POST"
      local url = self:set_env_vars(self.url)
      -- Replace any percent-encoded colon (%3A or %3a) with a literal colon
      url = url:gsub("%%3[Aa]", ":")
      -- Determine AWS region and ensure it is a string.
      -- Determine AWS region and ensure it is a string.
      local region = "us-east-1"

      local credentials = require("codecompanion.aws-sdk.core.credentials")
      local access_key, secret_key, session_token = credentials.get()
      if not access_key or not secret_key then
        log:error("AWS credentials not found in SDK during signing")
        return request_opts
      end

      if not self._body then
        log:error("Request body not found for AWS signing")
        return request_opts
      end

      log:debug("Url used for signing: %s", url)
      log:debug("Body used for signing: %s", self._body)
      local signed_headers = aws.sign_request(
        method,
        url,
        region,
        "bedrock",
        self.headers, -- base headers before signing
        self._body, -- the JSON body string
        access_key,
        secret_key,
        session_token
      )

      -- Debug log the signed headers to ensure Authorization is present.
      log:debug("Signed headers returned: %s", vim.inspect(signed_headers))

      if not signed_headers or not signed_headers.Authorization then
        log:error("Failed to sign the request: no Authorization header produced")
        return request_opts
      end

      request_opts.headers = vim.tbl_extend("force", request_opts.headers or {}, signed_headers)
      log:debug("Final request headers: %s", vim.inspect(request_opts.headers))
      return request_opts
    end,

    --- Return the number of tokens generated
    ---@param self CodeCompanion.Adapter
    ---@param data string
    ---@return number|nil
    tokens = function(self, data)
      if data then
        local ok, json = pcall(vim.json.decode, data)
        if ok then
          local model_id = self.env_replaced and self.env_replaced.model_id or "anthropic.claude-3-sonnet-20240229-v1:0"
          if vim.startswith(model_id, "anthropic.claude") then
            if json.type == "message_start" then
              input_tokens = json.message.usage.input_tokens or 0
              output_tokens = json.message.usage.output_tokens or 0
            elseif json.type == "content_block_delta" and json.usage then
              output_tokens = output_tokens + (json.usage.output_tokens or 0)
            end
            return input_tokens + output_tokens
          elseif vim.startswith(model_id, "amazon.titan") then
            if json.usage then
              return (json.usage.input_tokens or 0) + (json.usage.output_tokens or 0)
            end
          end
        end
      end
    end,

    --- Format API response for the chat buffer.
    ---@param self CodeCompanion.Adapter
    ---@param data string
    ---@return table|nil
    chat_output = function(self, data)
      local output = {}

      if data and data ~= "" then
        local ok, json = pcall(vim.json.decode, data)
        if ok then
          local model_id = self.env_replaced and self.env_replaced.model_id or "anthropic.claude-3-sonnet-20240229-v1:0"
          if vim.startswith(model_id, "anthropic.claude") then
            if json.type == "message" then
              output.role = "assistant"
              output.content = json.content
            elseif json.type == "content_block_delta" then
              output.role = nil
              output.content = json.delta.text
            end
          elseif vim.startswith(model_id, "amazon.titan") then
            if json.outputText then
              output.role = "assistant"
              output.content = json.outputText
            end
          else
            log:error("Unsupported model for response parsing: %s", model_id)
            return
          end

          return {
            status = "success",
            output = output,
          }
        end
      end
    end,

    --- Format API response for inlining.
    ---@param self CodeCompanion.Adapter
    ---@param data string
    ---@param context table
    ---@return string|nil
    inline_output = function(self, data, context)
      if data and data ~= "" then
        local ok, json = pcall(vim.json.decode, data)
        if ok then
          local model_id = self.env_replaced and self.env_replaced.model_id or "anthropic.claude-3-sonnet-20240229-v1:0"
          if vim.startswith(model_id, "anthropic.claude") then
            if json.type == "content_block_delta" then
              return json.delta.text
            end
          elseif vim.startswith(model_id, "amazon.titan") then
            if json.outputText then
              return json.outputText
            end
          else
            log:error("Unsupported model for inline response parsing: %s", model_id)
          end
        end
      end
    end,

    --- Handle errors and completion.
    ---@param self CodeCompanion.Adapter
    ---@param data table
    ---@return nil
    on_exit = function(self, data)
      if data.status and data.status >= 400 then
        log:error("AWS Bedrock Error: %s", data.body)
      end
    end,
  },
  schema = {
    aws_profile = {
      order = 1,
      mapping = "env",
      type = "string",
      desc = "AWS profile to use from ~/.aws/credentials. Leave empty to use default profile.",
      default = "", -- Empty string means use default profile
      validate = function(p)
        return true, ""
      end,
    },
    aws_region = {
      order = 2,
      mapping = "env",
      type = "enum",
      desc = "AWS region to use. If not specified, uses region from AWS profile.",
      default = "", -- Empty string means use region from profile
      choices = {
        "", -- Use profile's region
        "us-east-1",
        "us-west-2",
        "eu-west-1",
      },
    },
    model = {
      order = 3,
      mapping = "parameters",
      type = "enum",
      desc = "AWS Bedrock model to use",
      default = "anthropic.claude-3-sonnet-20240229-v1:0",
      choices = {
        "anthropic.claude-3-sonnet-20240229-v1:0",
        "anthropic.claude-3-haiku-20240307-v1:0",
        "amazon.titan-text-express-v1",
      },
    },
    temperature = {
      order = 4,
      mapping = "parameters",
      type = "number",
      default = 0,
      validate = function(n)
        return n >= 0 and n <= 1, "Must be between 0 and 1"
      end,
      desc = "Controls randomness in the response. Higher values produce more creative but potentially less focused responses.",
    },
    max_tokens = {
      order = 5,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = 4096,
      desc = "The maximum number of tokens to generate. Different models have different maximum values.",
      validate = function(n)
        return n > 0 and n <= 8192, "Must be between 0 and 8192"
      end,
    },
    top_p = {
      order = 6,
      mapping = "parameters",
      type = "number",
      optional = true,
      default = nil,
      desc = "Nucleus sampling: only consider tokens comprising the top_p probability mass.",
      validate = function(n)
        return n >= 0 and n <= 1, "Must be between 0 and 1"
      end,
    },
    stop_sequences = {
      order = 7,
      mapping = "parameters",
      type = "list",
      optional = true,
      default = nil,
      subtype = {
        type = "string",
      },
      desc = "Sequences where the API will stop generating further tokens.",
      validate = function(l)
        return #l >= 1, "Must have at least one sequence"
      end,
    },
  },
}
