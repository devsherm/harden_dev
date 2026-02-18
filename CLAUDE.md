# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

This is a Rails 8 sandbox application used as the **development environment for a Claude Plugin for Rails development**. The app itself (a Blog with posts and comments) exists as a realistic test bed — not as the end product. Work in this repo focuses on building and testing Claude-assisted Rails tooling against a real Rails codebase.

## Common Commands

```bash
# Setup & run dev server
bin/setup                    # Install deps, prepare DB, start server
bin/setup --skip-server      # Install deps, prepare DB only
bin/dev                      # Start development server

# Testing
bin/rails test               # Run all unit/integration tests
bin/rails test test/models/blog/post_test.rb          # Single test file
bin/rails test test/models/blog/post_test.rb:7         # Single test by line
bin/rails test:system        # Run system (browser) tests

# Linting & security
bin/rubocop                  # RuboCop (omakase preset)
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error  # Security analysis
bin/bundler-audit            # Gem vulnerability scan
bin/importmap audit          # JS dependency audit

# Full CI pipeline (runs setup, rubocop, security scans, tests, seeds)
bin/ci

# Database
bin/rails db:prepare         # Create/migrate
bin/rails db:reset           # Drop, recreate, seed (dev only)
bin/rails db:seed:replant    # Truncate + re-seed
```

## Architecture

**Rails 8.1.2 / Ruby 3.3.1 / SQLite3** with the Solid stack (Solid Cache, Solid Queue, Solid Cable).

### Namespaced Blog module

All application code lives under a `Blog` namespace:

- **Models**: `Blog::Post` and `Blog::Comment` (comment `belongs_to :post`, FK constraint)
- **Controllers**: `Blog::PostsController`, `Blog::CommentsController` — standard scaffold CRUD
- **Routes**: `namespace :blog { resources :posts; resources :comments }`
- **Views**: ERB partials + jbuilder JSON templates under `app/views/blog/`

### Key conventions

- Controllers use `params.expect()` (Rails 8 strong params style)
- `ApplicationController` enforces `allow_browser versions: :modern`
- Code style: RuboCop with `rubocop-rails-omakase` preset (Basecamp/Rails conventions)
- JS: Hotwire (Turbo + Stimulus) via importmap — no Node/npm needed
- Assets: Propshaft (not Sprockets)
- Deployment: Docker + Kamal (config in `config/deploy.yml` and `.kamal/`)

### Database schema

Two tables: `blog_posts` (title, body, topic, author) and `blog_comments` (author, body, liked_by_author, post_id). Foreign key from comments to posts.

### CI pipeline

GitHub Actions (`.github/workflows/ci.yml`) runs in parallel: Brakeman, bundler-audit, importmap audit, RuboCop lint, Rails tests, and system tests. Mirrors `bin/ci` locally.
