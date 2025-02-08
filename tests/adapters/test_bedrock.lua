local assert = require("luassert")
local match = require("luassert.match")

describe("Bedrock adapter", function()
  local adapter = require("codecompanion.adapters.bedrock")

  before_each(function()
    -- Reset adapter state
    adapter.aws_credentials = nil
    adapter.env_replaced = {
      aws_profile = "",
      aws_region = "us-east-1",
      model_id = "anthropic.claude-3-sonnet-20240229-v1:0",
    }
  end)

  describe("setup", function()
    it("should load credentials from AWS profile", function()
      adapter.env_replaced.aws_profile = "default"
      local success = adapter.handlers.setup(adapter)
      assert.is_true(success)
      assert.is_table(adapter.aws_credentials)
      assert.is_string(adapter.aws_credentials.aws_access_key_id)
      assert.is_string(adapter.aws_credentials.aws_secret_access_key)
    end)

    it("should fallback to environment variables", function()
      os.getenv = function(key)
        if key == "AWS_ACCESS_KEY_ID" then return "test-key"
        elseif key == "AWS_SECRET_ACCESS_KEY" then return "test-secret"
        end
      end
      local success = adapter.handlers.setup(adapter)
      assert.is_true(success)
    end)
  end)

  describe("form_parameters", function()
    it("should sign request with AWS credentials", function()
      adapter.aws_credentials = {
        aws_access_key_id = "test-key",
        aws_secret_access_key = "test-secret",
      }
      local params = { test = "value" }
      local result = adapter.handlers.form_parameters(adapter, params, {})
      assert.are.same(params, result)
      assert.is_string(adapter.headers.authorization)
      assert.matches("AWS4%-HMAC%-SHA256", adapter.headers.authorization)
    end)
  end)

  describe("form_messages", function()
    it("should format Claude messages correctly", function()
      local messages = {
        { role = "system", content = "You are helpful." },
        { role = "user", content = "Hello" },
      }
      adapter.env_replaced.model_id = "anthropic.claude-3-sonnet-20240229-v1:0"
      local result = adapter.handlers.form_messages(adapter, messages)
      assert.are.same({
        anthropic_version = "bedrock-2023-05-31",
        messages = { { role = "user", content = "Hello" } },
        system = "You are helpful.",
      }, result)
    end)

    it("should format Titan messages correctly", function()
      local messages = {
        { role = "system", content = "You are helpful." },
        { role = "user", content = "Hello" },
      }
      adapter.env_replaced.model_id = "amazon.titan-text-express-v1"
      local result = adapter.handlers.form_messages(adapter, messages)
      assert.are.same({
        inputText = "You are helpful.\n\nHello",
        textGenerationConfig = {
          maxTokenCount = 4096,
          temperature = 0,
          topP = nil,
          stopSequences = nil,
        },
      }, result)
    end)
  end)

  describe("chat_output", function()
    it("should parse Claude streaming response", function()
      local data = [[{"type":"content_block_delta","delta":{"text":"Hello"},"usage":{"output_tokens":1}}]]
      local result = adapter.handlers.chat_output(adapter, data)
      assert.are.same({
        status = "success",
        output = {
          role = nil,
          content = "Hello",
        },
      }, result)
    end)

    it("should parse Titan response", function()
      adapter.env_replaced.model_id = "amazon.titan-text-express-v1"
      local data = [[{"outputText":"Hello","usage":{"input_tokens":1,"output_tokens":1}}]]
      local result = adapter.handlers.chat_output(adapter, data)
      assert.are.same({
        status = "success",
        output = {
          role = "assistant",
          content = "Hello",
        },
      }, result)
    end)
  end)

  describe("inline_output", function()
    it("should parse Claude streaming response", function()
      local data = [[{"type":"content_block_delta","delta":{"text":"Hello"},"usage":{"output_tokens":1}}]]
      local result = adapter.handlers.inline_output(adapter, data)
      assert.equals("Hello", result)
    end)

    it("should parse Titan response", function()
      adapter.env_replaced.model_id = "amazon.titan-text-express-v1"
      local data = [[{"outputText":"Hello","usage":{"input_tokens":1,"output_tokens":1}}]]
      local result = adapter.handlers.inline_output(adapter, data)
      assert.equals("Hello", result)
    end)
  end)

  describe("tokens", function()
    it("should track Claude token usage", function()
      local start_data = [[{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0}}}]]
      local delta_data = [[{"type":"content_block_delta","usage":{"output_tokens":5}}]]
      
      adapter.handlers.tokens(adapter, start_data)
      local total = adapter.handlers.tokens(adapter, delta_data)
      assert.equals(15, total)
    end)

    it("should track Titan token usage", function()
      adapter.env_replaced.model_id = "amazon.titan-text-express-v1"
      local data = [[{"outputText":"Hello","usage":{"input_tokens":10,"output_tokens":5}}]]
      local total = adapter.handlers.tokens(adapter, data)
      assert.equals(15, total)
    end)
  end)
end)