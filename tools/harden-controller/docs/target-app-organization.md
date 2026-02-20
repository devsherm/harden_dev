# App Organization Convention

A convention for organizing a Rails app into lockable units at the logical-screen level. This enables parallel `claude -p` agents to work on the same codebase without file collisions.

The organizing principle: **every file belongs at exactly one level in a four-level hierarchy.** Files start at the most specific level (screen) and are promoted upward only when a second consumer appears. This keeps lock scopes narrow and parallelism high.

---

## 1. Hierarchy

### Level 1: App

Shared across all modules. Changes here affect the entire application.

| Path | Contents |
|---|---|
| `app/views/shared/` | Partials and helpers used across all modules |
| `app/views/layouts/` | Application layout(s) |
| `app/services/shared/` | Services used across modules |
| `app/controllers/concerns/` | App-wide controller concerns (e.g., `authentication.rb`) |
| `app/models/concerns/` | App-wide model concerns |

### Level 2: Module

A namespace grouping related domain concepts (e.g., `blog/`, `core/`). Changes here affect all controllers and screens within the module.

| Path | Contents |
|---|---|
| `app/controllers/<module>/` | Controllers scoped to the module |
| `app/models/<module>/` | Models scoped to the module |
| `app/views/<module>/shared/` | Partials shared across controllers within the module |
| `app/services/<module>/shared/` | Services shared within the module |

### Level 3: Controller

A single controller's domain within a module (e.g., `blog/posts/`, `blog/comments/`). Changes here affect all screens owned by that controller.

| Path | Contents |
|---|---|
| `app/controllers/<module>/<controller>_controller.rb` | The controller file itself |
| `app/views/<module>/<controller>/shared/` | Partials used by multiple screens within the controller (e.g., `_form.html.erb` shared by New and Edit) |
| `app/services/<module>/<controller>/` | Services specific to this controller's domain |

### Level 4: Screen (the lockable unit)

A **logical screen** is a coherent UI surface as a human would experience it, identified by a **primary GET action**. This is the fundamental unit of parallelism — screen-level agents each operate on their own directory and cannot conflict with each other.

| Path | Contents |
|---|---|
| `app/views/<module>/<controller>/<screen>/` | All templates and partials unique to this screen |

Key properties of a screen:

- **One primary GET action.** The action whose response renders the screen. This is the screen's identity.
- **Zero or more secondary actions.** Non-GET actions (and some GETs like JSON variants) that serve this screen. These may span multiple controllers within the same module.
- **Private partials.** A partial in `<screen>/` is private to that screen. Moving it to `shared/` is a conscious promotion that widens the lock scope.

When an action serves two screens, extract the business logic to a shared service or private method at the controller or module level. The action in each screen's controller becomes a thin wrapper calling the shared implementation.

---

## 2. Screen Inventory — Blog App

This inventory maps every route in the blog app to a logical screen.

### Blog module

| Screen | Primary GET | Controller | Other actions serving this screen |
|---|---|---|---|
| Posts Index | `Blog::PostsController#index` | `posts` | `#destroy` (from list) |
| Post Detail | `Blog::PostsController#show` | `posts` | `Blog::CommentsController#create`, `#toggle_like`, `#destroy` |
| New Post | `Blog::PostsController#new` | `posts` | `#create` |
| Edit Post | `Blog::PostsController#edit` | `posts` | `#update` |
| Comments Index | `Blog::CommentsController#index` | `comments` | — |
| New Comment | `Blog::CommentsController#new` | `comments` | `#create` |
| Edit Comment | `Blog::CommentsController#edit` | `comments` | `#update` |

### Core module

| Screen | Primary GET | Controller | Other actions serving this screen |
|---|---|---|---|
| Login | `Core::SessionsController#new` | `sessions` | `#create`, `#destroy` |
| Registration | `Core::RegistrationsController#new` | `registrations` | `#create` |

### Cross-module dependencies

The **Post Detail** screen is the most complex — it renders comments inline with like/edit/delete controls, creating a cross-controller dependency within the blog module:

- `Blog::PostsController#show` renders the post and its comments list
- `Blog::CommentsController#create` handles the inline comment form submission
- `Blog::CommentsController#toggle_like` handles the like button
- `Blog::CommentsController#destroy` handles inline comment deletion

This dependency is declared via `.lockspec.json` (see §4 below) so the locking system can account for it.

---

## 3. Target Directory Structure

The structure below represents the fully organized state. The current blog app uses the standard Rails flat layout; this documents the target convention.

```
app/
  controllers/
    concerns/
      authentication.rb             # Level 1 — app-wide concern
    blog/
      posts_controller.rb           # Level 3 — controller
      comments_controller.rb        # Level 3 — controller
    core/
      sessions_controller.rb        # Level 3 — controller
      registrations_controller.rb   # Level 3 — controller

  models/
    concerns/                       # Level 1 — app-wide model concerns
    current.rb                      # Level 1 — CurrentAttributes
    blog/
      post.rb                       # Level 2 — module model
      comment.rb                    # Level 2 — module model
    core/
      user.rb                       # Level 2 — module model
      session.rb                    # Level 2 — module model

  views/
    layouts/
      application.html.erb          # Level 1 — app layout
    shared/                         # Level 1 — app-wide shared partials

    blog/
      shared/                       # Level 2 — module-wide shared partials

      posts/
        shared/
          _form.html.erb            # Level 3 — shared by New Post + Edit Post
          _blog_post.json.jbuilder  # Level 3 — shared by index + show JSON
        index/                      # Level 4 — "Posts Index" screen
          index.html.erb
          _post.html.erb            # private to index screen
          index.json.jbuilder
        show/                       # Level 4 — "Post Detail" screen
          show.html.erb             # renders comments inline
          show.json.jbuilder
        new/                        # Level 4 — "New Post" screen
          new.html.erb
        edit/                       # Level 4 — "Edit Post" screen
          edit.html.erb

      comments/
        shared/
          _form.html.erb            # Level 3 — shared by New Comment + Edit Comment
        index/                      # Level 4 — "Comments Index" screen
          index.html.erb
          _comment.html.erb         # private to index screen
          index.json.jbuilder
          _blog_comment.json.jbuilder
        new/                        # Level 4 — "New Comment" screen
          new.html.erb
        edit/                       # Level 4 — "Edit Comment" screen
          edit.html.erb

    core/
      sessions/
        new/                        # Level 4 — "Login" screen
          new.html.erb
      registrations/
        new/                        # Level 4 — "Registration" screen
          new.html.erb

  services/
    shared/                         # Level 1 — app-wide shared services
    blog/
      shared/                       # Level 2 — module-wide shared services
      posts/                        # Level 3 — post-specific services
      comments/                     # Level 3 — comment-specific services
    core/
      shared/                       # Level 2 — module-wide shared services
```

---

## 4. Cross-Screen Dependency Declaration

Each screen directory may contain a `.lockspec.json` file declaring read dependencies on files outside the screen's own directory. The locking system uses these declarations to compute lock sets before dispatching agents.

### Schema

```json
{
  "screen": "<human-readable screen name>",
  "primary_action": "<Module::Controller#action>",
  "reads_from": [
    "<path relative to rails root>",
    "..."
  ],
  "reason": "<why this dependency exists>"
}
```

### Example: Post Detail screen

```json
{
  "screen": "Post Detail",
  "primary_action": "Blog::PostsController#show",
  "reads_from": [
    "app/views/blog/comments/",
    "app/models/blog/comment.rb",
    "app/controllers/blog/comments_controller.rb"
  ],
  "reason": "show.html.erb renders comments inline with like/edit/delete controls"
}
```

### Rules

- `reads_from` entries are paths relative to the Rails root. Directories (trailing `/`) mean all files within.
- A screen without cross-screen dependencies does not need a `.lockspec.json`.
- `.lockspec.json` declares **read** dependencies only. Write scope is always the screen's own directory (for screen-level agents) or the controller's directory tree (for controller-level merge agents).
- When a screen has no `.lockspec.json`, the locking system assumes it reads only from app-level shared paths and its own controller's scope.

---

## 5. Convention Rules

1. **Every file lives at exactly one level.** If you're unsure, default to the most specific level (screen) and promote only when a second consumer appears.

2. **Promotion is a conscious decision.** Moving a partial from `<screen>/` to `shared/` widens the lock scope — it now affects all screens in that controller. Moving from controller `shared/` to module `shared/` widens it further. Each promotion should be deliberate.

3. **Services follow the same hierarchy.** `app/services/<module>/<controller>/` for controller-scoped services, `app/services/<module>/shared/` for module-scoped, `app/services/shared/` for app-wide.

4. **Cross-controller actions require dependency declaration.** When an action in one controller serves a screen owned by another controller (e.g., `CommentsController#create` serving the Post Detail screen), the owning screen must declare the dependency in `.lockspec.json`.

5. **Shared directories are read-heavy, write-rare.** Files in `shared/` at any level are read by multiple consumers, so changes to them have a wide blast radius. The locking system treats `shared/` paths as requiring broader locks.

6. **JSON endpoints are part of their screen.** `index.json.jbuilder` belongs to the Posts Index screen, not a separate API screen. JSON and HTML responses for the same action are co-located.

---

## 6. Why Screen-Level Organization

The screen level is the right granularity for parallel agent work because:

1. **Screens are naturally independent.** Two humans rarely edit the same screen simultaneously; the same holds for agents.

2. **Screen-level agents are read-only on app code.** They analyze and document — they don't modify app files. This makes screen-level work embarrassingly parallel. Each agent writes only to its own documentation directory (e.g., `.analysis/blog/posts/show/`).

3. **Cross-screen dependencies are rare and declarable.** Most screens are self-contained. The few that aren't (like Post Detail reading comment templates) can declare their dependencies explicitly.

4. **The write phase is naturally sequential.** Controller-level merge agents that actually modify code are few and operate on a bounded scope. They run after all screen-level analysis is complete.

5. **Lock granularity matches cognitive boundaries.** Developers think in screens. Agents that operate at the screen level produce outputs that are easy for a human operator to review.
