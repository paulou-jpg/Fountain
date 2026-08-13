# fountain2pdf

Renders a Fountain screenplay to a print-ready PDF in standard screenplay format.

```bash
fountain2pdf script.fountain script.pdf
fountain2pdf script.fountain --no-title-page --no-scene-numbers
```

Layout is done directly rather than through `FNPaginator`: screenplay format is
character-metric — Courier at 10 characters per inch on a fixed baseline grid —
so wrapping and pagination are exact integer arithmetic, and the output lands on
the columns the format calls for. It also keeps the renderer off AppKit.

## The metrics

These are the industry-standard margins as published by Final Draft, and
corroborated by the general formatting guidance.

| Element | Left edge | Width |
|---|---|---|
| Scene heading / Action | 1.50in | 60 chars (to 7.5in) |
| Dialogue | 2.50in | 35 chars |
| Parenthetical | 3.10in | 25 chars |
| Character | 3.70in | — |
| Transition | right-aligned to 7.50in | — |
| Page number | right-aligned 7.25in, 0.5in from top, `N.` | — |

12pt Courier, single-spaced on a 12pt baseline grid, 1in top and bottom margins:
**55 baselines to a page**, `(720 − 72) / 12 + 1`. That is the capacity of the
grid, not a line count to expect — blank rows between elements occupy baselines
too, so a dense page of Big Fish reaches about 45 lines of text. There is no
configurable leading; compressing a script to save pages is not standard format.

### Why not simply copy the reference PDFs

Five produced scripts were measured, and they bracket the published values
rather than agreeing with them, because writers customise their templates:

| script | dialogue | parenthetical | character | action | leading |
|---|---|---|---|---|---|
| **published standard** | **2.50in** | **3.10in** | **3.70in** | **1.50in** | **12pt** |
| Man Finds Tape | 2.54 | 3.14 | 3.74 | 1.24 | 12pt |
| Big Fish | 2.38 | 2.78 | 3.38 | 1.50 | 12pt |
| kevin kim | 2.25 | 2.90 | 3.50 | 1.50 | 10pt |
| death_and_ramen | 2.38 | 2.90 | 3.50 | 1.50 | 10pt |
| Topiary | 2.10 | 2.50 | 3.94 | 1.10 | 12pt |

*Man Finds Tape* comes closest: its dialogue, parenthetical and character
columns land within a twentieth of an inch of the published values. Its action
margin does not — 1.24in against 1.50in — so even the nearest script is not a
template to copy wholesale. Two of the five are compressed to 10pt leading to
save pages, which is not standard format and is not offered here.

**Transitions are right-aligned, not indented.** This is easy to get wrong and
worth recording. In *kevin kim*, `SMASH TO BLACK.` begins at x=406 and
`CUT TO BLACK.` at x=420 — a two-character difference in length, a 14.4pt
difference in position, and an identical right edge of 511.2.

That is two samples from one script, which is enough to establish the alignment
but not the position: 511.2 is 7.10in, whereas the published spec puts a
transition against the 1.0in right margin at 7.50in. The spec wins here, as it
does for the columns above, so this renders at 7.50in and does not reproduce the
reference exactly.

Note also that Fountain only recognises a transition that ends in `TO:`, plus
three standard closers. `SMASH TO BLACK.` is a transition in Final Draft but is
action in Fountain unless forced with `>`.

Sources: [Final Draft — What Are the Margins for a Screenplay?](https://www.finaldraft.com/blog/what-are-the-margins-for-a-screenplay), [StudioBinder — Screenplay Margins Explained](https://www.studiobinder.com/blog/screenplay-margins/), [Story Sense — Margin Settings](https://www.storysense.com/format/margins.htm)

## Pagination

- One blank line between elements; a Character / Parenthetical / Dialogue run is
  set solid.
- A character cue is never left stranded at the foot of a page — if the cue plus
  two lines of what follows will not fit, the page breaks before it.
- A speech that must break across pages leaves `(MORE)` at the foot and resumes
  under `NAME (CONT'D)`, never leaving fewer than two lines either side of the
  break.
- A Fountain page break (`===`) forces a new page.
- Page one carries no number.

Sections, synopses, notes and boneyards are omitted, per the spec.

## Dual dialogue

Two character cues flagged with `^`, back to back with their speeches, are set
side by side. The 6in text block is divided into two 2.70in columns with a 0.60in
gutter, which tile it exactly: `108 + 194.4 + 43.2 + 194.4 = 540`. Within a
column the dialogue sits at the column edge, the parenthetical is indented four
characters, and the cue nine. A caret with no partner cue falls back to normal
single-column layout.

The cue is **indented within its column, not centred over it**, which is worth
stating because centring looks plausible and is wrong. In the one reference that
carries several dual passages, `LUCAS` (5 characters) and `FERNETTE` (8) both
begin at x=381.6 — a standard deviation of 0.00 across every dual cue in the
script — and the cue sits 65.8pt, nine characters, right of its own dialogue,
identically in both columns. That is the single-column relationship (the cue
twelve characters right of the dialogue) scaled by the narrower column.

Recognising the arrangement on the way back in is harder than laying it out, and
is documented with [`pdf2fountain`](../pdf2fountain/README.md).

## Automatic continueds

When a character speaks again within the same scene, the repeat cue carries
`(CONT'D)`, as Final Draft does by default. The speaker resets at every scene
heading, transition and page break, an extension such as `(V.O.)` does not make
it a different character, and a cue that already says `(CONT'D)` is left alone.
Set `automaticContinueds` to `NO` to turn it off.

## Round trip

`fountain2pdf` and [`pdf2fountain`](../pdf2fountain/README.md) are inverses,
which is how both are tested. Rendering Big Fish and reading it back gives an
identical count of every element — 863 Action, 768 Character, 799 Dialogue,
97 Parenthetical, 192 Scene Heading, 35 Transition — with the sole structural
difference that a Fountain page break becomes an actual page boundary.

The recovered text is not character-identical to the source, and should not be
expected to be, because rendering adds things a printed script carries:

- **22 character cues gain a `(CONT'D)`** that the source did not spell out.
  That is the renderer doing its job. Big Fish already writes 102 of its own by
  hand, so the printed script carries 124.
- **10 cues differ only in whitespace** — `EDWARD  (CONT'D)` becomes
  `EDWARD (CONT'D)`. One of them is a cue that ends in a non-breaking space in
  the source, which is normalised away.
- **4 tokens are lost**, all of them title-page key labels (`Author:`,
  `Source:`, `Notes:`, `Copyright:`), which correctly do not print. That is
  0.015% of the script.

The important property is that this settles: rendering the recovered script and
reading it back a second time produces a **byte-identical file**. `(CONT'D)`
does not accumulate, spacing does not drift, and nothing further is lost.
