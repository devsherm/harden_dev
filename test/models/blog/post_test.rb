require "test_helper"

class Blog::PostTest < ActiveSupport::TestCase
  test "requires title" do
    post = Blog::Post.new(body: "x", author: "a")
    assert_not post.valid?
    assert_includes post.errors[:title], "can't be blank"
  end

  test "requires body" do
    post = Blog::Post.new(title: "x", author: "a")
    assert_not post.valid?
    assert_includes post.errors[:body], "can't be blank"
  end

  test "requires author" do
    post = Blog::Post.new(title: "x", body: "x")
    assert_not post.valid?
    assert_includes post.errors[:author], "can't be blank"
  end

  test "destroying post destroys comments" do
    post = Blog::Post.create!(title: "t", body: "b", author: "a")
    Blog::Comment.create!(post: post, author: "a", body: "b")
    assert_difference("Blog::Comment.count", -1) do
      post.destroy
    end
  end
end
