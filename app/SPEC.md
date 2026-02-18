# Blog Application Spec

## Glossary

- **Post**: A blog article authored by a single person. Stored in `blog_posts`.
- **Comment**: A reader response attached to exactly one Post. Stored in `blog_comments`.
- **Author**: A free-text string identifying who wrote a Post or Comment. Not an authenticated user — just a name.
- **Topic**: A free-text category label on a Post (e.g., "Rails", "Design"). Optional.
- **Liked by Author**: A string column on a Comment (`liked_by_author`). Currently a free-text input with no application-level behavior — the value is whatever the user types.

## Intent

A minimal multi-page blog where visitors can read posts, create new posts, and leave comments on existing posts. The application serves as a straightforward CRUD exercise — no authentication, no rich text, no media uploads.

## Domain Rules

- A Post has a **title**, **body**, **author**, and optional **topic**.
- A Comment has an **author**, **body**, and belongs to exactly one Post (enforced by a foreign key constraint).
- A Comment has a `liked_by_author` string field with no application-level behavior — it is a free-text input.
- Deleting a Post that has Comments raises `ActiveRecord::InvalidForeignKey` — there is no cascading delete.
- Posts and Comments are publicly readable with no access control.

## Technical Constraints

### Models

- `Blog::Post` has no validations. `Blog::Post.new.valid?` returns `true`.
- `Blog::Post` has no associations — it does not declare `has_many :comments`.
- `Blog::Comment` has no explicit validations. The only validation is the implicit `belongs_to :post` presence check (Rails default `optional: false`).
- `Blog::Comment` belongs to a Post (`belongs_to :post`).
- The foreign key from `blog_comments.post_id` to `blog_posts.id` is enforced at the database level.

### Controllers

- `Blog::PostsController` provides standard CRUD actions: index, show, new, create, edit, update, destroy.
- `Blog::CommentsController` provides standard CRUD actions: index, show, new, create, edit, update, destroy. The show action renders a single Comment with "Edit this comment", "Back to comments", and "Destroy this comment" controls.
- There is no `toggle_like` action — the `liked_by_author` field is edited only via the standard Comment form.
- Both controllers use `params.expect()` for strong parameters.
- Since `Blog::Post` has no validations, creating or updating a Post always succeeds (the create-failure and update-failure code paths in the controller are unreachable).
- Creating a Comment with a missing `post_id` fails the `belongs_to :post` validation (HTTP 422) and re-renders the new Comment form.
- Updating a Comment with invalid params returns validation errors (HTTP 422) and re-renders the edit form with error summary.

### Routes

- Posts are accessible under `namespace :blog` at `/blog/posts`.
- Comments are accessible under `namespace :blog` at `/blog/comments` (flat routes for all seven CRUD actions including show).
- There are no nested routes — Comments are not routed under Posts.
- There are no custom routes — no `toggle_like` or other non-CRUD actions.
- There is no root route. `GET /` returns a routing error. The `root "posts#index"` line is commented out in `routes.rb`.

### Views

All views use ERB templates with partials for reuse. JSON representations are available via jbuilder templates.

#### Layout and Navigation

- The application layout has no persistent header or navigation element. The `<body>` contains only `<%= yield %>`.
- There is no consistent "Back to posts" navigation pattern across pages. Individual pages include their own navigation links (see Post Show, Comment Show, Comment Edit below).

#### Post Index (`/blog/posts`)

- Displays all Posts via `Blog::Post.all` with no ordering — records appear in database insertion order.
- Each Post in the list renders via the `_post` partial showing **title**, **body**, **topic**, and **author** as labeled text fields. Titles are not linked to the Post show page — a separate "Show this post" link appears below each Post.
- A "New post" link appears below the list, linking to the new Post form.
- There is no empty state — when no Posts exist, the page displays only the heading "Posts" and the "New post" link.

#### Post Show (`/blog/posts/:id`)

- Displays the Post via the `_post` partial: **title**, **body**, **topic**, and **author** as labeled text. No **created_at** timestamp is shown.
- Below the Post, an "Edit this post" link, a "Back to posts" link, and a "Destroy this post" button are displayed.
- There is no Comments section — the Post show page does not display, list, or reference Comments in any way.
- There is no inline Comment form.

#### Liked by Author

- The `liked_by_author` field exists on the Comment model as a string column.
- The Comment form renders it as a plain text input labeled "Liked by author". The user can type any value.
- There is no toggle button, no Like/Unlike behavior, and no visual indicator. The field behaves identically to the author or body fields.
- The value is displayed as-is in the Comment partial: `<strong>Liked by author:</strong> {value}`.

#### Post Form (New / Edit)

- The new Post form is at `/blog/posts/new`. The edit Post form is at `/blog/posts/:id/edit`.
- Both forms contain: **title** (text input), **body** (textarea), **topic** (text input), **author** (text input).
- The submit button uses Rails-default labeling: "Create Post" on the new form and "Update Post" on the edit form.
- On successful create, the user is redirected to the new Post's show page with a flash notice: "Post was successfully created."
- On successful update, the user is redirected to the Post's show page with a flash notice: "Post was successfully updated."
- On successful destroy, the user is redirected to the Post index with a flash notice: "Post was successfully destroyed."

#### Comment Form (New / Edit)

- The standalone new Comment form at `/blog/comments/new` and edit at `/blog/comments/:id/edit` are the only paths for creating and editing Comments. There is no inline form on the Post show page.
- Both forms contain: **post_id** (text input — raw ID, not a dropdown), **body** (textarea), **author** (text input), and **liked_by_author** (text input).
- The Comment edit page includes a "Show this comment" link and a "Back to comments" link pointing to the Comments index.
- On successful Comment create, the user is redirected to the Comment's show page with a flash notice: "Comment was successfully created."
- On successful Comment update, the user is redirected to the Comment's show page with a flash notice: "Comment was successfully updated."
- On successful Comment destroy, the user is redirected to the Comments index with a flash notice: "Comment was successfully destroyed."

#### Validation Error Display

- The form templates include error display blocks using `style="color: red"` with a `pluralize`-based header ("X error(s) prohibited this blog_post from being saved").
- The error summary lists each validation error as a bullet point.
- Fields with errors are visually distinguished — wrapped in a `div.field_with_errors` so the user can see which fields need attention.
- Since `Blog::Post` has no validations, the Post form error display block is never triggered. Comment form errors trigger only when the `post` association is missing.

#### Styling

- The application uses the Rails default stylesheet. No custom CSS framework is required.
- Visual polish is a non-goal — functional clarity and correct HTML semantics take priority over aesthetics.

### Seed Data

- No seed data is defined. `db/seeds.rb` contains only comments — no records are created.

## Non-Goals

- **Authentication / Authorization**: There are no user accounts, sessions, or permission checks.
- **Rich text or media**: Bodies are plain text. No Action Text, no image uploads.
- **Pagination**: Not required. The dataset is assumed to be small.
- **Search or filtering**: No search bar, no topic-based filtering.
- **API versioning**: The JSON endpoints are not versioned.
- **Email or notifications**: No mailers, no Action Cable broadcasts.
- **Comment nesting**: Comments are flat — no replies to other Comments.

## Testability Hooks

### Model Assertions

| Assertion | How to verify |
|---|---|
| Post has no validations | `Blog::Post.new.valid?` returns `true` |
| Post has no `has_many` association | `Blog::Post.new.respond_to?(:comments)` returns `false` |
| Deleting a Post with Comments raises FK error | `post.destroy!` raises `ActiveRecord::InvalidForeignKey` when the Post has Comments |
| Comment belongs to Post | `Blog::Comment.new(author: "a", body: "x").valid?` returns `false` with error on `post` |

### Route and Controller Assertions

| Assertion | How to verify |
|---|---|
| GET /blog/posts returns 200 | Integration test confirms success |
| GET /blog/posts/:id returns 200 | Integration test confirms success for an existing Post |
| GET /blog/comments/:id returns 200 | Integration test confirms success for an existing Comment (show action exists) |
| GET /blog/posts.json returns JSON array | Response content type is `application/json` |
| Root path returns routing error | `GET /` returns `ActionController::RoutingError` — no root route is defined |
| POST /blog/posts with valid params redirects to Post show | Integration test confirms 302 redirect to the new Post's show page |
| POST /blog/comments with valid params redirects to Comment show | Integration test confirms 302 redirect to the new Comment's show page (not the parent Post) |
| DELETE /blog/comments/:id redirects to Comments index | Integration test confirms redirect to `/blog/comments` with flash "Comment was successfully destroyed." |

### UX Assertions

| Assertion | How to verify |
|---|---|
| Post index has no ordering guarantee | Posts appear in database insertion order; no `order` clause is applied |
| Post index has no empty state | With no Posts, the index page shows only "Posts" heading and "New post" link — no "No posts yet." message |
| Post index does not link titles to show pages | Each Post's title appears as plain text; a separate "Show this post" link provides navigation |
| Post index displays "New post" link below the list | System test: index page contains a link with text "New post" pointing to `/blog/posts/new`, rendered after the post list |
| Post show has no Comments section | System test: Post show page contains no "Comments" heading, no Comment list, and no inline Comment form |
| Post show has "Back to posts" link | System test: Post show page contains a "Back to posts" link whose `href` matches the Post index path |
| Post show displays edit and delete actions | System test: show page contains an "Edit this post" link and a "Destroy this post" button |
| No navigation header | System test: the layout `<body>` contains no persistent header or "Blog" link |
| `liked_by_author` is a plain text input | System test: the Comment form contains a text input labeled "Liked by author" with no toggle behavior |
| Comment edit page links to Comments index | System test: Comment edit page contains a "Back to comments" link whose `href` matches the Comments index path |
| Flash notice appears after Post create | System test: creating a Post shows "Post was successfully created." |
| Flash notice appears after Post update | System test: updating a Post shows "Post was successfully updated." |
| Flash notice appears after Post destroy | System test: destroying a Post redirects to index with "Post was successfully destroyed." |
| Flash notice appears after Comment create | System test: creating a Comment shows "Comment was successfully created." and redirects to Comment show |
| Seed data is empty | After `rails db:seed`, `Blog::Post.count` is `0` and `Blog::Comment.count` is `0` |
