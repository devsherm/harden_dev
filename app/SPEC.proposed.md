# Blog Application Spec

## Glossary

- **Post**: A blog article authored by a single person. Stored in `blog_posts`.
- **Comment**: A reader response attached to exactly one Post. Stored in `blog_comments`.
- **Author**: A free-text string identifying who wrote a Post or Comment. Not an authenticated user — just a name.
- **Topic**: A free-text category label on a Post (e.g., "Rails", "Design"). Optional.
- **Liked by Author**: A flag on a Comment indicating the Post's author has endorsed it. When set, contains the Post author's name.

## Intent

A minimal multi-page blog where visitors can read posts, create new posts, and leave comments on existing posts. The application serves as a straightforward CRUD exercise — no authentication, no rich text, no media uploads.

## Domain Rules

- A Post has a **title**, **body**, **author**, and optional **topic**.
- A Comment has an **author**, **body**, and belongs to exactly one Post (enforced by a foreign key constraint).
- A Comment may be marked as **liked by author**.
- Deleting a Post deletes its associated Comments (dependent destroy).
- Posts and Comments are publicly readable with no access control.

## Technical Constraints

### Models

- `Blog::Post` validates presence of **title**, **body**, and **author**.
- `Blog::Post` has many Comments (`has_many :comments, dependent: :destroy`).
- `Blog::Comment` validates presence of **author**, **body**, and **post** association.
- `Blog::Comment` belongs to a Post (`belongs_to :post`).
- The foreign key from `blog_comments.post_id` to `blog_posts.id` is enforced at the database level.

### Controllers

- `Blog::PostsController` provides standard CRUD actions: index, show, new, create, edit, update, destroy.
- `Blog::CommentsController` provides actions: index, new, create, edit, update, destroy. There is no show action — Comments are viewed on the parent Post's show page or via the Comment index.
- `Blog::CommentsController` provides a `toggle_like` action that toggles the `liked_by_author` field on a Comment (see Liked by Author under Views).
- Both controllers use `params.expect()` for strong parameters.
- Creating a Post with a blank title, body, or author returns validation errors and re-renders the form.
- Updating a Post with invalid params returns validation errors (HTTP 422) and re-renders the edit form with error summary.
- Creating a Comment with a blank author or body returns validation errors and re-renders the Post show page with the error summary above the inline Comment form. The submitted field values are preserved.
- Updating a Comment with invalid params returns validation errors (HTTP 422) and re-renders the edit form with error summary.

### Routes

- Posts are accessible under `namespace :blog` at `/blog/posts`.
- Comments are accessible under `namespace :blog` at `/blog/comments` (flat routes for index, new, create, edit, update, destroy).
- Comments are also accessible via a nested route under Posts: `POST /blog/posts/:post_id/comments` for creating a Comment on a specific Post. The inline Comment form on the Post show page submits to this nested route.
- A custom member route `PATCH /blog/comments/:id/toggle_like` is exposed for the liked-by-author toggle.
- The root route (`GET /`) issues a **302 redirect** to `/blog/posts`.

### Views

All views use ERB templates with partials for reuse. JSON representations are available via jbuilder templates.

#### Layout and Navigation

- The application layout includes a persistent header with the application name ("Blog") linked to the root path.
- Every page below the header includes a "Back to posts" link so the user can always return to the index in one click.

#### Post Index (`/blog/posts`)

- Displays all Posts ordered by **created_at descending** (newest first).
- Each Post in the list shows **title** (linked to the Post show page), **author**, and **topic** (if present). If topic is blank, no topic label is rendered — no "N/A" or placeholder.
- A "New post" link appears above the list, linking to the new Post form.
- **Empty state**: When no Posts exist, the page displays the text "No posts yet." followed by the "New post" link.

#### Post Show (`/blog/posts/:id`)

- Displays the Post's **title**, **author**, **topic** (if present), **body**, and **created_at** timestamp.
- Below the Post body, an "Edit" link and a "Delete" button are displayed. The Delete button submits a `DELETE` request — no confirmation dialog is required.
- Below the Post actions, a **Comments section** is rendered with the heading "Comments".
- Comments are listed in **created_at ascending** order (oldest first, preserving chronological conversation flow).
- Each Comment displays **author**, **body**, **created_at** timestamp, and the **liked by author** indicator (see below).
- Each Comment has an "Edit" link and a "Delete" link.
- **Comment empty state**: When the Post has no Comments, the text "No comments yet." is displayed.
- Below the comments list, an inline **new Comment form** is rendered directly on the Post show page (not a separate page). The form contains fields for **author** (text input) and **body** (textarea), plus a "Post comment" submit button. The form submits to the nested route `POST /blog/posts/:post_id/comments`.

#### Liked by Author

- On the Post show page, each Comment displays a "Like" or "Unlike" toggle button that submits a `PATCH` request to `/blog/comments/:id/toggle_like`.
- When a Comment's `liked_by_author` field is blank or empty, the toggle reads "Like" and submitting it sets the field to the Post author's name.
- When a Comment's `liked_by_author` field is populated, the toggle reads "Unlike" and submitting it clears the field. The Comment also displays the text "Liked by {author name}" below the Comment body.
- After toggling, the user is redirected back to the parent Post's show page.
- Since there is no authentication, the toggle is available to any visitor — this is intentional and consistent with the no-auth design.

#### Post Form (New / Edit)

- The new Post form is at `/blog/posts/new`. The edit Post form is at `/blog/posts/:id/edit`.
- Both forms contain: **title** (text input), **body** (textarea), **author** (text input), and **topic** (text input).
- A "Create post" submit button appears on the new form and "Update post" on the edit form.
- On successful create, the user is redirected to the new Post's show page with a flash notice: "Post was successfully created."
- On successful update, the user is redirected to the Post's show page with a flash notice: "Post was successfully updated."
- On successful destroy, the user is redirected to the Post index with a flash notice: "Post was successfully destroyed."

#### Comment Form (New / Edit)

- The primary path for creating a Comment is the inline form on the Post show page (described above).
- A standalone new Comment form exists at `/blog/comments/new` and edit at `/blog/comments/:id/edit`, consistent with the resourceful routes, but these are secondary paths.
- The Comment edit page includes a "Back to post" link pointing to the parent Post's show page.
- On successful Comment create, the user is redirected back to the parent Post's show page with a flash notice: "Comment was successfully created."
- On successful Comment update, the user is redirected back to the parent Post's show page with a flash notice: "Comment was successfully updated."
- On successful Comment destroy, the user is redirected back to the parent Post's show page with a flash notice: "Comment was successfully destroyed."

#### Validation Error Display

- When a form submission fails validation, the form is re-rendered (HTTP 422) with an error summary at the top of the form.
- The error summary lists each validation error as a bullet point (e.g., "Title can't be blank").
- Fields with errors are visually distinguished — wrapped in a `div.field_with_errors` so the user can see which fields need attention.

#### Styling

- The application uses the Rails default stylesheet. No custom CSS framework is required.
- Visual polish is a non-goal — functional clarity and correct HTML semantics take priority over aesthetics.

### Seed Data

- `db/seeds.rb` creates a small representative set of Posts and Comments so the app is not empty on first run.

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
| Post requires title | `Blog::Post.new(body: "x", author: "a").valid?` returns `false` with error on `title` |
| Post requires body | `Blog::Post.new(title: "x", author: "a").valid?` returns `false` with error on `body` |
| Post requires author | `Blog::Post.new(title: "x", body: "x").valid?` returns `false` with error on `author` |
| Comment requires author | `Blog::Comment.new(body: "x", post: some_post).valid?` returns `false` with error on `author` |
| Comment requires body | `Blog::Comment.new(author: "a", post: some_post).valid?` returns `false` with error on `body` |
| Comment belongs to Post | `Blog::Comment.new(author: "a", body: "x").valid?` returns `false` with error on `post` |
| Destroying a Post destroys its Comments | After `post.destroy`, `Blog::Comment.where(post_id: post.id).count` is `0` |

### Route and Controller Assertions

| Assertion | How to verify |
|---|---|
| POST /blog/posts with valid params redirects | Integration test confirms 302 redirect to the new Post's show page |
| POST /blog/posts with blank title re-renders form | Integration test confirms 422 and form with error messages |
| PATCH /blog/posts/:id with blank title re-renders edit form | Integration test confirms 422 and edit form with error messages |
| POST /blog/posts/:post_id/comments with valid params redirects | Integration test confirms 302 redirect to the parent Post's show page |
| POST /blog/posts/:post_id/comments with blank body re-renders Post show | Integration test confirms 422 and Post show page with Comment error messages |
| PATCH /blog/comments/:id with blank body re-renders edit form | Integration test confirms 422 and edit form with error messages |
| PATCH /blog/comments/:id/toggle_like toggles liked_by_author | Integration test confirms redirect to parent Post show and `liked_by_author` is set/cleared |
| GET /blog/posts returns 200 | Integration test confirms success |
| GET /blog/posts/:id returns 200 | Integration test confirms success for an existing Post |
| GET /blog/posts.json returns JSON array | Response content type is `application/json` |
| Root path redirects to Post index | `GET /` returns 302 redirect to `/blog/posts` |
| Comment delete redirects to parent Post show | Integration test: `DELETE /blog/comments/:id` redirects to the parent Post's show page with flash "Comment was successfully destroyed." |

### UX Assertions

| Assertion | How to verify |
|---|---|
| Post index orders by newest first | System test: create Post A then Post B; Post B appears above Post A on the index |
| Post index links titles to show pages | System test: index page contains a link with the Post title whose `href` matches the Post show path |
| Post index shows "No posts yet." when empty | System test: with no Posts, index page contains the text "No posts yet." |
| Post index displays "New post" link | System test: index page contains a link with text "New post" pointing to `/blog/posts/new` |
| Post show displays edit and delete actions | System test: show page contains an "Edit" link and a "Delete" button |
| Post show lists Comments oldest first | System test: create Comment A then Comment B on a Post; Comment A appears above Comment B |
| Post show inline Comment form is present | System test: Post show page contains a form with author input, body textarea, and "Post comment" submit button |
| Post show displays "No comments yet." when no Comments | System test: Post with zero Comments shows "No comments yet." |
| Comment liked toggle sets liked_by_author | System test: clicking "Like" on a Comment on a Post by "Alice" sets `liked_by_author` to "Alice" and displays "Liked by Alice" |
| Comment unlike toggle clears liked_by_author | System test: clicking "Unlike" on a liked Comment clears `liked_by_author` and removes the liked indicator |
| Flash notice appears after Post create | System test: creating a Post shows "Post was successfully created." |
| Flash notice appears after Post update | System test: updating a Post shows "Post was successfully updated." |
| Flash notice appears after Post destroy | System test: destroying a Post redirects to index with "Post was successfully destroyed." |
| Flash notice appears after Comment create | System test: creating a Comment redirects to Post show with "Comment was successfully created." |
| Validation errors display on failed Post create | System test: submitting a Post with blank title shows error summary containing "Title can't be blank" |
| Validation errors display on failed Post update | System test: editing a Post and blanking the title shows error summary containing "Title can't be blank" |
| Validation errors display on failed Comment create | System test: submitting inline Comment with blank body on Post show page shows error summary containing "Body can't be blank" |
| Comment edit page links back to parent Post | System test: Comment edit page contains a "Back to post" link whose `href` matches the parent Post's show path |
| Post show page has "Back to posts" link | System test: Post show page contains a "Back to posts" link whose `href` matches the Post index path |
| Navigation header links to root | System test: every page contains a header link with text "Blog" pointing to the root path |
| Seed data populates Posts and Comments | After `rails db:seed`, `Blog::Post.count > 0` and `Blog::Comment.count > 0` |
