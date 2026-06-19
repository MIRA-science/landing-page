# How this was made: Catalyze Open Science panel — companion Q&A post-show notes

**Slug:** `how-this-was-made`
**What this is:** a build-log / "how this was made" record of producing the companion **post-show notes** Q&A page for the Catalyze *Frontiers in Research: Open Science* panel (June 18, 2026).
**Goal it answers:** how do you turn a panel recording, its Zoom chat, and a prep doc into a trustworthy, well-designed companion Q&A page — with verified quotes, clear provenance, and an engaging interactive format?
**Created:** 2026-06-19
**Roam page:** none — kept local at the user's request (graph would otherwise be `dg-team`).

---

## The artifact

The page this log documents lives next door:

```
../index.html      # single self-contained file (Google Fonts CDN only)
```

Open it directly in a browser, or serve the folder (e.g. `python3 -m http.server --directory ..`).

## Layout

```
how-this-was-made/
├── conversation_log.md   # the provenance trail: user prompts verbatim, Claude responses summarized
├── README.md             # this file
└── .experiment.yaml      # marker that activates the log-experiment skill here
```

This is a build-log, not a data analysis, so the usual `data/ notebooks/ src/ plots/` dirs are omitted — the "output" is the web page in `../`.

## Source material (in the parent folder)

- `../transcript.txt` — panel transcript + Granola summary
- `../2026-06-18 12.00.26 Frontiers in Research_ Open Science_chat.txt` — Zoom chat (audience questions)
- Roam page **[[Catalyze Frontiers in Open Science Learning Session]]** (`dg-team`, uid `2_fnkmeUI`) — planned questions + prepared notes
- `../attendees.png`, `../attendee-dossier.md`

## Provenance

`conversation_log.md` holds the full session that produced the page — the four user prompts verbatim and a narrative summary of what each turn did, organized by turn. It is the specification trail for every decision baked into `../index.html`.
