//
//  CheckTests.m
//
//  Covers FNScriptCheck, the judgement behind `fountain-dump check`.
//
//  A checker that only ever reports "fine" is worthless, so each test here
//  feeds it something known to be wrong and asserts that it says so, then
//  feeds it the clean equivalent and asserts that it does not.
//

#import <XCTest/XCTest.h>
#import "FNScriptCheck.h"

@interface CheckTests : XCTestCase
@end

@implementation CheckTests

/// A well-formed script with nothing wrong with it.
- (NSString *)cleanScript
{
    return @"INT. HOUSE - DAY\n"
            "\n"
            "Bob waits by the window.\n"
            "\n"
            "BOB\n"
            "Nobody is coming.\n"
            "\n"
            "SARAH\n"
            "Somebody is always coming.\n"
            "\n"
            "She leaves.\n";
}

#pragma mark - The clean case

- (void)testCleanScriptReportsNothing
{
    FNScriptCheck *check = [FNScriptCheck checkOfSource:[self cleanScript]];
    XCTAssertEqual(check.problemCount, (NSUInteger)0, @"%@", [check report]);
    XCTAssertEqual(check.pageNumberLines, (NSUInteger)0);
    XCTAssertEqual(check.doubledSpaceLines, (NSUInteger)0);
    XCTAssertEqual(check.continuationMarkers, (NSUInteger)0);
    XCTAssertEqual(check.trailingWhitespaceLines, (NSUInteger)0);
    XCTAssertEqual(check.whitespaceOnlyElements, (NSUInteger)0);
    XCTAssertEqual(check.differingLines, (NSUInteger)0);
}

- (void)testElementsAreCounted
{
    FNScriptCheck *check = [FNScriptCheck checkOfSource:[self cleanScript]];
    XCTAssertEqualObjects(check.elementCounts[@"Scene Heading"], @1);
    XCTAssertEqualObjects(check.elementCounts[@"Character"], @2);
    XCTAssertEqualObjects(check.elementCounts[@"Dialogue"], @2);
    XCTAssertEqualObjects(check.elementCounts[@"Action"], @2);
}

- (void)testEmptyInputIsNotAProblem
{
    FNScriptCheck *check = [FNScriptCheck checkOfSource:@""];
    XCTAssertEqual(check.problemCount, (NSUInteger)0);
    XCTAssertEqual(check.cueBalance, 1.0, @"nothing spoken means nothing to judge");
}

#pragma mark - Marks of a bad import

- (void)testPageNumberLeftInTheBodyIsCaught
{
    NSString *source = @"INT. HOUSE - DAY\n\nBob waits.\n\n42.\n\nHe leaves.\n";
    FNScriptCheck *check = [FNScriptCheck checkOfSource:source];
    XCTAssertEqual(check.pageNumberLines, (NSUInteger)1);
    XCTAssertGreaterThan(check.problemCount, (NSUInteger)0);
}

- (void)testDoubledSpacesAreCaught
{
    NSString *source = @"INT. HOUSE - DAY\n\nBob waits  by the window  for hours.\n";
    FNScriptCheck *check = [FNScriptCheck checkOfSource:source];
    XCTAssertEqual(check.doubledSpaceLines, (NSUInteger)1, @"one offending line, however many runs it holds");
    XCTAssertGreaterThan(check.problemCount, (NSUInteger)0);
}

- (void)testContinuationMarkersAreCaught
{
    for (NSString *marker in @[@"(CONTINUED)", @"(MORE)"]) {
        NSString *source = [NSString stringWithFormat:@"INT. HOUSE - DAY\n\nBob waits.\n\n%@\n\nHe leaves.\n", marker];
        FNScriptCheck *check = [FNScriptCheck checkOfSource:source];
        XCTAssertEqual(check.continuationMarkers, (NSUInteger)1, @"missed %@", marker);
    }
}

- (void)testTrailingWhitespaceIsCaught
{
    NSString *source = @"INT. HOUSE - DAY\n\nBob waits.   \n\nHe leaves.\n";
    FNScriptCheck *check = [FNScriptCheck checkOfSource:source];
    XCTAssertEqual(check.trailingWhitespaceLines, (NSUInteger)1);
}

- (void)testWhitespaceOnlyElementsAreCaught
{
    // Two spaces on a line of their own survive parsing as an element.
    NSString *source = @"INT. HOUSE - DAY\n\nBob waits.\n\n  \n\nHe leaves.\n";
    FNScriptCheck *check = [FNScriptCheck checkOfSource:source];
    XCTAssertGreaterThan(check.whitespaceOnlyElements, (NSUInteger)0);
    XCTAssertGreaterThan(check.problemCount, (NSUInteger)0);
}

#pragma mark - Cue balance

- (void)testBalancedCuesAndDialoguePass
{
    FNScriptCheck *check = [FNScriptCheck checkOfSource:[self cleanScript]];
    XCTAssertEqual(check.characterCount, (NSUInteger)2);
    XCTAssertEqual(check.dialogueCount, (NSUInteger)2);
    XCTAssertEqual(check.cueBalance, 1.0);
    XCTAssertFalse(check.cueBalanceSuspicious);
}

/*
 The failure this is for: when column detection goes wrong in an import, cues
 are read as something else and the two counts come apart. A parenthetical
 splits a speech into several Dialogue elements under one cue, which is how a
 ratio below 1 arises in a well-formed file.
 */
- (void)testLopsidedCueCountIsFlagged
{
    NSMutableString *source = [NSMutableString stringWithString:@"INT. HOUSE - DAY\n"];
    [source appendString:@"\nBOB\nFirst part.\n(beat)\nSecond part.\n(beat)\nThird part.\n"];

    FNScriptCheck *check = [FNScriptCheck checkOfSource:source];
    XCTAssertEqual(check.characterCount, (NSUInteger)1);
    XCTAssertEqual(check.dialogueCount, (NSUInteger)3);
    XCTAssertLessThan(check.cueBalance, kFNCueBalanceThreshold);
    XCTAssertTrue(check.cueBalanceSuspicious, @"1 cue against 3 speeches should be flagged");
    XCTAssertGreaterThan(check.problemCount, (NSUInteger)0);
}

- (void)testCueBalanceThresholdIsAppliedAtTheBoundary
{
    XCTAssertEqualWithAccuracy(kFNCueBalanceThreshold, 0.8, 0.0001,
                               @"the threshold the rest of this test is built around");

    // 8 cues against 10 speeches is exactly 0.8, and must pass.
    NSMutableString *atBoundary = [NSMutableString stringWithString:@"INT. HOUSE - DAY\n"];
    for (int i = 0; i < 6; i++) [atBoundary appendFormat:@"\nBOB\nLine %d.\n", i];
    for (int i = 0; i < 2; i++) [atBoundary appendString:@"\nSARAH\nFirst part.\n(beat)\nSecond part.\n"];

    FNScriptCheck *boundary = [FNScriptCheck checkOfSource:atBoundary];
    XCTAssertEqual(boundary.characterCount, (NSUInteger)8, @"fixture: %@", [boundary report]);
    XCTAssertEqual(boundary.dialogueCount, (NSUInteger)10, @"fixture: %@", [boundary report]);
    XCTAssertEqualWithAccuracy(boundary.cueBalance, 0.8, 0.0001);
    XCTAssertFalse(boundary.cueBalanceSuspicious, @"exactly at the threshold is not suspicious");

    // 7 against 10 is 0.7, and must not.
    NSMutableString *below = [NSMutableString stringWithString:@"INT. HOUSE - DAY\n"];
    for (int i = 0; i < 4; i++) [below appendFormat:@"\nBOB\nLine %d.\n", i];
    for (int i = 0; i < 3; i++) [below appendString:@"\nSARAH\nFirst part.\n(beat)\nSecond part.\n"];

    FNScriptCheck *under = [FNScriptCheck checkOfSource:below];
    XCTAssertEqual(under.characterCount, (NSUInteger)7, @"fixture: %@", [under report]);
    XCTAssertEqual(under.dialogueCount, (NSUInteger)10, @"fixture: %@", [under report]);
    XCTAssertEqualWithAccuracy(under.cueBalance, 0.7, 0.0001);
    XCTAssertTrue(under.cueBalanceSuspicious, @"below the threshold should be flagged");
}

#pragma mark - Round trip

- (void)testRoundTripDifferenceIsReported
{
    /*
     A section heading written without a space round-trips with one, because the
     parser treats the markup as markup. Harmless, but the check should say so
     rather than stay quiet.
     */
    NSString *source = @"#Act One\n\nINT. HOUSE - DAY\n\nBob waits.\n";
    FNScriptCheck *check = [FNScriptCheck checkOfSource:source];
    XCTAssertGreaterThan(check.differingLines, (NSUInteger)0);
    XCTAssertGreaterThan(check.sampleDifferences.count, (NSUInteger)0);
    XCTAssertGreaterThan(check.problemCount, (NSUInteger)0);
}

- (void)testSampleDifferencesAreCapped
{
    NSMutableString *source = [NSMutableString string];
    for (int i = 0; i < 20; i++) [source appendFormat:@"#Section %d\n\nAction %d.\n\n", i, i];
    FNScriptCheck *check = [FNScriptCheck checkOfSource:source];
    XCTAssertGreaterThan(check.differingLines, (NSUInteger)5);
    XCTAssertLessThanOrEqual(check.sampleDifferences.count, (NSUInteger)5,
                             @"a report should not print hundreds of lines");
}

- (void)testCleanScriptRoundTripsWithoutDifference
{
    FNScriptCheck *check = [FNScriptCheck checkOfSource:[self cleanScript]];
    XCTAssertEqual(check.differingLines, (NSUInteger)0);
    XCTAssertEqual(check.sourceLineCount, check.writtenLineCount);
}

#pragma mark - The report itself

- (void)testReportStatesTheVerdict
{
    XCTAssertTrue([[[FNScriptCheck checkOfSource:[self cleanScript]] report]
                   containsString:@"nothing suspicious"]);

    NSString *bad = @"INT. HOUSE - DAY\n\nBob waits.   \n";
    XCTAssertTrue([[[FNScriptCheck checkOfSource:bad] report] containsString:@"problems found"]);
}

- (void)testReportMarksTheOffendingLine
{
    NSString *bad = @"INT. HOUSE - DAY\n\nBob waits.   \n";
    NSString *report = [[FNScriptCheck checkOfSource:bad] report];
    XCTAssertTrue([report containsString:@"trailing whitespace"]);
    XCTAssertTrue([report containsString:@"<-"], @"the offending row should be marked");
}

@end
