# Implementation Plan: Harden-Controller Code Review Fixes

Fixes all high and medium severity findings from `REVIEW.md`. Each item is atomic, leaves the codebase in a working state, and can be committed independently.

**Source of truth:** `REVIEW.md` (finding IDs H1–H4, M1–M8)
**Files in scope:** `tools/harden-controller/{pipeline.rb, server.rb, prompts.rb, index.html}`

---

## Recovery Instructions

- If `ruby -c tools/harden-controller/server.rb` fails after an item, fix the syntax error before moving on.
- If the server won't start (`ruby tools/harden-controller/server.rb`), check for missing requires or broken method signatures introduced by the current item.
- If an item cannot be completed as described, add a `BLOCKED:` note to the item and move to the next one.

---

## Items

- [ ] 1. Guard `@cancelled` reads with mutex
- [ ] 2. Prune completed threads from `@threads`
- [ ] 3. Return `entry.dup` from `find_controller`
- [ ] 4. Move `safe_write` out of mutex block in `run_hardening`
- [ ] 5. Add status guard to `retry_analysis`
- [ ] 6. Replace `$pipeline` reassignment with in-place `reset!`
- [ ] 7. Raise on unknown decision action in `decision_instructions`
- [ ] 8. Move prompts to separate store excluded from SSE
- [ ] 9. Make `/ask` and `/explain` non-blocking
- [ ] 10. Fix XSS in `onclick` handlers and unescaped finding fields

---

### 1. Guard `@cancelled` reads with mutex

**Implements:** REVIEW.md M3 — `@cancelled` not protected by mutex or memory barrier

**File:** `tools/harden-controller/pipeline.rb`

**What to do:**
- Change `cancelled?` (line 50) to acquire `@mutex` before reading `@cancelled`:
  ```ruby
  def cancelled?
    @mutex.synchronize { @cancelled }
  end
  ```
- In `shutdown` (line 54), set `@cancelled = true` inside `@mutex.synchronize`, before copying `@threads`. The existing line 56 already synchronizes for `@threads.dup` — combine them:
  ```ruby
  def shutdown(timeout: 5)
    threads = @mutex.synchronize do
      @cancelled = true
      @threads.dup
    end
    threads.each { |t| t.join(timeout) }
    threads.each { |t| t.kill if t.alive? }
  end
  ```

**Not in scope:** No changes to `safe_thread`, `spawn_with_timeout`, or any caller of `cancelled?`. Those already call it outside the mutex and that's fine — the fix here is making the read/write individually atomic.

**Done when:** `cancelled?` reads under mutex. `shutdown` sets `@cancelled` under the same mutex acquisition that copies `@threads`. `ruby -c pipeline.rb` passes.

**Testing:** Structural review only — no automated tests exist for this tool.

---

### 2. Prune completed threads from `@threads`

**Implements:** REVIEW.md M4 — `@threads` array grows without bound

**File:** `tools/harden-controller/pipeline.rb`

**What to do:**
- In `safe_thread` (line 46), prune dead threads before appending the new one. Inside the existing `@mutex.synchronize` block:
  ```ruby
  @mutex.synchronize do
    @threads.reject! { |t| !t.alive? }
    @threads << t
  end
  ```

**Not in scope:** No thread pool, no max-thread limit, no changes to `shutdown`. The prune-on-add pattern is sufficient for this workload (single-digit concurrent workflows).

**Done when:** `safe_thread` prunes dead threads from `@threads` before adding the new thread. `ruby -c pipeline.rb` passes.

**Testing:** Structural review only.

---

### 3. Return `entry.dup` from `find_controller`

**Implements:** REVIEW.md M2 — `find_controller` returns mutable reference to shared state

**File:** `tools/harden-controller/pipeline.rb`

**What to do:**
- In `find_controller` (line 601), change the return to `entry.dup`:
  ```ruby
  def find_controller(name)
    entry = @mutex.synchronize { @state[:controllers].find { |c| c[:name] == name } }
    raise "Controller not found: #{name}" unless entry
    entry.dup
  end
  ```

**Not in scope:** No deep-freeze of the controllers array. Callers only read top-level keys (`:name`, `:path`, `:full_path`), so a shallow dup is sufficient.

**Done when:** `find_controller` returns a dup'd hash. `ruby -c pipeline.rb` passes.

**Testing:** Structural review only.

---

### 4. Move `safe_write` out of mutex block in `run_hardening`

**Implements:** REVIEW.md H2 — `safe_write` called inside `@mutex.synchronize` blocks all state access during disk I/O

**File:** `tools/harden-controller/pipeline.rb`

**What to do:**
- In `run_hardening` (lines 247–255), the `@mutex.synchronize` block currently calls `safe_write(wf[:full_path], parsed["hardened_source"])` while holding the lock. Restructure to:
  1. Capture `write_path = wf[:full_path]` and `hardened_source_content = parsed["hardened_source"]` inside the mutex block.
  2. Close the mutex block.
  3. Call `safe_write(write_path, hardened_source_content)` outside the mutex if `hardened_source_content` is present.
  4. Re-acquire the mutex to set `wf[:hardened]`, `wf[:status]`, and `wf[:prompts][:harden]`.

  The resulting code should look like:
  ```ruby
  write_path = hardened_source_content = nil
  @mutex.synchronize do
    wf = @state[:workflows][name]
    wf[:original_source] = source
    wf[:hardened] = parsed
    wf[:status] = "hardened"
    wf[:prompts][:harden] = prompt
    write_path = wf[:full_path]
    hardened_source_content = parsed["hardened_source"]
  end

  safe_write(write_path, hardened_source_content) if hardened_source_content
  ```

**Not in scope:** The test-fix path (line 324) and CI-fix path (line 441) already write outside the mutex — leave those unchanged. Do not change `write_sidecar` calls (they are not under mutex). Do not remove `prompts` storage here — that's item 9.

**Done when:** `safe_write` in `run_hardening` executes outside `@mutex.synchronize`. The workflow state fields (`original_source`, `hardened`, `status`) are still set atomically under mutex. `ruby -c pipeline.rb` passes.

**Testing:** Structural review only.

---

### 5. Add status guard to `retry_analysis`

**Implements:** REVIEW.md M6 — `retry_analysis` has no status guard, can double-run a workflow

**Files:** `tools/harden-controller/pipeline.rb`, `tools/harden-controller/server.rb`

**What to do:**
- In `retry_analysis` (pipeline.rb lines 583–590), add a status guard inside the mutex block. Only allow retry when the workflow is in `"error"` status:
  ```ruby
  def retry_analysis(name)
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      return { error: "No workflow for #{name}" } unless workflow
      return { error: "#{name} is not in error state" } unless workflow[:status] == "error"
      workflow[:error] = nil
    end

    safe_thread(workflow_name: name) { run_analysis(name) }

    { status: "retrying" }
  end
  ```
- In the `/pipeline/retry` endpoint (server.rb lines 220–228), add a server-side status guard matching the pattern from `/pipeline/retry-tests` and `/pipeline/retry-ci`:
  ```ruby
  post "/pipeline/retry" do
    content_type :json
    body = parse_json_body
    controller = body["controller"]
    halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

    workflow = $pipeline.state[:workflows][controller]
    halt 404, { error: "No workflow for #{controller}" }.to_json unless workflow
    halt 409, { error: "#{controller} is not in error state" }.to_json unless workflow[:status] == "error"

    result = $pipeline.retry_analysis(controller)
    result.to_json
  end
  ```

**Not in scope:** No changes to `retry_tests` or `retry_ci` — they already have guards.

**Done when:** Both `retry_analysis` in pipeline.rb and `/pipeline/retry` in server.rb reject retries unless the workflow is in `"error"` status. `ruby -c pipeline.rb && ruby -c server.rb` passes.

**Testing:** Structural review only.

---

### 6. Replace `$pipeline` reassignment with in-place `reset!`

**Implements:** REVIEW.md H1 — `$pipeline` race condition on reset

**Files:** `tools/harden-controller/pipeline.rb`, `tools/harden-controller/server.rb`

**Requires:** Items 1–2 (mutex-guarded `@cancelled`, thread pruning)

**What to do:**
- Add a `reset!` method to `Pipeline` (pipeline.rb). This method should:
  1. Call `shutdown(timeout: 3)` to stop in-flight threads and set `@cancelled`.
  2. Under `@mutex`, reset all state back to initial values and clear `@cancelled`:
     ```ruby
     def reset!
       shutdown(timeout: 3)
       @mutex.synchronize do
         @cancelled = false
         @threads.clear
         @state[:phase] = "idle"
         @state[:controllers] = []
         @state[:workflows] = {}
         @state[:errors] = []
       end
     end
     ```
- In server.rb, replace the `/pipeline/reset` handler (lines 103–110):
  ```ruby
  post "/pipeline/reset" do
    content_type :json
    $pipeline.reset!
    $pipeline.safe_thread { $pipeline.discover_controllers }
    { status: "reset" }.to_json
  end
  ```
  This eliminates the `$pipeline` reassignment entirely — all request threads and the SSE loop keep their reference to the same object.

**Not in scope:** No module-level mutex around `$pipeline`. The `reset!` approach makes `$pipeline` effectively a constant. Do not change `$pipeline.shutdown` in `/shutdown` endpoint — that's a separate concern (L5).

**Done when:** `$pipeline` is assigned exactly once (at startup). `/pipeline/reset` calls `reset!` on the existing instance. `ruby -c pipeline.rb && ruby -c server.rb` passes.

**Testing:** Structural review. Manual verification: start server, trigger an analysis, hit `/pipeline/reset` mid-flight, confirm the server doesn't crash and discovery restarts.

---

### 7. Raise on unknown decision action in `decision_instructions`

**Implements:** REVIEW.md M5 — `decision_instructions` silently defaults to "apply all" on unknown action

**File:** `tools/harden-controller/prompts.rb`

**What to do:**
- In `decision_instructions` (line 296–308), replace the `else` branch with a raise:
  ```ruby
  else
    raise ArgumentError, "Unknown decision action: #{decision["action"].inspect}"
  end
  ```

**Not in scope:** No changes to callers. The `run_hardening` method already has a `rescue => e` that will catch this and set the workflow to error state.

**Done when:** `decision_instructions` raises `ArgumentError` for any action other than `"approve"`, `"modify"`, or `"selective"`. `ruby -c prompts.rb` passes.

**Testing:** Structural review only.

---

### 8. Move prompts to separate store excluded from SSE

**Implements:** REVIEW.md M7 — Prompt storage in workflow state causes SSE bloat

**Files:** `tools/harden-controller/pipeline.rb`, `tools/harden-controller/server.rb`

**What to do:**
- In `Pipeline#initialize` (pipeline.rb), add a `@prompt_store` hash alongside `@state`:
  ```ruby
  @prompt_store = {}  # keyed by "controller_name/phase"
  ```
- Add a public method to retrieve prompts:
  ```ruby
  def get_prompt(controller_name, phase)
    @mutex.synchronize { @prompt_store.dig(controller_name, phase) }
  end
  ```
- Replace all `wf[:prompts][:phase] = prompt` assignments (lines 194, 255, 320, 437, 533) with `@prompt_store` writes. Do this under the existing mutex block where each assignment lives:
  ```ruby
  # Instead of: wf[:prompts][:analyze] = prompt
  @prompt_store[name] ||= {}
  @prompt_store[name][:analyze] = prompt
  ```
  Apply this pattern for all five phases: `:analyze`, `:harden`, `:fix_tests`, `:fix_ci`, `:verify`.
- Remove the `:prompts` key from `build_workflow` (line 622). The workflow hash no longer carries prompts.
- Clear the controller's prompt store entry in `reset!` (item 6 already adds this method) — add `@prompt_store.clear` alongside the state reset.
- In server.rb, add a dedicated endpoint:
  ```ruby
  get "/pipeline/:name/prompts/:phase" do
    content_type :json
    prompt = $pipeline.get_prompt(params[:name], params[:phase].to_sym)
    halt 404, { error: "No prompt found" }.to_json unless prompt
    { controller: params[:name], phase: params[:phase], prompt: prompt }.to_json
  end
  ```

**Not in scope:** No frontend changes to fetch prompts from the new endpoint — the frontend doesn't currently display prompts. No changes to `to_json` serialization logic (removing `:prompts` from the workflow hash is sufficient to stop it from being serialized).

**Done when:** Prompts are stored in `@prompt_store`, not in workflow state. `to_json` output no longer contains prompt text. New `/pipeline/:name/prompts/:phase` endpoint returns the prompt for a given controller and phase. `ruby -c pipeline.rb && ruby -c server.rb` passes.

**Testing:** Structural review. Manual verification: start server, run an analysis, confirm the SSE `data:` payloads no longer contain prompt text. Hit `/pipeline/<controller>/prompts/analyze` and confirm it returns the prompt.

---

### 9. Make `/ask` and `/explain` non-blocking

**Implements:** REVIEW.md H3 — `/ask` and `/explain` block request threads for up to 120 seconds

**Files:** `tools/harden-controller/pipeline.rb`, `tools/harden-controller/server.rb`, `tools/harden-controller/index.html`

**Requires:** Item 9 (prompt store pattern established)

**What to do:**

**pipeline.rb:**
- Add a `@queries` array to `Pipeline#initialize` to store async query results:
  ```ruby
  @queries = []  # [{id:, controller:, type:, question:, finding_id:, status:, result:, error:, created_at:}]
  ```
- Add `@queries` to the `to_json` output so the frontend receives them via SSE. In `to_json`:
  ```ruby
  def to_json(*args)
    @mutex.synchronize { @state.merge(queries: @queries).to_json(*args) }
  end
  ```
- Clear `@queries` in `reset!`.
- Refactor `ask_question` to be async — create a query record, spawn a thread, return the query ID:
  ```ruby
  def ask_question(name, question)
    query_id = "ask_#{Time.now.to_f}"
    @mutex.synchronize do
      workflow = @state[:workflows][name]
      return { error: "No workflow for #{name}" } unless workflow
      @queries << { id: query_id, controller: name, type: "ask", question: question,
                    status: "pending", result: nil, error: nil, created_at: Time.now.iso8601 }
    end

    safe_thread do
      begin
        source_path = ctrl_name = analysis_json = nil
        @mutex.synchronize do
          wf = @state[:workflows][name]
          source_path = wf[:full_path]
          ctrl_name = wf[:name]
          analysis_json = (wf[:analysis] || {}).to_json
        end

        source = File.read(source_path)
        prompt = Prompts.ask(ctrl_name, source, analysis_json, question)
        answer = claude_call(prompt)

        @mutex.synchronize do
          q = @queries.find { |q| q[:id] == query_id }
          q[:status] = "complete"
          q[:result] = answer
        end
      rescue => e
        @mutex.synchronize do
          q = @queries.find { |q| q[:id] == query_id }
          q[:status] = "error"
          q[:error] = e.message
        end
      end
    end

    { query_id: query_id }
  end
  ```
- Apply the same pattern to `explain_finding` — create a query record with `type: "explain"`, spawn a thread, return query ID.

**server.rb:**
- Change `POST /ask` to return the query ID immediately (HTTP 202):
  ```ruby
  post "/ask" do
    content_type :json
    body = parse_json_body
    controller = body["controller"]
    question = body["question"]
    halt 400, { error: "No controller specified" }.to_json if controller.nil? || controller.empty?

    result = $pipeline.ask_question(controller, question)
    status 202
    result.to_json
  end
  ```
- Apply the same change to `POST /explain/:finding_id`.

**index.html:**
- Add a queries section to the workflow detail view that renders items from `state.queries` filtered to the current controller. Show pending queries with a spinner and completed queries with the rendered answer.
- Use `escapeHtml()` on all query-derived content (question text, answer text, error messages).
- When the user submits a question via the ask input, the existing `fetch('/ask', ...)` call still works — it just gets back a `query_id` instead of an `answer`. Remove the inline alert/display of the answer; the SSE-driven queries section handles it.

**Not in scope:** No query pagination or cleanup. No dismiss/delete for completed queries. The queries array will grow for the session but is cleared on `reset!`.

**DECISION POINT:** The queries array is included in SSE state, which means answers (potentially large markdown) are broadcast on every tick until the session resets. This is acceptable for a local dev tool with single-digit queries per session. If it becomes a problem, a follow-up can move completed queries to a separate store (same pattern as item 9). Default: include in SSE.

**Done when:** `POST /ask` and `POST /explain/:finding_id` return HTTP 202 immediately with a `query_id`. The Claude call runs in a background thread. Results appear in the SSE stream under `state.queries`. The frontend renders pending and completed queries. `ruby -c pipeline.rb && ruby -c server.rb` passes.

**Testing:** Structural review. Manual verification: start server, load an analysis, submit an ask question, confirm the endpoint returns immediately (< 1s), confirm the answer appears in the UI after the Claude call completes.

---

### 10. Fix XSS in `onclick` handlers and unescaped finding fields

**Implements:** REVIEW.md H4 (XSS via controller names in `onclick` handlers), REVIEW.md M8 (`finding.category` and `finding.action` rendered without `escapeHtml`)

**File:** `tools/harden-controller/index.html`

**What to do:**

**H4 — onclick handlers:**
- Add an `escapeAttr` helper alongside the existing `escapeHtml`:
  ```javascript
  function escapeAttr(str) {
    return String(str).replace(/&/g,'&amp;').replace(/'/g,'&#39;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }
  ```
- Find every `onclick="...('${c.name}')"` and `onclick="...('${finding.id}')"` pattern in the template literals. Replace the interpolated values with `escapeAttr()`:
  ```javascript
  // Before:
  onclick="analyzeController('${c.name}')"
  // After:
  onclick="analyzeController('${escapeAttr(c.name)}')"
  ```
- Apply to all occurrences. These include (at minimum): `analyzeController`, `loadAnalysis`, `retryAnalysis`, `submitDecision`, `retryTests`, `retryCi`, `explainFinding`, and any other functions called from onclick with interpolated values.

**M8 — unescaped finding fields:**
- Find all locations where `finding.category` and `finding.action` are rendered in the HTML. Wrap them in `escapeHtml()`:
  ```javascript
  // Before:
  ${finding.category}
  // After:
  ${escapeHtml(finding.category || '')}
  ```
- Apply the same treatment to `finding.action`.

**Not in scope:** No migration to `data-` attributes + event delegation. The `escapeAttr` approach is sufficient and lower-risk than a structural refactor of the event binding. M9 (full DOM re-render) is not addressed here.

**Done when:** All `onclick` handler interpolations use `escapeAttr()`. All `finding.category` and `finding.action` renders use `escapeHtml()`. A controller file named `test'_controller.rb` would not break the UI or execute injected JS. The HTML file is syntactically valid.

**Testing:** Structural review. Manual verification: confirm the UI renders correctly for a normal controller. Optionally test with a mock controller name containing `'<script>` to confirm it's escaped.
