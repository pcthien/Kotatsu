# Prompt: Kotatsu → cross-device web app (JVM parser-reuse architecture)

---

## Role

You are a senior full-stack engineer. Build a private, single-user web app to read
manga on any device, **reusing the 1256 Kotlin parsers** from Kotatsu unchanged.
Frontend + BFF on **Vercel** (Next.js). User data on **Supabase**. Scraping done
by a **long-lived JVM service** that embeds `kotatsu-parsers` and beats Cloudflare
with a real headless browser.

## Goal

Responsive PWA: browse/search sources, open a manga, read chapters (paged +
webtoon), with **library, history, bookmarks, and per-chapter progress** synced
across devices via my Supabase account.

## The two facts that dictate the architecture

1. **Reuse the Kotlin parsers — do not rewrite them.** They are a JVM/jsoup
   library (`com.github.pcthien:kotatsu-parsers`, my fork). Each source is a class
   implementing `getListPage()/getDetails()/getPages()` and returning typed models
   (`Manga`, `MangaChapter`, `MangaPage`). To use them you implement ONE interface:
   `MangaLoaderContext` (below). That is the entire integration surface for all
   1256 sources. A TS rewrite would throw all of this away — don't.

2. **Cloudflare blocks datacenter IPs and non-browser clients.** Sources like
   `truyenqqko.com` / `truyenggvn.com` terminate TLS or return empty `200`s to
   cloud IPs and plain HTTP clients. Vercel serverless `fetch()` WILL fail. The
   Android app survives only because it scrapes through a real **WebView**. So the
   scraper service MUST drive a **headless browser (Playwright)** for the
   JS-challenge + `cf_clearance` cookie, share that cookie jar with its OkHttp
   client, and route through a **residential/ISP proxy**. This is why the scraper
   is a persistent JVM service, **NOT a Vercel function.**

## Architecture

```
┌──────────────────────────────┐        ┌─────────────────────────────────────┐
│ Vercel — Next.js (App Router) │        │ Scraper service (Kotlin/Ktor, JVM)   │
│  • PWA reader/browse UI        │  REST  │  • depends on kotatsu-parsers (fork) │
│  • Route Handlers (BFF)        │──────▶ │  • ServerLoaderContext: OkHttp +     │
│  • /api/image proxy            │  +auth │    shared CookieJar + Playwright pool │
│  • Supabase client (RLS)       │  token │  • Cloudflare interceptor → browser   │
└───────────────┬───────────────┘        │  • residential proxy, per-source cfg  │
                │                         │  • short-TTL cache (Redis/in-mem)     │
                ▼                         │  Deploy: Fly.io / Railway / VPS       │
        ┌────────────────┐               │  (long-lived; NOT serverless)         │
        │  Supabase       │              └─────────────────────────────────────┘
        │  user data only │  Postgres + RLS, Auth, Storage
        └────────────────┘
```

Browser → Vercel only. Vercel → scraper service (server-to-server, bearer token).
The scraper is the only thing that touches manga sites.

## The core integration: implement `MangaLoaderContext`

This abstract class is the whole bridge to all parsers. Implement it once:

```kotlin
// build.gradle.kts:  implementation("com.github.pcthien:kotatsu-parsers:<commit-or-tag>")
// (JitPack builds the fork. Merge the fix branch to master first, or pin the commit.)

class ServerLoaderContext(
    override val httpClient: OkHttpClient,     // shares the cookieJar + proxy below
    override val cookieJar: CookieJar,         // shared with Playwright (cf_clearance)
    private val browser: PlaywrightPool,       // pool of headless browser contexts
    private val configs: SourceConfigStore,    // per-source domain override etc.
) : MangaLoaderContext() {

    // JS execution / Cloudflare: run the script inside a real page.
    override suspend fun evaluateJs(baseUrl: String, script: String): String? =
        browser.evaluate(baseUrl, script)      // loads baseUrl in a browser ctx, evals

    override suspend fun evaluateJs(script: String): String? =
        browser.evaluate("about:blank", script)

    override fun getConfig(source: MangaSource): MangaSourceConfig =
        configs.forSource(source)              // reads domain_override, prefs from DB/env

    override fun getDefaultUserAgent(): String = browser.userAgent   // MATCH the browser UA

    // Only a few parsers descramble images; back these with java BufferedImage.
    override fun redrawImageResponse(response: Response, redraw: (Bitmap) -> Bitmap): Response = TODO()
    override fun createBitmap(width: Int, height: Int): Bitmap = TODO()
}

// Usage — this is ALL you need to call any of the 1256 parsers:
val parser = loaderContext.newParserInstance(MangaParserSource.TRUYENQQ)
val page   = parser.getList(MangaSearchQuery.Builder().build())   // or with query/filter
val manga  = parser.getDetails(page.first())
val pages  = parser.getPages(manga.chapters!!.first())
```

### Cloudflare handling (the make-or-break part)

Mirror the Android app’s flow on the server:

1. OkHttp app-interceptor detects a Cloudflare block (challenge HTML, or the
   parsers’ `CloudFlareHelper` signal, or an empty `200` body).
2. On block: hand the URL to the **Playwright pool** → it loads the page in a real
   browser (through the residential proxy), waits out the JS challenge, and yields
   the `cf_clearance` (+ related) cookies.
3. Store those cookies in the **shared `CookieJar`**, then retry the OkHttp request.
4. Keep the browser’s **User-Agent identical** to OkHttp’s, or Cloudflare re-challenges.
5. Also retry on empty-body `200`s (some sources flap — the TruyenQQ parser already
   has this retry internally, but keep a generic guard too).

Persist cookies per source domain so you solve the challenge rarely, not per request.

## Scraper REST API (Ktor) — thin wrappers over the parser calls

```
GET  /sources                                   -> [{id,title,locale,contentType,isNsfw}]
GET  /list?source&page&query&sort&tags&state    -> [Manga]
GET  /details?source&url                         -> Manga + chapters[]
GET  /pages?source&chapterUrl                    -> [{url}]
GET  /image?source&url                           -> streamed bytes (Referer set) [or do in Next.js]
POST /resolve-link {url}                          -> Manga           (optional)
```
- Map each route to `newParserInstance(source).<method>(...)`; serialize the parser
  model to JSON DTOs (Manga/MangaChapter/MangaPage → plain objects).
- Auth every route with a shared bearer token (Vercel → scraper only).
- Cache list/details a few minutes; do not cache images long in the service.
- Per-source throttling (e.g. TruyenQQ rate-limits page fetches).

## Vercel / Next.js app

- App Router + TypeScript + Tailwind. PWA: installable, offline shell, service worker.
- Route Handlers call the scraper (server-side, with the bearer token) and Supabase.
- **Reader:** paged + continuous/webtoon, tap/keyboard/swipe nav, preloading, zoom,
  remembers page. **Browse:** source list, search, sort/filter, pagination, detail.
- **Image proxy** (`/api/image`): fetch the page image with the source domain as
  `Referer` + the browser UA, stream it back, cache aggressively. Manga image hosts
  are hotlink-protected; direct `<img src>` will 403.
- Secrets (scraper URL/token, Supabase service-role key, proxy creds) in server env
  only — never in the client bundle. `noindex`; auth-gate everything.

## Supabase — user data ONLY (never store the source catalog here)

```sql
-- every table RLS: user_id = auth.uid()
profiles(id uuid pk references auth.users, display_name, created_at)
favorites(id, user_id, source, manga_url, title, cover_url, category, added_at)
history(id, user_id, source, manga_url, title, cover_url, last_chapter_url, last_read_at)
bookmarks(id, user_id, source, manga_url, chapter_url, page int, note, created_at)
progress(user_id, source, chapter_url, page int, total int, percent numeric,
         updated_at, primary key(user_id, source, chapter_url))
source_settings(user_id, source, domain_override, enabled bool, pinned bool, sort_key int)
```
Identity matches the Android app: manga = `(source, manga_url)`, chapter =
`(source, chapter_url)` — so a Kotatsu backup can be imported later.

## Milestones (pause for review after each)

1. **Scraper service**: Ktor + `kotatsu-parsers` dep + `ServerLoaderContext` with
   Playwright + shared cookie jar + proxy. Prove `/list` and `/pages` work through
   Cloudflare for **TruyenQQ** and **FoxTruyen** (my fixed sources).
2. **Supabase**: schema + RLS + Auth.
3. **Next.js app**: login, browse/search, detail, reader (both modes), image proxy,
   progress/favorites/history sync.
4. **PWA polish**: installable, responsive, offline shell, `noindex`.

## Gotchas (do not skip)

- Cloudflare: browser-solve + shared cookie jar + matching UA + residential proxy.
- Empty-body 200 retry (source flakiness).
- Per-source `domain_override` (sources move domains constantly).
- Image `Referer` proxy (else 403).
- Per-source rate limits.
- `redrawImageResponse`/`createBitmap`: only needed by descrambling sources —
  implement with `java.awt.image.BufferedImage`; stub until a source needs it.
- Cost/effort center of gravity is the **browser pool + residential proxy**, not
  Vercel/Supabase. Budget for it.

## Legal

Aggregates copyrighted content; the original app was discontinued under legal
pressure. Keep it private, single-user, auth-gated, `noindex`, no public sharing.

---

**First step:** confirm this architecture, stand up the scraper service (milestone
1), and prove one source loads end-to-end through Cloudflare before building the UI.
```
