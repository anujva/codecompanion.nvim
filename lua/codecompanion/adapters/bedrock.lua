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
    -- AWS auth headers will be added by the form_parameters handler
  },
  parameters = {
    stream = true,
  },
  opts = {
    stream = true,
  },
  handlers = {
    ---Set up AWS authentication before the request
    ---@param self CodeCompanion.Adapter
    ---@return boolean
    setup = function(self)
      -- Initialize env_replaced if it doesn't exist
      self.env_replaced = self.env_replaced or {}

      -- Get profile from env or env_replaced, fallback to "default" if empty
      local profile = self.env_replaced.aws_profile or self.env.aws_profile
      if profile == "" then
        profile = "default"
      end
      log:debug("Using AWS profile: %s", profile)

      -- Try to get credentials from profile
      local creds, err = read_aws_credentials(profile)
      if creds then
        -- Store credentials for use in form_parameters
        self.aws_credentials = creds
        log:debug("Successfully loaded AWS credentials")
        return true
      end

      -- If profile credentials failed, try environment variables
      if os.getenv("AWS_ACCESS_KEY_ID") and os.getenv("AWS_SECRET_ACCESS_KEY") then
        log:debug("Using AWS credentials from environment variables")
        return true
      end

      -- No credentials found
      log:error(
        "AWS credentials not found in profile or environment variables: %s",
        err or "No environment variables set"
      )
      return false
    end,

    ---Set the parameters and handle AWS authentication
    ---@param self CodeCompanion.Adapter
    ---@param params table
    ---@param messages table
    ---@return table
    form_parameters = function(self, params, messages)
      -- Initialize env_replaced if it doesn't exist
      self.env_replaced = self.env_replaced or {}

      -- Get region and ensure it's a string
      local region = self.env_replaced.aws_region
      if type(region) ~= "string" then
        region = ""
      end

      if region == "" then
        -- Try to get region from profile
        if self.aws_credentials and self.aws_credentials.region then
          region = tostring(self.aws_credentials.region)
        else
          -- Default to us-east-1 if no region specified
          region = "us-east-1"
        end
      end
      log:debug("Using AWS region: %s (type: %s)", region, type(region))

      -- Get model ID from parameters or env
      local model_id = self.parameters.model or self.env_replaced.model_id or "anthropic.claude-3-sonnet-20240229-v1:0"
      log:debug("Using model ID: %s", model_id)

      -- Replace variables directly and encode model ID for URL
      -- Replace variables with escaped patterns for literals
      local url = self.url:gsub("%${model_id}", model_id):gsub("%${region}", region)
      log:debug("Constructed URL: %s", url)

      -- Get AWS credentials
      local access_key, secret_key, session_token
      if self.aws_credentials then
        -- Use credentials from profile
        access_key = self.aws_credentials.aws_access_key_id
        secret_key = self.aws_credentials.aws_secret_access_key
        session_token = self.aws_credentials.aws_session_token
        log:debug("Using credentials from AWS profile")
      else
        -- Fallback to environment variables
        access_key = os.getenv("AWS_ACCESS_KEY_ID")
        secret_key = os.getenv("AWS_SECRET_ACCESS_KEY")
        session_token = os.getenv("AWS_SESSION_TOKEN")
        log:debug("Using credentials from environment variables")
      end

      if not access_key or not secret_key then
        log:error("AWS credentials not found")
        return params
      end

      -- Format messages first
      local formatted_params = self.handlers.form_messages(self, messages)
      if not formatted_params then
        log:error("Failed to format messages")
        return params
      end

      -- Prepare request body
      local body = vim.json.encode(formatted_params)
      if not body then
        log:error("Failed to encode request parameters")
        return params
      end

      log:debug("Request body: %s", body)

      -- Sign the request and get response
      local headers = aws.sign_request(
        "POST",
        url,
        region,
        "bedrock",
        self.headers,
        body,
        access_key,
        secret_key,
        session_token
      )

      -- Store the headers and URL for use in the request
      self.headers = headers
      self.url = url

      -- Return the original params since we're handling the request in aws.lua
      return params
    end,

    ---Set the format of the role and content for the messages
    ---@param self CodeCompanion.Adapter
    ---@param messages table
    ---@return table
    form_messages = function(self, messages)
      -- Initialize env_replaced if it doesn't exist
      self.env_replaced = self.env_replaced or {}

      -- Extract and format system messages
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

      -- Remove system messages and merge user/assistant messages
      messages = utils.merge_messages(vim
        .iter(messages)
        :filter(function(msg)
          return msg.role ~= "system"
        end)
        :totable())

      -- Format based on model provider
      local model_id = self.env_replaced.model_id or "anthropic.claude-3-sonnet-20240229-v1:0"
      if vim.startswith(model_id, "anthropic.claude") then
        -- Format for Claude models
        return {
          anthropic_version = "bedrock-2023-05-31",
          messages = messages,
          system = system,
        }
      elseif vim.startswith(model_id, "amazon.titan") then
        -- Format for Titan models
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

    ---Returns the number of tokens generated
    ---@param self CodeCompanion.Adapter
    ---@param data string
    ---@return number|nil
    tokens = function(self, data)
      if data then
        local ok, json = pcall(vim.json.decode, data)
        if ok then
          local model_id = self.env_replaced and self.env_replaced.model_id or "anthropic.claude-3-sonnet-20240229-v1:0"
          if vim.startswith(model_id, "anthropic.claude") then
            -- Claude models provide token usage in message_start events
            if json.type == "message_start" then
              input_tokens = (json.message.usage.input_tokens or 0)
              output_tokens = json.message.usage.output_tokens or 0
            elseif json.type == "content_block_delta" then
              output_tokens = output_tokens + (json.usage.output_tokens or 0)
            end
            return input_tokens + output_tokens
          elseif vim.startswith(model_id, "amazon.titan") then
            -- Titan models provide token usage in completion events
            if json.usage then
              input_tokens = json.usage.input_tokens or input_tokens
              output_tokens = json.usage.output_tokens or output_tokens
              return input_tokens + output_tokens
            end
          end
        end
      end
    end,

    ---Output the data from the API ready for the chat buffer
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
            -- Parse Claude model response
            if json.type == "message" then
              output.role = "assistant"
              output.content = json.content
            elseif json.type == "content_block_delta" then
              output.role = nil
              output.content = json.delta.text
            end
          elseif vim.startswith(model_id, "amazon.titan") then
            -- Parse Titan model response
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

    ---Output the data from the API ready for inlining
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
            -- Parse Claude model response
            if json.type == "content_block_delta" then
              return json.delta.text
            end
          elseif vim.startswith(model_id, "amazon.titan") then
            -- Parse Titan model response
            if json.outputText then
              return json.outputText
            end
          else
            log:error("Unsupported model for inline response parsing: %s", model_id)
          end
        end
      end
    end,

    ---Handle errors and completion
    ---@param self CodeCompanion.Adapter
    ---@param data table
    ---@return nil
    on_exit = function(self, data)
      if data.status >= 400 then
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
        -- TODO: Implement validation to check if profile exists in ~/.aws/credentials
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
        -- Add other relevant regions
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
        -- Add other available models
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
