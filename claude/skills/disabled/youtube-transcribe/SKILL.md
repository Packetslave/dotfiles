---
name: youtube-transcribe
description: Download a YouTube video's audio, transcribe it locally with Whisper, and write a structured summary with a timestamped outline. Use this whenever Brian gives a YouTube URL (youtube.com or youtu.be) and wants any of - a transcript, a summary, notes, "what does this video say", key takeaways, or the audio saved - even if he doesn't say "transcribe". Also use when he asks to summarize a video whose transcript folder already exists under output/youtube/.
triggers:
  - transcribe this youtube video
  - summarize this video
  - get the transcript of <youtube url>
  - what does this video cover
  - pull the audio from this video
---

# YouTube Transcribe & Summarize

Turns a YouTube URL into four artifacts in `output/youtube/<slug>/`:

| File | What | Who makes it |
|------|------|--------------|
| `audio.mp3` | 128kbps mono listening copy | script |
| `transcript.txt` | Reflowed, readable paragraphs | script |
| `transcript.srt` | Timestamped segments | script |
| `metadata.json` | id, title, uploader, duration, upload date, URL, model, backend | script |
| `summary.md` | Structured overview + timestamped outline | **the assistant** |

## Who Runs the Script (environment check first)

The script runs on any real host — macOS (Apple Silicon) **or** Linux. What
it can't run on is the Cowork sandbox, which can't reach YouTube (not on the
network allowlist). Who runs it depends on the session environment — check
which one this is (see CLAUDE.md, Git & the Sandbox, for the same
distinction):

- **Native Claude Code (macOS or Linux host):** the assistant runs the script
  itself via Bash — no handoff. It's long-running (download + transcription);
  allow several minutes and use a generous timeout, or run it in the
  background and monitor.
- **Cowork sandbox:** the assistant cannot run it. Same split as the
  `lecture-processing` skill: give Brian the command to run in a terminal on
  a real host; he reports back. The summary step is pure text work and
  happens in the sandbox fine.

### Speech-to-text backends

The script picks one automatically and records the choice in
`metadata.json` as `whisper_backend`:

| Host | Backend | Notes |
|------|---------|-------|
| macOS, Apple Silicon | `mlx` — mlx-whisper | Metal-accelerated |
| Everything else (Linux) | `ct2` — whisper-ctranslate2 | faster-whisper/CTranslate2, CPU or CUDA |

Override with `WHISPER_BACKEND=mlx|ct2` if you ever need to force one.
Measured on mfa1 (Ryzen 9 9955HX, 32 threads, no usable GPU) with `small.en`
on the `ct2` backend: **~21x realtime** — a 7:22 video transcribed in 27s
wall clock including model load. Linux hosts are a first-class option here,
not a degraded fallback.

### Model size: what upgrading buys

Benchmarked 2026-08-27 on mfa1/`ct2`, one 15-minute single-speaker video
(full writeup: `output/md/whisper-model-comparison-2026-08-27.md`):

| Model | Speed | Sentence marks | Notes |
|---|---|---|---|
| `small.en` | 21x RT | 64 | mis-spells proper nouns ("Jaco" for Jocko) |
| `medium.en` | 7.4x RT | 77 | fixes names; **drops ~100 content words** |
| `large-v3-turbo` | 5.7x RT | 84 | best structure; one proper-noun regression |

Punctuation improves monotonically with size — that is capacity, not the
`.en`-vs-multilingual distinction, since English-only `medium.en` sits near
the large model. Note `large-v3-turbo` is *slower* than `medium.en` despite
its slim decoder.

Upgrading fixes **proper nouns and sentence structure**. It does **not** fix
domain idiom or pronoun drift — all three failed those identically. The
default stays `small.en` because the summary stage repairs what the ASR
misses (see Rules), so the extra runtime buys transcript polish rather than
summary quality. Pass a larger size when the raw transcript matters in its
own right.

## Prerequisites (one-time host setup)

- `ffmpeg` and `uv`, both installed by the dotfiles ansible bootstrap
  (`homebrew_common_formulae`). By hand: `brew install ffmpeg uv`.
- Everything else runs via `uvx` in cached ephemeral environments, no pip
  installs: `yt-dlp`, and whichever of `mlx-whisper` / `whisper-ctranslate2`
  the platform selects. The Whisper model auto-downloads from Hugging Face on
  first run into `~/.cache/huggingface`.
- A JS runtime for yt-dlp's EJS challenge solver (`deno`, also in
  `homebrew_common_formulae`; `node` works too). See step 2.

## Workflow

0. **Check the ingest log first — before downloading anything.**

   ```
   /home/blanders/src/cowork/Skills/wiki-ops/scripts/ingest-log.py check "<url>"
   ```

   Exit 3 means this video is already in `Skills/_ingest-log.txt` (the line
   is printed). **STOP.** Show Brian the line and ask whether he wants it
   re-ingested; do nothing else until he says so. Exit 0 means proceed.
   The log is the shared record across all three ingest skills, and every
   run ends by appending to it (step 9).

1. **Brian gives a YouTube URL.** Run the script (see Who Runs the Script
   above — in native Claude Code, run it yourself; in the Cowork sandbox,
   give Brian the command for his Mac terminal):

   ```
   bash "$(git rev-parse --show-toplevel)/Skills/youtube-transcribe/transcribe_youtube.sh" "<url>"
   ```

   The optional second argument is a plain Whisper size name — the default
   `small.en` is English-only, so for a non-English video pass a multilingual
   size: `... "<url>" small`. The script maps the size to whatever the active
   backend calls it, so the same argument works on macOS and Linux.

2. **Handle errors.** Whether the script ran in-session or Brian pastes its
   output, common failures: `uvx`/`ffmpeg` missing (→ `brew install ffmpeg
   uv`), age-restricted or private video (yt-dlp will say so — there's no
   workaround to suggest, just say why it failed).

   **`HTTP Error 403: Forbidden` on the audio download** (with warnings
   about a "challenge solver" / "n challenge solving failed"): YouTube's
   2026 "n challenge" changes require yt-dlp's EJS challenge solver, which
   is opt-in and needs a JS runtime (deno). The fix is machine-level and
   dotfiles-managed since 2026-08-16: `~/.config/yt-dlp/config` containing
   `--remote-components ejs:github` (symlinked from `~/dotfiles/yt-dlp/config`
   by the ansible bootstrap, which also installs deno). If a machine 403s,
   it hasn't had the bootstrap rerun — either run it or create that config
   file directly. Not a stale-yt-dlp problem; don't chase version refreshes
   first. Details on the wiki's yt-dlp page.

   On a host with `node` but no `deno`, yt-dlp warns that no JS runtime was
   found (it only enables deno by default) — add `--js-runtimes node` or
   install deno. Verified 2026-08-27 on mfa1: modern videos still downloaded
   without it, but the warning is the same failure path.

3. **Verify the outputs** in `output/youtube/<slug>/`: all four files exist,
   and `transcript.txt` length is plausible for the video duration in
   `metadata.json` (roughly 100+ words per minute of speech — a 20-minute
   talk producing 300 words means something went wrong; flag it rather than
   summarizing garbage). The check is one line: `wc -w transcript.txt`
   against `duration_seconds / 60` from `metadata.json`; 120–220 wpm is
   normal talking-to-camera pace.

4. **Write `summary.md`** into the same folder, following the format below.
   Read `transcript.txt` for content and `transcript.srt` for the outline
   timestamps. **Get the timestamps with the helper, not an ad-hoc grep:**

   ```
   /home/blanders/src/cowork/Skills/youtube-transcribe/scripts/srt-ts.sh \
     output/youtube/<slug>/transcript.srt "phrase one" "phrase two" …
   ```

   It prints the SRT's last timestamp first (compare it to
   `duration_seconds`; if it is near zero the hour field was lost) and then,
   per phrase, every match as `HH:MM:SS <total-seconds> <phrase>` — the
   seconds column is what the `?t=` links take. It exists because two
   mistakes recurred: a `grep -B2 | grep '^[0-9]'` captures the subtitle
   *index* line instead of the arrow line and yields nonsense like `17`
   for a 17:44 video, and slicing to `mm:ss` drops the hour on a 60+ minute
   video so its closing minutes read as its opening ones (papercut
   `13ecfef7`, graduated 2026-09-11). A phrase that spans a segment boundary
   comes back MISSING — shorten it. Write the summary with a quoted heredoc
   via Bash (`cat > … <<'EOF'`):
   the harness's Write tool refuses `.md` files when this skill runs inside
   a subagent ("return findings as text, not report files"), and the
   heredoc works in every context. Note the sandbox mount can serve stale
   reads right after Brian's script writes files — if the transcript looks
   truncated, re-read before concluding anything is wrong.

5. Give Brian the summary path and the Caddy URL
   (`http://<host>:2015/output/youtube/<slug>/summary.md` — see CLAUDE.md,
   Local web server).

6. **Push the summary to Instapaper automatically** (no need to ask) via the
   `instapaper` MCP server (registered in `.mcp.json`; creds come from
   `secrets/instapaper.enc.env` through sops). Render the summary to an HTML
   file in the session scratchpad —
   `PATH="/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:$PATH" cmark-gfm
   -e autolink summary.md > <scratchpad>/<slug>.html` (autolink makes the
   bare Source URL clickable; the PATH prefix covers both Homebrew prefixes;
   `<scratchpad>` is the session scratchpad directory named in the system
   prompt, which keeps the rendered file out of the tracked `output/youtube/`
   dir) — and call `add_private_bookmark` with: `content_file` = the
   **absolute path** of that HTML file, `title` =
   `<video title> — <channel> · <duration>`, `source_label` =
   `youtube-transcribe`. Never `cat` the HTML and pass it as `content`: the
   server reads the file itself, so the body never enters the conversation
   and a 60+ minute summary pushes in one call (`content_file` landed in the
   instapaper-mcp checkout 2026-09-05, bead `cowork-wfl4`; if the server
   rejects the parameter, that machine's `build/` predates it — rebuild with
   `npm run build` in `src/_external/instapaper-mcp`). Verify by reading the
   bookmark back with `get_article_content` and checking it ends with the
   Outline's closing list. Do **not** pass `description` — Instapaper silently
   discards it whenever `is_private_from_source` is set (verified 2026-08-23:
   an identical call with a real URL keeps the description, the private one
   comes back `""`, and no endpoint can set it after the fact). `title` is
   the only list-view field that survives on a private bookmark, which is why
   the channel and duration ride along inside it; the original URL stays
   reachable from the **Source:** line in the body. Best-effort, never a
   blocker: if the MCP isn't connected (Cowork sandbox, credentials unset,
   server down), say so and move on. Skip it when the video was clearly
   throwaway (e.g. Brian only wanted the audio).

7. **Bookmark the original video to Pinboard automatically** (no need to ask)
   via the `pinboard-write` skill (`Skills/pinboard-write/scripts/pinboard-write.py`
   — see `Skills/pinboard-write/SKILL.md`). Run:

   ```
   export REPO="$(git rev-parse --show-toplevel)"
   export VURL="<original YouTube URL>"
   export VTITLE="<video title>"
   sops exec-env "$REPO/secrets/pinboard.enc.env" \
     '"$REPO"/Skills/pinboard-write/scripts/pinboard-write.py add \
       --url "$VURL" --title "$VTITLE" \
       --tags youtube,<2-4 topic tags> --private'
   ```

   **Pass the URL and title through exported variables, as above — do not
   inline them into the single-quoted string.** `sops exec-env` takes its
   command as one argument, and an apostrophe in the title closes that quote:
   a title like "Watch This if You're Not In A Good Place In Life" dies with
   `unmatched "` before the script ever runs. Apostrophes are common in
   YouTube titles. `sops exec-env` adds to the existing environment rather
   than replacing it, so exported variables survive into the command.

   The `sops` call uses the default age key location; the chassis-specific
   `SOPS_AGE_KEY_FILE` papercut that fires on every `sops` command does not
   apply to cowork's `secrets/`.

   Always include the `youtube` tag; pick 2-4 additional lowercase, hyphenated
   topic tags from the video's actual subject matter (e.g. `machine-learning`,
   `personal-finance`) — reuse existing tags where they fit rather than
   inventing near-duplicates. The personal-development corpus already uses
   `advice`, `art`, `business`, `creativity`, `finance`, `goal-setting`,
   `habits`, `inspiration`, `leadership`, `life`, `productivity`,
   `psychology`, `writing`; only reach for the `pinboard` MCP's `list_tags`
   (the whole ~600-tag list, no filter) when the subject is outside that
   set. **No speaker or person tags** (Brian's call, 2026-08-27):
   tag the subject matter, not who is talking. The wiki is where speakers are
   tracked. Bookmark is private, matching the Instapaper push. Best-
   effort, never a blocker: if `secrets/pinboard.enc.env` doesn't exist yet or
   the call fails, say so and move on. Skip it when the video was clearly
   throwaway (same condition as the Instapaper step, above).

8. **Ingest the new information into the second brain wiki automatically**
   (the claude-obsidian vault — see CLAUDE.md, Memory). No need to ask —
   Brian's standing instruction (2026-08-03) is to ingest unless he says
   otherwise. Ingest the transcript as an external source via
   `/claude-obsidian:wiki-ingest` (pointing it at the
   `output/youtube/<slug>/` files) so the durable facts land with
   provenance. **Since 2026-09-06 the default is to QUEUE the ingest, not
   apply it:** draft the write set below exactly as before, put it in a JSON
   manifest (shape in `Skills/wiki-ops/SKILL.md`, "Ingests ride the queue
   too": `title`, `log_entry`, `hot_line`, `source`, `writes`) and run
   `Skills/wiki-ops/scripts/wiki-queue.py add-ingest --manifest <file>`. It
   inlines the drafts, anchor-checks every edit against the live vault and
   refuses on any problem. The page lands at the next `/drain`, batched
   with everything else waiting; tell Brian the record name. Ingest
   directly — the `wiki-ops` "Standard operation flow" through
   `wiki-tx.py`, same manifest plus the log and hot edits — only when Brian
   asks for the page now. Either way **use the tooling rather than
   hand-building the bundle**: `wiki-tx.py` already imports
   `stable_source_id` and generates the source-ledger write, so hand-rolling
   means reverse-engineering the `src-<20 hex>` key derivation out of
   `claude_obsidian/ledgers.py` for no gain (done needlessly 2026-08-27).
   Two traps if you do end up hand-building: the ledger's `generated_at`
   must be a full UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`), not a date, and
   `sources` is a dict keyed by source id, not a list. Skip the ingest when Brian says not
   to file this one, or when the video was clearly throwaway (e.g. Brian
   only asked for the audio).

   **The repo root is the vault.** `output/youtube/<slug>/transcript.txt` is
   an in-vault locator, so the manifest's `sources` entry records it
   directly (`content_kind: document`, `authority: secondary` for a talk or
   interview). The wiki-ingest skill's rule that an outside-vault path needs
   an `inbox/` capture does not apply — do not stop on it.

   **Which corpus? Decide before drafting a single page.** The write set
   below is for the **personal-development corpus** — motivational,
   productivity, self-help, career and life-advice content, whether from a
   named speaker, an interview, a channel persona or an anonymous listicle
   account (the hub already holds all four). A video that is **not**
   motivational content — an AI-practice talk, an engineering-leadership
   interview, a product walkthrough, a technical explainer — does **not**
   get a speaker page or a hub edit; filing it that way put a Netflix CPTO
   into the motivational corpus once. Use the **AI-practice / topic
   precedent** instead, modelled on `wiki/library/concepts/elizabeth-stone-
   netflix-ai-era.md` and `wiki/library/concepts/don-woodlock-ai-without-
   outsourcing-thinking.md`: one concept page under `wiki/library/concepts/` named
   `<speaker>-<topic>` with tags `concept` plus a topic tag (`ai`,
   `engineering-leadership`, `learning`), the speaker as an alias rather than
   an entity, `related:` pointing at the nearest existing topic pages (and a
   back-link edit on the closest one), one line in the index's `## Library`
   section (its imported-topics subsection) next to its neighbours, no `personal-development.md` edit, and a
   `## Provenance` section naming the transcript path, model, authority and
   any assistant-knowledge corrections. Borderline cases (a productivity
   YouTuber explaining an AI workflow, say) go by the *use* the content is
   put to: a practice for doing work is the topic precedent, advice about
   how to live and motivate yourself is the corpus. Say which precedent you
   used in the report so Brian can reshape the queued record before the
   drain. Applied five times before it was written down here (Stone
   2026-08-20, Ben AI's prompting rules and Woodlock 2026-09-05, Swadia
   2026-09-11); papercut `deadcef0`, graduated 2026-09-11.

   **Every page an ingest creates lives under `wiki/library/`** — imported
   third-party material is its own corpus since the 2026-09-18 split
   (`Decisions/decision-wiki-library-split-2026-09-18.md`); wikisearch
   searches Brian's own pages by default and the library on request, so a
   page filed under `wiki/concepts/` would be mis-classified as first-party.

   **Wiki write set for the personal-development corpus** (read
   `wiki/library/concepts/personal-development.md` first for the convention,
   and one recent speaker/framework pair as the model):

   - **Speaker page** `wiki/library/entities/<slug>.md` (create, or `edits` to an
     existing one's `related:`, `summary:`, `updated:`, and "Ingested
     material" list). Slug by real name when the person is a public figure
     (`david-foster-wallace`), by channel name when the channel is the
     persona (`struthless`, `penrose`), with the other as an alias. Carry an
     **ASR gotchas** section listing the mis-hearings the next ingest will
     hit again, and the funnel caveat.
   - **Framework page** `wiki/library/concepts/<speaker>-<framework>.md` (create, or
     expand the existing page when the video is more evidence for a
     framework already filed). End with a **Provenance** section: the
     transcript path, model, authority, and any correction made from
     assistant knowledge rather than the source — flag those explicitly.
   - **Hub** `wiki/library/concepts/personal-development.md`: three anchored edits
     — the `related:` list, Speakers, Frameworks — each at the alphabetical
     neighbour's line.
   - **Index** `wiki/index.md`: two lines in the `## Library` section's
     Personal Development subsection, alphabetical. The `## Sources` list there is **retired**
     (unmaintained since 2026-08-22); the ledger is the record. Do not add
     a Sources line.
   - **Log** `wiki/log.md`: one paragraph in the voice of the entries
     already there, heading `## YYYY-MM-DD — Ingest: <framework title>
     (youtube-transcribe)`. Queued: it is the manifest's `log_entry` and the
     drain writes it. Direct: prepend under the anchor `"# Wiki Log\n\n"`.
   - **Hot cache** `wiki/hot.md`: one bullet. Queued: the manifest's
     `hot_line`. Direct: prepend under `"## Recent Changes\n\n"` and
     **prune one** from the bottom — the file's own rule is under 500 words,
     and six ingests in a row skipped the prune.
   - **Ledger**: generated from `sources` by `build-bundle` (at the drain,
     or directly); never hand-edited.

   Use `edits` for every existing file (index, log, hot, hub are enforced);
   full-file writes only for the two creates. An ingest record may not
   carry log or hot writes at all — `add-ingest` refuses them.

9. **Append to the ingest log** — always, even when steps 6-8 were skipped
   as throwaway, so the next run is refused rather than repeated:

   ```
   /home/blanders/src/cowork/Skills/wiki-ops/scripts/ingest-log.py add "<url>" "<video title>"
   ```

   Commit `Skills/_ingest-log.txt` with the rest of the run (the
   `output/youtube/<slug>/` files and, when queued, the `wiki-queue/`
   record). With a queued ingest this log is the only duplicate guard until
   the drain writes the ledger. If Brian explicitly approved a re-ingest at
   step 0, pass `--force` here.

## summary.md Format

```markdown
# <Video Title>

**Channel:** <uploader> · **Duration:** <mm:ss> · **Published:** <upload date>
**Source:** <url>

## Overview

2-4 paragraphs of prose: what the video is about, its main argument or
narrative arc, and who'd find it worth watching.

## Key Takeaways

- 3-7 substantive points (full sentences, not fragments).

## Detailed Summary

The full substance of the video, organized coherently with ### subheadings
(by main idea, following the video's argument structure) and bullet points
under each. For every main idea capture the supporting arguments, and end
with the speaker's conclusion. Highlight what makes the content concrete:
**bold** any data and figures, call out specific examples and incidents,
and include important quotes verbatim (quoted, attributed to the speaker).
This section is where depth lives — the Overview stays short because this
exists.

## Outline

- [0:00](https://youtu.be/<id>?t=0) — Section description
- [4:32](https://youtu.be/<id>?t=272) — Section description
- ...
```

Outline guidance: derive sections from real topic shifts in the transcript,
not fixed intervals — typically 5-15 entries depending on length. Get each
timestamp from the `.srt` segment where that topic starts, and make the link
`https://youtu.be/<id>?t=<total-seconds>` so it jumps straight there.
Quote sparingly; the transcript exists for exact wording.

## Rules

- Don't fabricate any step of the pipeline. If the output folder or a file
  is missing, say what's missing and give Brian the command — never invent
  transcript content or summarize from prior knowledge of the video.
- Transcripts are ASR output: expect occasional mis-hearings, especially
  names and technical terms. Cross-check odd-looking proper nouns against
  `metadata.json` (title/uploader often contain the correct spellings)
  before repeating them in the summary.
- **Repair domain idiom in the summary — the transcript won't have it.**
  Model size does not fix low-frequency idiom (verified across three sizes,
  2026-08-27), and unlike proper nouns there is no metadata to check it
  against, so the summary stage is the only backstop. A phrase that reads as
  odd in context usually is: all three models heard a high-school football
  anecdote as "quit during two days", where the speaker said **two-a-days**.
  Trust discourse context over the transcript's literal words. And never
  treat agreement between two ASR runs as confirmation — same-family models
  share a language-model prior and fail the same way for the same reason.
- Playlist URLs: the script passes `--no-playlist` (a URL that's both a
  video and a playlist processes just the video). For a whole playlist, run
  the script once per video URL.
- Existing outputs are never overwritten silently — the slug includes the
  video id, so re-running the same video overwrites its own folder only.
  Regenerating `summary.md` over an existing one is fine; ask before
  touching the script-produced files (per repo rules on editing existing
  files).
