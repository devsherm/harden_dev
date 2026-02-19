require "test_helper"

class Core::UserTest < ActiveSupport::TestCase
  test "requires name" do
    user = Core::User.new(password: "password")
    assert_not user.valid?
    assert_includes user.errors[:name], "can't be blank"
  end

  test "requires unique name" do
    Core::User.create!(name: "Unique", password: "password")
    duplicate = Core::User.new(name: "Unique", password: "password")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "strips whitespace from name" do
    user = Core::User.new(name: "  Alice  ", password: "password")
    assert_equal "Alice", user.name
  end

  test "authenticates with correct password" do
    user = core_users(:alice)
    assert user.authenticate("password")
  end

  test "rejects incorrect password" do
    user = core_users(:alice)
    assert_not user.authenticate("wrong")
  end
end
