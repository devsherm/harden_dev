require "test_helper"

class Blog::PostTest < ActiveSupport::TestCase
  test "requires title" do
    post = Blog::Post.new(body: "x", user: core_users(:alice))
    assert_not post.valid?
    assert_includes post.errors[:title], "can't be blank"
  end

  test "requires body" do
    post = Blog::Post.new(title: "x", user: core_users(:alice))
    assert_not post.valid?
    assert_includes post.errors[:body], "can't be blank"
  end

  test "requires user" do
    post = Blog::Post.new(title: "x", body: "x")
    assert_not post.valid?
    assert_includes post.errors[:user], "must exist"
  end

  test "destroying post destroys comments" do
    post = Blog::Post.create!(title: "t", body: "b", user: core_users(:alice))
    Blog::Comment.create!(post: post, user: core_users(:bob), body: "b")
    assert_difference("Blog::Comment.count", -1) do
      post.destroy
    end
  end
end
