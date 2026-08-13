//
//  ConverterTests.m
//
//  Covers fountain2pdf (FNPDFRenderer) and pdf2fountain (FNPDFImporter).
//
//  The two tools verify each other: a fixture is rendered to PDF, the PDF is
//  read back, and the result is compared with the source. That needs no PDF
//  fixtures in the bundle, and it exercises the geometry both tools depend on.
//
//  The page metrics asserted here are the industry standard published by Final
//  Draft; see fountain2pdf/FNPDFMetrics.h and fountain2pdf/README.md.
//

#import <XCTest/XCTest.h>
#import <Quartz/Quartz.h>
#import "FNScript.h"
#import "FNElement.h"
#import "FNPDFRenderer.h"
#import "FNPDFImporter.h"
#import "FNPDFMetrics.h"

@interface ConverterTests : XCTestCase
@end

@implementation ConverterTests

#pragma mark - Helpers

- (NSString *)sourceForFixture:(NSString *)name
{
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *path = [bundle pathForResource:name ofType:@"fountain"];
    XCTAssertNotNil(path, @"fixture %@.fountain is missing from the test bundle", name);
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
}

- (NSData *)renderFixture:(NSString *)name
{
    FNScript *script = [[FNScript alloc] initWithString:[self sourceForFixture:name]];
    FNPDFRenderer *renderer = [[FNPDFRenderer alloc] initWithScript:script];
    return [renderer PDFData];
}

- (NSString *)temporaryPathWithExtension:(NSString *)extension
{
    NSString *name = [NSString stringWithFormat:@"%@-%@.%@", NSStringFromClass([self class]),
                      [[NSUUID UUID] UUIDString], extension];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

/// Left edges of every text line on a page, rounded to the nearest point.
- (NSCountedSet *)leftEdgesInPDF:(NSData *)data
{
    PDFDocument *doc = [[PDFDocument alloc] initWithData:data];
    NSCountedSet *lefts = [NSCountedSet set];
    for (NSUInteger i = 0; i < [doc pageCount]; i++) {
        PDFPage *page = [doc pageAtIndex:i];
        NSRect bounds = [page boundsForBox:kPDFDisplayBoxMediaBox];
        for (PDFSelection *sel in [[page selectionForRect:bounds] selectionsByLine]) {
            NSString *text = [[sel string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (text.length == 0) continue;
            NSRect r = [sel boundsForPage:page];
            if (NSIsEmptyRect(r)) continue;
            [lefts addObject:@((NSInteger)llround(NSMinX(r)))];
        }
    }
    return lefts;
}

- (NSDictionary *)elementCountsFor:(NSString *)fountain
{
    FNScript *script = [[FNScript alloc] initWithString:fountain];
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (FNElement *element in script.elements) {
        counts[element.elementType] = @([counts[element.elementType] integerValue] + 1);
    }
    return counts;
}

#pragma mark - Renderer: output

- (void)testRendererProducesAPDF
{
    NSData *data = [self renderFixture:@"Big Fish"];
    XCTAssertNotNil(data);
    XCTAssertGreaterThan(data.length, (NSUInteger)1000);

    NSString *magic = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, 5)]
                                            encoding:NSASCIIStringEncoding];
    XCTAssertEqualObjects(magic, @"%PDF-");

    PDFDocument *doc = [[PDFDocument alloc] initWithData:data];
    XCTAssertNotNil(doc);
    XCTAssertGreaterThan([doc pageCount], (NSUInteger)1);
}

- (void)testPageIsUSLetter
{
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[self renderFixture:@"Big Fish"]];
    NSRect bounds = [[doc pageAtIndex:1] boundsForBox:kPDFDisplayBoxMediaBox];
    XCTAssertEqualWithAccuracy(NSWidth(bounds), 612.0, 0.5);
    XCTAssertEqualWithAccuracy(NSHeight(bounds), 792.0, 0.5);
}

#pragma mark - Renderer: geometry

// The industry-standard columns as published by Final Draft.
- (void)testElementColumnsMatchFinalDraft
{
    NSCountedSet *lefts = [self leftEdgesInPDF:[self renderFixture:@"Big Fish"]];

    XCTAssertGreaterThan([lefts countForObject:@((NSInteger)kFNActionLeft)], (NSUInteger)100,
                         @"action/scene headings should sit at 1.5in");
    XCTAssertGreaterThan([lefts countForObject:@((NSInteger)kFNDialogueLeft)], (NSUInteger)100,
                         @"dialogue should sit at 2.50in");
    XCTAssertGreaterThan([lefts countForObject:@((NSInteger)kFNCharacterLeft)], (NSUInteger)50,
                         @"character cues should sit at 3.70in");
    XCTAssertGreaterThan([lefts countForObject:@((NSInteger)kFNParentheticalLeft)], (NSUInteger)5,
                         @"parentheticals should sit at 3.10in");
}

- (void)testTextNeverCrossesTheRightMargin
{
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[self renderFixture:@"Big Fish"]];
    CGFloat rightLimit = kFNActionLeft + kFNActionWidth * kFNCharWidth;   // 7.5in
    for (NSUInteger i = 0; i < MIN([doc pageCount], (NSUInteger)20); i++) {
        PDFPage *page = [doc pageAtIndex:i];
        NSRect bounds = [page boundsForBox:kPDFDisplayBoxMediaBox];
        for (PDFSelection *sel in [[page selectionForRect:bounds] selectionsByLine]) {
            if ([[sel string] stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceCharacterSet]].length == 0) continue;
            NSRect r = [sel boundsForPage:page];
            if (NSIsEmptyRect(r)) continue;
            XCTAssertLessThanOrEqual(NSMaxX(r), rightLimit + 1.0,
                                     @"line overruns the right margin: %@", [sel string]);
        }
    }
}

- (void)testTransitionsAreRightAligned
{
    NSString *source = @"INT. HOUSE - DAY\n\nBob leaves.\n\nCUT TO:\n\nINT. BAR - NIGHT\n\nHe arrives.\n\nDISSOLVE TO:\n\nEXT. ROAD - DAY\n\nEnd.";
    FNScript *script = [[FNScript alloc] initWithString:source];
    FNPDFRenderer *renderer = [[FNPDFRenderer alloc] initWithScript:script];
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[renderer PDFData]];

    NSMutableArray *rightEdges = [NSMutableArray array];
    PDFPage *page = [doc pageAtIndex:0];
    for (PDFSelection *sel in [[page selectionForRect:[page boundsForBox:kPDFDisplayBoxMediaBox]] selectionsByLine]) {
        NSString *text = [[sel string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![text hasSuffix:@"TO:"]) continue;
        [rightEdges addObject:@(NSMaxX([sel boundsForPage:page]))];
    }

    XCTAssertEqual(rightEdges.count, (NSUInteger)2, @"both transitions should be present");
    if (rightEdges.count == 2) {
        // Different lengths, same right edge -- that is what right-aligned means.
        XCTAssertEqualWithAccuracy([rightEdges[0] doubleValue], [rightEdges[1] doubleValue], 1.0);
    }
}

- (void)testPageNumbersStartOnPageTwo
{
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[self renderFixture:@"Big Fish"]];

    // Index 0 is the title page for this fixture, so body page one is index 1.
    NSString *first = [[doc pageAtIndex:1] string];
    XCTAssertFalse([first containsString:@"\n2."], @"the first body page should carry no number");

    PDFPage *third = [doc pageAtIndex:3];
    NSRect bounds = [third boundsForBox:kPDFDisplayBoxMediaBox];
    BOOL foundNumber = NO;
    for (PDFSelection *sel in [[third selectionForRect:bounds] selectionsByLine]) {
        NSString *text = [[sel string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSRect r = [sel boundsForPage:third];
        if ([text isEqualToString:@"3."] && NSMinY(r) > NSMaxY(bounds) - 72.0) {
            foundNumber = YES;
            XCTAssertEqualWithAccuracy(NSMaxX(r), kFNPageNumberRight, 2.0,
                                       @"page number should be right-aligned at 7.25in");
        }
    }
    XCTAssertTrue(foundNumber, @"page three should be numbered \"3.\"");
}

- (void)testFiftyFiveLinesToAPage
{
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[self renderFixture:@"Big Fish"]];
    NSUInteger maxRows = 0;
    for (NSUInteger i = 1; i < MIN([doc pageCount], (NSUInteger)25); i++) {
        PDFPage *page = [doc pageAtIndex:i];
        NSRect bounds = [page boundsForBox:kPDFDisplayBoxMediaBox];
        NSMutableSet *baselines = [NSMutableSet set];
        for (PDFSelection *sel in [[page selectionForRect:bounds] selectionsByLine]) {
            if ([[sel string] stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceCharacterSet]].length == 0) continue;
            NSRect r = [sel boundsForPage:page];
            if (NSIsEmptyRect(r)) continue;
            if (NSMinY(r) > NSMaxY(bounds) - 60.0) continue;   // page number
            [baselines addObject:@((NSInteger)llround(NSMinY(r)))];
        }
        maxRows = MAX(maxRows, baselines.count);
    }
    XCTAssertLessThanOrEqual(maxRows, kFNLinesPerPage,
                             @"a page carried more than %lu lines", (unsigned long)kFNLinesPerPage);
    XCTAssertGreaterThan(maxRows, (NSUInteger)40, @"pages are suspiciously sparse");
}

#pragma mark - Dual dialogue

/*
 PDFKit returns one selection per baseline, so a dual-dialogue row comes back as
 a single line whose text holds both columns and whose bounds span the gutter.
 That is exactly the evidence needed: same baseline, two columns.
 */
- (void)testDualDialogueSharesBaselines
{
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE\nWe need to talk about this right now.\n\n"
                        "SARAH ^\nThere is nothing at all to discuss.\n\nThey glare at each other.\n";
    FNScript *script = [[FNScript alloc] initWithString:source];
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[[[FNPDFRenderer alloc] initWithScript:script] PDFData]];
    PDFPage *page = [doc pageAtIndex:0];

    BOOL cuesShareABaseline = NO;
    NSUInteger rowsSpanningBothColumns = 0;

    for (PDFSelection *sel in [[page selectionForRect:[page boundsForBox:kPDFDisplayBoxMediaBox]] selectionsByLine]) {
        NSString *text = [[sel string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (text.length == 0) continue;
        NSRect r = [sel boundsForPage:page];
        if (NSIsEmptyRect(r)) continue;

        BOOL startsInLeftColumn = NSMinX(r) < kFNDualRightColumn;
        BOOL reachesRightColumn = NSMaxX(r) > kFNDualRightColumn;
        if (startsInLeftColumn && reachesRightColumn) {
            rowsSpanningBothColumns++;
            if ([text containsString:@"BRUCE"] && [text containsString:@"SARAH"]) {
                cuesShareABaseline = YES;
            }
        }
    }

    XCTAssertTrue(cuesShareABaseline, @"the two character cues should sit on the same baseline");
    XCTAssertGreaterThan(rowsSpanningBothColumns, (NSUInteger)1,
                         @"dual dialogue was not laid out side by side");
}

- (void)testDualDialogueStaysInsideTheTextBlock
{
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE\nWe need to talk about this right now, seriously, before it is too late.\n\n"
                        "SARAH ^\nThere is nothing at all to discuss with you about any of it.\n";
    FNScript *script = [[FNScript alloc] initWithString:source];
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[[[FNPDFRenderer alloc] initWithScript:script] PDFData]];
    PDFPage *page = [doc pageAtIndex:0];

    for (PDFSelection *sel in [[page selectionForRect:[page boundsForBox:kPDFDisplayBoxMediaBox]] selectionsByLine]) {
        if ([[sel string] stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceCharacterSet]].length == 0) continue;
        NSRect r = [sel boundsForPage:page];
        if (NSIsEmptyRect(r)) continue;
        XCTAssertGreaterThanOrEqual(NSMinX(r), kFNDualLeftColumn - 1.0,
                                    @"dual dialogue starts left of the margin: %@", [sel string]);
        XCTAssertLessThanOrEqual(NSMaxX(r), kFNRightMargin + 1.0,
                                 @"dual dialogue overruns the right margin: %@", [sel string]);
    }
}

- (void)testSingleDualCueDoesNotBreakLayout
{
    // A caret with no partner cue after it must fall back to normal layout.
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE ^\nAll alone here.\n\nAction follows.\n";
    FNScript *script = [[FNScript alloc] initWithString:source];
    NSData *data = [[[FNPDFRenderer alloc] initWithScript:script] PDFData];
    XCTAssertNotNil(data);
    PDFDocument *doc = [[PDFDocument alloc] initWithData:data];
    XCTAssertTrue([[[doc pageAtIndex:0] string] containsString:@"All alone here."]);
}

#pragma mark - Speech continuation

- (void)testLongSpeechBreaksWithMoreAndContinued
{
    // One very long speech, guaranteed to cross a page boundary.
    NSMutableString *speech = [NSMutableString string];
    for (NSUInteger i = 0; i < 120; i++) {
        [speech appendFormat:@"This is sentence number %lu of a very long uninterrupted speech. ", (unsigned long)i];
    }
    NSString *source = [NSString stringWithFormat:@"INT. HOUSE - DAY\n\nBRUCE\n%@\n", speech];

    FNScript *script = [[FNScript alloc] initWithString:source];
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[[[FNPDFRenderer alloc] initWithScript:script] PDFData]];
    XCTAssertGreaterThan([doc pageCount], (NSUInteger)1, @"the speech should span pages");

    NSString *firstPage = [[doc pageAtIndex:0] string];
    NSString *secondPage = [[doc pageAtIndex:1] string];

    XCTAssertTrue([firstPage containsString:@"(MORE)"], @"no (MORE) at the foot of the broken page");
    XCTAssertTrue([secondPage containsString:@"BRUCE (CONT'D)"], @"the speech did not resume under a (CONT'D) cue");
    XCTAssertFalse([secondPage containsString:@"(MORE)"], @"(MORE) should only appear where a speech breaks");
}

- (void)testShortSpeechIsNotBrokenAcrossPages
{
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE\nJust a short line.\n\nEnd.\n";
    FNScript *script = [[FNScript alloc] initWithString:source];
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[[[FNPDFRenderer alloc] initWithScript:script] PDFData]];
    XCTAssertFalse([[[doc pageAtIndex:0] string] containsString:@"(MORE)"]);
}

#pragma mark - Importer

- (void)testImporterRejectsAMissingFile
{
    NSError *error = nil;
    XCTAssertNil([FNPDFImporter fountainFromPDFAtPath:@"/nonexistent/file.pdf" error:&error]);
    XCTAssertNotNil(error);
}

#pragma mark - Automatic continueds

- (void)testRepeatSpeakerGetsContinued
{
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE\nFirst thing.\n\nHe pauses, thinking.\n\nBRUCE\nSecond thing.\n";
    FNScript *script = [[FNScript alloc] initWithString:source];
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[[[FNPDFRenderer alloc] initWithScript:script] PDFData]];
    NSString *page = [[doc pageAtIndex:0] string];

    XCTAssertTrue([page containsString:@"BRUCE (CONT'D)"], @"the repeat cue should carry (CONT'D)");
    XCTAssertTrue([page containsString:@"Second thing."]);
}

- (void)testDifferentSpeakerDoesNotGetContinued
{
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE\nFirst thing.\n\nSARAH\nHer turn.\n";
    FNScript *script = [[FNScript alloc] initWithString:source];
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[[[FNPDFRenderer alloc] initWithScript:script] PDFData]];
    XCTAssertFalse([[[doc pageAtIndex:0] string] containsString:@"(CONT'D)"]);
}

- (void)testContinuedResetsAtASceneHeading
{
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE\nFirst thing.\n\nINT. BAR - NIGHT\n\nBRUCE\nNew scene.\n";
    FNScript *script = [[FNScript alloc] initWithString:source];
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[[[FNPDFRenderer alloc] initWithScript:script] PDFData]];
    XCTAssertFalse([[[doc pageAtIndex:0] string] containsString:@"(CONT'D)"],
                   @"a new scene should start the speaker over");
}

- (void)testExistingContinuedIsNotDoubled
{
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE\nFirst.\n\nHe waits.\n\nBRUCE (CONT'D)\nSecond.\n";
    FNScript *script = [[FNScript alloc] initWithString:source];
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[[[FNPDFRenderer alloc] initWithScript:script] PDFData]];
    XCTAssertFalse([[[doc pageAtIndex:0] string] containsString:@"(CONT'D) (CONT'D)"]);
}

- (void)testContinuedsCanBeTurnedOff
{
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE\nFirst thing.\n\nHe pauses.\n\nBRUCE\nSecond thing.\n";
    FNScript *script = [[FNScript alloc] initWithString:source];
    FNPDFRenderer *renderer = [[FNPDFRenderer alloc] initWithScript:script];
    renderer.automaticContinueds = NO;
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[renderer PDFData]];
    XCTAssertFalse([[[doc pageAtIndex:0] string] containsString:@"(CONT'D)"]);
}

#pragma mark - Round trip

// The strongest check available: render to PDF, read it back, compare.
- (void)testRoundTripPreservesElementCounts
{
    NSString *source = [self sourceForFixture:@"Big Fish"];
    NSString *pdfPath = [self temporaryPathWithExtension:@"pdf"];

    FNScript *script = [[FNScript alloc] initWithString:source];
    FNPDFRenderer *renderer = [[FNPDFRenderer alloc] initWithScript:script];
    NSError *error = nil;
    XCTAssertTrue([renderer writeToFile:pdfPath error:&error], @"%@", error);

    NSString *recovered = [FNPDFImporter fountainFromPDFAtPath:pdfPath error:&error];
    XCTAssertNotNil(recovered, @"%@", error);

    NSDictionary *before = [self elementCountsFor:source];
    NSDictionary *after = [self elementCountsFor:recovered];

    for (NSString *type in @[@"Character", @"Dialogue", @"Parenthetical", @"Scene Heading"]) {
        NSInteger a = [before[type] integerValue], b = [after[type] integerValue];
        XCTAssertEqual(a, b, @"%@ count changed across the round trip: %ld -> %ld", type, (long)a, (long)b);
    }

    [[NSFileManager defaultManager] removeItemAtPath:pdfPath error:NULL];
}

- (void)testRoundTripPreservesNumerals
{
    NSString *source = @"Title: Numbers\n\nINT. HORIZON SAVINGS & LOAN - DAY #12#\n\n"
                        "BRUCE (50s) slides a BILL across the counter: $32.94. The clock reads 8:37 PM.\n\n"
                        "BRUCE\nI put 401k money into that AUDI R8 in 2007.\n";
    NSString *pdfPath = [self temporaryPathWithExtension:@"pdf"];

    FNScript *script = [[FNScript alloc] initWithString:source];
    FNPDFRenderer *renderer = [[FNPDFRenderer alloc] initWithScript:script];
    NSError *error = nil;
    XCTAssertTrue([renderer writeToFile:pdfPath error:&error], @"%@", error);

    NSString *recovered = [FNPDFImporter fountainFromPDFAtPath:pdfPath error:&error];
    XCTAssertNotNil(recovered, @"%@", error);

    for (NSString *numeral in @[@"32.94", @"8:37", @"401k", @"R8", @"2007", @"50s"]) {
        XCTAssertTrue([recovered containsString:numeral],
                      @"numeral %@ was lost; got:\n%@", numeral, recovered);
    }

    [[NSFileManager defaultManager] removeItemAtPath:pdfPath error:NULL];
}

// Side-by-side columns have to be recognised on the way back in, or the two
// speeches come back interleaved as action.
- (void)testDualDialogueSurvivesTheRoundTrip
{
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE\nWe need to talk about this right now.\n\n"
                        "SARAH ^\nThere is nothing at all to discuss.\n\nThey glare at each other.\n";
    NSString *pdfPath = [self temporaryPathWithExtension:@"pdf"];

    FNScript *script = [[FNScript alloc] initWithString:source];
    NSError *error = nil;
    XCTAssertTrue([[[FNPDFRenderer alloc] initWithScript:script] writeToFile:pdfPath error:&error], @"%@", error);

    NSString *recovered = [FNPDFImporter fountainFromPDFAtPath:pdfPath error:&error];
    XCTAssertNotNil(recovered, @"%@", error);

    FNScript *back = [[FNScript alloc] initWithString:recovered];
    NSMutableArray *cues = [NSMutableArray array];
    for (FNElement *element in back.elements) {
        if ([element.elementType isEqualToString:@"Character"]) {
            [cues addObject:@[element.elementText, @(element.isDualDialogue)]];
        }
    }

    XCTAssertEqual(cues.count, (NSUInteger)2, @"expected two cues, got:\n%@", recovered);
    if (cues.count == 2) {
        XCTAssertEqualObjects(cues[0][0], @"BRUCE");
        XCTAssertEqualObjects(cues[1][0], @"SARAH");
        XCTAssertTrue([cues[0][1] boolValue], @"first cue lost its dual-dialogue flag");
        XCTAssertTrue([cues[1][1] boolValue], @"second cue lost its dual-dialogue flag");
    }

    NSDictionary *after = [self elementCountsFor:recovered];
    XCTAssertEqual([after[@"Dialogue"] integerValue], (NSInteger)2);
    XCTAssertEqual([after[@"Action"] integerValue], (NSInteger)1);

    [[NSFileManager defaultManager] removeItemAtPath:pdfPath error:NULL];
}

/*
 A cue is indented within its dual column, not centred over it. The reference
 sets it that way: LUCAS (5 characters) and FERNETTE (8) both begin at the same
 x. Cues of different lengths must therefore share a left edge.
 */
- (void)testDualDialogueCuesAreIndentedNotCentred
{
    NSString *source = @"INT. HOUSE - DAY\n\nENDICOTT\nNo!\n\nLUCAS ^\nNo!\n";
    FNScript *script = [[FNScript alloc] initWithString:source];
    PDFDocument *doc = [[PDFDocument alloc] initWithData:[[[FNPDFRenderer alloc] initWithScript:script] PDFData]];
    PDFPage *page = [doc pageAtIndex:0];

    CGFloat expectedLeft = kFNDualLeftColumn + kFNDualCueIndent * kFNCharWidth;
    CGFloat expectedRight = kFNDualRightColumn + kFNDualCueIndent * kFNCharWidth;

    BOOL found = NO;
    for (PDFSelection *sel in [[page selectionForRect:[page boundsForBox:kPDFDisplayBoxMediaBox]] selectionsByLine]) {
        NSString *text = [[sel string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![text containsString:@"ENDICOTT"] || ![text containsString:@"LUCAS"]) continue;
        found = YES;
        NSRect r = [sel boundsForPage:page];
        // The row starts at the left cue and ends at the end of the right cue.
        XCTAssertEqualWithAccuracy(NSMinX(r), expectedLeft, 1.0, @"left cue is not at the column indent");
        XCTAssertEqualWithAccuracy(NSMaxX(r), expectedRight + strlen("LUCAS") * kFNCharWidth, 1.5,
                                   @"right cue is not at the column indent");
    }
    XCTAssertTrue(found, @"the two cues should share a baseline");
}

// Two dual passages separated by action must stay two passages.
- (void)testConsecutiveDualPassagesSeparatedByActionSurvive
{
    NSString *source = @"INT. HOUSE - DAY\n\nENDICOTT\nNo!\n\nLUCAS ^\nNo!\n\n"
                        "They stare at each other.\n\nABIGAIL\nWe are twins.\n\nFERNETTE ^\nWe are twins.\n";
    NSString *pdfPath = [self temporaryPathWithExtension:@"pdf"];
    FNScript *script = [[FNScript alloc] initWithString:source];
    NSError *error = nil;
    XCTAssertTrue([[[FNPDFRenderer alloc] initWithScript:script] writeToFile:pdfPath error:&error], @"%@", error);

    NSString *recovered = [FNPDFImporter fountainFromPDFAtPath:pdfPath error:&error];
    XCTAssertNotNil(recovered, @"%@", error);

    FNScript *back = [[FNScript alloc] initWithString:recovered];
    NSMutableArray *cues = [NSMutableArray array];
    for (FNElement *e in back.elements) {
        if ([e.elementType isEqualToString:@"Character"]) [cues addObject:e.elementText];
    }
    XCTAssertEqualObjects(cues, (@[@"ENDICOTT", @"LUCAS", @"ABIGAIL", @"FERNETTE"]),
                          @"the two passages ran together:\n%@", recovered);

    [[NSFileManager defaultManager] removeItemAtPath:pdfPath error:NULL];
}

- (void)testRoundTripKeepsDialogueWithItsCharacter
{
    NSString *source = @"INT. HOUSE - DAY\n\nBRUCE\nI never knew what he was up TO:\nthat was the problem.\n\nEnd of scene.\n";
    NSString *pdfPath = [self temporaryPathWithExtension:@"pdf"];

    FNScript *script = [[FNScript alloc] initWithString:source];
    NSError *error = nil;
    XCTAssertTrue([[[FNPDFRenderer alloc] initWithScript:script] writeToFile:pdfPath error:&error], @"%@", error);

    NSString *recovered = [FNPDFImporter fountainFromPDFAtPath:pdfPath error:&error];
    XCTAssertNotNil(recovered, @"%@", error);

    NSDictionary *after = [self elementCountsFor:recovered];
    XCTAssertEqual([after[@"Character"] integerValue], (NSInteger)1);
    XCTAssertEqual([after[@"Dialogue"] integerValue], (NSInteger)1);
    XCTAssertNil(after[@"Transition"], @"the spoken line ending in TO: became a transition");

    [[NSFileManager defaultManager] removeItemAtPath:pdfPath error:NULL];
}

@end
