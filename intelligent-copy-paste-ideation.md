# Intelligent Copy‑Paste — Ideation & Product Spec

> **One‑liner:** *Copy once, paste perfectly.* A context‑aware paste engine that transforms whatever’s on your clipboard into the right format for the app and field you’re pasting into—automatically, with a quick chooser when needed.

---

## 0) TL;DR

- **Problem:** Copy/paste is dumb. Users manually fix formatting, tables, code blocks, links, and trackers every day. Existing clipboard managers require manual action and aren’t target‑app aware.
- **Solution:** A **target‑aware** paste that inspects (a) the **destination context** (app, window, field) and (b) the **clipboard payload** (HTML/RTF/plain, table, code, URL, image, PDF), then applies a **best‑guess recipe** (deterministic first, AI only if needed). One keystroke, instant results.
- **Why now:** OSes expose enough signals (bundle ID, accessibility tree, browser URL). Deterministic transforms are robust; optional local/LLM helpers are now good enough for rare “rewrite/summarize” cases.
- **Scope:** Mac first, Windows next. Menubar app + optional browser extension. Small, opinionated, local‑first MVP that can ship in 4–6 weeks.
- **Monetization:** Free tier + Pro ($5–8/mo) for unlimited “smart pastes,” per‑app profiles, OCR‑to‑table, AI fallback, and sync.

---

## 1) Goals & Non‑Goals

### Goals
1. **Zero‑friction paste**: Default behavior should “just work” for the most common cases (Slack, Notion, Google Docs, Excel, VS Code, Apple Notes, Outlook/Gmail web).  
2. **Deterministic first**: Prefer fast, local, explainable transforms; show a **palette** to override and learn from overrides.  
3. **Per‑app memory**: Learn user preferences per (content type × target app/field).  
4. **Privacy**: Local‑first. No clipboard history unless explicitly enabled. No network calls without explicit consent.  
5. **Performance**: <10ms decision budget for common cases; <60ms for complex table or HTML normalization; AI calls async and opt‑in.

### Non‑Goals (MVP)
- Full clipboard history manager (we only need last item; history is an opt‑in extra).  
- Cross‑device sync (v1 feature).  
- Rich automation framework like Keyboard Maestro (we provide a simple **Recipe DSL** and JS hooks, not a full macro engine).  
- Mobile (iOS/Android not in scope initially).

---

## 2) Users, Personas, and Use Cases

### Personas
- **Ops/RevOps**: lives in Sheets/Excel, Notion/Confluence, Jira. Constant table cleanup, URL sanitization.  
- **Engineers**: pasting code into Docs/Notion/Confluence; stripping ANSI; fencing; aligning indents.  
- **PM/Analyst**: copying web tables/charts/snippets into docs; converting meeting invite text into structured blocks.  
- **Support/Success**: pasting ticket links (Jira, Zendesk) as readable titles; cleaning customer data (addresses, phone numbers).

### High‑value Use Cases
1. **Table from anywhere → structured**: HTML/PDF/screenshot table → Markdown/CSV in Notion/Docs/Sheets.  
2. **URL → smart link**: Strip trackers; fetch title; paste `Title — domain.tld` with preserved hyperlink.  
3. **Code → fenced block**: Detect language; fix indentation; strip ANSI; add ```lang fences for docs.  
4. **Styled text → match destination style**: Keep links, drop inline styles, preserve bullets and headings.  
5. **Jira/GitHub issue link → rich chip**: `#123 · Title · Status` (no API key required for public; optional for private).  
6. **Email signature → contact**: Parse name/title/company/phone → paste as vCard block or CSV columns.  
7. **Address → appropriate format**: Single‑line for spreadsheets; multi‑line for labels; detect the destination field type.  
8. **Meeting invite → compact card**: Title, date/time, join link, passcode, organizer; collapse boilerplate.

---

## 3) Product Experience

### 3.1 Paste Flow
- **Default paste** (`⌘V`): Run classifier → choose top recipe → paste result.  
- **Palette paste** (hold `⌘V` or press `⇧⌘V`): Show **Paste Palette** with:  
  - Top recommendation (preview).  
  - 2–4 alternates (Plain, Markdown, Table, Link+Title, Code Block, Quote).  
  - Quick keys `1..5` or arrow+Enter.  
- **Mini HUD** after paste: “Converted HTML → Markdown · Undo · Always use this here.”

### 3.2 Per‑App Profiles
- Simple toggles per app:  
  - **Slack**: paste as plain text by default; treat `code` as triple‑backticks.  
  - **Notion**: prefer Markdown; convert tables.  
  - **Google Docs**: match style; keep links; convert headings & bullets.  
  - **Excel/Sheets**: prefer CSV/TSV; coerce address to single line.  
- Profile overrides are remembered and editable in Settings.

### 3.3 Teach Mode
- First time in each app, show the palette and record the selection.  
- Over time, the ranking model biases toward what you choose for that (content × app) combo.  
- “Reset learning” per app available.

---

## 4) Functional Spec

### 4.1 Destination Context Detection
- **Signals**: frontmost bundle ID, window title, focused element traits (AXRole/AXSubrole), clipboard type negotiation; optional browser URL via extension (Chrome/Safari).  
- **Field hints**: detect “code editor” (monospaced, spellcheck off), “rich text” (RTF/HTML), “plain text,” “spreadsheet cell,” “search field,” “URL bar.”  
- **Confidence**: compute a destination confidence score to gate certain transforms (e.g., don’t paste CSV into a search field).

### 4.2 Clipboard Classifier
- Inputs: NSPasteboard/CFPasteboard flavors (public.utf8‑plain‑text, public.html, public.rtf, TIFF/PNG, PDF), payload size, first bytes.  
- Heuristics:  
  - **URL**: regex for schemes + TLD, path/query sniff.  
  - **HTML**: presence of `<table>`, `<a>`, `<li>`, `<pre><code>`.  
  - **Code**: language hints (shebangs, braces/keywords density), ANSI sequences.  
  - **Table**: delimiter sniff (`,` `;` `	`), constant column count across lines, HTML table.  
  - **Address/Phone**: libpostal/phonelib validation (offline).  
  - **Invite**: meeting providers patterns, ICS hints in text.  
  - **Image/PDF**: defer to OCR pipeline on demand.

### 4.3 Recipe Engine
- **Deterministic transforms** (synchronous): HTML→Markdown, “match style,” table normalizer, link sanitizer, code fence/indent fixer, quote/bullet cleanup, smart dashes/quotes normalization, JSON↔CSV, address reformat, email‑sig→vCard.  
- **AI transforms** (async/opt‑in): rewrite tone, summarize selection, extract key fields from messy text when heuristics fail.  
- **Ranking**: `score = w_app · P(recipe|app) + w_field · P(recipe|field) + w_content · P(recipe|content) + w_user · habit_bias`  
- **Learning**: on override, increment counts for (app, field, content) → chosen recipe; exponential decay to remain adaptable.

### 4.4 Transform Library (MVP)
- **Plain (match destination style)**: strip inline styles, preserve hyperlinks, semantic lists/headings.  
- **Markdown**: HTML→GFM; normalize code fences; escape pipes/backticks.  
- **Table**: HTML→Markdown table or CSV; CSV delimiter detection; quote escaping; column width normalization.  
- **Smart Link**: fetch `<title>` (via headless request or from the page if browser extension present), strip `utm_*` and known trackers, output `[Title](URL)` or `Title — domain`.  
- **Code Block**: detect language; correct indentation; wrap with ```lang; remove ANSI.  
- **Quote/Excerpt**: prefix `>`; wrap long lines.  
- **Address Format**: single‑line vs multi‑line; normalize punctuation; preserve diacritics.  
- **Email Signature → vCard block/CSV**: regex+NER hybrid for name/title/company/phone/email; confidence thresholds.  
- **Invite → Card**: title, date/time (with timezone), join URL, passcode; collapse boilerplate.

### 4.5 OCR & “From Anything” Tables
- macOS **Vision** for on‑device OCR; cell boundary heuristics (rulings, whitespace bands); Levenshtein smoothing for header rows.  
- Windows: Tesseract or PowerToys interop; same table extractor.  
- Output: Markdown/CSV; preview in palette.

### 4.6 Browser Extension (Optional, High Value)
- Read current tab URL and `<title>` for target‑aware decisions when pasting into web apps (Docs/Sheets/Gmail).  
- Content script offers origin‑scoped API: “focus type hint” (contenteditable vs input vs code mirror).  
- Never exfiltrate page content; just surface minimal signals.

---

## 5) Architecture

### 5.1 Components
- **Core App (Swift/Obj‑C on macOS)**: menubar UI, hotkeys, paste interception, accessibility queries, transform engine, settings.  
- **Transform Workers**:  
  - **HTML/Markdown pipeline** (Down/Showdown or custom parser).  
  - **Table parser** (delimiter sniff + HTML table walker).  
  - **Code tools** (langid via fast heuristics; ANSI stripper).  
  - **Address/Contact** (libpostal, phonelib).  
  - **OCR** (Vision/Tesseract).  
- **Browser Extension** (Chrome/Safari): optional hints.  
- **Local DB** (SQLite): preferences, per‑app recipes, tiny ranking tables, audit log.  
- **Plugin Host** (v1): JS/TS transforms sandboxed via Deno/Node, constrained by time/memory.

### 5.2 Data Model (SQLite)
- `apps(id TEXT PRIMARY KEY, name TEXT)`  
- `recipes(id TEXT PRIMARY KEY, name TEXT, kind TEXT)`  
- `prefs(app_id TEXT, recipe_id TEXT, content_type TEXT, field_type TEXT, weight REAL, PRIMARY KEY(app_id, recipe_id, content_type, field_type))`  
- `events(ts INTEGER, app_id TEXT, content_type TEXT, chosen_recipe TEXT, override INTEGER)`  
- `settings(key TEXT PRIMARY KEY, value TEXT)`

### 5.3 Paste Event Flow
1. User presses `⌘V`.  
2. Read destination context (bundle ID, field traits).  
3. Inspect clipboard flavors; classify content.  
4. Generate candidate recipes; compute scores; pick top.  
5. If **hold** or **low confidence**, show Palette.  
6. Run transform; copy result to a private pasteboard; send synthetic paste (or inject text).  
7. Show Mini HUD; record event (override? success?).

### 5.4 Pseudocode (Selection + Learning)

```pseudo
onPaste(event):
  ctx = detectDestination()        // app, window, fieldType, url?
  clip = readClipboardFlavors()    // html, rtf, plain, image, pdf
  cType = classify(clip)           // url|html|table|code|address|invite|plain|image|pdf
  candidates = recipesFor(cType)
  for r in candidates:
    s = w_app*p(r|ctx.app) + w_field*p(r|ctx.field) + w_ct*p(r|cType) + w_user*habitBias(ctx, cType, r)
    rank[r] = s
  pick = argmax(rank)
  if isHeldModifier() or lowConfidence(rank):
    pick = showPalette(rank, preview=transformedSamples)
  out = runTransform(pick, clip, ctx)
  paste(out)
  learn(ctx, cType, pick, overridden = paletteShown && userChangedPick)
```

---

## 6) Privacy, Security, and Safety

- **Local‑first**: All deterministic transforms on‑device.  
- **No clipboard history by default**: single‑item pipeline; optional history with scrub rules.  
- **Never capture in sensitive apps**: per‑app denylist (password managers, terminals).  
- **Network calls are explicit**: URL fetch or AI only if user enables; show cloud icon in HUD when used.  
- **Redaction**: mask emails/keys before any outbound call.  
- **Audit**: “What left your machine?” log with toggles to disable any integration.

---

## 7) Performance Targets & Strategies

- **Decision** (classification + ranking): **<10ms** typical; **<30ms** p95.  
- **HTML→Markdown**: **<60ms** for 50KB HTML.  
- **Table extract**: **<100ms** for 200 rows.  
- **Cold starts** cached; background warming when app focus changes.  
- **Guardrails**: size caps, timeouts, streaming paste for large outputs, cancel on keyup.

---

## 8) Pricing & Packaging

- **Free**: basic transforms, per‑app default, 20 smart pastes/day, no AI/OCR table.  
- **Pro ($5–8/mo)**: unlimited, OCR→table, AI fallback, per‑app recipes, team sharing, browser hints, audit.  
- **Teams ($3/user/mo add‑on)**: shared recipes, managed settings, exportable logs.

---

## 9) Go‑to‑Market

- **Distribution**: Product Hunt, Raycast Store command, short demo GIFs, Twitter/X dev audience.  
- **ICP outreach**: RevOps/Analysts/PMs; “screenshot → Sheets table in 2 keys” demo.  
- **Content**: “100 Best Copy‑Paste Recipes” gallery (SEO + community).  
- **Partnerships**: Notion/Linear/Jira templates that render best with our paste.  
- **Telemetry (opt‑in)**: success rate, overrides, top recipes → drive roadmap.

---

## 10) Roadmap

### MVP (Weeks 1–6)
- Core app, palette, per‑app profiles.  
- Classifier + transforms: Plain, Markdown, Table, Smart Link, Code Block, Quote.  
- Mini HUD + learning; local DB; basic settings.  
- macOS Vision OCR stubbed; Windows plan.

### v0.2 (Weeks 7–10)
- URL unfurl w/ extension; invite→card; email‑sig→contact.  
- Teams: shared recipes (file‑based sync).  
- Plugin host (JS/TS) + **Recipe DSL**.

### v1.0 (Months 3–4)
- Windows build; cross‑platform parity.  
- Sync via iCloud/Drive/Dropbox optional.  
- Marketplace for community recipes.

---

## 11) Recipe DSL (Draft)

```yaml
name: "URL → Smart Link"
id: smart-link
when:
  content: url
  app_in: [Notion, Google Docs, Slack]
do:
  - strip_trackers: true
  - fetch_title: { timeout_ms: 500, prefer_extension_title: true }
  - format: "[{title}]({url})"
fallback:
  - format: "{domain} — {title}"
```

```yaml
name: "HTML table → Markdown"
id: html-table-md
when:
  content: html
  contains: ["<table"]
do:
  - html_to_table: {}
  - table_to_markdown: { align: header, max_width: 120 }
```

```yaml
name: "Code → Fenced block"
id: code-fence
when:
  content: code
  app_in: [Notion, Confluence, Google Docs]
do:
  - detect_language: {}
  - fix_indentation: { tab_size: 2 }
  - fence: "```{lang}\n{body}\n```"
```

---

## 12) UI Notes

- **Palette**: compact, keyboard‑first, previews inline; top pick highlighted; “Always use here” checkbox.  
- **Settings**: per‑app toggles, denylist, AI toggle, network usage log, recipe gallery with search.  
- **HUD**: 2‑second unobtrusive toast; undo button; cloud icon if network used.

---

## 13) QA & Acceptance

- **Golden paths**: 100 sample inputs × 8 target apps → 95% top‑1 success; p95 latency <100ms.  
- **Edge cases**: massive HTML (news pages), non‑ASCII, RTL scripts, mixed code/text blocks, CSV with quotes/commas/newlines.  
- **Security**: denylist enforcement; no clipboard capture in terminals; no background network on paste unless enabled.  
- **Stability**: survives app focus changes; cleans up temporary pasteboard items; robust against empty/invalid clipboard.

---

## 14) Risks & Mitigations

- **OS API churn / Accessibility changes** → keep fallbacks (global hotkeys “Paste as Plain/MD/CSV”).  
- **Performance regressions** → profiling harness; size/timeout guards; pre‑warming.  
- **Privacy concerns** → local‑first defaults; explicit toggles; transparent audit log.  
- **App‑specific quirks (Docs/Sheets editors)** → browser extension hints + heuristics; ship per‑app patches as recipes.

---

## 15) Open Questions

1. Should AI be local (e.g., small model) for basic rewrites, or strictly cloud‑optional?  
2. How aggressive should “match destination style” be in Docs vs Word?  
3. Which 10 transforms are “day‑one must‑haves” after MVP?  
4. Is a Raycast‑only first release acceptable, or do we need a standalone app day one?  
5. What’s the minimum viable **Teams** feature for early revenue?

---

## 16) Implementation Seeds (Mac)

### Swift: Reading Pasteboard & Front App

```swift
import AppKit

func frontmostAppBundleID() -> String? {
    return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
}

func readClipboard() -> (plain: String?, html: String?) {
    let pb = NSPasteboard.general
    let plain = pb.string(forType: .string)
    let html = pb.string(forType: .html)
    return (plain, html)
}
```

### Swift: Injecting a Paste Safely

```swift
func pasteString(_ s: String) {
    let pb = NSPasteboard.general
    pb.declareTypes([.string], owner: nil)
    pb.setString(s, forType: .string)
    // Send CMD+V key event if needed, or insert via AX API depending on focus.
}
```

### TypeScript: Recipe Hook (v1 Plugins)

```ts
export interface RecipeCtx {
  app: string
  fieldType: "plain" | "rich" | "code" | "cell" | "search"
  contentType: "url" | "html" | "table" | "code" | "plain" | "address" | "invite"
  data: { plain?: string; html?: string }
}

export default async function run(ctx: RecipeCtx): Promise<string> {
  // Example: URL → Smart Link
  const url = extractUrl(ctx.data.plain || ctx.data.html || "")
  const clean = stripTrackers(url)
  const title = await getTitleFast(clean) // from extension or HEAD request
  return `[${title}](${clean})`
}
```

---

## 17) Success Metrics (after 30 days live)

- **Daily Active Smart Pasters** / DAU.  
- **Top‑1 accuracy** (no override) ≥ 80% overall; ≥ 90% in target apps.  
- **Average time saved per paste** (self‑report + modeled).  
- **Override rate trend** (should fall over user lifetime).  
- **Activation to Pro conversion** ≥ 3–5% in target audience.

---

## 18) Appendix — Example Transform I/O

### A) HTML → Markdown (list + links)

**Input (HTML):**
```html
<ul><li><a href="https://example.com?a=1&utm_source=x">Hello</a></li><li>World</li></ul>
```

**Output (Markdown):**
```md
- [Hello](https://example.com?a=1)
- World
```

### B) Web Table → CSV

**Input (HTML):**
```html
<table><tr><th>City</th><th>Temp</th></tr><tr><td>Berlin</td><td>22</td></tr><tr><td>Lisbon</td><td>26</td></tr></table>
```

**Output (CSV):**
```
City,Temp
Berlin,22
Lisbon,26
```

### C) Code Snippet → Fenced

**Input:**
```
for i in range(3):  print(i)
```

**Output:**
```python
for i in range(3):
  print(i)
```

---

**Build stance:** Mac‑first, small + fast + local. Ship a delightful MVP, then add OCR‑to‑table and Teams. Keep AI optional and explain every network call.
