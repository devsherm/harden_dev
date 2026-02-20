# frozen_string_literal: true

class Pipeline
  module ClaudeClient
    private

    def claude_call(prompt)
      acquire_claude_slot
      begin
        output, success = spawn_with_timeout("claude", "-p", prompt, timeout: CLAUDE_TIMEOUT)
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
