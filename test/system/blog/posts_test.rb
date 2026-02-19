require "application_system_test_case"

class Blog::PostsTest < ApplicationSystemTestCase
  test "post index orders by newest first" do
    user = core_users(:alice)
    old_post = Blog::Post.create!(title: "Old Post", body: "body", user: user, created_at: 1.day.ago)
    new_post = Blog::Post.create!(title: "New Post", body: "body", user: user, created_at: Time.current)

    visit blog_posts_url

    titles = all("a").map(&:text).select { |t| [ "Old Post", "New Post" ].include?(t) }
    assert_equal [ "New Post", "Old Post" ], titles
  end

  test "post index title links to show page" do
    post = blog_posts(:one)
    visit blog_posts_url
    assert_selector "a[href='#{blog_post_path(post)}']", text: post.title
  end

  test "post index shows empty state" do
    Blog::Comment.delete_all
    Blog::Post.delete_all
    visit blog_posts_url
    assert_text "No posts yet."
  end

  test "post index displays new post link" do
    visit blog_posts_url
    assert_selector "a[href='#{new_blog_post_path}']", text: "New post"
  end

  test "post show displays edit and delete actions" do
    post = blog_posts(:one)
    visit blog_post_url(post)
    assert_selector "a", text: "Edit"
    assert_selector "button", text: "Delete"
  end

  test "post show lists comments oldest first" do
    post = blog_posts(:one)
    user = core_users(:alice)
    Blog::Comment.create!(post: post, user: user, body: "First comment", created_at: 1.day.ago)
    Blog::Comment.create!(post: post, user: user, body: "Second comment", created_at: Time.current)

    visit blog_post_url(post)

    first_position = page.body.index("First comment")
    second_position = page.body.index("Second comment")
    assert first_position < second_position, "First comment should appear before second comment"
  end

  test "post show displays inline comment form" do
    post = blog_posts(:one)
    visit blog_post_url(post)
    assert_selector "textarea"
    assert_selector "input[type='submit'][value='Post comment']"
  end

  test "post show displays no comments yet when empty" do
    user = core_users(:alice)
    post = Blog::Post.create!(title: "Empty Post", body: "body", user: user)
    visit blog_post_url(post)
    assert_text "No comments yet."
  end

  test "post show has back to posts link" do
    post = blog_posts(:one)
    visit blog_post_url(post)
    assert_selector "a[href='#{blog_posts_path}']", text: "Back to posts"
  end

  test "flash notice after post create" do
    sign_in_as_system("Alice")
    visit new_blog_post_url
    fill_in "Title", with: "My New Post"
    fill_in "Body", with: "Post body here"
    click_on "Create post"
    assert_text "Post was successfully created."
  end

  test "flash notice after post update" do
    sign_in_as_system("Alice")
    post = blog_posts(:one)
    visit edit_blog_post_url(post)
    fill_in "Title", with: "Updated Title"
    click_on "Update post"
    assert_text "Post was successfully updated."
  end

  test "flash notice after post destroy" do
    sign_in_as_system("Alice")
    post = Blog::Post.create!(title: "To Delete", body: "body", user: core_users(:alice))
    visit blog_post_url(post)
    click_on "Delete"
    assert_text "Post was successfully destroyed."
  end

  test "validation errors on post create with blank title" do
    sign_in_as_system("Alice")
    visit new_blog_post_url
    fill_in "Body", with: "Some body"
    click_on "Create post"
    assert_text "Title can't be blank"
  end

  test "validation errors on post update with blank title" do
    sign_in_as_system("Alice")
    post = blog_posts(:one)
    visit edit_blog_post_url(post)
    fill_in "Title", with: ""
    click_on "Update post"
    assert_text "Title can't be blank"
  end

  test "navigation header links to root on every page" do
    visit blog_posts_url
    assert_selector "header a[href='#{root_path}']", text: "Blog"

    post = blog_posts(:one)
    visit blog_post_url(post)
    assert_selector "header a[href='#{root_path}']", text: "Blog"
  end

  test "seed data populates posts and comments" do
    Blog::Comment.delete_all
    Blog::Post.delete_all
    Core::User.delete_all
    Rails.application.load_seed
    assert Blog::Post.count > 0, "Expected seed data to create posts"
    assert Blog::Comment.count > 0, "Expected seed data to create comments"
  end
end
