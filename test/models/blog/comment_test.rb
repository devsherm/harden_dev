require "test_helper"

class Blog::CommentTest < ActiveSupport::TestCase
  test "requires author" do
    post = blog_posts(:one)
    comment = Blog::Comment.new(body: "x", post: post)
    assert_not comment.valid?
    assert_includes comment.errors[:author], "can't be blank"
  end

  test "requires body" do
    post = blog_posts(:one)
    comment = Blog::Comment.new(author: "a", post: post)
    assert_not comment.valid?
    assert_includes comment.errors[:body], "can't be blank"
  end

  test "requires post" do
    comment = Blog::Comment.new(author: "a", body: "x")
    assert_not comment.valid?
    assert comment.errors[:post].any?
  end
end
