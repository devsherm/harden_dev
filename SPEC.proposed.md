# Blog Application Spec

## Glossary

- **Post**: A blog article authored by a single person. Stored in `blog_posts`.
- **Comment**: A reader response attached to exactly one Post. Stored in `blog_comments`.
- **Author**: A free-text string identifying who wrote a Post or Comment. Not an authenticated user — just a name.
- **Topic**: A free-text category label on a Post (e.g., "Rails", "Design"). Optional.
- **Liked by Author**: A flag on a Comment indicating the Post's author has endorsed it. Stored as a string field.

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

- `Blog::Post` validates presence of **title** and **body**.
- `Blog::Post` has many Comments (`has_many :comments, dependent: :destroy`).
- `Blog::Comment` validates presence of **body** and **post** association.
- `Blog::Comment` belongs to a Post (`belongs_to :post`).
- The foreign key from `blog_comments.post_id` to `blog_posts.id` is enforced at the database level.

### Controllers

- `Blog::PostsController` provides standard CRUD actions: index, show, new, create, edit, update, destroy.
- `Blog::CommentsController` provides standard CRUD actions: index, show, new, create, edit, update, destroy.
- Both controllers use `params.expect()` for strong parameters.
- Creating a Post with a blank title or body returns validation errors and re-renders the form.
- Creating a Comment with a blank body returns validation errors and re-renders the form.

### Routes

- Posts are accessible under `namespace :blog` at `/blog/posts`.
- Comments are accessible under `namespace :blog` at `/blog/comments`.
- The root route resolves to the Posts index.

### Views

- Post index displays all Posts with title, author, and topic.
- Post show displays the full Post and its Comments.
- Post form (new/edit) includes fields for title, body, author, and topic.
- Comment form includes fields for author and body.
- All views use ERB templates with partials for reuse.
- JSON representations are available via jbuilder templates.

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

| Assertion | How to verify |
|---|---|
| Post requires title | `Blog::Post.new(body: "x").valid?` returns `false` with error on `title` |
| Post requires body | `Blog::Post.new(title: "x").valid?` returns `false` with error on `body` |
| Comment requires body | `Blog::Comment.new(post: some_post).valid?` returns `false` with error on `body` |
| Comment belongs to Post | `Blog::Comment.new(body: "x").valid?` returns `false` with error on `post` |
| Destroying a Post destroys its Comments | After `post.destroy`, `Blog::Comment.where(post_id: post.id).count` is `0` |
| POST /blog/posts with valid params returns 302 or 201 | Integration test confirms redirect to the new Post |
| POST /blog/posts with blank title re-renders form | Integration test confirms 422 and form with errors |
| GET /blog/posts returns 200 | Integration test confirms success |
| GET /blog/posts/:id returns 200 | Integration test confirms success for an existing Post |
| GET /blog/posts.json returns JSON array | Response content type is `application/json` |
| Root path resolves to Post index | `GET /` redirects or renders the Posts listing |
