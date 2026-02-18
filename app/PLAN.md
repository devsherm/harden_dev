# Implementation Plan

> Generated from `app/SPEC.proposed.md` (delta mode)

## Recovery Instructions

- If tests fail after an item, fix the failing tests before moving to the next item.
- If an item cannot be completed as described, add a `BLOCKED:` note to the item and move to the next one.
- After completing each item, verify the codebase is in a clean, working state before proceeding.

## Items

- [ ] 1. **Fix foreign key migration**
  - **Implements**: Spec § Domain Rules (FK constraint), § Technical Constraints > Models (FK at database level)
  - **Completion**: `ActiveRecord::Base.connection.foreign_keys("blog_comments")` returns a FK with `to_table: "blog_posts"`. `Blog::Comment.create!(post: Blog::Post.create!(title: "t", body: "b", author: "a"), author: "a", body: "b")` succeeds without error. `bin/rails test` passes.
  - **Scope boundary**: Only the migration and schema. No model, controller, or view changes.
  - **Files**: `db/migrate/XXXXXX_fix_blog_comments_foreign_key.rb`, `db/schema.rb` (auto-updated)
  - **Testing**: Run `bin/rails db:migrate` and verify in console. Run `bin/rails test` to ensure no regressions.
  - **Instructions**: The existing migration `20260218113451_create_blog_comments.rb` uses `t.references :post, null: false, foreign_key: true` which generated `add_foreign_key "blog_comments", "posts"` in `db/schema.rb`. This is wrong because the posts table is actually named `blog_posts`, not `posts`. Generate a new migration: `bin/rails generate migration FixBlogCommentsForeignKey`. In the migration file, write:
    ```ruby
    class FixBlogCommentsForeignKey < ActiveRecord::Migration[8.1]
      def change
        remove_foreign_key :blog_comments, :posts if foreign_key_exists?(:blog_comments, :posts)
        add_foreign_key :blog_comments, :blog_posts, column: :post_id
      end
    end
    ```
    Then run `bin/rails db:migrate`. Verify in `db/schema.rb` that the foreign key line reads `add_foreign_key "blog_comments", "blog_posts"`.

- [ ] 2. **Add Post model validations and association**
  - **Implements**: Spec § Technical Constraints > Models (Post validates title, body, author; has_many comments dependent destroy)
  - **Completion**: `Blog::Post.new.valid?` returns `false` with errors on title, body, author. `Blog::Post.new.respond_to?(:comments)` returns `true`. Destroying a post destroys its comments. `bin/rails test` passes.
  - **Scope boundary**: Only `Blog::Post` model file. No controller, view, or test changes.
  - **Files**: `app/models/blog/post.rb`
  - **Testing**: Verify in console. Run `bin/rails test` to confirm existing tests still pass (fixtures have valid data).
  - **Instructions**: Edit `app/models/blog/post.rb` to add `has_many :comments, dependent: :destroy` and `validates :title, :body, :author, presence: true`. The file currently contains only `class Blog::Post < ApplicationRecord` with no body.

- [ ] 3. **Add Comment model validations**
  - **Implements**: Spec § Technical Constraints > Models (Comment validates author, body; post validated by belongs_to)
  - **Completion**: `Blog::Comment.new(post: some_post).valid?` returns `false` with errors on author and body. `Blog::Comment.new(author: "a", body: "b").valid?` returns `false` with error on post. `bin/rails test` passes.
  - **Scope boundary**: Only `Blog::Comment` model file. No controller, view, or test changes.
  - **Files**: `app/models/blog/comment.rb`
  - **Testing**: Verify in console. Run `bin/rails test` to confirm existing tests still pass.
  - **Instructions**: Edit `app/models/blog/comment.rb` to add `validates :author, :body, presence: true`. The `belongs_to :post` already exists (which provides the post presence validation by default in Rails 5+). The file currently has `belongs_to :post` and nothing else.

- [ ] 4. **Update routes: root redirect, nested comments, toggle_like, remove comment show**
  - **Implements**: Spec § Technical Constraints > Routes
  - **Completion**: `GET /` returns 302 redirect to `/blog/posts`. Route `POST /blog/posts/:post_id/comments` exists. Route `PATCH /blog/comments/:id/toggle_like` exists. `GET /blog/comments/:id` is not routable. All other comment routes (index, new, create, edit, update, destroy) still exist. `bin/rails test` passes.
  - **Scope boundary**: Only `config/routes.rb`. Also remove the `"should show blog_comment"` test from `test/controllers/blog/comments_controller_test.rb` to keep tests green after removing the show route. No controller or view changes.
  - **Files**: `config/routes.rb`, `test/controllers/blog/comments_controller_test.rb` (remove show test only)
  - **Testing**: Run `bin/rails routes | grep blog` to verify. Run `bin/rails test` to confirm passing.
  - **Instructions**: (1) In `config/routes.rb`, add `get "/", to: redirect("/blog/posts")` at the top level (outside the namespace block, above the `namespace :blog` block). This produces a 302 redirect. (2) Inside the `namespace :blog` block, change `resources :comments` to:
    ```ruby
    resources :comments, except: [:show] do
      member do
        patch :toggle_like
      end
    end
    ```
    (3) Add a nested route for comment creation inside the namespace block (after the existing `resources :posts` line):
    ```ruby
    resources :posts, only: [] do
      resources :comments, only: [:create]
    end
    ```
    This uses `only: []` on posts to avoid duplicating post routes — it only adds the nested comments create route. (4) In `test/controllers/blog/comments_controller_test.rb`, delete the `"should show blog_comment"` test block. Only remove the show test; leave all other tests unchanged.

- [ ] 5. **Application layout: navigation header and "Back to posts" link**
  - **Implements**: Spec § Views > Layout and Navigation
  - **Completion**: Every page renders a persistent header with the application name "Blog" linked to the root path (`/`). Every page includes a "Back to posts" link pointing to `/blog/posts` below the header. `bin/rails test` passes.
  - **Scope boundary**: Only the application layout file and removal of redundant links from individual post view templates. Do not change page-specific content.
  - **Files**: `app/views/layouts/application.html.erb`, `app/views/blog/posts/show.html.erb` (remove "Back to posts" link), `app/views/blog/posts/edit.html.erb` (remove "Back to posts" and "Show this post" links), `app/views/blog/posts/new.html.erb` (remove "Back to posts" link)
  - **Testing**: Run `bin/rails test`.
  - **Instructions**: (1) In `app/views/layouts/application.html.erb`, inside `<body>`, add before `<%= yield %>`:
    ```erb
    <header>
      <%= link_to "Blog", root_path %>
    </header>
    <nav>
      <%= link_to "Back to posts", blog_posts_path %>
    </nav>
    ```
    (2) In `app/views/blog/posts/show.html.erb`, remove the `<%= link_to "Back to posts", blog_posts_path %>` line and its pipe separator. (3) In `app/views/blog/posts/edit.html.erb`, remove the `<div>` block at the bottom containing "Show this post" and "Back to posts" links. (4) In `app/views/blog/posts/new.html.erb`, remove the `<div>` block containing the "Back to posts" link.

- [ ] 6. **Post index: ordering, title links, empty state, "New post" placement**
  - **Implements**: Spec § Views > Post Index, § Technical Constraints > Controllers (index ordering)
  - **Completion**: Post index lists posts newest first (`created_at DESC`). Each post title is a link to the post show page. "New post" link appears above the post list. When no posts exist, "No posts yet." is displayed followed by the "New post" link. Topic is shown only when present (no placeholder/label when blank). Post body is NOT shown on the index. `bin/rails test` passes.
  - **Scope boundary**: Only the posts controller index action and post index view/partial. No changes to show, edit, or other views.
  - **Files**: `app/controllers/blog/posts_controller.rb` (index action), `app/views/blog/posts/index.html.erb`, `app/views/blog/posts/_post.html.erb`
  - **Testing**: Run `bin/rails test`.
  - **Instructions**: (1) In `app/controllers/blog/posts_controller.rb`, in the `index` method, change `@blog_posts = Blog::Post.all` to `@blog_posts = Blog::Post.order(created_at: :desc)`. (2) Replace the entire contents of `app/views/blog/posts/index.html.erb` with:
    ```erb
    <p style="color: green"><%= notice %></p>

    <% content_for :title, "Posts" %>

    <h1>Posts</h1>

    <%= link_to "New post", new_blog_post_path %>

    <% if @blog_posts.any? %>
      <div id="blog_posts">
        <% @blog_posts.each do |blog_post| %>
          <%= render blog_post %>
        <% end %>
      </div>
    <% else %>
      <p>No posts yet.</p>
    <% end %>
    ```
    (3) Replace the entire contents of `app/views/blog/posts/_post.html.erb` with:
    ```erb
    <div id="<%= dom_id post %>">
      <p>
        <%= link_to post.title, post %>
        — by <%= post.author %>
        <% if post.topic.present? %>
          | <%= post.topic %>
        <% end %>
      </p>
    </div>
    ```

- [ ] 7. **Post show: display post details, actions, comments section, and inline comment form**
  - **Implements**: Spec § Views > Post Show
  - **Completion**: Post show displays title, author, topic (if present), body, and created_at timestamp. Below body: "Edit" link (to edit path) and "Delete" button (submits DELETE, no confirmation). Below actions: "Comments" heading. Comments listed in created_at ascending order showing author, body, created_at per comment. Each comment has "Edit" link and "Delete" link. When no comments: "No comments yet." text. Below comments list: inline form with author text input, body textarea, and "Post comment" submit button. Form action is `POST /blog/posts/:post_id/comments`. `bin/rails test` passes.
  - **Scope boundary**: Only `app/views/blog/posts/show.html.erb` and `app/controllers/blog/posts_controller.rb` (show action). Like/Unlike toggle is NOT included — that is item 9. The comment display here does NOT include the like toggle button or "Liked by" indicator yet.
  - **Files**: `app/views/blog/posts/show.html.erb`, `app/controllers/blog/posts_controller.rb` (show action)
  - **Testing**: Run `bin/rails test`.
  - **Instructions**: (1) In `app/controllers/blog/posts_controller.rb`, in the `show` method (currently empty), add `@blog_comment = @blog_post.comments.build`. Note: `@blog_post` is already set by the `before_action :set_blog_post`. (2) Replace the entire contents of `app/views/blog/posts/show.html.erb` with:
    ```erb
    <p style="color: green"><%= notice %></p>

    <h1><%= @blog_post.title %></h1>

    <p>By <%= @blog_post.author %></p>
    <% if @blog_post.topic.present? %>
      <p>Topic: <%= @blog_post.topic %></p>
    <% end %>

    <div><%= @blog_post.body %></div>

    <p>Posted on <%= @blog_post.created_at %></p>

    <div>
      <%= link_to "Edit", edit_blog_post_path(@blog_post) %>
      <%= button_to "Delete", @blog_post, method: :delete %>
    </div>

    <h2>Comments</h2>

    <% if @blog_post.comments.any? %>
      <% @blog_post.comments.order(:created_at).each do |comment| %>
        <div id="<%= dom_id comment %>">
          <p><strong><%= comment.author %></strong></p>
          <p><%= comment.body %></p>
          <p><%= comment.created_at %></p>
          <p>
            <%= link_to "Edit", edit_blog_comment_path(comment) %>
            <%= button_to "Delete", blog_comment_path(comment), method: :delete %>
          </p>
        </div>
      <% end %>
    <% else %>
      <p>No comments yet.</p>
    <% end %>

    <h3>Leave a comment</h3>

    <%= form_with(model: [@blog_post, @blog_comment]) do |form| %>
      <% if @blog_comment.errors.any? %>
        <div>
          <ul>
            <% @blog_comment.errors.full_messages.each do |message| %>
              <li><%= message %></li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <div>
        <%= form.label :author, style: "display: block" %>
        <%= form.text_field :author %>
      </div>

      <div>
        <%= form.label :body, style: "display: block" %>
        <%= form.textarea :body %>
      </div>

      <div>
        <%= form.submit "Post comment" %>
      </div>
    <% end %>
    ```

- [ ] 8a. **Comments controller: remove show action, update create for nested route and redirect, update destroy and update redirects**
  - **Implements**: Spec § Technical Constraints > Controllers (CommentsController actions, redirects)
  - **Completion**: (1) No `show` action in controller. (2) `create` determines post from `params[:post_id]` (nested route) or `params.dig(:blog_comment, :post_id)` (flat route); on success redirects to parent post show with flash "Comment was successfully created."; on failure re-renders `"blog/posts/show"` with status 422 (setting up `@blog_post` and `@blog_comment` for the show template). (3) `update` redirects to `blog_post_path(@blog_comment.post)` with correct flash. (4) `destroy` redirects to `blog_post_path(@blog_comment.post)` with correct flash. (5) `blog_comment_params` permits only `[:body, :author]`. `bin/rails test` passes after item 8c fixes tests.
  - **Scope boundary**: Only `app/controllers/blog/comments_controller.rb`. No view or test changes in this sub-item.
  - **Files**: `app/controllers/blog/comments_controller.rb`
  - **Testing**: Run `bin/rails test` (some comment controller tests may fail due to redirect assertion mismatches; this is expected and will be fixed in item 8c).
  - **Instructions**: Edit `app/controllers/blog/comments_controller.rb`:
    (1) Change the `before_action` line from `only: %i[ show edit update destroy ]` to `only: %i[ edit update destroy ]`.
    (2) Delete the entire `show` method.
    (3) Replace the `create` method with:
    ```ruby
    def create
      @blog_post = Blog::Post.find(params[:post_id] || params.dig(:blog_comment, :post_id))
      @blog_comment = @blog_post.comments.build(blog_comment_params)

      respond_to do |format|
        if @blog_comment.save
          format.html { redirect_to blog_post_path(@blog_post), notice: "Comment was successfully created." }
          format.json { render :show, status: :created, location: @blog_comment }
        else
          format.html { render "blog/posts/show", status: :unprocessable_entity }
          format.json { render json: @blog_comment.errors, status: :unprocessable_entity }
        end
      end
    end
    ```
    (4) In the `update` method, change the success redirect from `redirect_to @blog_comment` to `redirect_to blog_post_path(@blog_comment.post), notice: "Comment was successfully updated.", status: :see_other`.
    (5) In the `destroy` method, change the redirect from `redirect_to blog_comments_path` to `redirect_to blog_post_path(@blog_comment.post), notice: "Comment was successfully destroyed.", status: :see_other`.
    (6) In `blog_comment_params`, change `params.expect(blog_comment: [ :post_id, :body, :author, :liked_by_author ])` to `params.expect(blog_comment: [ :body, :author ])`.

- [ ] 8b. **Comments controller: add toggle_like action and delete show view files**
  - **Implements**: Spec § Views > Liked by Author (toggle_like behavior), cleanup of removed show route
  - **Completion**: (1) `toggle_like` action exists: finds comment, toggles `liked_by_author` (sets to `comment.post.author` if blank, clears to nil if populated), redirects to parent post show. (2) `show.html.erb` and `show.json.jbuilder` for comments are deleted. `bin/rails test` passes.
  - **Scope boundary**: Only adding the `toggle_like` method to the comments controller and deleting two view files.
  - **Files**: `app/controllers/blog/comments_controller.rb` (add `toggle_like` method), `app/views/blog/comments/show.html.erb` (DELETE), `app/views/blog/comments/show.json.jbuilder` (DELETE)
  - **Testing**: Run `bin/rails test`.
  - **Instructions**: (1) In `app/controllers/blog/comments_controller.rb`, add the following public method (before the `private` keyword):
    ```ruby
    def toggle_like
      @blog_comment = Blog::Comment.find(params.expect(:id))
      if @blog_comment.liked_by_author.present?
        @blog_comment.update(liked_by_author: nil)
      else
        @blog_comment.update(liked_by_author: @blog_comment.post.author)
      end
      redirect_to blog_post_path(@blog_comment.post)
    end
    ```
    (2) Delete the file `app/views/blog/comments/show.html.erb`. (3) Delete the file `app/views/blog/comments/show.json.jbuilder`.

- [ ] 8c. **Update comment controller tests for new redirects and routes**
  - **Implements**: Spec § Testability Hooks > Route and Controller Assertions (comment-related assertions)
  - **Completion**: All existing comment controller tests pass with updated redirect expectations. The create test uses the nested route and asserts redirect to parent post. The update test asserts redirect to parent post. The destroy test asserts redirect to parent post. `bin/rails test test/controllers/blog/comments_controller_test.rb` passes.
  - **Scope boundary**: Only `test/controllers/blog/comments_controller_test.rb`.
  - **Files**: `test/controllers/blog/comments_controller_test.rb`
  - **Testing**: Run `bin/rails test test/controllers/blog/comments_controller_test.rb`.
  - **Instructions**: Replace the entire contents of `test/controllers/blog/comments_controller_test.rb` with:
    ```ruby
    require "test_helper"

    class Blog::CommentsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @blog_comment = blog_comments(:one)
        @blog_post = @blog_comment.post
      end

      test "should get index" do
        get blog_comments_url
        assert_response :success
      end

      test "should get new" do
        get new_blog_comment_url
        assert_response :success
      end

      test "should create blog_comment" do
        assert_difference("Blog::Comment.count") do
          post blog_post_comments_url(@blog_post), params: { blog_comment: { author: @blog_comment.author, body: @blog_comment.body } }
        end

        assert_redirected_to blog_post_url(@blog_post)
      end

      test "should get edit" do
        get edit_blog_comment_url(@blog_comment)
        assert_response :success
      end

      test "should update blog_comment" do
        patch blog_comment_url(@blog_comment), params: { blog_comment: { author: @blog_comment.author, body: @blog_comment.body } }
        assert_redirected_to blog_post_url(@blog_comment.post)
      end

      test "should destroy blog_comment" do
        post_for_redirect = @blog_comment.post
        assert_difference("Blog::Comment.count", -1) do
          delete blog_comment_url(@blog_comment)
        end

        assert_redirected_to blog_post_url(post_for_redirect)
      end
    end
    ```

- [ ] 9. **Like/Unlike toggle button and "Liked by" indicator on post show**
  - **Implements**: Spec § Views > Liked by Author
  - **Completion**: Each comment on the post show page shows: (1) A "Like" button when `liked_by_author` is blank/nil, or an "Unlike" button when populated. The button submits `PATCH` to `toggle_like_blog_comment_path(comment)`. (2) When `liked_by_author` is populated, text "Liked by {author name}" appears below the comment body. `bin/rails test` passes.
  - **Scope boundary**: Only the comment rendering section within `app/views/blog/posts/show.html.erb`. The `toggle_like` controller action already exists from item 8b.
  - **Files**: `app/views/blog/posts/show.html.erb` (comment display section only)
  - **Testing**: Run `bin/rails test`.
  - **Instructions**: In `app/views/blog/posts/show.html.erb`, find the comment loop (the `<% @blog_post.comments.order(:created_at).each do |comment| %>` block). Inside each comment's `<div>`, after the line displaying `comment.body`, add:
    ```erb
    <% if comment.liked_by_author.present? %>
      <p>Liked by <%= comment.liked_by_author %></p>
    <% end %>
    ```
    Then, after the `created_at` line and before the Edit/Delete links, add:
    ```erb
    <%= button_to(comment.liked_by_author.present? ? "Unlike" : "Like", toggle_like_blog_comment_path(comment), method: :patch) %>
    ```

- [ ] 10a. **Post form: update submit button labels and error display format**
  - **Implements**: Spec § Views > Post Form (submit labels), § Views > Validation Error Display
  - **Completion**: Post form submit button reads "Create post" on new and "Update post" on edit. Error summary lists validation errors as bullet points without the old "N error(s) prohibited..." header. `bin/rails test` passes.
  - **Scope boundary**: Only `app/views/blog/posts/_form.html.erb`.
  - **Files**: `app/views/blog/posts/_form.html.erb`
  - **Testing**: Run `bin/rails test`.
  - **Instructions**: Edit `app/views/blog/posts/_form.html.erb`. (1) Replace the error display block (the `<div style="color: red">` with `pluralize`-based header) with:
    ```erb
    <% if blog_post.errors.any? %>
      <div>
        <ul>
          <% blog_post.errors.full_messages.each do |message| %>
            <li><%= message %></li>
          <% end %>
        </ul>
      </div>
    <% end %>
    ```
    (2) Replace the submit button `<%= form.submit %>` with:
    ```erb
    <%= form.submit blog_post.new_record? ? "Create post" : "Update post" %>
    ```

- [ ] 10b. **Comment form: remove liked_by_author field, replace post_id with collection select, update error display**
  - **Implements**: Spec § Views > Comment Form (remove liked_by_author, post dropdown), § Views > Validation Error Display
  - **Completion**: Comment form does NOT include a `liked_by_author` field. The `post_id` field is a collection select dropdown instead of a raw text input. Error summary matches bullet-point format (no old header). `bin/rails test` passes.
  - **Scope boundary**: Only `app/views/blog/comments/_form.html.erb`.
  - **Files**: `app/views/blog/comments/_form.html.erb`
  - **Testing**: Run `bin/rails test`.
  - **Instructions**: Replace the entire contents of `app/views/blog/comments/_form.html.erb` with:
    ```erb
    <%= form_with(model: blog_comment) do |form| %>
      <% if blog_comment.errors.any? %>
        <div>
          <ul>
            <% blog_comment.errors.full_messages.each do |message| %>
              <li><%= message %></li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <div>
        <%= form.label :post_id, style: "display: block" %>
        <%= form.collection_select :post_id, Blog::Post.all, :id, :title, prompt: "Select a post" %>
      </div>

      <div>
        <%= form.label :body, style: "display: block" %>
        <%= form.textarea :body %>
      </div>

      <div>
        <%= form.label :author, style: "display: block" %>
        <%= form.text_field :author %>
      </div>

      <div>
        <%= form.submit %>
      </div>
    <% end %>
    ```

- [ ] 10c. **Comment edit and new view: update navigation links**
  - **Implements**: Spec § Views > Comment Form ("Back to post" link on edit, navigation on new)
  - **Completion**: Comment edit page has a "Back to post" link pointing to `blog_post_path(@blog_comment.post)`. Comment new page does not link to the removed show page. `bin/rails test` passes.
  - **Scope boundary**: Only `app/views/blog/comments/edit.html.erb` and `app/views/blog/comments/new.html.erb`.
  - **Files**: `app/views/blog/comments/edit.html.erb`, `app/views/blog/comments/new.html.erb`
  - **Testing**: Run `bin/rails test`.
  - **Instructions**: (1) Replace the entire contents of `app/views/blog/comments/edit.html.erb` with:
    ```erb
    <% content_for :title, "Editing comment" %>

    <h1>Editing comment</h1>

    <%= render "form", blog_comment: @blog_comment %>

    <br>

    <div>
      <%= link_to "Back to post", blog_post_path(@blog_comment.post) %>
    </div>
    ```
    (2) Replace the entire contents of `app/views/blog/comments/new.html.erb` with:
    ```erb
    <% content_for :title, "New comment" %>

    <h1>New comment</h1>

    <%= render "form", blog_comment: @blog_comment %>
    ```

- [ ] 11. **Model tests**
  - **Implements**: Spec § Testability Hooks > Model Assertions (all 7 assertions)
  - **Completion**: Tests cover: Post requires title, Post requires body, Post requires author, Comment requires author, Comment requires body, Comment belongs to Post (missing post fails validation), destroying a Post destroys its Comments. All pass with `bin/rails test test/models/`.
  - **Scope boundary**: Only model test files. No application code changes.
  - **Files**: `test/models/blog/post_test.rb`, `test/models/blog/comment_test.rb`
  - **Testing**: Run `bin/rails test test/models/`.
  - **Instructions**: (1) Replace the contents of `test/models/blog/post_test.rb` with:
    ```ruby
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
    ```
    (2) Replace the contents of `test/models/blog/comment_test.rb` with:
    ```ruby
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
    ```

- [ ] 12a. **Posts controller tests: add validation and JSON tests**
  - **Implements**: Spec § Testability Hooks > Route and Controller Assertions (post-related: blank title create 422, blank title update 422, JSON index, root redirect)
  - **Completion**: Tests cover: POST with blank title returns 422, PATCH with blank title returns 422, GET index.json returns JSON, GET root redirects to posts index. All pass with `bin/rails test test/controllers/blog/posts_controller_test.rb`.
  - **Scope boundary**: Only `test/controllers/blog/posts_controller_test.rb`. No application code changes.
  - **Files**: `test/controllers/blog/posts_controller_test.rb`
  - **Testing**: Run `bin/rails test test/controllers/blog/posts_controller_test.rb`.
  - **Instructions**: Add the following tests to the existing `Blog::PostsControllerTest` class after the existing tests:
    ```ruby
    test "should not create post with blank title" do
      assert_no_difference("Blog::Post.count") do
        post blog_posts_url, params: { blog_post: { author: "a", body: "b", title: "", topic: "" } }
      end
      assert_response :unprocessable_entity
    end

    test "should not update post with blank title" do
      patch blog_post_url(@blog_post), params: { blog_post: { title: "" } }
      assert_response :unprocessable_entity
    end

    test "should return JSON index" do
      get blog_posts_url(format: :json)
      assert_response :success
      assert_equal "application/json; charset=utf-8", @response.content_type
    end

    test "root redirects to posts index" do
      get root_url
      assert_redirected_to blog_posts_url
    end
    ```

- [ ] 12b. **Comments controller tests: add validation, toggle_like, and nested route tests**
  - **Implements**: Spec § Testability Hooks > Route and Controller Assertions (comment-related: blank body create 422, blank body update 422, toggle_like, destroy redirect)
  - **Completion**: Tests cover: POST with blank body returns 422, PATCH with blank body returns 422, toggle_like sets and clears liked_by_author, destroy redirects to parent post. All pass with `bin/rails test test/controllers/blog/comments_controller_test.rb`.
  - **Scope boundary**: Only `test/controllers/blog/comments_controller_test.rb`. No application code changes.
  - **Files**: `test/controllers/blog/comments_controller_test.rb`
  - **Testing**: Run `bin/rails test test/controllers/blog/comments_controller_test.rb`.
  - **Instructions**: Add the following tests to the existing `Blog::CommentsControllerTest` class (rewritten in item 8c) after the existing tests:
    ```ruby
    test "should not create comment with blank body" do
      assert_no_difference("Blog::Comment.count") do
        post blog_post_comments_url(@blog_post), params: { blog_comment: { author: "a", body: "" } }
      end
      assert_response :unprocessable_entity
    end

    test "should not update comment with blank body" do
      patch blog_comment_url(@blog_comment), params: { blog_comment: { body: "" } }
      assert_response :unprocessable_entity
    end

    test "should toggle like on comment" do
      patch toggle_like_blog_comment_url(@blog_comment)
      assert_redirected_to blog_post_url(@blog_post)
      @blog_comment.reload
      assert_equal @blog_post.author, @blog_comment.liked_by_author
    end

    test "should toggle unlike on comment" do
      @blog_comment.update!(liked_by_author: @blog_post.author)
      patch toggle_like_blog_comment_url(@blog_comment)
      assert_redirected_to blog_post_url(@blog_post)
      @blog_comment.reload
      assert_nil @blog_comment.liked_by_author
    end
    ```

- [ ] 12c. **Update fixtures for valid data**
  - **Implements**: Supports all tests (fixtures must have valid data for validations)
  - **Completion**: Fixtures have distinct, realistic values. Posts have non-blank title, body, author. Comments have non-blank author, body, and valid post reference. `bin/rails test` passes.
  - **Scope boundary**: Only fixture files.
  - **Files**: `test/fixtures/blog/posts.yml`, `test/fixtures/blog/comments.yml`
  - **Testing**: Run `bin/rails test`.
  - **Instructions**: Replace `test/fixtures/blog/posts.yml` with:
    ```yaml
    one:
      title: First Post
      body: This is the first post body.
      topic: Rails
      author: Alice

    two:
      title: Second Post
      body: This is the second post body.
      topic: Design
      author: Bob
    ```
    Replace `test/fixtures/blog/comments.yml` with:
    ```yaml
    one:
      post: one
      body: Great article!
      author: Charlie
      liked_by_author:

    two:
      post: two
      body: Thanks for sharing.
      author: Diana
      liked_by_author:
    ```

- [ ] 13a. **System tests: post index behavior**
  - **Implements**: Spec § Testability Hooks > UX Assertions (index ordering, title links, empty state, "New post" link)
  - **Completion**: System tests cover: posts ordered newest first, titles link to show pages, "No posts yet." when empty, "New post" link present. All pass with `bin/rails test:system`.
  - **Scope boundary**: Only `test/system/blog/posts_test.rb`. No application code changes.
  - **Files**: `test/system/blog/posts_test.rb`
  - **Testing**: Run `bin/rails test:system`.
  - **Instructions**: Replace the contents of `test/system/blog/posts_test.rb` with:
    ```ruby
    require "application_system_test_case"

    class Blog::PostsTest < ApplicationSystemTestCase
      test "post index orders by newest first" do
        old_post = Blog::Post.create!(title: "Old Post", body: "body", author: "a", created_at: 1.day.ago)
        new_post = Blog::Post.create!(title: "New Post", body: "body", author: "a", created_at: Time.current)

        visit blog_posts_url

        titles = all("a").map(&:text).select { |t| ["Old Post", "New Post"].include?(t) }
        assert_equal ["New Post", "Old Post"], titles
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
    end
    ```

- [ ] 13b. **System tests: post show, comments display, and inline form**
  - **Implements**: Spec § Testability Hooks > UX Assertions (post show actions, comments oldest first, inline form, no comments empty state, "Back to posts" link)
  - **Completion**: System tests cover: edit and delete actions present, comments oldest first, inline comment form present, "No comments yet." when no comments, "Back to posts" link. All pass with `bin/rails test:system`.
  - **Scope boundary**: Only `test/system/blog/posts_test.rb` (append to existing file). No application code changes.
  - **Files**: `test/system/blog/posts_test.rb`
  - **Testing**: Run `bin/rails test:system`.
  - **Instructions**: Add the following tests to the `Blog::PostsTest` class in `test/system/blog/posts_test.rb`:
    ```ruby
    test "post show displays edit and delete actions" do
      post = blog_posts(:one)
      visit blog_post_url(post)
      assert_selector "a", text: "Edit"
      assert_selector "button", text: "Delete"
    end

    test "post show lists comments oldest first" do
      post = blog_posts(:one)
      old_comment = Blog::Comment.create!(post: post, author: "a", body: "First comment", created_at: 1.day.ago)
      new_comment = Blog::Comment.create!(post: post, author: "b", body: "Second comment", created_at: Time.current)

      visit blog_post_url(post)

      first_position = page.body.index("First comment")
      second_position = page.body.index("Second comment")
      assert first_position < second_position, "First comment should appear before second comment"
    end

    test "post show displays inline comment form" do
      post = blog_posts(:one)
      visit blog_post_url(post)
      assert_selector "input[type='text']"
      assert_selector "textarea"
      assert_selector "input[type='submit'][value='Post comment']"
    end

    test "post show displays no comments yet when empty" do
      post = Blog::Post.create!(title: "Empty Post", body: "body", author: "a")
      visit blog_post_url(post)
      assert_text "No comments yet."
    end

    test "post show has back to posts link" do
      post = blog_posts(:one)
      visit blog_post_url(post)
      assert_selector "a[href='#{blog_posts_path}']", text: "Back to posts"
    end
    ```

- [ ] 13c. **System tests: like/unlike toggle**
  - **Implements**: Spec § Testability Hooks > UX Assertions (like sets indicator, unlike clears indicator)
  - **Completion**: System tests cover: clicking "Like" sets liked_by_author and shows "Liked by {author}", clicking "Unlike" clears it. All pass with `bin/rails test:system`.
  - **Scope boundary**: Only a new system test file `test/system/blog/comments_test.rb`. No application code changes.
  - **Files**: `test/system/blog/comments_test.rb`
  - **Testing**: Run `bin/rails test:system`.
  - **Instructions**: Create `test/system/blog/comments_test.rb` with:
    ```ruby
    require "application_system_test_case"

    class Blog::CommentsTest < ApplicationSystemTestCase
      test "like toggle sets liked_by_author" do
        post = blog_posts(:one)
        comment = blog_comments(:one)

        visit blog_post_url(post)
        within "#blog_comment_#{comment.id}" do
          click_on "Like"
        end

        assert_text "Liked by #{post.author}"
      end

      test "unlike toggle clears liked_by_author" do
        post = blog_posts(:one)
        comment = blog_comments(:one)
        comment.update!(liked_by_author: post.author)

        visit blog_post_url(post)
        within "#blog_comment_#{comment.id}" do
          click_on "Unlike"
        end

        assert_no_text "Liked by #{post.author}"
      end
    end
    ```

- [ ] 13d. **System tests: flash notices**
  - **Implements**: Spec § Testability Hooks > UX Assertions (flash notices for post create/update/destroy, comment create)
  - **Completion**: System tests cover: flash after post create, update, destroy, and comment create. All pass with `bin/rails test:system`.
  - **Scope boundary**: Only `test/system/blog/posts_test.rb` (append) and `test/system/blog/comments_test.rb` (append). No application code changes.
  - **Files**: `test/system/blog/posts_test.rb`, `test/system/blog/comments_test.rb`
  - **Testing**: Run `bin/rails test:system`.
  - **Instructions**: (1) Add the following tests to `Blog::PostsTest` in `test/system/blog/posts_test.rb`:
    ```ruby
    test "flash notice after post create" do
      visit new_blog_post_url
      fill_in "Title", with: "My New Post"
      fill_in "Body", with: "Post body here"
      fill_in "Author", with: "TestAuthor"
      click_on "Create post"
      assert_text "Post was successfully created."
    end

    test "flash notice after post update" do
      post = blog_posts(:one)
      visit edit_blog_post_url(post)
      fill_in "Title", with: "Updated Title"
      click_on "Update post"
      assert_text "Post was successfully updated."
    end

    test "flash notice after post destroy" do
      post = blog_posts(:one)
      visit blog_post_url(post)
      click_on "Delete"
      assert_text "Post was successfully destroyed."
    end
    ```
    (2) Add the following test to `Blog::CommentsTest` in `test/system/blog/comments_test.rb`:
    ```ruby
    test "flash notice after comment create" do
      post = blog_posts(:one)
      visit blog_post_url(post)
      fill_in "Author", with: "TestCommenter"
      fill_in "Body", with: "A test comment"
      click_on "Post comment"
      assert_text "Comment was successfully created."
    end
    ```

- [ ] 13e. **System tests: validation errors**
  - **Implements**: Spec § Testability Hooks > UX Assertions (validation errors on post create/update, comment create)
  - **Completion**: System tests cover: blank title on post create shows error, blank title on post update shows error, blank body on inline comment shows error. All pass with `bin/rails test:system`.
  - **Scope boundary**: Only `test/system/blog/posts_test.rb` (append) and `test/system/blog/comments_test.rb` (append). No application code changes.
  - **Files**: `test/system/blog/posts_test.rb`, `test/system/blog/comments_test.rb`
  - **Testing**: Run `bin/rails test:system`.
  - **Instructions**: (1) Add the following tests to `Blog::PostsTest` in `test/system/blog/posts_test.rb`:
    ```ruby
    test "validation errors on post create with blank title" do
      visit new_blog_post_url
      fill_in "Body", with: "Some body"
      fill_in "Author", with: "Someone"
      click_on "Create post"
      assert_text "Title can't be blank"
    end

    test "validation errors on post update with blank title" do
      post = blog_posts(:one)
      visit edit_blog_post_url(post)
      fill_in "Title", with: ""
      click_on "Update post"
      assert_text "Title can't be blank"
    end
    ```
    (2) Add the following test to `Blog::CommentsTest` in `test/system/blog/comments_test.rb`:
    ```ruby
    test "validation errors on inline comment create with blank body" do
      post = blog_posts(:one)
      visit blog_post_url(post)
      fill_in "Author", with: "Someone"
      click_on "Post comment"
      assert_text "Body can't be blank"
    end
    ```

- [ ] 13f. **System tests: navigation and remaining UX assertions**
  - **Implements**: Spec § Testability Hooks > UX Assertions (header "Blog" link, comment edit "Back to post" link, seed data)
  - **Completion**: System tests cover: navigation header "Blog" link on every page, comment edit has "Back to post" link, seed data creates posts and comments. All pass with `bin/rails test:system`.
  - **Scope boundary**: Only `test/system/blog/posts_test.rb` (append) and `test/system/blog/comments_test.rb` (append). No application code changes.
  - **Files**: `test/system/blog/posts_test.rb`, `test/system/blog/comments_test.rb`
  - **Testing**: Run `bin/rails test:system`.
  - **Instructions**: (1) Add the following tests to `Blog::PostsTest` in `test/system/blog/posts_test.rb`:
    ```ruby
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
      Rails.application.load_seed
      assert Blog::Post.count > 0, "Expected seed data to create posts"
      assert Blog::Comment.count > 0, "Expected seed data to create comments"
    end
    ```
    (2) Add the following test to `Blog::CommentsTest` in `test/system/blog/comments_test.rb`:
    ```ruby
    test "comment edit page has back to post link" do
      comment = blog_comments(:one)
      visit edit_blog_comment_url(comment)
      assert_selector "a[href='#{blog_post_path(comment.post)}']", text: "Back to post"
    end
    ```

- [ ] 14. **Seed data**
  - **Implements**: Spec § Seed Data
  - **Completion**: After `bin/rails db:seed:replant`, `Blog::Post.count > 0` and `Blog::Comment.count > 0`. Posts have varied titles, bodies, authors, and topics. Comments are distributed across multiple posts with different authors.
  - **Scope boundary**: Only `db/seeds.rb`. No schema, model, or controller changes.
  - **Files**: `db/seeds.rb`
  - **Testing**: Run `bin/rails db:seed:replant` and verify counts.
  - **Instructions**: Replace the contents of `db/seeds.rb` with:
    ```ruby
    post1 = Blog::Post.create!(
      title: "Getting Started with Rails",
      body: "Rails is a great framework for building web applications quickly. It follows convention over configuration, making it easy to get started.",
      author: "Alice",
      topic: "Rails"
    )

    post2 = Blog::Post.create!(
      title: "Design Principles for Modern Web Apps",
      body: "Good design starts with understanding your users. In this post, we explore key principles for creating intuitive interfaces.",
      author: "Bob",
      topic: "Design"
    )

    post3 = Blog::Post.create!(
      title: "My Weekend Project",
      body: "This weekend I built a small CLI tool in Ruby. It was a fun exercise and I learned a lot about argument parsing.",
      author: "Charlie"
    )

    post4 = Blog::Post.create!(
      title: "Why Testing Matters",
      body: "Automated tests give you confidence that your code works as expected. They also serve as living documentation for your codebase.",
      author: "Alice",
      topic: "Testing"
    )

    Blog::Comment.create!(post: post1, author: "Bob", body: "Great introduction! This helped me get started.")
    Blog::Comment.create!(post: post1, author: "Charlie", body: "I wish I had read this when I first started learning Rails.")
    Blog::Comment.create!(post: post1, author: "Diana", body: "Could you write a follow-up on Active Record?")
    Blog::Comment.create!(post: post2, author: "Alice", body: "These principles are spot on. I especially agree about user empathy.")
    Blog::Comment.create!(post: post2, author: "Eve", body: "Do you have any book recommendations on this topic?")
    Blog::Comment.create!(post: post3, author: "Bob", body: "Sounds like a fun project! Mind sharing the repo?")
    Blog::Comment.create!(post: post4, author: "Diana", body: "Testing has saved me so many times. Great post!")
    Blog::Comment.create!(post: post4, author: "Charlie", body: "What testing framework do you recommend for beginners?")
    ```

- [ ] 15. **Update comment index view to remove show links**
  - **Implements**: Spec § Technical Constraints > Routes (no comment show route)
  - **Completion**: The comment index page does not contain "Show this comment" links (which would be broken since the show route was removed). `bin/rails test` passes.
  - **Scope boundary**: Only `app/views/blog/comments/index.html.erb`.
  - **Files**: `app/views/blog/comments/index.html.erb`
  - **Testing**: Run `bin/rails test`.
  - **Instructions**: In `app/views/blog/comments/index.html.erb`, remove the `<%= link_to "Show this comment", blog_comment %>` line and its surrounding `<p>` tags. Replace with an "Edit" link for each comment: `<%= link_to "Edit", edit_blog_comment_path(blog_comment) %>`.
