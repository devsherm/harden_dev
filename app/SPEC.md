# Blog Application Layer -- Spec

## Intent

The `app/` directory contains the Rails application layer for a namespaced blog system. It provides full CRUD for two resources -- posts and comments -- under a `Blog` namespace, with both HTML and JSON response formats. The application serves as a sandbox for Claude-assisted Rails development workflows, built on Rails 8 conventions with Hotwire, Propshaft, and importmap-based JavaScript.

## Terminology

- **Blog namespace**: The `Blog` module that scopes all domain models and controllers. Defines a `table_name_prefix` of `"blog_"` so that database tables are named `blog_posts` and `blog_comments`.
- **Post** (`Blog::Post`): A blog post with `title`, `body`, `topic`, and `author` attributes. The primary content entity.
- **Comment** (`Blog::Comment`): A comment on a post with `body`, `author`, `liked_by_author`, and `post_id` attributes. Always belongs to a post via foreign key.
- **Scaffold CRUD**: The standard Rails scaffold pattern providing `index`, `show`, `new`, `edit`, `create`, `update`, and `destroy` actions with both HTML and JSON response formats.
- **Strong params**: Parameter filtering via Rails 8's `params.expect()` method (not the older `params.require().permit()` pattern).

## Architecture

The application follows standard Rails MVC with a single level of namespacing under `Blog`.

### Request Flow

All requests pass through `ApplicationController`, which enforces modern browser requirements via `allow_browser versions: :modern` and invalidates ETags when the importmap changes via `stale_when_importmap_changes`. Both `Blog::PostsController` and `Blog::CommentsController` inherit from `ApplicationController`.

### Dual-Format Responses

Every CRUD action responds to both HTML and JSON formats:

| Action | HTML response | JSON response |
|--------|--------------|---------------|
| `index` | Renders ERB template iterating over collection | Jbuilder array via partial |
| `show` | Renders ERB template with single record partial | Jbuilder single record via partial |
| `new` | Renders form partial | N/A |
| `edit` | Renders form partial | N/A |
| `create` (success) | Redirects to show with flash notice | Renders show, status 201 |
| `create` (failure) | Re-renders `new`, status 422 | Renders errors JSON, status 422 |
| `update` (success) | Redirects to show with flash notice, status 303 | Renders show, status 200 |
| `update` (failure) | Re-renders `edit`, status 422 | Renders errors JSON, status 422 |
| `destroy` | Redirects to index with flash notice, status 303 | Head 204 no content |

### Model Relationships

`Blog::Comment` declares `belongs_to :post`, establishing a required association to `Blog::Post`. The database enforces this with a foreign key constraint (`add_foreign_key "blog_comments", "posts"`) and an index on `post_id`. `Blog::Post` does not declare a `has_many :comments` association.

### No Model Validations

Neither `Blog::Post` nor `Blog::Comment` defines application-level validations. The only enforcement is the database-level `NOT NULL` constraint on `blog_comments.post_id` (inherited from the `belongs_to` association's implicit `optional: false` default in Rails 8).

### JavaScript

The client-side stack uses Hotwire (Turbo + Stimulus) loaded via importmap. A Stimulus `Application` instance is initialized in `controllers/application.js` with `debug: false`. Controllers are eager-loaded from the `controllers/` directory. A sample `hello_controller.js` exists that sets `textContent` to `"Hello World!"` on connect -- this is a Rails scaffold artifact, not application functionality.

### Asset Pipeline

Propshaft serves assets without preprocessing. The `application.css` manifest file is present but contains only comments -- no application-specific styles are defined.

## Code Organization

| Path | Description |
|------|-------------|
| `controllers/application_controller.rb` | Base controller enforcing modern browser gate and importmap ETag invalidation |
| `controllers/blog/posts_controller.rb` | Full CRUD for `Blog::Post` with `before_action :set_blog_post` on member actions |
| `controllers/blog/comments_controller.rb` | Full CRUD for `Blog::Comment` with `before_action :set_blog_comment` on member actions |
| `models/blog.rb` | Module defining `table_name_prefix "blog_"` |
| `models/blog/post.rb` | `Blog::Post < ApplicationRecord` -- no validations, no associations beyond table defaults |
| `models/blog/comment.rb` | `Blog::Comment < ApplicationRecord` with `belongs_to :post` |
| `models/application_record.rb` | Abstract base class (`primary_abstract_class`) |
| `views/blog/posts/` | ERB templates and jbuilder partials for posts CRUD |
| `views/blog/comments/` | ERB templates and jbuilder partials for comments CRUD |
| `views/layouts/application.html.erb` | Main HTML layout with Propshaft stylesheets and importmap tags |
| `views/layouts/mailer.html.erb` | HTML email layout (default scaffold) |
| `views/layouts/mailer.text.erb` | Plain text email layout (yields only) |
| `views/pwa/manifest.json.erb` | PWA manifest for "HardenDev" (not linked from layout) |
| `views/pwa/service-worker.js` | Commented-out service worker stub (no active functionality) |
| `javascript/application.js` | Entry point importing Turbo and Stimulus controllers |
| `javascript/controllers/application.js` | Stimulus Application setup (`debug: false`) |
| `javascript/controllers/index.js` | Eager-loads all Stimulus controllers |
| `javascript/controllers/hello_controller.js` | Scaffold sample controller (not used by application) |
| `assets/stylesheets/application.css` | Empty CSS manifest (comments only) |
| `helpers/application_helper.rb` | Empty helper module |
| `helpers/blog/posts_helper.rb` | Empty helper module |
| `helpers/blog/comments_helper.rb` | Empty helper module |
| `jobs/application_job.rb` | Base job class (scaffold default, no custom jobs) |
| `mailers/application_mailer.rb` | Base mailer with `from: "from@example.com"` (scaffold default, no custom mailers) |

## View Layer Details

### Posts Views

The post form (`_form.html.erb`) uses `form_with(model: blog_post)` and exposes four fields: `title` (text field), `body` (textarea), `topic` (text field), `author` (text field). Error display renders inline with `style="color: red"` using `pluralize` for the error count header.

The post partial (`_post.html.erb`) renders a `div` with `dom_id(post)` displaying title, body, topic, and author as labeled fields.

The JSON partial (`_blog_post.json.jbuilder`) extracts `id`, `title`, `body`, `topic`, `author`, `created_at`, `updated_at`, plus a `url` field pointing to the JSON show endpoint.

### Comments Views

The comment form (`_form.html.erb`) uses `form_with(model: blog_comment)` and exposes four fields: `post_id` (text field), `body` (textarea), `author` (text field), `liked_by_author` (text field). Error display follows the same pattern as posts.

The comment partial (`_comment.html.erb`) renders a `div` with `dom_id(comment)` displaying post_id, body, author, and liked_by_author as labeled fields.

The JSON partial (`_blog_comment.json.jbuilder`) extracts `id`, `post_id`, `body`, `author`, `liked_by_author`, `created_at`, `updated_at`, plus a `url` field pointing to the JSON show endpoint.

### Layout

The application layout sets a dynamic title via `content_for(:title)` falling back to `"Harden Dev"`. It includes CSRF meta tags, CSP meta tag, a head yield block, Propshaft stylesheet tag (`:app`), and importmap JavaScript tags. PWA manifest link is commented out. Icons reference `/icon.png` and `/icon.svg`.

## Design Decisions

- **Namespace isolation via `table_name_prefix`**: The `Blog` module defines `table_name_prefix "blog_"` rather than using STI or a separate database. This keeps all blog tables in the same SQLite database with a consistent `blog_` prefix, matching the namespace convention.
- **No root route**: The application does not define a root route. The `root "posts#index"` line exists as a comment in `routes.rb` but is not active.
- **PWA disabled**: The PWA manifest route and service worker route are both commented out in `routes.rb`. The manifest link is commented out in the layout. The PWA files exist as scaffolded stubs only.
- **No model validations**: Both models are deliberately bare -- no presence, format, or custom validations. The only constraint enforcement is at the database level (foreign key, NOT NULL on `post_id`).
- **No `has_many` inverse**: `Blog::Post` does not declare `has_many :comments`. Only the `belongs_to` side of the association exists on `Blog::Comment`. This means there is no direct `post.comments` query path from a post instance.
- **`liked_by_author` stored as string**: The `liked_by_author` column on `blog_comments` is a `string` type rather than `boolean`. The form renders it as a text field. No type coercion or boolean casting is applied.
- **Comments use `post_id` text field**: The comment form exposes `post_id` as a raw text input rather than a select/dropdown of existing posts. This is the default scaffold behavior.
- **Strong params via `params.expect()`**: Both controllers use the Rails 8 `params.expect()` pattern for strong parameters rather than the older `params.require().permit()` chain.
- **`destroy!` with bang**: Both controllers call `destroy!` (raising on failure) rather than `destroy` (returning false). Any destroy failure raises an exception rather than being handled gracefully.
- **Record lookup via `params.expect(:id)`**: The `set_blog_post` and `set_blog_comment` callbacks use `params.expect(:id)` for type-safe parameter extraction. An invalid or missing `id` raises `ActionController::ParameterMissing`.
- **Flash notices via redirect options**: Success messages ("Post was successfully created.", etc.) are passed as `notice:` keyword arguments to `redirect_to`, not set via `flash[:notice]` separately.
- **All helpers empty**: The three helper modules (`ApplicationHelper`, `Blog::PostsHelper`, `Blog::CommentsHelper`) are defined but contain no methods. View logic is inline in ERB templates.
- **Inline styles for error display**: Form validation errors use `style="color: red"` directly in the ERB markup rather than CSS classes. This is standard scaffold output.
- **Turbo Drive active by default**: No `data-turbo="false"` attributes are set. All navigation and form submissions go through Turbo Drive. The delete buttons use `button_to` with `method: :delete`, which Turbo handles natively.

## Non-Goals

- **Authentication and authorization**: No user accounts, sessions, or access control. All actions are publicly accessible.
- **Custom styling or UI framework**: No CSS framework, no custom stylesheets. Views use scaffold-generated markup with inline styles.
- **API-only mode**: The application serves both HTML and JSON but is not configured as `ActionController::API`. Full browser support (CSRF, cookies, sessions) is active.
- **Background jobs or mailers**: The `ApplicationJob` and `ApplicationMailer` base classes exist as scaffolds but no concrete jobs or mailers are implemented.
- **Search, pagination, or filtering**: Collection endpoints (`index`) load all records via `.all` with no scoping, pagination, or search.
- **Nested routes**: Comments are not nested under posts in routing. Both resources are top-level within the `blog` namespace (`/blog/comments`, `/blog/posts`).
