# frozen_string_literal: true

require_relative "test_helper"

class ParseJsonResponseTest < PipelineTestCase
  # parse_json_response is private; invoke via send
  def parse(raw)
    @pipeline.send(:parse_json_response, raw)
  end

  def test_clean_json_object
    raw = '{"controller": "posts_controller", "status": "analyzed"}'
    result = parse(raw)
    assert_equal "posts_controller", result["controller"]
    assert_equal "analyzed", result["status"]
  end

  def test_markdown_wrapped_json
    raw = <<~RAW
      ```json
      {"controller": "posts_controller", "status": "analyzed"}
      ```
    RAW
    result = parse(raw)
    assert_equal "posts_controller", result["controller"]
  end

  def test_json_embedded_in_prose
    raw = <<~RAW
      Here is the analysis result:

      {"controller": "posts_controller", "status": "analyzed", "findings": []}

      I hope this helps!
    RAW
    result = parse(raw)
    assert_equal "posts_controller", result["controller"]
    assert_equal [], result["findings"]
  end

  def test_array_response_raises
    raw = '[{"controller": "posts_controller"}]'
    err = assert_raises(RuntimeError) { parse(raw) }
    assert_match(/Expected JSON object but got Array/i, err.message)
  end

  def test_pure_garbage_raises
    raw = "This is not JSON at all, just random text with no braces"
    err = assert_raises(RuntimeError) { parse(raw) }
    assert_match(/Failed to parse JSON/i, err.message)
  end

  def test_empty_string_raises
    err = assert_raises(RuntimeError) { parse("") }
    assert_match(/Failed to parse JSON/i, err.message)
  end

  def test_nested_braces_parsed_correctly
    raw = '{"controller": "posts_controller", "nested": {"deep": {"value": 42}}, "list": [{"a": 1}]}'
    result = parse(raw)
    assert_equal "posts_controller", result["controller"]
    assert_equal 42, result.dig("nested", "deep", "value")
    assert_equal [{"a" => 1}], result["list"]
  end

  def test_multiple_json_objects_in_prose_raises
    # When two JSON objects appear in prose, the first-{ to last-} extraction
    # spans invalid content and JSON.parse fails — expected behavior.
    raw = <<~RAW
      Some preamble text
      {"controller": "posts_controller", "status": "analyzed"}
      And some trailing {"noise": true}
    RAW
    assert_raises(JSON::ParserError) { parse(raw) }
  end

  def test_json_with_whitespace_padding
    raw = "   \n\n  {\"controller\": \"posts_controller\", \"status\": \"ok\"}  \n\n  "
    result = parse(raw)
    assert_equal "posts_controller", result["controller"]
  end

  def test_markdown_fence_with_language_tag
    raw = "```json\n{\"key\": \"value\"}\n```"
    result = parse(raw)
    assert_equal "value", result["key"]
  end

  def test_braces_present_but_invalid_json_between_them
    raw = "prefix { this is not: json } suffix"
    assert_raises(JSON::ParserError) { parse(raw) }
  end
end
