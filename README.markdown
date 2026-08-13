# Fountain

Fountain is a simple markup syntax that allows screenplays to be written, edited, and shared in plain, human-readable text. Fountain allows you to work on your screenplay anywhere, on any computer, using any software that edits text files.

Like John Gruber’s Markdown, a priority of Fountain is that the raw file itself is eminently readable. Every effort has been made to impose a minimum of syntax requirements. When syntax is required, it should be intuitive. Even when viewed in plain text, your screenplay should feel like a screenplay.

For more details on Fountain see http://fountain.io.

---

## About this fork

This is a fork of [nyousefi/Fountain](https://github.com/nyousefi/Fountain). The
upstream library is unchanged in shape — same classes, same data model — but a
number of parsing and output defects are fixed, the test suite has been ported
so it runs again, and two command line tools have been added.

**Three tools:**

| | |
|---|---|
| [`pdf2fountain`](pdf2fountain/README.md) | Converts a screenplay PDF to Fountain by reading glyph geometry rather than flattened text |
| [`fountain2pdf`](fountain2pdf/README.md) | Renders Fountain to a print-ready PDF in standard screenplay format |
| `fountain-dump` | Inspects a Fountain file and reports anything that looks wrong |

The first two are inverses, and that is how both are tested: rendering a script
to PDF and reading it back recovers every element count exactly.

`fountain-dump check` is the one to reach for after a conversion. It reports the
element census, the signs of a bad import — page numbers left in the body,
doubled spaces, `(CONTINUED)` markers, whitespace-only elements — and whether the
file survives a round trip through the writer unchanged. It exits non-zero when
it finds something, so it can gate a script:

```bash
./bin/pdf2fountain script.pdf out.fountain && ./bin/fountain-dump check out.fountain
```

Its other commands are `stats`, `elements` (one line per parsed element, with
flags for centred, dual-dialogue, scene number and section depth), `roundtrip`
and `html`. All read `-` for stdin.

**The library** now parses several things it previously got wrong. The two that
lost work: text appearing on the title page was deleted from the body wherever it
recurred, and every transition was rewritten as `> CUT TO:` on the way out.
Beyond those, `EXT/INT` and `E/I` slugs are recognised, a spoken line ending in
`TO:` stays dialogue instead of becoming a transition, sections and page breaks
no longer swallow the line after them, inline and multi-line boneyards no longer
leak into output, and HTML output is escaped. The full list is in the commit
message for `modernize-parser-and-converters`, and every item has a test in
`FountainTests/RegressionTests.m`.

The upstream note that Fountain "does not include production features such as
MOREs, CONTINUEDs, revision marks" remains true of the *format*. `fountain2pdf`
adds MOREs and CONTINUEDs at the rendering stage, where they belong, and
`pdf2fountain` removes them on the way back.

---

## Building

The Xcode project builds the library, the two sample apps and the tests. The
command line tools are built with make:

```bash
make            # both tools into bin/
make test       # run the XCTest suite
make clean
```

Building the sample app from Xcode needs a deployment target override on current
toolchains, since the project originally targeted macOS 10.7:

```bash
xcodebuild -project Fountain.xcodeproj -scheme "Sample Project Mac" build
```

## Overview

To encourage and ease integration of Fountain into your own apps we're making our own Fountain code available to you under a permissive MIT license. The code was designed for our own use, so your mileage may vary, but we're hoping this will at least help you get going with Fountain.

The Xcode project includes files to read and write Fountain files, and stores the file in a fairly generic data model. If this model is insufficent for your needs, or you have your own model you'd like to use, we recommend using a converter to bridge the two models.

One important note: we do not deal with text styling (bold, italic, underline, etc) in the parser or data model. We retain the styling and pass it along for downstream use. That is, whatever is supposed to display or print the Fountain file should handle text styling and clean up of the styling markup. We think that's just easier on everyone. We've included regular expressions for text styling, in case you need them.

## Components

### FNScript

FNScript is intended to make it easy to drop Fountain support into new apps. FNScript handles reading and writing of Fountain files, and holds the script content. The content of the script is represented as an NSArray of FNElements, and the title page is an NSArray of NSDictionary items.

### FNElement

This is the data model for the script elements.

### FastFountainParser

FastFountainParser is a redesigned line-by-line parser. The advantages to this parser over the previously used FountainParser are 1) less reliance on regular expressions (it should be much easier to change now) and 2) greatly improved performance. FastFountainParser is roughly 10 times faster than FountainParser. It is the default in FNScript, however you may still use the older FountainParser via using the FNParserTypeRegex option on the appropriate methods.

Note that the legacy `FountainParser` has **not** received the fixes described
above, and has a defect of its own: given a cue with a lower-case extension such
as `BRUCE (v.o.)`, it drops the character name entirely and keeps only the
extension, as a parenthetical. Prefer the default parser.

### FountainWriter

FountainWriter provides class methods to convert an FNScript into a Fountain NSString.

### FountainParser

FountainParser provides class methods to read a Fountain script's title page and script body separately. The body is returned as an NSArray of FNElements, and the title page is returned as an NSArray of NSDictionary items. This code is provided for legacy purposes.

### FountainRegexes

This file contains all the regular expressions used by FountainParser. It remains a part of this package because regular expressions provide the simplest route to portability. That said, please be aware that the regular expressions are not fully compliant with the tests, and may not be updated for a while.

### FNPDFRenderer

Renders an FNScript to a print-ready PDF. Layout is character-metric rather than
measured, which keeps it off AppKit and lands it on the columns the format calls
for. See [fountain2pdf/README.md](fountain2pdf/README.md) for the page geometry
and where the numbers come from.

### FNPDFImporter

Reads a screenplay PDF back into Fountain. See
[pdf2fountain/README.md](pdf2fountain/README.md).

## Installation

1. Copy all the files in the Fountain group to your project.
2. RegexKitLite requires the `-licucore` linker flag to be added to your project. See http://regexkit.sourceforge.net/RegexKitLite/#AddingRegexKitLitetoyourProject for help enabling RegexKitLite in your project.

If you don't want to use RegexKitLite you can remove the references to it in FountainParser.m and FountainWriter.m. You shouldn't have to change much code outside those files to change the regex library. While the regular expressions should be compatible with most standard regex implementation, you might have to massage them to work with a different library. Good luck with that.

RegexKitLite predates ARC and must be compiled with `-fno-objc-arc`; the Makefile
does this for you.

## Usage

See the sample project for a simple example of how the classes here can be used.

## Testing

```bash
make test
```

154 tests, and they run again — the suite was written against SenTestingKit,
which has not shipped with Xcode for years, so none of it had compiled or run in
a long time. It is now XCTest, the target is a proper `.xctest` bundle, and the
project carries a shared scheme with a test action.

Three groups:

- The **original suite**, ported. One expectation was changed rather than
  preserved: scene heading text no longer keeps the space that preceded a scene
  number, because the writer added its own and the document did not round-trip.
  The reasoning is recorded at the top of `SceneNumberTests.m`.
- **`RegressionTests.m`** — one test per fixed defect, named for the behaviour it
  protects. 20 of its 27 fail against upstream. The remaining seven guard
  behaviour that was already correct there, or that broke partway through this
  work and was fixed — a whitespace-only line crashing the scanner, a multi-line
  boneyard splitting the block around it.
- **`ConverterTests.m`** — the two tools, checked against each other. Page
  geometry is verified by reading the generated PDF back with PDFKit and
  asserting on the actual column positions.
- **`CheckTests.m`** — the judgement behind `fountain-dump check`. Each test
  feeds it something known to be wrong and asserts it says so, then feeds it the
  clean equivalent and asserts it does not.

## Known gaps

- `FNPaginator` still depends on AppKit/UIKit text layout; `FNPDFRenderer` does
  not, and is the better basis for new work.
- The vendored RegexKitLite is unmaintained and uses deprecated `OSSpinLock`.
  `NSRegularExpression` would remove the dependency and the `-licucore` flag.
- The iOS sample target needs the iOS platform installed to build.
- `pdf2fountain` does not recover emphasis; PDF text runs carry it in the font,
  which is not read.

## License

All code is copyright Nima Yousefi &amp; John August. Released under an MIT license. Do whatever you want with this code, but it would be super cool if you shared your improvements with the world.

See the included LICENSE file for legal jargon.

## Credits

### Fountain Format

Fountain comes from several sources. John August and Nima Yousefi developed Scrippets, which used simple markup to embed screenplay-formatted material in websites. Stu Maschwitz drafted a more extensive spec known as Screenplay Markdown or SPMD, designed for full-length screenplays.

Stu and John discovered that they were simultaneously working on similar text-based screenplay formats, and merged them into what you see here. Other contributors to the spec include Martin Vilcans, Brett Terpstra, Jonathan Poritsky, and Clinton Torres.

### Fountain Code

The code included here was developed by Nima Yousefi and John August, with copious emotional and spiritual support by Ryan Nelson and Stuart Friedel. However, all invectives should be directly solely at Nima Yousefi (don't worry, he has it coming).
