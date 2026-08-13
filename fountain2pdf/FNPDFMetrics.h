//
//  FNPDFMetrics.h
//
//  Page geometry for a US-Letter screenplay, in PostScript points.
//
//  These are the industry-standard margins as published by Final Draft, and
//  corroborated by the general formatting guidance. Measurements taken from
//  five produced scripts bracket them -- writers customise their templates, so
//  no single script is authoritative. See fountain2pdf/README.md.
//
//  Everything is single-spaced 12pt Courier on a 12pt baseline grid: 55 lines
//  to a page. There is no configurable leading; compressing a script to save
//  pages is not standard format.
//

#import <Foundation/Foundation.h>

// Paper
static const CGFloat kFNPageWidth        = 612.0;   // 8.5in
static const CGFloat kFNPageHeight       = 792.0;   // 11in

// Courier at 10 characters per inch. Screenplay layout is character-metric, so
// every column below is a whole number of characters from the paper edge.
static const CGFloat kFNFontSize         = 12.0;
static const CGFloat kFNCharWidth        = 7.2;     // 12pt Courier advance
static const CGFloat kFNLineHeight       = 12.0;    // single-spaced

// Margins. The first baseline sits 1in below the top of the paper and the last
// no higher than 1in above the bottom: (720 - 72) / 12 + 1 = 55 lines.
static const CGFloat kFNTopBaseline      = 720.0;
static const CGFloat kFNBottomBaseline   = 72.0;
static const NSUInteger kFNLinesPerPage  = 55;

// Element columns.
static const CGFloat kFNActionLeft        = 108.0;  // 1.50in, also scene headings
static const CGFloat kFNDialogueLeft      = 180.0;  // 2.50in
static const CGFloat kFNParentheticalLeft = 223.2;  // 3.10in
static const CGFloat kFNCharacterLeft     = 266.4;  // 3.70in
static const CGFloat kFNRightMargin       = 540.0;  // 7.50in; transitions end here

// Wrap widths, in characters.
static const NSUInteger kFNActionWidth        = 60;  // 1.5in - 7.5in
static const NSUInteger kFNDialogueWidth      = 35;  // 2.5in - 6.0in
static const NSUInteger kFNParentheticalWidth = 25;  // 3.1in - 5.6in
static const NSUInteger kFNCharacterWidth     = 38;

// Page number: "12." right-aligned at 7.25in, baseline 0.5in below the top.
// Page one is never numbered.
static const CGFloat kFNPageNumberRight  = 522.0;
static const CGFloat kFNPageNumberY      = 756.0;

// Scene numbers sit in the gutters either side of the text block.
static const CGFloat kFNSceneNumberLeft  = 54.0;    // 0.75in
static const CGFloat kFNSceneNumberRight = 540.0;   // 7.50in

/*
 Dual dialogue divides the 6in text block into two columns with a gutter
 between them. Within a column the dialogue sits at the column's left edge, the
 parenthetical is indented, and the character cue is centred over the block.
 */
// 108 + 194.4 + 43.2 gutter = 345.6, and 345.6 + 194.4 = 540: the two columns
// and the gutter tile the 6in text block exactly.
static const CGFloat kFNDualColumnWidth  = 194.4;   // 2.70in == 27 characters
static const CGFloat kFNDualLeftColumn   = 108.0;   // 1.50in
static const CGFloat kFNDualRightColumn  = 345.6;   // 4.80in
static const NSUInteger kFNDualWidth     = 27;
static const NSUInteger kFNDualParenIndent = 4;     // characters

/*
 A character cue is indented within its column, not centred over it. Measured
 from the reference: in the one script here that carries several dual-dialogue
 passages, LUCAS (5 characters) and FERNETTE (8) both begin at x=381.6, and the
 cue sits 65.8pt -- 9 characters -- right of its own dialogue, identically in
 both columns. That is the same relationship as the single-column layout, where
 the cue is 12 characters right of the dialogue, scaled by the narrower column.
 */
static const NSUInteger kFNDualCueIndent = 9;       // characters

// Continuation markers when a speech breaks across a page.
static const CGFloat kFNMoreLeft         = 223.2;  // aligned with parentheticals
