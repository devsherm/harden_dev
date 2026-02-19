require "test_helper"

class Core::SessionTest < ActiveSupport::TestCase
  test "belongs to user" do
    session = core_sessions(:alice_session)
    assert_equal core_users(:alice), session.user
  end

  test "destroying user cascades to sessions" do
    user = core_users(:alice)
    assert_difference("Core::Session.count", -1) do
      user.destroy
    end
  end
end
