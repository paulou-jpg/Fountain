# pdf2fountain

Converts a screenplay PDF into Fountain.

```bash
pdf2fountain script.pdf script.fountain
pdf2fountain script.pdf -              # write to stdout
```

The PDF needs a text layer. A scanned script exits with
`No text layer found -- the PDF may be scanned images` rather than producing
nonsense.

## Why it reads geometry

A screenplay PDF already knows what every line is, and it says so with the left
margin: action against the left margin, dialogue indented, a character cue
indented further still. That is the whole of screenplay format.

Converters that start from flattened text throw all of it away and then try to
guess it back from capitalisation, which is where the familiar damage comes
from — dialogue promoted to action, page furniture left in the body, numerals
eaten by cleanup rules aimed at page numbers. Reading the positions instead
means the element types are recovered rather than inferred.

The columns are **learned per document, not assumed**, because writers customise
their templates and no two of the reference scripts agree — dialogue ranges from
2.10in to 2.54in across five of them, against a published standard of 2.50in.
The measurements are tabulated in
[fountain2pdf's README](../fountain2pdf/README.md). `P2F_DEBUG=1` prints what
was learned for a given file:

```
columns  action=108 dialogue=162 paren=207 character=252 transition=338
spacing  pitch=10.0 paragraphGap=15.0
```

Everything is measured from the **left edge** of a line, which is what four of
the five references use: their cues of every length share one x exactly, so the
left edge is stable and the centre is not. *Topiary* is the exception — it
centres its cues on the page, every one at x=306.0, so their left edges vary by
name length. Nearest-column assignment absorbs that (the variation is a few
points against column gaps of tens), and it converts with no round-trip
differences, but a script that centred its cues *and* used unusually long names
would be the case to watch.

The action margin is the **leftmost substantial column** — not the most common
one, which in a dialogue-heavy script is the dialogue column. In *kevin kim*,
action carries 588 lines and dialogue 1248, so taking the mode would put every
action line in the wrong bucket. Line pitch is likewise the most common *small*
gap, since the overall mode would find the double spacing between paragraphs and
then nothing would ever look like a paragraph break.

## What it handles

**Scene numbers** in the margin gutters are lifted into Fountain's `#12#` form —
73 of them in *kevin kim*. The production's own gutter number is treated as
definitive, so a shot heading that carries one becomes a scene heading even
without an INT/EXT prefix: `.BLACK SCREEN. #1#`.

**Revision marks.** A revised draft carries a change mark in the right margin of
every altered line, and PDFKit folds it into that line's text — a heading arrives
as `INT. INDUSTRIAL SPACE - AFTERMATH *`. The marks are removed by position: they
sit in a single column outside the text block, so two or more sharing a right
edge identify it. Measuring the gap before the mark instead does not work, since
on a heavily revised page the character advance is computed from the very lines
carrying marks and the gap disappears into it. On the reference draft this
removes 538 of 2,102 lines' worth of litter.

**Split parentheticals.** PDFKit reports a parenthetical as two overlapping runs
— the brackets apart from the word between them — and not always the same way:
sometimes `( )` around the content, sometimes a lone `)` after it, sometimes with
the opening bracket missing from the extraction altogether. Left alone that
yields an empty parenthetical and a stray line of dialogue. Where the two runs
overlap, the content is taken from one and the brackets rewritten.

**Page furniture** — page numbers, `(CONTINUED)`, `(MORE)` — is removed by
position, not by pattern. A bare number is furniture only in the top inch of the
page. This matters: `2007.` at the end of a wrapped line of dialogue is
indistinguishable from a page number by text alone, and discarding it is exactly
the bug this tool exists to avoid. There is a test for that line.

**Wrapped lines** are rejoined with single spaces — zero doubled inner spaces
survive in any of the reference conversions.

**Forced elements** are emitted only where the parser would otherwise misread the
text: `>` for a transition it would not recognise unaided, `.` for a shot
heading, `@` for a cue it would not read as one, `!` for an action line that
opens with a character that means something else in Fountain. The cue test asks
what the parser accepts rather than whether the line is all uppercase — the
latter forces every `LYNN (V.O.) (cont'd)` for no reason, 110 of them in the
reference draft.

**Speeches split across pages** by `(MORE)` / `(CONT'D)` are rejoined into one
speech, so the recovered script has the same element count as the printed one.

**Dual dialogue** is recognised and comes back with its caret. This is harder
than it sounds — see below.

**Title pages** are read from page one, with the draft date told apart from the
title. A bare date is a date; putting it in the `Title:` field is a common
importer mistake.

## Dual dialogue

PDFKit merges some side-by-side rows into a single selection and reports others
as two, so neither form can be trusted on its own. Columns are found by
**baseline**: a row qualifies when two runs of text share one, with a real gutter
between them. Only runs of two or more such rows are accepted, because a single
one could be a scene heading beside a gutter number — real dual dialogue is
always a cue plus at least one line of speech.

Two things in the margins imitate it:

- **Scene numbers** in the gutters. Excluded by requiring the right-hand column
  to begin no more than two inches right of the page midline.
- **Change marks on a revised draft.** These sit beyond the right margin and
  widen every row they appear on, so splitting at the midline cuts an ordinary
  sentence in half — `compu`/`ter`, `ma`/`ke`. On *Man Finds Tape*, a 100-page
  revised draft, the test as first written produced 138 false positives.
  Candidates are now also required to have been cut on whitespace (the two
  halves must rejoin into the row exactly), and the gap between the runs is then
  measured directly by bisecting for each run's true edge, since
  `-boundsForPage:` on a rect-derived selection reports the query rect rather
  than the glyphs.

With both guards that draft yields ten detections, and all ten are genuine: nine
are a pair of twins who speak in unison, and one is two characters shouting
"No!" together. Across the other three references the count is one — two
characters screaming at once — and zero for the remaining two.

Spot-checking the source PDF confirms it. On page 78 of *Man Finds Tape*,
`ENDICOTT` sits at x=155.3 and `LUCAS` at x=381.6 on the same baseline, while
two other `ENDICOTT` cues on the same page sit alone at x=269.5 and are
correctly left as ordinary dialogue.

`P2F_DUAL=1` prints every accepted row with its page number.

## Limitations

- Assumes dual columns are roughly symmetric about the centre of the text block.
  True of every layout measured here, but an assumption.
- Two dual passages with no element between them run together into one, because
  a run of qualifying rows is taken as a single exchange. Anything between them —
  action, a scene heading — separates them correctly, which is how they appear
  in practice.
- Emphasis is not recovered: `*utterly* **certain**` comes back as
  `utterly certain`. PDF text runs carry the styling in the font, which is not
  read.
- Revision marks are discarded rather than preserved as revision metadata, so a
  revised draft converts to a clean script but loses which lines had changed.
- Scene headings that carry no gutter number and no INT/EXT prefix stay as
  action, which is what the Fountain spec says they are.

## Round trip

`pdf2fountain` and [`fountain2pdf`](../fountain2pdf/README.md) are inverses, and
that is how both are tested — the detail of what survives a round trip, and what
rendering legitimately adds, is documented there. Converted output also
round-trips through the library's own writer with zero differences on all four
reference scripts.
