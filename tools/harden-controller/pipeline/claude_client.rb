# frozen_string_literal: true

class Pipeline
  module ClaudeClient
    ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
    ANTHROPIC_API_VERSION = "2023-06-01"
    API_DEFAULT_MODEL = "claude-sonnet-4-6"
    API_MAX_TOKENS = 4096
    API_WEB_SEARCH_MAX_USES = 10

    private

    def claude_call(prompt)
      acquire_claude_slot
      begin
        output, success = spawn_with_timeout("claude", "-p", "--dangerously-skip-permissions", prompt, timeout: CLAUDE_TIMEOUT)
        raise "claude -p failed: #{output[0..500]}" unless success
        output.strip
      ensure
        release_claude_slot
      end
    end

    def acquire_claude_slot
      @claude_semaphore.synchronize do
        while @claude_active >= MAX_CLAUDE_CONCURRENCY
          @claude_slots.wait(@claude_semaphore, 5)
          raise "Pipeline cancelled" if cancelled?
        end
        @claude_active += 1
      end
    end

    def release_claude_slot
      @claude_semaphore.synchronize do
        @claude_active -= 1
        @claude_slots.signal
      end
    end

    def api_call(prompt, model: API_DEFAULT_MODEL)
      acquire_api_slot
      begin
        uri = URI(ANTHROPIC_API_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true

        request = Net::HTTP::Post.new(uri.path)
        request["x-api-key"] = @api_key
        request["anthropic-version"] = ANTHROPIC_API_VERSION
        request["content-type"] = "application/json"

        body = {
          model: model,
          max_tokens: API_MAX_TOKENS,
          tools: [
            {
              type: "web_search_20250305",
              name: "web_search",
              max_uses: API_WEB_SEARCH_MAX_USES
            }
          ],
          messages: [
            { role: "user", content: prompt }
          ]
        }
        request.body = body.to_json

        response = http.request(request)
        raise "Claude API error #{response.code}: #{response.body[0..500]}" unless response.is_a?(Net::HTTPSuccess)

        parsed = JSON.parse(response.body)
        extract_text_blocks(parsed)
      ensure
        release_api_slot
      end
    end

    def acquire_api_slot
      @api_semaphore.synchronize do
        while @api_active >= MAX_API_CONCURRENCY
          @api_slots.wait(@api_semaphore, 5)
          raise "Pipeline cancelled" if cancelled?
        end
        @api_active += 1
      end
    end

    def release_api_slot
      @api_semaphore.synchronize do
        @api_active -= 1
        @api_slots.signal
      end
    end

    def extract_text_blocks(parsed_response)
      content = parsed_response["content"] || []
      content
        .select { |block| block["type"] == "text" }
        .map { |block| block["text"] }
        .join("\n")
    end

    def parse_json_response(raw)
      cleaned = raw.gsub(/\A```json\s*/, "").gsub(/\s*```\z/, "").strip
      result = begin
        JSON.parse(cleaned)
      rescue JSON::ParserError
        start = raw.index("{")
        finish = raw.rindex("}")
        if start && finish && finish > start
          JSON.parse(raw[start..finish])
        else
          raise "Failed to parse JSON from claude response: #{raw[0..200]}"
        end
      end
      raise "Expected JSON object but got #{result.class}: #{raw[0..200]}" unless result.is_a?(Hash)
      result
    end
  end
end
