# Implementation Plan: AWS Bedrock Adapter

## Overview
Add support for AWS Bedrock to allow CodeCompanion to use various foundation models available through AWS's managed service.

## Prerequisites
1. AWS Account with Bedrock access
2. AWS credentials configured (either via AWS profiles or access/secret keys)
3. Model access enabled in Bedrock console

## Implementation Steps

### 1. AWS Authentication Support
- Support multiple authentication methods:
  1. AWS Profile (primary method)
     - Read from `~/.aws/credentials` and `~/.aws/config`
     - Support profile selection via configuration
     - Handle default profile if none specified
  2. Direct credentials (fallback)
     - Support AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY
     - Support AWS_SESSION_TOKEN for temporary credentials

### 2. Basic Adapter Structure
Create new file at `lua/codecompanion/adapters/bedrock.lua` with:
- Basic adapter interface implementation
- Model configuration
- AWS authentication handling
- Environment variables setup

### 2. Core Components

#### Environment Variables
```lua
env = {
  -- AWS credentials will be read from ~/.aws/credentials based on selected profile
  aws_profile = "schema.aws_profile.default", -- Profile to use from ~/.aws/credentials
  aws_region = "schema.aws_region.default",   -- Region from profile or override
  model_id = "schema.model.default",
}
```

#### Headers & Authentication
- Implement AWS Signature V4 signing process
- Read and parse AWS credentials file
- Support profile-based authentication
- Fall back to environment variables if needed
- Set required headers for AWS authentication
- Handle content-type and other required headers

#### URL Structure
```lua
url = "https://bedrock-runtime.${region}.amazonaws.com/model/${model_id}/invoke",
```

### 3. Handler Functions

#### form_parameters
- Format request parameters based on selected model
- Handle different model providers' requirements
- Support streaming configuration

#### form_messages
- Format messages according to model requirements
- Handle system prompts appropriately
- Support different model message formats (Claude vs Titan)

#### chat_output
- Parse streaming responses
- Handle model-specific response formats
- Extract content and role information
- Support error handling

#### inline_output
- Format responses for inline buffer insertion
- Handle streaming data appropriately

#### on_exit
- Implement error handling
- Log AWS-specific error messages
- Handle rate limits and quotas

### 4. Schema Definition
```lua
schema = {
  aws_profile = {
    order = 1,
    mapping = "env",
    type = "string",
    desc = "AWS profile to use from ~/.aws/credentials. Leave empty to use default profile.",
    default = "",  -- Empty string means use default profile
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
    default = "",  -- Empty string means use region from profile
    choices = {
      "",  -- Use profile's region
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
  -- Add other relevant parameters
}
```

### 5. Testing
1. Create test file at `tests/adapters/test_bedrock.lua`
2. Test AWS profile handling:
   - Default profile loading
   - Custom profile selection
   - Profile region override
   - Missing/invalid profile handling
   - Credentials file parsing
   - Profile switching during runtime
3. Test different model providers:
   - Anthropic Claude models
   - Amazon Titan models
   - Model-specific parameters
4. Test authentication methods:
   - Profile-based authentication (primary)
   - Environment variable fallback
   - Session token support
   - Invalid credentials handling
5. Test streaming responses:
   - Different model response formats
   - Chunked data handling
   - Connection interruption
6. Test error handling:
   - AWS credential errors
   - Profile configuration errors
   - Region-specific errors
   - Model access permissions
   - Rate limiting responses
7. Test parameter validation:
   - Profile validation
   - Region validation
   - Model-specific parameters
   - Temperature ranges

### 6. Documentation
1. Update adapter documentation
2. Add AWS setup instructions
3. Document model-specific features
4. Add usage examples

## Technical Considerations

### Authentication
- Implement AWS Signature V4 signing
- Support different AWS credential sources:
  - Primary: AWS profiles from ~/.aws/credentials
    * Parse INI-style credentials file
    * Support profile inheritance
    * Handle [profile] sections correctly
    * Support role assumption if specified
  - Fallback: Environment variables
    * AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY
    * AWS_SESSION_TOKEN for temporary credentials
    * AWS_PROFILE for profile override
- Handle token refresh if needed
- Cache credentials with appropriate TTL
- Support credential provider chain resolution

### Profile Management
- Monitor ~/.aws/credentials for changes
- Handle missing or corrupt credentials file
- Support cross-account role assumption
- Handle profile region preferences
- Support AWS SSO profiles
- Implement profile switching without restart

### Error Handling
- AWS service errors
- Model-specific errors
- Rate limiting
- Authentication failures
- Profile-related errors:
  * Missing credentials file
  * Invalid profile format
  * Permission issues
  * Role assumption failures
  * Region mismatches

### Performance
- Optimize streaming handling
- Consider caching for authentication
- Handle large context windows efficiently

## Next Steps
1. Create initial adapter implementation
2. Test with basic Claude model
3. Add support for other models
4. Implement comprehensive testing
5. Update documentation
6. Submit PR for review