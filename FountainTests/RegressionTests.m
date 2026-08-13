//
//  RegressionTests.m
//
//  One test per defect fixed in the parser, writer and HTML output. Each test
//  is named for the behaviour it protects and fails against the code as it
//  stood before the fix.
//

#import <XCTest/XCTest.h>
#import "FastFountainParser.h"
#import "FNScript.h"
#import "FNElement.h"
#import "FNHTMLScript.h"

@interface RegressionTests : XCTestCase
@end

@implementation RegressionTests

#pragma mark - Helpers

- (NSArray *)parse:(NSString *)source
{
    return [[[FastFountainParser alloc] initWithString:source] elements];
}

- (NSString *)typeAt:(NSUInteger)index in:(NSArray *)elements
{
    if (index >= elements.count) return nil;
    FNElement *element = elements[index];
    return element.elementType;
}

- (NSString *)textAt:(NSUInteger)index in:(NSArray *)elements
{
    if (index >= elements.count) return nil;
    FNElement *element = elements[index];
    return element.elementText;
}

- (FNElement *)elementAt:(NSUInteger)index in:(NSArray *)elements
{
    return (index < elements.count) ? elements[index] : nil;
}

- (NSString *)htmlFor:(NSString *)source
{
    FNScript *script = [[FNScript alloc] initWithString:source];
    return [[[FNHTMLScript alloc] initWithScript:script] html];
}

- (NSString *)roundTrip:(NSString *)source
{
    return [[[FNScript alloc] initWithString:source] stringFromDocument];
}

#pragma mark - 1. Title page

// The title block was removed with a string replacement, which deleted every
// later occurrence of the same text from the body.
- (void)testTitlePageTextIsNotDeletedFromTheBody
{
    NSArray *elements = [self parse:@"Title: BIG FISH\n\nINT. HOUSE - DAY\n\nA poster reads:\n\nTitle: BIG FISH\n\nBob nods."];
    NSMutableArray *texts = [NSMutableArray array];
    for (FNElement *e in elements) {
        [texts addObject:e.elementText];
    }
    XCTAssertTrue([texts containsObject:@"Title: BIG FISH"],
                  @"the body line was deleted along with the title block: %@", texts);
}

/*
 The title page is only recognised when the FIRST line of the document is a
 "key:" directive. Without that anchor, an opening paragraph containing a colon
 part-way down was consumed as metadata and vanished from the script.

 A document that genuinely opens with "key: value" on line one is still read as
 a title page -- that is what the spec defines a title page to be, and the
 ambiguity is not resolvable here.
 */
- (void)testOpeningParagraphIsNotMistakenForATitlePage
{
    NSString *source = @"Bob waits by the door.\nTime: 4pm.\n\nINT. HOUSE - DAY";
    FNScript *script = [[FNScript alloc] initWithString:source];
    XCTAssertEqual(script.titlePage.count, (NSUInteger)0);
    XCTAssertEqualObjects([self typeAt:0 in:script.elements], @"Action");
    XCTAssertTrue([[self textAt:0 in:script.elements] containsString:@"Time: 4pm."],
                  @"the paragraph was consumed as title page metadata");
}

// FNHTMLScript rendered six hardcoded keys and discarded everything else.
- (void)testNonStandardTitlePageKeysAreRendered
{
    NSString *html = [self htmlFor:@"Title: KEVIN KIM\nInfo:\n\tWritten by\n\tTiger Ji\n\nINT. HOUSE - DAY\n\nEnd."];
    XCTAssertTrue([html containsString:@"Tiger Ji"], @"a non-standard title page key was dropped from the output");
}

#pragma mark - 2. Single-line structural elements

- (void)testSectionHeadingDoesNotSwallowTheFollowingLine
{
    NSArray *elements = [self parse:@"# Act One\nINT. HOUSE - DAY\n\nBob waits."];
    XCTAssertEqualObjects([self typeAt:0 in:elements], @"Section Heading");
    XCTAssertEqualObjects([self textAt:0 in:elements], @"Act One");
    XCTAssertEqualObjects([self typeAt:1 in:elements], @"Scene Heading");
}

- (void)testPageBreakDoesNotSwallowTheFollowingLine
{
    NSArray *elements = [self parse:@"Action one.\n\n===\nINT. HOUSE - DAY\n\nBob waits."];
    XCTAssertEqualObjects([self typeAt:1 in:elements], @"Page Break");
    XCTAssertEqualObjects([self typeAt:2 in:elements], @"Scene Heading");
}

// Structural markers are omitted from formatted output, so they also satisfy
// the blank-line-before requirement for whatever follows them.
- (void)testSynopsisSatisfiesBlankLineBefore
{
    NSArray *elements = [self parse:@"= A synopsis\nEXT. ROAD - DAY\n\nEnd."];
    XCTAssertEqualObjects([self typeAt:0 in:elements], @"Synopsis");
    XCTAssertEqualObjects([self typeAt:1 in:elements], @"Scene Heading");
}

#pragma mark - 3. Transitions

- (void)testDialogueEndingInTOIsNotATransition
{
    NSArray *elements = [self parse:@"INT. HOUSE - DAY\n\nBOB\nI never knew what he was up TO:\nthat was the problem."];
    XCTAssertEqualObjects([self typeAt:2 in:elements], @"Dialogue");
}

- (void)testForcedSceneHeadingDoesNotFireInsideDialogue
{
    NSArray *elements = [self parse:@"INT. STAGE - NIGHT\n\nCUE\n. Button. Blue light washes the stage."];
    XCTAssertEqualObjects([self typeAt:2 in:elements], @"Dialogue");
}

// The spec's escape hatch: trailing spaces after the colon mean Action.
- (void)testTrailingSpaceDemotesATransition
{
    NSArray *elements = [self parse:@"Bob leaves.\n\nCUT TO:  \n\nINT. BAR - NIGHT"];
    XCTAssertNotEqualObjects([self typeAt:1 in:elements], @"Transition");
}

#pragma mark - 4. Character cues

/*
 The spec allows a character extension in either case. The old pattern rejected
 any lowercase at all except the one literal string "(cont'd)", so an ordinary
 "(v.o.)" cue was demoted to action and took its speech with it.
 */
- (void)testCueWithLowercaseExtensionIsRecognised
{
    for (NSString *cue in @[@"BRUCE (v.o.)", @"BRUCE (o.s.)", @"BRUCE (cont'd)"]) {
        NSString *source = [NSString stringWithFormat:@"INT. HOUSE - DAY\n\n%@\nSpoken aloud.", cue];
        NSArray *elements = [self parse:source];
        XCTAssertEqualObjects([self typeAt:1 in:elements], @"Character", @"not read as a cue: %@", cue);
        XCTAssertEqualObjects([self textAt:1 in:elements], cue);
        XCTAssertEqualObjects([self typeAt:2 in:elements], @"Dialogue", @"speech lost after %@", cue);
    }
}

/*
 An age beside a name introduces a character in description. It is not a cue and
 must never become one -- this is where the notation actually appears in scripts.
 */
- (void)testAgeGivenInDescriptionStaysAction
{
    NSArray *elements = [self parse:
        @"INT. BAR - NIGHT\n\nA man walks in to the bar, BRUCE (50s) calls out to him."
         "\n\nGRACE LEE (53) speaks without looking up from her rice."];

    XCTAssertEqualObjects([self typeAt:1 in:elements], @"Action");
    XCTAssertEqualObjects([self typeAt:2 in:elements], @"Action");
    XCTAssertTrue([[self textAt:1 in:elements] containsString:@"BRUCE (50s)"], @"the age was altered");
    XCTAssertTrue([[self textAt:2 in:elements] containsString:@"GRACE LEE (53)"], @"the age was altered");
}

- (void)testCueRequiresAnAlphabeticCharacter
{
    NSArray *elements = [self parse:@"INT. HOUSE - DAY\n\n1985\nSomething happens."];
    XCTAssertNotEqualObjects([self typeAt:1 in:elements], @"Character",
                             @"a line with no letters was accepted as a cue");
}

#pragma mark - 5. Scene heading variants

- (void)testAllSlugVariantsAreRecognised
{
    NSArray *slugs = @[@"INT. A - DAY", @"EXT. B - DAY", @"EST. C - DAY",
                       @"INT/EXT. D - DAY", @"EXT/INT. E - DAY",
                       @"INT./EXT. F - DAY", @"EXT./INT. G - DAY",
                       @"I/E. H - DAY", @"E/I. I - DAY"];
    for (NSString *slug in slugs) {
        NSArray *elements = [self parse:[NSString stringWithFormat:@"%@\n\nAction.", slug]];
        XCTAssertEqualObjects([self typeAt:0 in:elements], @"Scene Heading", @"not recognised: %@", slug);
    }
}

- (void)testSlugPrefixMustBeFollowedByASeparator
{
    NSArray *elements = [self parse:@"INTERIOR DECORATING\n\nAction."];
    XCTAssertNotEqualObjects([self typeAt:0 in:elements], @"Scene Heading");
}

#pragma mark - 6. Dual dialogue

// The caret used to mark any earlier Character, however far back.
- (void)testDualDialogueDoesNotReachPastAnInterveningElement
{
    NSArray *elements = [self parse:@"INT. HOUSE - DAY\n\nBOB\nHi.\n\nSome action line.\n\nSUE ^\nHello."];
    XCTAssertEqualObjects([self typeAt:1 in:elements], @"Character");
    XCTAssertFalse([self elementAt:1 in:elements].isDualDialogue, @"a character two blocks away was flagged as dual dialogue");
}

- (void)testDualDialoguePairsAdjacentCues
{
    NSArray *elements = [self parse:@"INT. HOUSE - DAY\n\nJIM\nHey.\n\nPAT ^\nYo."];
    XCTAssertTrue([self elementAt:1 in:elements].isDualDialogue);
    XCTAssertTrue([self elementAt:3 in:elements].isDualDialogue);
}

#pragma mark - 7. Writer

// TRANSITION_PATTERN is newline-delimited and was matched against bare text, so
// it never matched and every transition was rewritten as "> CUT TO:".
- (void)testTransitionsAreNotForcedOnWrite
{
    NSString *output = [self roundTrip:@"INT. HOUSE - DAY\n\nBob leaves.\n\nCUT TO:\n\nINT. BAR - NIGHT"];
    XCTAssertTrue([output containsString:@"\nCUT TO:\n"], @"transition was force-prefixed: %@", output);
    XCTAssertFalse([output containsString:@"> CUT TO:"]);
}

- (void)testSceneNumberRoundTripsWithoutADoubledSpace
{
    NSString *output = [self roundTrip:@"INT. HOUSE - DAY #1#\n\nBob waits."];
    XCTAssertTrue([output containsString:@"INT. HOUSE - DAY #1#"], @"got: %@", output);
    XCTAssertFalse([output containsString:@"DAY  #1#"]);
}

#pragma mark - 8. Centered text

- (void)testCenteredTextSurvivesTrailingWhitespace
{
    NSArray *elements = [self parse:@"> CENTERED < \n\nAction."];
    XCTAssertEqualObjects([self typeAt:0 in:elements], @"Action");
    XCTAssertTrue([self elementAt:0 in:elements].isCentered);
    XCTAssertEqualObjects([self textAt:0 in:elements], @"CENTERED");
}

#pragma mark - 9. HTML escaping

- (void)testHTMLEntitiesAreEscaped
{
    NSString *html = [self htmlFor:@"INT. HORIZON SAVINGS & LOAN - DAY\n\nSmith & Jones <the firm>."];
    XCTAssertTrue([html containsString:@"SAVINGS &amp; LOAN"], @"ampersand was emitted raw");
    XCTAssertTrue([html containsString:@"&lt;the firm&gt;"], @"angle brackets were emitted raw");
}

#pragma mark - 10. Emphasis

- (void)testEmphasisTagsAreProperlyNested
{
    NSString *html = [self htmlFor:@"INT. HOUSE - DAY\n\nThis is ***bold italic*** text."];
    XCTAssertTrue([html containsString:@"<strong><em>bold italic</em></strong>"],
                  @"tags closed out of order");
}

#pragma mark - 11. Boneyard

- (void)testInlineBoneyardIsRemovedFromTheSurroundingText
{
    NSArray *elements = [self parse:@"INT. HOUSE - DAY\n\nBob waits /* cut this */ and leaves."];
    for (FNElement *e in elements) {
        if (![e.elementType isEqualToString:@"Boneyard"]) {
            XCTAssertFalse([e.elementText containsString:@"cut this"],
                           @"boneyard text leaked into %@", e.elementType);
        }
    }
}

- (void)testBoneyardSpanningLinesDoesNotSplitItsBlock
{
    NSArray *elements = [self parse:@"INT. HOUSE - DAY\n\nAction /* start\nspanning\nmulti */ end."];
    NSUInteger actionCount = 0;
    for (FNElement *e in elements) {
        if ([e.elementType isEqualToString:@"Action"]) actionCount++;
    }
    XCTAssertEqual(actionCount, (NSUInteger)1, @"text either side of the comment became separate elements");
}

#pragma mark - 12. Notes

- (void)testMultiLineNoteBecomesASingleComment
{
    NSArray *elements = [self parse:@"INT. HOUSE - DAY\n\n[[a standalone\nmultiline note]]\n\nEnd."];
    XCTAssertEqualObjects([self typeAt:1 in:elements], @"Comment");
    XCTAssertEqualObjects([self textAt:1 in:elements], @"a standalone\nmultiline note");
}

- (void)testNotesAreOmittedFromRenderedOutput
{
    NSString *html = [self htmlFor:@"INT. HOUSE - DAY\n\n[[a standalone\nmultiline note]]\n\nEnd."];
    XCTAssertFalse([html containsString:@"multiline note"], @"note text was rendered");
}

#pragma mark - Robustness

- (void)testWhitespaceOnlyLineDoesNotCrash
{
    NSArray *elements = [self parse:@"INT. HOUSE - DAY\n\nBob waits.\n\n \n\nHe leaves."];
    XCTAssertNotNil(elements);
}

- (void)testControlCharactersAreStripped
{
    NSArray *elements = [self parse:@"INT. HOUSE - DAY\n\nListening to \x01music\x00 on the radio."];
    NSString *text = [self textAt:1 in:elements];
    XCTAssertNotNil(text);
    XCTAssertEqualObjects(text, @"Listening to music on the radio.");
}

@end
