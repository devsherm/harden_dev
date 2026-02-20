# App Organization Convention

A conceptual model for categorizing a Rails app's files into lockable ownership tiers. This enables parallel `claude -p` agents to work on the same codebase without file collisions.

The organizing principle: **every file belongs at exactly one level in a four-level hierarchy.** Files are categorized by their most specific consumer. This determines lock contention characteristics — files at higher levels affect more agents when locked.

**This is a conceptual model, not a filesystem mandate.** The Rails app retains its standard directory layout. The hierarchy describes ownership and contention, not physical directory nesting.

---

## 1. Hierarchy

### Level 1: App

Shared across all modules. Write locks on these files have the widest blast radius — they potentially block all merge agents.

| Ownership | Examples |
|---|---|
| App-wide concerns | `app/controllers/concerns/authentication.rb` |
| App-wide views | `app/views/layouts/application.html.erb`, `app/views/shared/` |
| App-wide services | `app/services/shared/` |
| App-wide model concerns | `app/models/concerns/` |

### Level 2: Module

A namespace grouping related domain concepts (e.g., `blog/`, `core/`). Write locks on module-scoped files affect all controllers within the module.

| Ownership | Examples |
|---|---|
| Module models | `app/models/blog/post.rb`, `app/models/blog/comment.rb` |
| Module shared views | Partials shared across controllers within the module |
| Module shared services | `app/services/blog/shared/` |

### Level 3: Controller

A single controller's domain within a module (e.g., `blog/posts/`, `blog/comments/`). Write locks on controller-scoped files affect only that controller's merge agent — other controllers run freely in parallel.

| Ownership | Examples |
|---|---|
| Controller file | `app/controllers/blog/posts_controller.rb` |
| Controller views | `app/views/blog/posts/` (all templates and partials) |
| Controller services | `app/services/blog/posts/` |
| Controller tests | `test/controllers/blog/posts_controller_test.rb` |

### Level 4: Screen (the analysis unit)

A **logical screen** is a coherent UI surface as a human would experience it, identified by a **primary GET action**. This is the fundamental unit of analysis parallelism — screen-level agents each analyze their own scope and produce independent output.

Key properties of a screen:

- **One primary GET action.** The action whose response renders the screen. This is the screen's identity.
- **Zero or more secondary actions.** Non-GET actions (and some GETs like JSON variants) that serve this screen. These may span multiple controllers within the same module.
- **Read scope.** The set of files the screen's analysis agent needs to read, declared in the screen manifest.

Screens exist as metadata entries in a centralized manifest, not as physical directories.

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

This dependency is declared in the screen manifest (see §3) so the locking system can account for it.

---

## 3. Screen Manifest

The screen manifest is a centralized JSON file declaring all screens, their actions, and read dependencies. It is maintained manually (Claude-assisted for initial generation) and lives alongside the pipeline configuration.

### Schema

```json
{
  "screens": [
    {
      "name": "<human-readable screen name>",
      "module": "<module name>",
      "controller": "<controller name>",
      "primary_action": "<Module::Controller#action>",
      "secondary_actions": ["<Module::Controller#action>"],
      "reads_from": [
        "<path relative to rails root>"
      ]
    }
  ]
}
```

### Example: Blog app manifest

```json
{
  "screens": [
    {
      "name": "Posts Index",
      "module": "blog",
      "controller": "posts",
      "primary_action": "Blog::PostsController#index",
      "secondary_actions": ["Blog::PostsController#destroy"],
      "reads_from": []
    },
    {
      "name": "Post Detail",
      "module": "blog",
      "controller": "posts",
      "primary_action": "Blog::PostsController#show",
      "secondary_actions": [
        "Blog::CommentsController#create",
        "Blog::CommentsController#toggle_like",
        "Blog::CommentsController#destroy"
      ],
      "reads_from": [
        "app/views/blog/comments/_comment.html.erb",
        "app/views/blog/comments/_form.html.erb",
        "app/models/blog/comment.rb",
        "app/controllers/blog/comments_controller.rb"
      ]
    },
    {
      "name": "New Post",
      "module": "blog",
      "controller": "posts",
      "primary_action": "Blog::PostsController#new",
      "secondary_actions": ["Blog::PostsController#create"],
      "reads_from": []
    },
    {
      "name": "Edit Post",
      "module": "blog",
      "controller": "posts",
      "primary_action": "Blog::PostsController#edit",
      "secondary_actions": ["Blog::PostsController#update"],
      "reads_from": []
    },
    {
      "name": "Comments Index",
      "module": "blog",
      "controller": "comments",
      "primary_action": "Blog::CommentsController#index",
      "secondary_actions": [],
      "reads_from": []
    },
    {
      "name": "New Comment",
      "module": "blog",
      "controller": "comments",
      "primary_action": "Blog::CommentsController#new",
      "secondary_actions": ["Blog::CommentsController#create"],
      "reads_from": []
    },
    {
      "name": "Edit Comment",
      "module": "blog",
      "controller": "comments",
      "primary_action": "Blog::CommentsController#edit",
      "secondary_actions": ["Blog::CommentsController#update"],
      "reads_from": []
    },
    {
      "name": "Login",
      "module": "core",
      "controller": "sessions",
      "primary_action": "Core::SessionsController#new",
      "secondary_actions": ["Core::SessionsController#create", "Core::SessionsController#destroy"],
      "reads_from": []
    },
    {
      "name": "Registration",
      "module": "core",
      "controller": "registrations",
      "primary_action": "Core::RegistrationsController#new",
      "secondary_actions": ["Core::RegistrationsController#create"],
      "reads_from": []
    }
  ]
}
```

### Rules

- `reads_from` entries are paths relative to the Rails root. These declare files **outside** the screen's own controller scope that the analysis agent needs to read.
- A screen with no cross-screen dependencies has an empty `reads_from` array.
- `reads_from` declares **read** dependencies only. Write targets are determined by the analysis phase output, not the manifest. (See `SPEC.safe_write.md` §5.)
- When `reads_from` is empty, the analysis agent reads from the screen's own controller scope plus app-level shared paths (layouts, concerns).

---

## 4. Contention Tiers

The hierarchy maps directly to lock contention characteristics. Understanding these tiers helps operators predict parallelism and identify bottlenecks.

| Tier | Scope | Contention | Parallelism impact |
|---|---|---|---|
| **Controller** | Files private to one controller | Low | Merge agents for different controllers run freely in parallel |
| **Module** | Files shared within a module | Moderate | Merge agents within the same module may serialize on shared files |
| **App** | Files shared across all modules | High | Any merge agent touching app-scoped files blocks others needing the same files |

The lock manager operates at file granularity — it doesn't know about tiers. Tiers are a mental model for operators to reason about parallelism when reviewing analysis output and write target declarations.

### Minimizing contention

- **Keep files at the lowest possible tier.** A partial used by only one controller belongs in the controller's views, not in `shared/`.
- **Promote consciously.** Moving a file from controller-scoped to module-shared means merge agents from different controllers may contend on it. Each promotion should be deliberate.
- **Declare narrowly.** Analysis agents should identify the specific files that need modification, not broad directories.

---

## 5. Convention Rules

1. **Every file belongs at exactly one level.** Categorize by the most specific consumer. If only one screen uses a partial, it's controller-scoped. Promote only when a consumer in a different controller (or module) appears.

2. **Promotion widens contention.** Moving a file from controller scope to module `shared/` means merge agents for different controllers in that module may contend on it. Moving from module to app scope widens it further. Each promotion is a conscious trade-off between code reuse and parallelism.

3. **Services follow the same hierarchy.** `app/services/<module>/<controller>/` for controller-scoped services, `app/services/<module>/shared/` for module-scoped, `app/services/shared/` for app-wide.

4. **Cross-controller actions require manifest declaration.** When an action in one controller serves a screen owned by another controller (e.g., `CommentsController#create` serving the Post Detail screen), the owning screen must declare the dependency in the manifest's `reads_from`.

5. **Shared files are read-heavy, write-rare.** Files at higher tiers (module, app) are read by many agents but modified rarely. The locking system naturally reflects this — reads don't conflict with reads, so shared files only cause contention during write phases.

6. **JSON endpoints belong to their screen.** `index.json.jbuilder` is part of the Posts Index screen, not a separate API screen. JSON and HTML responses for the same action are co-located in the screen's analysis scope.

---

## 6. Why Screen-Level Organization

The screen level is the right granularity for parallel analysis because:

1. **Screens are naturally independent.** Two humans rarely analyze the same screen simultaneously; the same holds for agents.

2. **Screen-level agents are read-only on app code.** They analyze and document — they don't modify app files. This makes screen-level work embarrassingly parallel.

3. **Cross-screen dependencies are rare and declarable.** Most screens are self-contained. The few that aren't (like Post Detail reading comment templates) can declare their dependencies explicitly in the manifest.

4. **The write phase is naturally coarser.** Controller-level merge agents that actually modify code operate on a bounded file set declared by the analysis phase. They run after all screen-level analysis is complete for their controller.

5. **Screens match cognitive boundaries.** Developers think in screens. Analysis scoped to a screen produces output that's easy for a human operator to review.
