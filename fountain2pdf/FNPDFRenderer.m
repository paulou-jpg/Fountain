//
//  FNPDFRenderer.m
//
//  Screenplay layout is character-metric: Courier at 10 characters per inch on
//  a fixed baseline grid. That makes wrapping and pagination exact integer
//  arithmetic rather than text measurement, so this does its own layout instead
//  of going through FNPaginator (which needs AppKit/UIKit text machinery).
//
//  Layout is organised as rows rather than lines, because dual dialogue puts
//  two columns of text on a single baseline.
//

#import "FNPDFRenderer.h"
#import "FNPDFMetrics.h"
#import "FNScript.h"
#import "FNElement.h"
#import <CoreText/CoreText.h>

#pragma mark - Laid-out pieces

typedef NS_ENUM(NSInteger, FNPDFAlignment) {
    FNPDFAlignLeft = 0,
    FNPDFAlignRight,
    FNPDFAlignCenter,
};

/// One run of text placed on a baseline.
@interface FNPDFLine : NSObject
@property (copy, nonatomic) NSString *text;
@property (nonatomic) CGFloat x;             // left edge, or the anchor for other alignments
@property (nonatomic) FNPDFAlignment alignment;
@property (copy, nonatomic) NSString *sceneNumber;   // drawn in both gutters
@end

@implementation FNPDFLine
@end

/// One baseline. Normally a single line; two when dual dialogue is in play.
typedef NSArray<FNPDFLine *> FNPDFRow;

/// One screenplay element after wrapping.
@interface FNPDFBlock : NSObject
@property (copy, nonatomic) NSString *type;
@property (copy, nonatomic) NSString *characterName;   // for (MORE) / (CONT'D)
@property (strong, nonatomic) NSMutableArray<FNPDFRow *> *rows;
@property (nonatomic) BOOL startsNewPage;
@end

@implementation FNPDFBlock
- (instancetype)init
{
    self = [super init];
    if (self) _rows = [NSMutableArray array];
    return self;
}
@end

#pragma mark -

@interface FNPDFRenderer ()
@property (strong, nonatomic) FNScript *script;
@property (nonatomic) NSUInteger pageCount;
@end

@implementation FNPDFRenderer {
    CTFontRef _regular;
    CTFontRef _bold;
    CTFontRef _italic;
    CTFontRef _boldItalic;
}

- (instancetype)initWithScript:(FNScript *)script
{
    self = [super init];
    if (self) {
        _script = script;
        _includesTitlePage = ([script.titlePage count] > 0);
        _includesSceneNumbers = YES;
        _automaticContinueds = YES;

        _regular    = CTFontCreateWithName(CFSTR("Courier"), kFNFontSize, NULL);
        _bold       = CTFontCreateWithName(CFSTR("Courier-Bold"), kFNFontSize, NULL);
        _italic     = CTFontCreateWithName(CFSTR("Courier-Oblique"), kFNFontSize, NULL);
        _boldItalic = CTFontCreateWithName(CFSTR("Courier-BoldOblique"), kFNFontSize, NULL);
    }
    return self;
}

- (void)dealloc
{
    if (_regular) CFRelease(_regular);
    if (_bold) CFRelease(_bold);
    if (_italic) CFRelease(_italic);
    if (_boldItalic) CFRelease(_boldItalic);
}

#pragma mark - Text preparation

// Forced-element markers are markup, not text. The parser strips '.' from
// forced scene headings; the rest are removed here.
- (NSString *)stripForcingMarkerFrom:(NSString *)text type:(NSString *)type
{
    if (text.length == 0) return text;
    unichar first = [text characterAtIndex:0];
    if (([type isEqualToString:@"Character"] && first == '@') ||
        ([type isEqualToString:@"Action"] && first == '!') ||
        ([type isEqualToString:@"Lyrics"] && first == '~')) {
        return [text substringFromIndex:1];
    }
    return text;
}

// Notes never appear in a printed script.
- (NSString *)removeNotesFrom:(NSString *)text
{
    NSRegularExpression *notes = [NSRegularExpression regularExpressionWithPattern:@"\\[{2}.*?\\]{2}"
                                                                          options:NSRegularExpressionDotMatchesLineSeparators
                                                                            error:NULL];
    return [notes stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
}

- (NSString *)cleanedTextFor:(FNElement *)element
{
    NSString *text = [self removeNotesFrom:[self stripForcingMarkerFrom:element.elementText type:element.elementType]];
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

/*
 Wrap to a character count. Courier is monospace, so this is exact -- no text
 measurement is involved, which is also why the output lands on the columns the
 format calls for.
 */
- (NSArray<NSString *> *)wrap:(NSString *)text toWidth:(NSUInteger)width
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *paragraph in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [paragraph stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) {
            [out addObject:@""];
            continue;
        }
        NSMutableString *line = [NSMutableString string];
        for (NSString *word in [trimmed componentsSeparatedByString:@" "]) {
            if (word.length == 0) continue;
            if (line.length == 0) {
                [line appendString:word];
            }
            else if (line.length + 1 + word.length <= width) {
                [line appendString:@" "];
                [line appendString:word];
            }
            else {
                [out addObject:[line copy]];
                [line setString:@""];
                [line appendString:word];
            }
            while (line.length > width) {         // a word longer than the column
                [out addObject:[line substringToIndex:width]];
                [line setString:[line substringFromIndex:width]];
            }
        }
        if (line.length) [out addObject:[line copy]];
    }
    return out;
}

- (FNPDFLine *)lineWithText:(NSString *)text x:(CGFloat)x alignment:(FNPDFAlignment)alignment
{
    FNPDFLine *line = [[FNPDFLine alloc] init];
    line.text = text;
    line.x = x;
    line.alignment = alignment;
    return line;
}

#pragma mark - Layout

/// Wrapped lines for one element, positioned in a single column.
- (NSArray<FNPDFLine *> *)linesForElement:(FNElement *)element
{
    NSString *type = element.elementType;
    NSString *text = [self cleanedTextFor:element];
    if (text.length == 0) return @[];

    CGFloat left = kFNActionLeft;
    NSUInteger width = kFNActionWidth;
    FNPDFAlignment alignment = FNPDFAlignLeft;

    if ([type isEqualToString:@"Character"]) {
        left = kFNCharacterLeft; width = kFNCharacterWidth;
        text = [text uppercaseString];
    }
    else if ([type isEqualToString:@"Dialogue"] || [type isEqualToString:@"Lyrics"]) {
        left = kFNDialogueLeft; width = kFNDialogueWidth;
    }
    else if ([type isEqualToString:@"Parenthetical"]) {
        left = kFNParentheticalLeft; width = kFNParentheticalWidth;
    }
    else if ([type isEqualToString:@"Transition"]) {
        alignment = FNPDFAlignRight; left = kFNRightMargin;
        text = [text uppercaseString];
    }
    else if ([type isEqualToString:@"Scene Heading"]) {
        text = [text uppercaseString];
    }

    if (element.isCentered) {
        alignment = FNPDFAlignCenter;
        left = kFNActionLeft + (kFNActionWidth * kFNCharWidth) / 2.0;
    }

    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *wrapped in [self wrap:text toWidth:width]) {
        [lines addObject:[self lineWithText:wrapped x:left alignment:alignment]];
    }
    if (self.includesSceneNumbers && [type isEqualToString:@"Scene Heading"] && lines.count) {
        [(FNPDFLine *)lines[0] setSceneNumber:element.sceneNumber];
    }
    return lines;
}

/// Wrapped lines for one speech placed inside a dual-dialogue column.
- (NSArray<FNPDFLine *> *)linesForElement:(FNElement *)element inColumnAt:(CGFloat)columnLeft
{
    NSString *type = element.elementType;
    NSString *text = [self cleanedTextFor:element];
    if (text.length == 0) return @[];

    NSMutableArray *lines = [NSMutableArray array];

    if ([type isEqualToString:@"Character"]) {
        // Indented within the column, the way the reference sets it -- not
        // centred over it. See kFNDualCueIndent.
        text = [text uppercaseString];
        CGFloat left = columnLeft + kFNDualCueIndent * kFNCharWidth;
        for (NSString *wrapped in [self wrap:text toWidth:(kFNDualWidth - kFNDualCueIndent)]) {
            [lines addObject:[self lineWithText:wrapped x:left alignment:FNPDFAlignLeft]];
        }
    }
    else if ([type isEqualToString:@"Parenthetical"]) {
        CGFloat left = columnLeft + kFNDualParenIndent * kFNCharWidth;
        for (NSString *wrapped in [self wrap:text toWidth:(kFNDualWidth - kFNDualParenIndent)]) {
            [lines addObject:[self lineWithText:wrapped x:left alignment:FNPDFAlignLeft]];
        }
    }
    else {
        for (NSString *wrapped in [self wrap:text toWidth:kFNDualWidth]) {
            [lines addObject:[self lineWithText:wrapped x:columnLeft alignment:FNPDFAlignLeft]];
        }
    }
    return lines;
}

/*
 The speaker's name without any extension: "BRUCE (V.O.)" and "BRUCE" are the
 same character, so the second of them still earns a (CONT'D).
 */
- (NSString *)speakerNameFromCue:(NSString *)cue
{
    NSRange paren = [cue rangeOfString:@"("];
    NSString *name = (paren.location != NSNotFound) ? [cue substringToIndex:paren.location] : cue;
    return [[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] uppercaseString];
}

- (BOOL)isSpeechContinuation:(FNElement *)element
{
    return ([element.elementType isEqualToString:@"Dialogue"] ||
            [element.elementType isEqualToString:@"Parenthetical"] ||
            [element.elementType isEqualToString:@"Lyrics"]);
}

/*
 Two character cues both flagged for dual dialogue, back to back with their
 speeches, are laid out side by side. Returns the index just past the pair, or
 NSNotFound when this is not a dual pair after all.
 */
- (NSUInteger)buildDualBlockFrom:(NSArray *)elements
                              at:(NSUInteger)index
                            into:(NSMutableArray<FNPDFBlock *> *)blocks
{
    FNElement *firstCue = elements[index];
    if (![firstCue.elementType isEqualToString:@"Character"] || !firstCue.isDualDialogue) return NSNotFound;

    NSMutableArray *leftElements = [NSMutableArray arrayWithObject:firstCue];
    NSUInteger i = index + 1;
    while (i < elements.count && [self isSpeechContinuation:elements[i]]) {
        [leftElements addObject:elements[i]];
        i++;
    }

    // The partner cue has to come next, and must also be flagged.
    if (i >= elements.count) return NSNotFound;
    FNElement *secondCue = elements[i];
    if (![secondCue.elementType isEqualToString:@"Character"] || !secondCue.isDualDialogue) return NSNotFound;

    NSMutableArray *rightElements = [NSMutableArray arrayWithObject:secondCue];
    i++;
    while (i < elements.count && [self isSpeechContinuation:elements[i]]) {
        [rightElements addObject:elements[i]];
        i++;
    }

    NSMutableArray<FNPDFLine *> *leftLines = [NSMutableArray array];
    for (FNElement *e in leftElements) {
        [leftLines addObjectsFromArray:[self linesForElement:e inColumnAt:kFNDualLeftColumn]];
    }
    NSMutableArray<FNPDFLine *> *rightLines = [NSMutableArray array];
    for (FNElement *e in rightElements) {
        [rightLines addObjectsFromArray:[self linesForElement:e inColumnAt:kFNDualRightColumn]];
    }

    FNPDFBlock *block = [[FNPDFBlock alloc] init];
    block.type = @"Dual Dialogue";
    NSUInteger height = MAX(leftLines.count, rightLines.count);
    for (NSUInteger row = 0; row < height; row++) {
        NSMutableArray *cells = [NSMutableArray array];
        if (row < leftLines.count) [cells addObject:leftLines[row]];
        if (row < rightLines.count) [cells addObject:rightLines[row]];
        [block.rows addObject:cells];
    }
    if (block.rows.count) [blocks addObject:block];
    return i;
}

- (NSArray<FNPDFBlock *> *)buildBlocks
{
    NSMutableArray<FNPDFBlock *> *blocks = [NSMutableArray array];

    // Omitted from formatted output, per the spec.
    NSSet *ignored = [NSSet setWithObjects:@"Boneyard", @"Comment", @"Synopsis", @"Section Heading", nil];

    NSArray *elements = self.script.elements;
    NSString *currentCharacter = nil;
    NSString *lastSpeaker = nil;      // resets at every scene boundary

    NSUInteger i = 0;
    while (i < elements.count) {
        FNElement *element = elements[i];
        NSString *type = element.elementType;

        if ([ignored containsObject:type]) { i++; continue; }

        if ([type isEqualToString:@"Page Break"]) {
            FNPDFBlock *block = [[FNPDFBlock alloc] init];
            block.type = type;
            block.startsNewPage = YES;
            [blocks addObject:block];
            lastSpeaker = nil;
            i++;
            continue;
        }

        // A new scene, or a transition out of one, ends any run of speech.
        if ([type isEqualToString:@"Scene Heading"] || [type isEqualToString:@"Transition"]) {
            lastSpeaker = nil;
        }

        if ([type isEqualToString:@"Character"] && element.isDualDialogue) {
            NSUInteger next = [self buildDualBlockFrom:elements at:i into:blocks];
            if (next != NSNotFound) {
                currentCharacter = nil;
                lastSpeaker = nil;
                i = next;
                continue;
            }
        }

        /*
         Automatic character continueds: when a character speaks again inside the
         same scene, the repeat cue carries (CONT'D). This is Final Draft's
         default behaviour, and it is applied to the laid-out cue rather than to
         the element, so the parsed script is left untouched.
         */
        FNElement *cueElement = element;
        if (self.automaticContinueds && [type isEqualToString:@"Character"]) {
            NSString *cue = [self cleanedTextFor:element];
            NSString *speaker = [self speakerNameFromCue:cue];
            BOOL alreadyMarked = ([cue rangeOfString:@"CONT'D" options:NSCaseInsensitiveSearch].location != NSNotFound);

            if (speaker.length && lastSpeaker && [speaker isEqualToString:lastSpeaker] && !alreadyMarked) {
                cueElement = [FNElement elementOfType:type
                                                 text:[cue stringByAppendingString:@" (CONT'D)"]];
                cueElement.isDualDialogue = element.isDualDialogue;
                cueElement.isCentered = element.isCentered;
            }
            lastSpeaker = speaker;
        }

        NSArray<FNPDFLine *> *lines = [self linesForElement:cueElement];
        if (lines.count == 0) { i++; continue; }

        if ([type isEqualToString:@"Character"]) {
            currentCharacter = [[self cleanedTextFor:cueElement] uppercaseString];
        }

        FNPDFBlock *block = [[FNPDFBlock alloc] init];
        block.type = type;
        block.characterName = currentCharacter;
        for (FNPDFLine *line in lines) {
            [block.rows addObject:@[line]];
        }
        [blocks addObject:block];
        i++;
    }
    return blocks;
}

#pragma mark - Pagination

- (FNPDFRow *)moreRow
{
    return @[[self lineWithText:@"(MORE)" x:kFNMoreLeft alignment:FNPDFAlignLeft]];
}

- (FNPDFRow *)continuedRowFor:(NSString *)name
{
    NSString *text = [NSString stringWithFormat:@"%@ (CONT'D)", name ?: @""];
    return @[[self lineWithText:text x:kFNCharacterLeft alignment:FNPDFAlignLeft]];
}

/*
 Blocks are separated by one blank line, except within a dialogue run
 (Character / Parenthetical / Dialogue), which is set solid.

 Two widow rules, both standard:
   - a character cue is never left stranded at the foot of a page;
   - a speech that has to break across pages leaves (MORE) at the foot and
     resumes under "NAME (CONT'D)", and never leaves fewer than two lines on
     either side of the break.
 */
- (NSArray<NSArray<FNPDFRow *> *> *)paginate:(NSArray<FNPDFBlock *> *)blocks
{
    NSMutableArray *pages = [NSMutableArray array];
    NSMutableArray<FNPDFRow *> *page = [NSMutableArray array];
    NSString *previousType = nil;

    NSSet *dialogueRun = [NSSet setWithObjects:@"Character", @"Parenthetical", @"Dialogue", @"Lyrics", nil];
    FNPDFRow *blank = @[];

    for (NSUInteger b = 0; b < blocks.count; b++) {
        FNPDFBlock *block = blocks[b];

        if (block.startsNewPage) {
            if (page.count) { [pages addObject:page]; page = [NSMutableArray array]; }
            previousType = nil;
            continue;
        }

        BOOL solidWithPrevious = (previousType != nil &&
                                  [dialogueRun containsObject:block.type] &&
                                  [dialogueRun containsObject:previousType] &&
                                  ![block.type isEqualToString:@"Character"]);
        NSUInteger separator = (previousType == nil || page.count == 0) ? 0 : (solidWithPrevious ? 0 : 1);

        // Keep a cue with the opening of its speech.
        NSUInteger needed = separator + block.rows.count;
        if ([block.type isEqualToString:@"Character"]) {
            NSUInteger following = (b + 1 < blocks.count) ? MIN(blocks[b + 1].rows.count, (NSUInteger)2) : 0;
            needed += following;
        }

        BOOL splittable = ([block.type isEqualToString:@"Dialogue"] || [block.type isEqualToString:@"Lyrics"]);

        if (page.count && page.count + needed > kFNLinesPerPage) {
            NSUInteger available = 0;
            if (splittable && (page.count + separator + 1) < kFNLinesPerPage) {
                // One row of the remaining space has to hold (MORE).
                available = kFNLinesPerPage - page.count - separator - 1;
            }

            if (splittable && available >= 2 && (block.rows.count - available) >= 2) {
                for (NSUInteger s = 0; s < separator; s++) [page addObject:blank];
                for (NSUInteger r = 0; r < available; r++) [page addObject:block.rows[r]];
                [page addObject:[self moreRow]];
                [pages addObject:page];

                page = [NSMutableArray array];
                [page addObject:[self continuedRowFor:block.characterName]];
                for (NSUInteger r = available; r < block.rows.count; r++) {
                    [page addObject:block.rows[r]];
                }
                previousType = block.type;
                continue;
            }

            [pages addObject:page];
            page = [NSMutableArray array];
            separator = 0;
        }

        for (NSUInteger s = 0; s < separator; s++) [page addObject:blank];
        for (FNPDFRow *row in block.rows) {
            if (page.count >= kFNLinesPerPage) {
                [pages addObject:page];
                page = [NSMutableArray array];
            }
            [page addObject:row];
        }
        previousType = block.type;
    }
    if (page.count) [pages addObject:page];
    return pages;
}

#pragma mark - Emphasis

// Split a line into runs carrying bold / italic / underline, consuming the
// Fountain markup as it goes.
- (NSArray *)runsForLine:(NSString *)text
{
    NSMutableArray *runs = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    __block BOOL bold = NO, italic = NO, underline = NO;

    void (^flush)(void) = ^{
        if (current.length == 0) return;
        [runs addObject:@[[current copy], @(bold), @(italic), @(underline)]];
        [current setString:@""];
    };

    NSUInteger i = 0;
    while (i < text.length) {
        unichar c = [text characterAtIndex:i];

        if (c == '\\' && i + 1 < text.length) {          // escaped character
            [current appendFormat:@"%C", [text characterAtIndex:i + 1]];
            i += 2;
            continue;
        }
        if (c == '*') {
            NSUInteger run = 0;
            while (i + run < text.length && [text characterAtIndex:i + run] == '*') run++;
            flush();
            if (run >= 3)      { bold = !bold; italic = !italic; }
            else if (run == 2) { bold = !bold; }
            else               { italic = !italic; }
            i += run;
            continue;
        }
        if (c == '_') {
            flush();
            underline = !underline;
            i += 1;
            continue;
        }
        [current appendFormat:@"%C", c];
        i++;
    }
    flush();
    return runs;
}

- (CTFontRef)fontForBold:(BOOL)bold italic:(BOOL)italic
{
    if (bold && italic) return _boldItalic;
    if (bold) return _bold;
    if (italic) return _italic;
    return _regular;
}

#pragma mark - Drawing

- (void)drawText:(NSString *)text at:(CGPoint)origin inContext:(CGContextRef)ctx
{
    if (text.length == 0) return;
    NSDictionary *attributes = @{ (id)kCTFontAttributeName: (__bridge id)_regular };
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    CGContextSetTextPosition(ctx, origin.x, origin.y);
    CTLineDraw(line, ctx);
    CFRelease(line);
}

- (void)drawLine:(FNPDFLine *)line atBaseline:(CGFloat)y inContext:(CGContextRef)ctx
{
    NSArray *runs = [self runsForLine:line.text];

    // Placement is driven by the visible length; the markup is already gone.
    NSUInteger visibleLength = 0;
    for (NSArray *run in runs) visibleLength += [(NSString *)run[0] length];

    CGFloat x = line.x;
    if (line.alignment == FNPDFAlignRight) {
        x = line.x - visibleLength * kFNCharWidth;
    }
    else if (line.alignment == FNPDFAlignCenter) {
        x = line.x - (visibleLength * kFNCharWidth) / 2.0;
    }

    for (NSArray *run in runs) {
        NSString *text = run[0];
        if (text.length == 0) continue;
        CTFontRef font = [self fontForBold:[run[1] boolValue] italic:[run[2] boolValue]];
        NSMutableDictionary *attributes = [@{ (id)kCTFontAttributeName: (__bridge id)font } mutableCopy];
        if ([run[3] boolValue]) {
            attributes[(id)kCTUnderlineStyleAttributeName] = @(kCTUnderlineStyleSingle);
        }
        NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:attributes];
        CTLineRef ctLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
        CGContextSetTextPosition(ctx, x, y);
        CTLineDraw(ctLine, ctx);
        CFRelease(ctLine);
        x += text.length * kFNCharWidth;
    }

    if (line.sceneNumber.length) {
        [self drawText:line.sceneNumber at:CGPointMake(kFNSceneNumberLeft, y) inContext:ctx];
        [self drawText:line.sceneNumber at:CGPointMake(kFNSceneNumberRight, y) inContext:ctx];
    }
}

- (void)drawTitlePageInContext:(CGContextRef)ctx
{
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in self.script.titlePage) {
        [fields addEntriesFromDictionary:entry];
    }

    CGFloat centre = kFNPageWidth / 2.0;
    __block CGFloat y = kFNPageHeight * 0.62;

    void (^centred)(NSString *) = ^(NSString *text) {
        if (text.length == 0) return;
        CGFloat x = centre - (text.length * kFNCharWidth) / 2.0;
        [self drawText:text at:CGPointMake(x, y) inContext:ctx];
        y -= kFNLineHeight;
    };

    for (NSString *value in fields[@"title"] ?: @[]) centred([value uppercaseString]);
    y -= kFNLineHeight * 2;
    for (NSString *value in fields[@"credit"] ?: @[@"written by"]) centred(value);
    y -= kFNLineHeight;
    for (NSString *value in fields[@"authors"] ?: @[]) centred(value);
    for (NSString *value in fields[@"source"] ?: @[]) { y -= kFNLineHeight; centred(value); }

    /*
     Everything else the author put on the title page. Dropping unrecognised
     keys would lose real content -- Big Fish carries its draft status and
     copyright in "Notes:" and "Copyright:".
     */
    NSArray *placed = @[@"title", @"credit", @"authors", @"source", @"contact", @"draft date"];
    y -= kFNLineHeight * 2;
    for (NSString *key in [[fields allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([placed containsObject:key]) continue;
        for (NSString *value in fields[key]) centred(value);
    }

    // Contact bottom left, draft date bottom right -- the conventional placement.
    CGFloat bottom = 144.0;
    for (NSString *value in fields[@"contact"] ?: @[]) {
        [self drawText:value at:CGPointMake(kFNActionLeft, bottom) inContext:ctx];
        bottom -= kFNLineHeight;
    }
    bottom = 144.0;
    for (NSString *value in fields[@"draft date"] ?: @[]) {
        CGFloat x = kFNRightMargin - value.length * kFNCharWidth;
        [self drawText:value at:CGPointMake(x, bottom) inContext:ctx];
        bottom -= kFNLineHeight;
    }
}

#pragma mark - Output

- (NSData *)PDFData
{
    NSMutableData *data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect mediaBox = CGRectMake(0, 0, kFNPageWidth, kFNPageHeight);

    NSString *title = nil;
    for (NSDictionary *entry in self.script.titlePage) {
        if (entry[@"title"]) title = [entry[@"title"] firstObject];
    }
    NSDictionary *info = title.length ? @{ (id)kCGPDFContextTitle: title } : @{};

    CGContextRef ctx = CGPDFContextCreate(consumer, &mediaBox, (__bridge CFDictionaryRef)info);
    CGDataConsumerRelease(consumer);
    if (!ctx) return nil;

    NSArray<NSArray<FNPDFRow *> *> *pages = [self paginate:[self buildBlocks]];
    self.pageCount = pages.count;

    if (self.includesTitlePage) {
        CGPDFContextBeginPage(ctx, NULL);
        [self drawTitlePageInContext:ctx];
        CGPDFContextEndPage(ctx);
    }

    for (NSUInteger p = 0; p < pages.count; p++) {
        CGPDFContextBeginPage(ctx, NULL);

        if (p > 0) {   // page one carries no number
            NSString *number = [NSString stringWithFormat:@"%lu.", (unsigned long)(p + 1)];
            CGFloat x = kFNPageNumberRight - number.length * kFNCharWidth;
            [self drawText:number at:CGPointMake(x, kFNPageNumberY) inContext:ctx];
        }

        CGFloat y = kFNTopBaseline;
        for (FNPDFRow *row in pages[p]) {
            for (FNPDFLine *line in row) {
                [self drawLine:line atBaseline:y inContext:ctx];
            }
            y -= kFNLineHeight;
        }

        CGPDFContextEndPage(ctx);
    }

    CGPDFContextClose(ctx);
    CGContextRelease(ctx);
    return data;
}

- (BOOL)writeToFile:(NSString *)path error:(NSError **)error
{
    NSData *data = [self PDFData];
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:@"FNPDFRenderer" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not create the PDF context"}];
        }
        return NO;
    }
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

@end
