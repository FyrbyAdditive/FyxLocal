# FyxLocal 0.7.0 — Release Test Schedule

Covers all changes since 0.6.5. Sessions are ordered so each reuses the
previous one's setup. Tick as you go; anything that fails, note the step
number and what happened.

**Build under test:** `make-app.sh` release build (`build/FyxLocal.app`),
version 0.7.0.

---

## Session 0 — Automated gates (~5 min, terminal)

- [ ] 0.1 `FCHAT_SKIP_MLX=1 swift test --skip "CodeSandbox"` → all suites pass (≈745 tests / 122 suites).
- [ ] 0.2 `swift test --filter CodeSandbox` (run separately; flaky only under nested sandboxes) → 9/9.
- [ ] 0.3 `FCHAT_MCP_E2E=1 swift test --filter MCPEverythingE2ETests` (needs node/npx) → 4/4 against the real everything server.

## Session 1 — MCP tasks, elicitation & live status (everything server)

Setup: Settings → MCP → “server everything” (`npx -y @modelcontextprotocol/server-everything`) enabled. Any chat.

- [ ] 1.1 Ask the model to run `simulate-research-query` with a topic. → No `-32601 requires task augmentation`; tool card shows live stage text ("Gathering sources…" → …); final report renders.
- [ ] 1.2 Same tool with `ambiguous=true`. → Elicitation sheet appears naming **server everything**, enum picker marked Required; pick an option → **Accept** → report reflects the chosen interpretation.
- [ ] 1.3 Repeat 1.2 but press **Esc** (cancel). → Task still completes with a default interpretation; no hang.
- [ ] 1.4 Repeat 1.2 but click **Decline**. → Same graceful completion.
- [ ] 1.5 Sloppy-argument tolerance: if a call ever fails with `Invalid task creation result`, that's a regression — the client should coerce `ambiguous: 1` → `true` before sending. (Hard to force; watch for it across 1.1–1.4 retries.)
- [ ] 1.6 Mid-task cancel: start 1.1 and hit the stop button while stages tick. → Turn stops; card shows cancelled/failed state; no beachball; server not wedged (next call works).

## Session 2 — MCP resources, prompts & tool refresh (same server)

- [ ] 2.1 Inspector → **MCP servers** → expand “server everything”. → Resources listed with type icons; prompts listed below.
- [ ] 2.2 **Attach** a text resource. → Appears as a composer attachment chip; send a message referencing it → model sees the content.
- [ ] 2.3 Attach a binary (non-image) resource. → Friendly “can't be attached” message, no crash.
- [ ] 2.4 **Use** a prompt without arguments. → Its text prefills the composer (not auto-sent).
- [ ] 2.5 **Use** a prompt with arguments. → Argument sheet appears; required-field validation works; Insert prefills the composer.
- [ ] 2.6 Tool-list refresh: while connected, toggle the everything server's `TOGGLE_TOOLS`-style behaviour if available, or restart the server process externally and reconnect — after a `tools/list_changed` the Settings card tool count updates without a manual reconnect. (Best-effort: the everything server emits list_changed periodically when configured; otherwise rely on unit coverage.)

## Session 3 — Anthropic prompt caching (needs api.anthropic.com provider)

Setup: a provider with API type “Anthropic Messages” and a real Anthropic key. DeepSeek's Anthropic endpoint *ignores* caching — metrics stay zero there; that's expected.

- [ ] 3.1 Settings → Providers → Anthropic card shows a **Prompt caching** toggle, ON by default.
- [ ] 3.2 First message of a fresh chat (with tools enabled). → Metrics line shows `N cache write`.
- [ ] 3.3 Second message within 5 minutes. → Metrics line shows `N cached` (read) ≫ 0.
- [ ] 3.4 Turn with tool calls. → Later iterations show large `cached` counts (loop reuse).
- [ ] 3.5 Toggle caching OFF, send again. → No cache metrics; request still succeeds (string-form system prompt).
- [ ] 3.6 DeepSeek-via-Anthropic provider still works end-to-end (field silently ignored).

## Session 4 — RAG: dedup, citations, new formats

Setup: Collections pane, a test collection.

- [ ] 4.1 Drop a folder of documents. → Summary reads “N added”.
- [ ] 4.2 Drop the **same folder again**. → “N unchanged”, fast (no re-embed); document count unchanged.
- [ ] 4.3 Edit one file in the folder, re-drop. → “1 updated, N-1 unchanged”; only one document row for that file.
- [ ] 4.4 Delete a document from the collection, then rag_search for its content. → No hits from the deleted doc (vector-orphan regression check — restart the app between delete and search for the strict version).
- [ ] 4.5 In a chat with the collection attached, ask something answerable from a document. → rag_search result renders as a **citation list** (name · page · section · snippet · score), not raw JSON.
- [ ] 4.6 Click a citation's document name. → Original file opens. Right-click → Reveal in Finder works.
- [ ] 4.7 Move/rename that source file on disk, ask again. → Citation renders non-clickable with “Original file not found” tooltip; no crash.
- [ ] 4.8 Drop an **.xlsx**. → Ingests; kind “xlsx”, table icon; search finds cell text; sheet name appears as section in citations.
- [ ] 4.9 Drop an **.epub** (DRM-free). → Ingests; chapters searchable; a DRM'd epub fails with a readable parse error (not a crash).
- [ ] 4.10 Drop a **screenshot with text** (png/jpg). → Ingests via OCR; the visible text is searchable. A text-free photo ingests with empty text (no error).
- [ ] 4.11 Old transcripts from 0.6.5 still render their rag_search results (raw JSON fallback acceptable for undecodable old payloads; new-shape ones get the citation list).

## Session 5 — Thinking pill & general regression

- [ ] 5.1 Ask a long-reasoning question (reasoning effort high). → Pill sits **below** the growing reasoning block, staying visible just above the composer the whole time.
- [ ] 5.2 Tool-heavy query (e.g. “find me the latest EU news today”). → Pill visible during *every* silent phase: before first text, while digesting tool results, between tool rounds. It hides only while answer text is streaming.
- [ ] 5.3 Earlier reasoning blocks stay **collapsed** when a later thinking phase starts (only the newest expands).
- [ ] 5.4 Back-compat: launch 0.7.0 against your existing state.json. → All conversations load; save a chat; `grep progressMessage ~/Library/…/FyxLocal/state.json` → no hits (transient field never persisted).
- [ ] 5.5 Localization spot-check: switch system language to Spanish → new UI strings (elicitation sheet, ingest summary, Attach/Use, caching toggle) render translated.
- [ ] 5.6 Ten minutes of normal use (scrolling, switching chats, editing titles) → no beachball. If one appears: `sample FyxLocal 3` and save the output.

## Known limits (don't file as bugs)

- Prompt-cache metrics are zero on non-Anthropic gateways (expected).
- xlsx dates/formulas show raw serials/cached values.
- Resource subscriptions, resource templates, URL-mode elicitation, folder auto-sync, PDF page deep-links, scanned-PDF OCR: deferred, not in 0.7.0.
