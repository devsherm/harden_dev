require "test_helper"

class Blog::CommentTest < ActiveSupport::TestCase
  test "requires user" do
    post = blog_posts(:one)
    comment = Blog::Comment.new(body: "x", post: post)
    assert_not comment.valid?
    assert_includes comment.errors[:user], "must exist"
  end

  test "requires body" do
    post = blog_posts(:one)
    comment = Blog::Comment.new(user: core_users(:alice), post: post)
    assert_not comment.valid?
    assert_includes comment.errors[:body], "can't be blank"
  end

  test "requires post" do
    comment = Blog::Comment.new(user: core_users(:alice), body: "x")
    assert_not comment.valid?
    assert comment.errors[:post].any?
  end

  test "like_status defaults to unset" do
    post = blog_posts(:one)
    comment = Blog::Comment.create!(user: core_users(:alice), post: post, body: "test")
    assert comment.unset?
  end

  test "can toggle to liked" do
    post = blog_posts(:one)
    comment = Blog::Comment.create!(user: core_users(:alice), post: post, body: "test")
    comment.liked!
    assert comment.liked?
  end
end
