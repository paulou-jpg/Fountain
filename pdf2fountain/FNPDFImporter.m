//
//  FNPDFImporter.m
//
//  Screenplay PDFs carry their structure geometrically: the left edge of a line
//  tells you whether it is action, dialogue, a parenthetical, a character cue or
//  a transition. Importers that work from flattened text throw that away and
//  then try to guess it back from capitalisation, which is where the usual
//  damage comes from -- swallowed numerals, dialogue promoted to action, page
//  furniture left in the body.
//
//  This reads glyph positions via PDFKit, recovers lines and their indentation,
//  clusters the indents into columns, and emits Fountain from the result.
//

#import "FNPDFImporter.h"
#import <Quartz/Quartz.h>

static const CGFloat kPointsPerInch = 72.0;

typedef NS_ENUM(NSInteger, P2FKind) {
    P2FKindUnknown = 0,
    P2FKindAction,
    P2FKindSceneHeading,
    P2FKindCharacter,
    P2FKindParenthetical,
    P2FKindDialogue,
    P2FKindTransition,
    P2FKindCentered,
};

@interface P2FLine : NSObject
@property (copy, nonatomic) NSString *text;
@property (nonatomic) CGFloat left;
@property (nonatomic) CGFloat right;
@property (nonatomic) CGFloat top;       // distance from top of page
@property (nonatomic) NSInteger page;
@property (nonatomic) P2FKind kind;
@property (copy, nonatomic) NSString *sceneNumber;
@property (nonatomic) BOOL blankBefore;
@property (nonatomic) NSInteger dualColumn;   // -1 normal, 0 left, 1 right
@property (nonatomic) NSRect bounds;          // page coordinates, for re-querying
@end

@implementation P2FLine
- (instancetype)init
{
    self = [super init];
    if (self) _dualColumn = -1;
    return self;
}
@end

#pragma mark - Text helpers

static NSString *P2FTrim(NSString *s)
{
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Collapse runs of internal whitespace. PDF text carries the visual padding of
// the page; rejoining wrapped lines verbatim is what produces the "double space
// everywhere" look in converted files.
static NSString *P2FCollapseSpaces(NSString *s)
{
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"[ \\t]{2,}" options:0 error:NULL];
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@" "];
}

static BOOL P2FMatches(NSString *s, NSString *pattern)
{
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:NSRegularExpressionCaseInsensitive
                                                                         error:NULL];
    return [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] > 0;
}

static BOOL P2FMatchesCS(NSString *s, NSString *pattern)
{
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    return [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] > 0;
}

static BOOL P2FIsUpper(NSString *s)
{
    BOOL sawLetter = NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 'a' && c <= 'z') return NO;
        if (c >= 'A' && c <= 'Z') sawLetter = YES;
    }
    return sawLetter;
}

// Slug prefixes, matching the parser's own recognition.
static BOOL P2FLooksLikeSlug(NSString *s)
{
    return P2FMatches(s, @"^(INT|EXT|EST|INT\\.?/EXT|EXT\\.?/INT|I\\.?/E|E\\.?/I)\\.?([.\\-\\s]|$)");
}

static BOOL P2FLooksLikeTransition(NSString *s)
{
    if (P2FMatchesCS(s, @"^[^a-z\\n]*[A-Z][^a-z\\n]*TO:$")) return YES;
    // Only these three are recognised unaided by the parser; anything else has
    // to be forced with '>' or it will come back as Action.
    NSSet *standard = [NSSet setWithObjects:@"FADE OUT.", @"FADE TO BLACK.", @"CUT TO BLACK.", nil];
    return [standard containsObject:P2FTrim(s)];
}

/*
 Page furniture that should never reach the Fountain body.

 The number test is deliberately position-gated. A line that is nothing but
 "2007." looks exactly like a page number, but it is also how a wrapped line of
 dialogue can end -- and discarding it on text alone is precisely the mistake
 that silently eats real numerals. Only a bare number in the top inch of the
 page is furniture.
 */
static BOOL P2FIsPageFurniture(P2FLine *line)
{
    NSString *t = P2FTrim(line.text);
    if (t.length == 0) return YES;
    if (P2FMatchesCS(t, @"^\\(?(CONTINUED|MORE)\\)?[.:]?$")) return YES;
    if (P2FMatchesCS(t, @"^CONTINUED:?\\s*\\(\\d+\\)$")) return YES;

    BOOL inHeaderBand = (line.top < 72.0);
    if (!inHeaderBand) return NO;
    if (P2FMatchesCS(t, @"^\\d{1,4}\\.$")) return YES;               // page number
    if (P2FMatchesCS(t, @"^\\d{1,4}\\.\\s+\\d{1,4}\\.$")) return YES;  // doubled page number
    return NO;
}

#pragma mark - Extraction

/*
 The narrowest window starting at x0 that still contains all of `target`, i.e.
 where that run of text ends. -boundsForPage: on a rect-derived selection
 reports the query rect rather than the glyphs, so the edge has to be found by
 bisection instead.
 */
static CGFloat P2FTextRightEdge(PDFPage *page, NSRect row, CGFloat x0, CGFloat x1, NSString *target)
{
    CGFloat lo = x0, hi = x1;
    for (int step = 0; step < 12 && (hi - lo) > 1.0; step++) {
        CGFloat mid = (lo + hi) / 2.0;
        NSString *t = P2FTrim([[page selectionForRect:
            NSMakeRect(x0 - 1, NSMinY(row), mid - x0 + 1, NSHeight(row))] string] ?: @"");
        if ([t isEqualToString:target]) hi = mid; else lo = mid;
    }
    return hi;
}

/// The mirror image: where a run of text ending at x1 begins.
static CGFloat P2FTextLeftEdge(PDFPage *page, NSRect row, CGFloat x0, CGFloat x1, NSString *target)
{
    CGFloat lo = x0, hi = x1;
    for (int step = 0; step < 12 && (hi - lo) > 1.0; step++) {
        CGFloat mid = (lo + hi) / 2.0;
        NSString *t = P2FTrim([[page selectionForRect:
            NSMakeRect(mid, NSMinY(row), x1 - mid + 1, NSHeight(row))] string] ?: @"");
        if ([t isEqualToString:target]) lo = mid; else hi = mid;
    }
    return lo;
}


// Recover lines with their geometry from a PDF page.
//
// PDFKit's own line segmentation is used rather than raw glyph positions:
// -characterBoundsAtIndex: indexes the content stream, while -string is in
// reading order, so the two cannot be zipped together. -selectionsByLine gives
// both the text and its bounds in one consistent space.
static NSArray<P2FLine *> *P2FLinesForPage(PDFPage *page, NSInteger pageIndex)
{
    NSRect pageBounds = [page boundsForBox:kPDFDisplayBoxMediaBox];
    PDFSelection *whole = [page selectionForRect:pageBounds];
    if (!whole) return @[];

    NSRegularExpression *ctrl = [NSRegularExpression regularExpressionWithPattern:
                                 @"[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]" options:0 error:NULL];

    NSMutableArray<P2FLine *> *lines = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (PDFSelection *sel in [whole selectionsByLine]) {
        NSString *raw = [sel string];
        if (raw.length == 0) continue;
        NSString *content = P2FTrim(raw);
        if (content.length == 0) continue;

        NSRect r = [sel boundsForPage:page];
        if (NSIsEmptyRect(r)) continue;

        // The same line can come back more than once; key on position + text.
        NSString *key = [NSString stringWithFormat:@"%ld|%ld|%@",
                         (long)llround(NSMinY(r)), (long)llround(NSMinX(r)), content];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];

        content = [ctrl stringByReplacingMatchesInString:content options:0
                                                   range:NSMakeRange(0, content.length) withTemplate:@""];

        P2FLine *line = [[P2FLine alloc] init];
        line.text = P2FCollapseSpaces(content);
        line.left = NSMinX(r);
        line.right = NSMaxX(r);
        line.bounds = r;
        line.top = NSMaxY(pageBounds) - NSMaxY(r);
        line.page = pageIndex;
        [lines addObject:line];
    }

    [lines sortUsingComparator:^NSComparisonResult(P2FLine *a, P2FLine *b) {
        if (fabs(a.top - b.top) > 2.0) return a.top < b.top ? NSOrderedAscending : NSOrderedDescending;
        return a.left < b.left ? NSOrderedAscending : NSOrderedDescending;
    }];

    /*
     The character advance for this page, as the MEDIAN width-per-character.
     A mean is dragged upwards by rows that hold two columns, and a minimum is
     dragged downwards by any single odd line; the median is stable as long as
     most of the page is ordinary text, which it always is.
     */
    NSMutableArray *ratios = [NSMutableArray array];
    for (P2FLine *line in lines) {
        if (line.text.length < 10) continue;
        [ratios addObject:@((line.right - line.left) / (CGFloat)line.text.length)];
    }
    [ratios sortUsingSelector:@selector(compare:)];
    CGFloat charAdvance = ratios.count ? [ratios[ratios.count / 2] doubleValue] : 7.2;
    if (charAdvance <= 0) charAdvance = 7.2;

    CGFloat splitX = NSMidX(pageBounds);

    /*
     Dual dialogue is decided by baseline, and only then are merged rows taken
     apart. PDFKit merges some side-by-side rows into one selection and reports
     others separately, so a row qualifies either way:

       - two pieces of text sharing a baseline, one each side of the midline,
         separated by a real gutter; or
       - one piece straddling the midline that is far wider than its text needs.

     A single such row proves nothing -- a scene heading flanked by a gutter
     number looks identical. Real dual dialogue is a cue plus at least one line
     of speech, so only runs of two or more rows are accepted, and nothing is
     split outside them.
     */
    NSMutableArray<NSMutableArray<P2FLine *> *> *rows = [NSMutableArray array];
    for (P2FLine *line in lines) {
        NSMutableArray *row = rows.lastObject;
        if (row && fabs([(P2FLine *)row.firstObject top] - line.top) <= 2.0) [row addObject:line];
        else [rows addObject:[NSMutableArray arrayWithObject:line]];
    }

    /*
     A dual right-hand column is a block of speech that begins not far right of
     the midline. Two things in the margins imitate it and must not be mistaken
     for it: revision asterisks on a revised draft, which sit out beyond the
     right margin, and scene numbers in the gutters. Requiring both sides to
     carry real text, and the right side to start within a column's reach of the
     midline, rules them out.
     */
    CGFloat rightColumnLimit = splitX + kPointsPerInch * 2.0;
    NSUInteger minimumColumnLength = 2;

    NSMutableDictionary<NSNumber *, NSArray<NSString *> *> *splitCache = [NSMutableDictionary dictionary];

    NSMutableIndexSet *dualRows = [NSMutableIndexSet indexSet];
    NSUInteger runStart = 0;
    for (NSUInteger i = 0; i <= rows.count; i++) {
        BOOL qualifies = NO;

        if (i < rows.count) {
            NSArray *row = rows[i];
            if (row.count == 2) {
                P2FLine *a = row[0], *b = row[1];
                qualifies = (a.right < splitX && b.left >= splitX &&
                             (b.left - a.right) > charAdvance * 3.0 &&
                             a.text.length >= minimumColumnLength &&
                             b.text.length >= minimumColumnLength &&
                             b.left <= rightColumnLimit);
            }
            else if (row.count == 1) {
                P2FLine *a = row[0];
                CGFloat needed = a.text.length * charAdvance;
                if (a.left < splitX && a.right > splitX &&
                    (a.right - a.left - needed) > charAdvance * 3.0) {
                    // Trial split, cached so the accepted pass need not repeat it.
                    NSRect r = a.bounds;
                    NSString *leftText = P2FTrim([[page selectionForRect:
                        NSMakeRect(NSMinX(r) - 1, NSMinY(r), splitX - NSMinX(r), NSHeight(r))] string] ?: @"");
                    NSString *rightText = P2FTrim([[page selectionForRect:
                        NSMakeRect(splitX, NSMinY(r), NSMaxX(r) - splitX + 1, NSHeight(r))] string] ?: @"");
                    /*
                     Splitting at the midline only means something if the
                     midline lands in a gutter. On a revised draft the row is
                     wide because of a change mark out in the margin, and the
                     split lands mid-sentence -- so first check that the two
                     halves rejoin into the row exactly, which can only happen
                     if the cut fell on whitespace.
                     */
                    NSString *rejoined = P2FCollapseSpaces([NSString stringWithFormat:@"%@ %@", leftText, rightText]);
                    BOOL cutOnWhitespace = [rejoined isEqualToString:P2FCollapseSpaces(a.text)];

                    qualifies = (leftText.length >= minimumColumnLength &&
                                 rightText.length >= minimumColumnLength &&
                                 cutOnWhitespace);

                    if (qualifies) {
                        // A word boundary is not enough on its own -- the cut
                        // could have fallen on an ordinary space. Measure the
                        // real distance between the two runs of text.
                        CGFloat leftEnd = P2FTextRightEdge(page, r, NSMinX(r), splitX, leftText);
                        CGFloat rightStart = P2FTextLeftEdge(page, r, splitX, NSMaxX(r), rightText);
                        qualifies = ((rightStart - leftEnd) > charAdvance * 3.0 &&
                                     rightStart <= rightColumnLimit);
                    }
                    if (qualifies) splitCache[@(i)] = @[leftText, rightText];
                }
            }
        }

        if (qualifies) continue;
        if (i - runStart >= 2) [dualRows addIndexesInRange:NSMakeRange(runStart, i - runStart)];
        runStart = i + 1;
    }

    if (dualRows.count == 0) return lines;

    NSMutableArray<P2FLine *> *result = [NSMutableArray array];
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSArray<P2FLine *> *row = rows[i];

        if (![dualRows containsIndex:i]) {
            [result addObjectsFromArray:row];
            continue;
        }

        if (row.count == 2) {
            [row[0] setDualColumn:0];
            [row[1] setDualColumn:1];
            if (getenv("P2F_DUAL")) {
                fprintf(stderr, "dual p%ld: |%s| // |%s|\n", (long)pageIndex + 1,
                        [(P2FLine *)row[0] text].UTF8String, [(P2FLine *)row[1] text].UTF8String);
            }
            [result addObjectsFromArray:row];
            continue;
        }

        // One merged row, taken apart during qualification.
        P2FLine *merged = row[0];
        NSRect r = merged.bounds;
        NSArray<NSString *> *halves = splitCache[@(i)];
        NSString *leftText = halves.firstObject ?: @"";
        NSString *rightText = halves.lastObject ?: @"";

        if (leftText.length == 0 || rightText.length == 0) {
            [result addObjectsFromArray:row];   // could not split; leave it be
            continue;
        }

        // -boundsForPage: on a rect-derived selection reports the query rect,
        // not the glyphs, so the halves are placed against the outer edges of
        // the merged row instead.
        NSInteger column = 0;
        for (NSArray *half in @[@[leftText, @(NSMinX(r))],
                                @[rightText, @(NSMaxX(r) - rightText.length * charAdvance)]]) {
            P2FLine *line = [[P2FLine alloc] init];
            line.text = P2FCollapseSpaces(half[0]);
            line.left = [half[1] doubleValue];
            line.right = line.left + [(NSString *)half[0] length] * charAdvance;
            line.bounds = NSMakeRect(line.left, NSMinY(r), line.right - line.left, NSHeight(r));
            line.top = merged.top;
            line.page = pageIndex;
            line.dualColumn = column++;
            [result addObject:line];
        }
        if (getenv("P2F_DUAL")) {
            fprintf(stderr, "dual p%ld: |%s| // |%s|\n", (long)pageIndex + 1,
                    leftText.UTF8String, rightText.UTF8String);
        }
    }
    return result;
}

#pragma mark - Column model

/*
 Rather than assume Final Draft's exact margins, learn them: the most common
 left edge in the document is the action margin, and every other column is
 described as an offset from it.
 */
typedef struct {
    CGFloat action;
    CGFloat dialogue;
    CGFloat parenthetical;
    CGFloat character;
    CGFloat transition;
} P2FColumns;

static P2FColumns P2FLearnColumns(NSArray<P2FLine *> *lines)
{
    // Histogram of left edges, quantised to 3pt.
    NSCountedSet *hist = [NSCountedSet set];
    for (P2FLine *l in lines) {
        [hist addObject:@((NSInteger)llround(l.left / 3.0) * 3)];
    }

    /*
     A column is "substantial" if it carries a real share of the document. That
     rules out the scene-number gutter and the page-number corner, which are
     further left and further right than any body column but appear on only a
     few percent of lines. The action margin is then simply the leftmost
     substantial column -- NOT the most common one, which in a dialogue-heavy
     script is the dialogue column.
     */
    NSUInteger threshold = MAX((NSUInteger)20, (NSUInteger)(lines.count / 20));
    NSMutableArray<NSNumber *> *substantial = [NSMutableArray array];
    for (NSNumber *n in hist) {
        if ([hist countForObject:n] >= threshold) [substantial addObject:n];
    }
    [substantial sortUsingSelector:@selector(compare:)];

    P2FColumns cols;
    cols.action = substantial.count ? [substantial[0] doubleValue] : 108.0;

    cols.dialogue = cols.action + kPointsPerInch * 0.9;
    for (NSNumber *n in substantial) {
        if ([n doubleValue] > cols.action + kPointsPerInch * 0.4) { cols.dialogue = [n doubleValue]; break; }
    }

    cols.character = cols.action + kPointsPerInch * 2.0;
    for (NSNumber *n in substantial) {
        CGFloat x = [n doubleValue];
        if (x > cols.dialogue + kPointsPerInch * 0.4 && x < cols.action + kPointsPerInch * 3.4) {
            cols.character = x;
        }
    }

    cols.parenthetical = (cols.dialogue + cols.character) / 2.0;
    cols.transition = cols.character + kPointsPerInch * 1.2;

    return cols;
}

// Assign to the nearest learned column, then let the text override where it is
// unambiguous (a slug is a slug; a line starting with "(" is a parenthetical).
static P2FKind P2FClassify(P2FLine *line, P2FColumns cols, CGFloat rightMargin)
{
    NSString *t = line.text;

    // A number printed in the scene-number gutter is the production's own
    // statement that this line is a scene heading -- including shot headings
    // like "BLACK SCREEN." that carry no INT/EXT prefix.
    if (line.sceneNumber.length > 0) return P2FKindSceneHeading;

    CGFloat candidates[5] = { cols.action, cols.dialogue, cols.parenthetical, cols.character, cols.transition };
    P2FKind kinds[5] = { P2FKindAction, P2FKindDialogue, P2FKindParenthetical, P2FKindCharacter, P2FKindTransition };
    P2FKind kind = P2FKindAction;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (int i = 0; i < 5; i++) {
        CGFloat d = fabs(line.left - candidates[i]);
        if (d < bestDistance) { bestDistance = d; kind = kinds[i]; }
    }

    if ([t hasPrefix:@"("] && (kind == P2FKindCharacter || kind == P2FKindParenthetical || kind == P2FKindDialogue)) {
        return P2FKindParenthetical;
    }
    // The parenthetical column sits between dialogue and character, so short
    // lines land on it by proximity. A parenthetical always opens with "(".
    if (kind == P2FKindParenthetical) {
        kind = P2FKindDialogue;
    }
    if (kind == P2FKindCharacter && ![t hasPrefix:@"("] && !P2FIsUpper(t) && t.length > 40) {
        return P2FKindDialogue;   // a long mixed-case line is not a cue
    }
    if (kind == P2FKindTransition && !P2FIsUpper(t)) {
        return P2FKindAction;
    }
    if (kind == P2FKindAction) {
        if (P2FLooksLikeSlug(t)) return P2FKindSceneHeading;
        // Centered text sits inset from both margins by a similar amount.
        CGFloat leftGap = line.left - cols.action;
        CGFloat rightGap = rightMargin - line.right;
        if (leftGap > kPointsPerInch * 0.5 && fabs(leftGap - rightGap) < kPointsPerInch * 0.4) {
            return P2FKindCentered;
        }
    }
    return kind;
}

#pragma mark - Scene numbers

/*
 Margin scene numbers sit outside the action margin on both sides of a slug.
 They are the single biggest source of corrupted numerals in converted files:
 flattened text glues them onto the heading, and cleanup regexes then eat real
 numbers trying to remove them. Here they are simply identified by position.
 */
static void P2FExtractSceneNumbers(NSMutableArray<P2FLine *> *lines, P2FColumns cols)
{
    NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];

    for (NSUInteger i = 0; i < lines.count; i++) {
        P2FLine *l = lines[i];
        if (l.left >= cols.action - 12.0) continue;   // starts at or right of the margin

        NSString *t = P2FTrim(l.text);

        // The gutter line holds the scene number, usually printed twice -- once
        // in each margin. It is its own line in the layout, so it is lifted out
        // and attached to the heading that follows.
        NSRegularExpression *pair = [NSRegularExpression regularExpressionWithPattern:
                                     @"^([0-9][0-9A-Za-z.\\-]{0,7})(?:\\s+\\1)?$" options:0 error:NULL];
        if ([pair numberOfMatchesInString:t options:0 range:NSMakeRange(0, t.length)] > 0) {
            NSTextCheckingResult *m = [pair firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
            NSString *number = [t substringWithRange:[m rangeAtIndex:1]];
            for (NSUInteger j = i + 1; j < lines.count && j < i + 3; j++) {
                P2FLine *next = lines[j];
                if (next.page != l.page) break;
                if (P2FLooksLikeSlug(next.text) || P2FIsUpper(next.text)) {
                    next.sceneNumber = number;
                    break;
                }
            }
            [drop addIndex:i];
            continue;
        }

        // Or the number shares the heading's own line.
        NSRegularExpression *inline_ = [NSRegularExpression regularExpressionWithPattern:
                                        @"^([0-9][0-9A-Za-z.\\-]*)\\s+(.*?)(?:\\s+([0-9][0-9A-Za-z.\\-]*))?$"
                                                                               options:0 error:NULL];
        NSTextCheckingResult *m = [inline_ firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
        if (!m) continue;
        NSString *number = [t substringWithRange:[m rangeAtIndex:1]];
        NSString *body = [t substringWithRange:[m rangeAtIndex:2]];
        if (!P2FLooksLikeSlug(body) && !P2FIsUpper(body)) continue;

        l.text = P2FTrim(body);
        l.sceneNumber = number;
        l.left = cols.action;
    }

    [lines removeObjectsAtIndexes:drop];
}

#pragma mark - Assembly

static NSString *P2FBuildFountain(NSArray<P2FLine *> *lines, NSDictionary *titlePage, P2FColumns cols)
{
    NSMutableString *out = [NSMutableString string];

    // ---- Title page -------------------------------------------------------
    NSArray *order = @[@"Title", @"Credit", @"Author", @"Authors", @"Source", @"Draft date", @"Contact"];
    BOOL wroteTitle = NO;
    for (NSString *key in order) {
        NSString *value = titlePage[key];
        if (value.length == 0) continue;
        if ([value containsString:@"\n"]) {
            [out appendFormat:@"%@:\n", key];
            for (NSString *part in [value componentsSeparatedByString:@"\n"]) {
                if (P2FTrim(part).length) [out appendFormat:@"\t%@\n", P2FTrim(part)];
            }
        }
        else {
            [out appendFormat:@"%@: %@\n", key, value];
        }
        wroteTitle = YES;
    }
    if (wroteTitle) [out appendString:@"\n"];

    // ---- Body -------------------------------------------------------------
    __block P2FKind previousKind = P2FKindUnknown;
    NSMutableArray<P2FLine *> *block = [NSMutableArray array];

    void (^flush)(void) = ^{
        if (block.count == 0) return;
        P2FLine *first = block[0];
        P2FKind kind = first.kind;

        // Rejoin the wrapped lines of the block with single spaces.
        NSMutableString *joined = [NSMutableString string];
        for (P2FLine *l in block) {
            if (joined.length) [joined appendString:@" "];
            [joined appendString:l.text];
        }
        NSString *text = P2FCollapseSpaces(P2FTrim(joined));
        if (text.length == 0) { [block removeAllObjects]; return; }

        /*
         Dialogue with no character cue above it is not dialogue. Sound and
         music cues are often typeset at the dialogue indent with no cue line;
         treated as dialogue they would be emitted bare, and a leading '.' would
         then be read back as a forced scene heading.
         */
        if ((kind == P2FKindDialogue || kind == P2FKindParenthetical) &&
            !(previousKind == P2FKindCharacter || previousKind == P2FKindParenthetical ||
              previousKind == P2FKindDialogue)) {
            kind = P2FKindAction;
        }

        BOOL isDialogueRun = (kind == P2FKindDialogue || kind == P2FKindParenthetical);
        // Character / Parenthetical / Dialogue form one block with no blank
        // lines between them; everything else is separated by one blank line.
        if (out.length > 0 && ![out hasSuffix:@"\n\n"]) {
            if (!(isDialogueRun && (previousKind == P2FKindCharacter ||
                                    previousKind == P2FKindDialogue ||
                                    previousKind == P2FKindParenthetical))) {
                [out appendString:@"\n"];
            }
        }

        switch (kind) {
            case P2FKindSceneHeading: {
                // Force the slug when it does not start with a standard prefix,
                // so shot headings like "A RIVER." survive as scene headings.
                if (!P2FLooksLikeSlug(text)) [out appendString:@"."];
                [out appendString:text];
                if (first.sceneNumber.length) [out appendFormat:@" #%@#", first.sceneNumber];
                [out appendString:@"\n"];
                break;
            }
            case P2FKindTransition: {
                // Force it unless the parser would recognise it unaided.
                if (!P2FLooksLikeTransition(text)) [out appendString:@"> "];
                [out appendFormat:@"%@\n", text];
                break;
            }
            case P2FKindCentered:
                [out appendFormat:@"> %@ <\n", text];
                break;
            case P2FKindCharacter: {
                // Mixed-case cues have to be forced or they read as action.
                if (!P2FIsUpper([text stringByReplacingOccurrencesOfString:@"^" withString:@""])) {
                    [out appendString:@"@"];
                }
                [out appendFormat:@"%@\n", text];
                break;
            }
            case P2FKindAction: {
                /*
                 No '!' forcing is needed to stop an all-caps line reading as a
                 cue -- every block is separated by a blank line, and a cue
                 requires a non-blank line after it. It IS needed when the line
                 opens with a character that forces some other element: a
                 stage direction like ". Button. Blue light washes the stage."
                 would otherwise be read as a forced scene heading.
                 */
                unichar first = [text characterAtIndex:0];
                if (first == '.' || first == '>' || first == '~' || first == '@' ||
                    first == '#' || first == '=' || first == '!') {
                    [out appendString:@"!"];
                }
                [out appendFormat:@"%@\n", text];
                break;
            }
            default:
                [out appendFormat:@"%@\n", text];
                break;
        }
        if (getenv("P2F_TRACE") && [text containsString:[NSString stringWithUTF8String:getenv("P2F_TRACE")]]) {
            fprintf(stderr, "TRACE kind=%ld prevKind=%ld blankBefore=%d |%s|\n",
                    (long)kind, (long)previousKind, (int)first.blankBefore, text.UTF8String);
        }
        previousKind = kind;
        [block removeAllObjects];
    };

    /*
     One side of a dual-dialogue pair: the cue, then its speech. The second
     column carries the caret that tells the parser the two are simultaneous.
     */
    void (^emitSpeech)(NSArray<P2FLine *> *, BOOL) = ^(NSArray<P2FLine *> *column, BOOL isSecond) {
        if (column.count == 0) return;
        if (out.length > 0 && ![out hasSuffix:@"\n\n"]) [out appendString:@"\n"];

        NSString *cue = P2FCollapseSpaces(P2FTrim(column[0].text));
        if (!P2FIsUpper(cue)) [out appendString:@"@"];      // mixed-case cues must be forced
        [out appendFormat:@"%@%@\n", cue, isSecond ? @" ^" : @""];

        NSMutableString *speech = [NSMutableString string];
        for (NSUInteger k = 1; k < column.count; k++) {
            NSString *t = P2FTrim(column[k].text);
            if (t.length == 0) continue;
            if ([t hasPrefix:@"("]) {
                if (speech.length) { [out appendFormat:@"%@\n", P2FCollapseSpaces(speech)]; [speech setString:@""]; }
                [out appendFormat:@"%@\n", P2FCollapseSpaces(t)];
                continue;
            }
            if (speech.length) [speech appendString:@" "];
            [speech appendString:t];
        }
        if (speech.length) [out appendFormat:@"%@\n", P2FCollapseSpaces(speech)];
        previousKind = P2FKindDialogue;
    };

    NSUInteger index = 0;
    while (index < lines.count) {
        P2FLine *line = lines[index];

        // A run of side-by-side rows becomes two speeches, the second carrying ^.
        if (line.dualColumn >= 0) {
            flush();
            NSMutableArray *leftColumn = [NSMutableArray array];
            NSMutableArray *rightColumn = [NSMutableArray array];
            while (index < lines.count && lines[index].dualColumn >= 0) {
                if (lines[index].dualColumn == 0) [leftColumn addObject:lines[index]];
                else [rightColumn addObject:lines[index]];
                index++;
            }
            emitSpeech(leftColumn, NO);
            emitSpeech(rightColumn, YES);
            continue;
        }

        if (line.kind == P2FKindUnknown) { index++; continue; }
        if (block.count > 0) {
            P2FLine *prev = block.lastObject;
            BOOL sameKind = (prev.kind == line.kind);
            BOOL contiguous = !line.blankBefore;
            // Scene headings, cues, transitions and parentheticals are single
            // blocks; only action and dialogue wrap across lines.
            BOOL wrappable = (line.kind == P2FKindAction || line.kind == P2FKindDialogue);
            if (!(sameKind && contiguous && wrappable)) flush();
        }
        [block addObject:line];
        index++;
    }
    flush();

    // Never emit more than one blank line in a row.
    NSRegularExpression *squeeze = [NSRegularExpression regularExpressionWithPattern:@"\\n{3,}" options:0 error:NULL];
    NSString *result = [squeeze stringByReplacingMatchesInString:out options:0
                                                           range:NSMakeRange(0, out.length) withTemplate:@"\n\n"];
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
}

#pragma mark - Title page

static NSDictionary *P2FTitlePageFromLines(NSArray<P2FLine *> *lines, NSInteger *outConsumed)
{
    NSMutableDictionary *tp = [NSMutableDictionary dictionary];
    NSMutableArray *pageOne = [NSMutableArray array];
    for (P2FLine *l in lines) {
        if (l.page != 0) break;
        [pageOne addObject:l];
    }
    if (pageOne.count == 0) { *outConsumed = 0; return tp; }

    // A title page has no slug and little text. If page one looks like script,
    // leave it alone.
    for (P2FLine *l in pageOne) {
        if (P2FLooksLikeSlug(l.text)) { *outConsumed = 0; return tp; }
    }
    if (pageOne.count > 14) { *outConsumed = 0; return tp; }

    NSMutableArray *credits = [NSMutableArray array];
    NSMutableArray *contact = [NSMutableArray array];
    NSString *title = nil;
    NSString *draftDate = nil;
    NSString *credit = nil;
    BOOL seenBy = NO;

    for (P2FLine *l in pageOne) {
        NSString *t = P2FCollapseSpaces(P2FTrim(l.text));
        if (t.length == 0) continue;

        if (P2FMatches(t, @"^(written|screenplay|story|teleplay)\\s+by$") || [t.lowercaseString isEqualToString:@"by"]) {
            credit = t; seenBy = YES; continue;
        }
        // A bare date is a draft date, not the title -- this is the mistake
        // that puts "08/06/2026" in the Title field.
        if (P2FMatches(t, @"^\\d{1,4}[-/.]\\d{1,2}[-/.]\\d{1,4}$") ||
            P2FMatches(t, @"^(draft|revision|rev\\.?)\\b.*") ||
            P2FMatches(t, @"^[A-Z][a-z]+ \\d{1,2},? \\d{4}$")) {
            draftDate = draftDate ?: t; continue;
        }
        if (P2FMatches(t, @"^(\\+?[0-9() .\\-]{7,}|\\S+@\\S+\\.\\S+)$")) { [contact addObject:t]; continue; }
        if (!seenBy && !title) { title = t; continue; }
        if (seenBy) { [credits addObject:t]; continue; }
        [contact addObject:t];
    }

    if (title) tp[@"Title"] = title;
    if (credit) tp[@"Credit"] = credit;
    if (credits.count) tp[credits.count > 1 ? @"Authors" : @"Author"] = [credits componentsJoinedByString:@"\n"];
    if (draftDate) tp[@"Draft date"] = draftDate;
    if (contact.count) tp[@"Contact"] = [contact componentsJoinedByString:@"\n"];

    *outConsumed = (NSInteger)pageOne.count;
    return tp;
}

#pragma mark - Entry point

@implementation FNPDFImporter

+ (NSString *)fountainFromPDFAtPath:(NSString *)path error:(NSError **)error
{
    NSURL *url = [NSURL fileURLWithPath:[path stringByExpandingTildeInPath]];
    PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
    if (!doc) {
        if (error) {
            *error = [NSError errorWithDomain:@"FNPDFImporter" code:1 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not open %@", path]}];
        }
        return nil;
    }

    NSMutableArray<P2FLine *> *lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < [doc pageCount]; i++) {
        [lines addObjectsFromArray:P2FLinesForPage([doc pageAtIndex:i], (NSInteger)i)];
    }
    if (lines.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"FNPDFImporter" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"No text layer found -- the PDF may be scanned images"}];
        }
        return nil;
    }

    NSInteger consumed = 0;
    NSMutableDictionary *titlePage = [P2FTitlePageFromLines(lines, &consumed) mutableCopy];
    if ([titlePage[@"Title"] length] == 0) {
        NSString *metaTitle = P2FTrim([doc documentAttributes][PDFDocumentTitleAttribute] ?: @"");
        if (metaTitle.length > 0 && ![metaTitle.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
            titlePage[@"Title"] = metaTitle;
        }
    }
    if (consumed > 0) [lines removeObjectsInRange:NSMakeRange(0, (NSUInteger)consumed)];

    P2FColumns cols = P2FLearnColumns(lines);
    P2FExtractSceneNumbers(lines, cols);
    cols = P2FLearnColumns(lines);   // re-learn without the gutter lines

    CGFloat rightMargin = 0;
    for (P2FLine *l in lines) rightMargin = MAX(rightMargin, l.right);

    // Learn the line pitch: the most common SMALL gap between consecutive lines.
    NSCountedSet *pitches = [NSCountedSet set];
    for (NSUInteger i = 1; i < lines.count; i++) {
        P2FLine *a = lines[i - 1], *b = lines[i];
        if (a.page != b.page) continue;
        CGFloat dy = b.top - a.top;
        if (dy > 1.0 && dy < 40.0) [pitches addObject:@((NSInteger)llround(dy))];
    }
    CGFloat pitch = 12.0;
    NSUInteger pitchCount = 0;
    for (NSNumber *n in pitches) {
        if ([n doubleValue] > 16.0) continue;
        if ([pitches countForObject:n] > pitchCount) {
            pitchCount = [pitches countForObject:n];
            pitch = [n doubleValue];
        }
    }
    CGFloat paragraphGap = pitch * 1.5;

    if (getenv("P2F_DEBUG")) {
        fprintf(stderr,
                "columns  action=%.0f dialogue=%.0f paren=%.0f character=%.0f transition=%.0f\n"
                "spacing  pitch=%.1f paragraphGap=%.1f\n",
                cols.action, cols.dialogue, cols.parenthetical, cols.character, cols.transition,
                pitch, paragraphGap);
    }

    NSMutableArray<P2FLine *> *kept = [NSMutableArray array];
    P2FLine *previous = nil;
    /*
     A speech broken over a page boundary is printed as "(MORE)" at the foot and
     "NAME (CONT'D)" at the head of the next page. That is typography, not
     content: the importer rejoins the speech so the recovered Fountain has the
     same element count as the script that was printed.
     */
    BOOL resumingSpeech = NO;

    for (P2FLine *l in lines) {
        NSString *t = P2FTrim(l.text);

        if (P2FMatchesCS(t, @"^\\(MORE\\)$")) { resumingSpeech = YES; continue; }
        if (P2FIsPageFurniture(l)) continue;

        l.kind = P2FClassify(l, cols, rightMargin);

        // Drop the repeated cue; the speech itself follows on the next line.
        if (resumingSpeech && l.kind == P2FKindCharacter && P2FMatchesCS(t, @"\\(CONT'D\\)$")) {
            continue;
        }

        if (previous) {
            BOOL newPage = (l.page != previous.page);
            l.blankBefore = newPage || ((l.top - previous.top) > paragraphGap);
        } else {
            l.blankBefore = YES;
        }

        if (resumingSpeech) {
            l.blankBefore = NO;      // join what came before the page break
            resumingSpeech = NO;
        }

        previous = l;
        [kept addObject:l];
    }

    return [P2FBuildFountain(kept, titlePage, cols) stringByAppendingString:@"\n"];
}

@end
