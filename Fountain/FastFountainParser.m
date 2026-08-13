//
//  FastFountainParser.m
//
//  Copyright (c) 2012-2013 Nima Yousefi & John August
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to
//  deal in the Software without restriction, including without limitation the
//  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
//  sell copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
//  IN THE SOFTWARE.
//

#import "FastFountainParser.h"
#import "FNElement.h"
#import "RegexKitLite.h"

static NSString * const kInlinePattern = @"^([^\\t\\s][^:]*):\\s*([^\\t\\s].*$)";
static NSString * const kDirectivePattern = @"^([^\\t\\s][^:]*):([\\t\\s]*$)";

// A Scene Heading begins with one of the standard slug prefixes, followed by a
// separator. All the INT/EXT combinations the wild throws at us are covered
// here: INT, EXT, EST, INT/EXT, EXT/INT, I/E, E/I, with or without periods.
static NSString * const kSceneHeadingPattern =
    @"^(INT|EXT|EST|INT\\.?/EXT|EXT\\.?/INT|I\\.?/E|E\\.?/I)\\.?([\\.\\-\\s]|$)";

// A Character cue is entirely uppercase (at least one letter, no lowercase),
// optionally followed by an extension in parentheses, which the spec allows in
// either case -- "SARAH (cont'd)", "BRUCE (v.o.)" -- and an optional
// dual-dialogue caret.
//
// This matches a whole line and nothing less. An age beside a name introduces a
// character in description -- "BRUCE (50s) calls out to him" -- and stays
// action, which is where that notation almost always appears.
static NSString * const kCharacterPattern =
    @"^[ \\t]*[^a-z\\n]*[A-Z][^a-z\\n]*(\\([^)\\n]*\\))?[ \\t]*\\^?[ \\t]*$";

// A Transition is uppercase and ends in "TO:", or is one of the standard
// closers. Anchored, so a spoken line that merely contains "TO:" is not one.
// Note there is no leading [A-Z] requirement: "TO:" on its own is the minimum
// transition, and the pattern already excludes lowercase.
static NSString * const kTransitionPattern = @"^[^a-z\\n]*TO:$";

// Placeholder used to fold a multi-line note onto a single logical line so the
// line-oriented scanner can see it whole. Restored when the element is built.
static NSString * const kNewlineToken = @"\x01FNNL\x01";

@implementation FastFountainParser

- (id)initWithString:(NSString *)string
{
    self = [super init];
    if (self) {
        _elements = [[NSMutableArray alloc] init];
        _titlePage = [[NSMutableArray alloc] init];
        [self parseContents:string];
    }
    return self;
}

- (id)initWithFile:(NSString *)filePath
{
    self = [super init];
    if (self) {
        _elements = [[NSMutableArray alloc] init];
        _titlePage = [[NSMutableArray alloc] init];

        NSError *error = nil;
        NSString *contents = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:&error];
        if (!contents) {
            NSLog(@"Couldn't read the file %@: %@", filePath, error.localizedDescription);
            return self;
        }
        [self parseContents:contents];
    }
    return self;
}

#pragma mark - Pre-passes

// Control characters (other than tab and newline) have no meaning in Fountain
// and truncate anything downstream that touches a C string. Drop them.
- (NSString *)sanitize:(NSString *)contents
{
    return [contents stringByReplacingOccurrencesOfRegex:@"[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]" withString:@""];
}

/*
 The Boneyard is the only Fountain construct that spans line breaks, and it can
 open and close mid-line. Handling it inside the line scanner meant only
 whole-line boneyards were ever recognised, so inline ones leaked into rendered
 output. We lift them out here instead: the returned array holds the residual
 text of each line, and boneyards is populated with the comment text keyed by
 the index of the line on which each one closed.
 */
- (NSArray *)stripBoneyardsFromLines:(NSArray *)lines
                               into:(NSMutableDictionary *)boneyards
                           consumed:(NSMutableIndexSet *)consumed
{
    NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:[lines count]];
    NSMutableString *current = nil;   // non-nil while inside a boneyard

    for (NSUInteger i = 0; i < [lines count]; i++) {
        NSString *line = lines[i];
        NSMutableString *residual = [NSMutableString string];
        NSUInteger pos = 0;
        BOOL startedInsideBoneyard = (current != nil);

        while (pos <= [line length]) {
            if (current) {
                NSRange close = [line rangeOfString:@"*/" options:0 range:NSMakeRange(pos, [line length] - pos)];
                if (close.location == NSNotFound) {
                    [current appendString:[line substringFromIndex:pos]];
                    [current appendString:@"\n"];
                    pos = [line length] + 1;
                }
                else {
                    [current appendString:[line substringWithRange:NSMakeRange(pos, close.location - pos)]];
                    boneyards[@(i)] = [current copy];
                    current = nil;
                    pos = close.location + 2;
                }
            }
            else {
                NSRange open = [line rangeOfString:@"/*" options:0 range:NSMakeRange(pos, [line length] - pos)];
                if (open.location == NSNotFound) {
                    [residual appendString:[line substringFromIndex:pos]];
                    break;
                }
                [residual appendString:[line substringWithRange:NSMakeRange(pos, open.location - pos)]];
                current = [NSMutableString string];
                pos = open.location + 2;
            }
        }
        /*
         A line whose entire content was boneyard is not a paragraph break --
         it must not be counted as a blank line, or the text either side of a
         multi-line comment ends up in separate elements.
         */
        if (startedInsideBoneyard && [residual length] == 0) {
            [consumed addIndex:i];
        }
        [cleaned addObject:residual];
    }

    // An unterminated boneyard runs to the end of the document.
    if (current && [lines count] > 0) {
        boneyards[@([lines count] - 1)] = [current copy];
    }
    return cleaned;
}

/*
 A standalone note may span several lines. Fold those onto one logical line so
 the scanner's single-line note rule sees the whole thing; the token is turned
 back into a newline when the Comment element is built.
 */
- (NSArray *)foldMultiLineNotesInLines:(NSArray *)lines
{
    NSMutableArray *folded = [NSMutableArray arrayWithCapacity:[lines count]];
    NSUInteger i = 0;
    while (i < [lines count]) {
        NSString *line = lines[i];
        BOOL opensNote = [line isMatchedByRegex:@"^\\s*\\[\\["];
        BOOL closesNote = [line isMatchedByRegex:@"\\]\\]\\s*$"];

        if (opensNote && !closesNote) {
            NSMutableString *joined = [NSMutableString stringWithString:line];
            NSUInteger j = i + 1;
            BOOL closed = NO;
            while (j < [lines count]) {
                [joined appendString:kNewlineToken];
                [joined appendString:lines[j]];
                if ([lines[j] isMatchedByRegex:@"\\]\\]\\s*$"]) { closed = YES; break; }
                if ([lines[j] isEqualToString:@""] && j > i + 40) break;   // runaway guard
                j++;
            }
            if (closed) {
                [folded addObject:joined];
                i = j + 1;
                continue;
            }
        }
        [folded addObject:line];
        i++;
    }
    return folded;
}

#pragma mark - Parsing

- (void)parseContents:(NSString *)contents
{
    contents = [self sanitize:contents];
    contents = [contents stringByReplacingOccurrencesOfRegex:@"\\r\\n|\\r|\\n" withString:@"\n"];
    // Trim leading blank lines only -- never the indentation of the first line.
    contents = [contents stringByReplacingOccurrencesOfRegex:@"^\\n+" withString:@""];
    contents = [NSString stringWithFormat:@"%@\n\n", contents];

    NSRange firstBlankLineRange = [contents rangeOfString:@"\n\n"];
    NSString *topOfDocument = [contents substringToIndex:firstBlankLineRange.location];

    // ----------------------------------------------------------------------
    // TITLE PAGE
    // ----------------------------------------------------------------------
    BOOL foundTitlePage = NO;
    NSString *openKey = @"";
    NSMutableArray *openValues = [NSMutableArray array];
    NSArray *topLines = [topOfDocument componentsSeparatedByString:@"\n"];

    // The block at the top of the document is only a title page if its very
    // first line is a "key:" directive. Otherwise a scene of dialogue that
    // happens to contain a colon would be eaten as metadata.
    BOOL looksLikeTitlePage = ([topLines count] > 0 &&
                               ([topLines[0] isMatchedByRegex:kDirectivePattern] ||
                                [topLines[0] isMatchedByRegex:kInlinePattern]));

    if (looksLikeTitlePage) {
        for (NSString *line in topLines) {
            if ([line isEqualToString:@""] || [line isMatchedByRegex:kDirectivePattern]) {
                foundTitlePage = YES;
                if (![openKey isEqualToString:@""]) {
                    [self.titlePage addObject:@{openKey: openValues}];
                    openValues = [NSMutableArray array];
                }

                openKey = [[line stringByMatching:kDirectivePattern capture:1] lowercaseString];
                if ([openKey isEqualToString:@"author"]) {
                    openKey = @"authors";
                }
            }
            else if ([line isMatchedByRegex:kInlinePattern]) {
                foundTitlePage = YES;
                if (![openKey isEqualToString:@""]) {
                    [self.titlePage addObject:@{openKey: openValues}];
                    openKey = @"";
                    openValues = [NSMutableArray array];
                }

                NSString *key = [[line stringByMatching:kInlinePattern capture:1] lowercaseString];
                NSString *value = [line stringByMatching:kInlinePattern capture:2];

                if ([key isEqualToString:@"author"]) {
                    key = @"authors";
                }

                [self.titlePage addObject:@{key: @[value]}];
                openKey = @"";
                openValues = [NSMutableArray array];
            }
            else if (foundTitlePage) {
                [openValues addObject:[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
            }
        }
    }

    if (foundTitlePage) {
        if (![openKey isEqualToString:@""] && [openValues count] == 0 && [self.titlePage count] == 0) {
            // Nothing usable -- leave the document alone.
        }
        else {
            if (![openKey isEqualToString:@""]) {
                [self.titlePage addObject:@{openKey: openValues}];
                openKey = @"";
                openValues = [NSMutableArray array];
            }
            /*
             Remove the title block by RANGE. The old code did a string
             replacement, which deleted every later occurrence of the same text
             from the body -- silently dropping real dialogue and action.
             */
            contents = [contents substringFromIndex:firstBlankLineRange.location];
        }
    }

    // ----------------------------------------------------------------------
    // BODY
    // ----------------------------------------------------------------------
    contents = [NSString stringWithFormat:@"\n%@", contents];
    NSArray *rawLines = [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    NSMutableDictionary *boneyards = [NSMutableDictionary dictionary];
    NSMutableIndexSet *consumedByBoneyard = [NSMutableIndexSet indexSet];
    NSArray *lines = [self stripBoneyardsFromLines:rawLines into:boneyards consumed:consumedByBoneyard];
    lines = [self foldMultiLineNotesInLines:lines];

    /*
     Structural markers -- sections, synopses, page breaks, notes and boneyards
     -- occupy exactly one line, never absorb the line after them, and are
     omitted from formatted output. Because they vanish from the rendered
     script, they also satisfy the "blank line before" requirement for whatever
     follows: a Scene Heading directly under a section header is still a Scene
     Heading. They leave newlinesBefore at 1 for that reason.
     */
    NSSet *singleLineTypes = [NSSet setWithObjects:@"Section Heading", @"Synopsis",
                              @"Page Break", @"Comment", @"Boneyard", nil];

    NSUInteger newlinesBefore = 0;
    NSInteger index = -1;
    BOOL isInsideDialogueBlock = NO;

    for (NSString *line in lines) {
        index++;

        // A boneyard that closed on this line is emitted before the residual text.
        NSString *boneyardText = boneyards[@(index)];
        if (boneyardText) {
            [self.elements addObject:[FNElement elementOfType:@"Boneyard" text:boneyardText]];
            if ([[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0) {
                // A boneyard on a line of its own behaves like a structural marker.
                newlinesBefore = 1;
                continue;
            }
            // An inline boneyard leaves newlinesBefore alone, so the text on
            // either side of it still joins into one element.
        }

        // Lyrics -- forced with a leading tilde.
        if ([line length] > 0 && [line characterAtIndex:0] == '~') {
            FNElement *lastElement = [self.elements lastObject];
            if (lastElement && [lastElement.elementType isEqualToString:@"Lyrics"] && newlinesBefore > 0) {
                [self.elements addObject:[FNElement elementOfType:@"Lyrics" text:@" "]];
            }
            [self.elements addObject:[FNElement elementOfType:@"Lyrics" text:line]];
            newlinesBefore = 0;
            continue;
        }

        // Forced Action.
        if ([line length] > 0 && [line characterAtIndex:0] == '!') {
            [self.elements addObject:[FNElement elementOfType:@"Action" text:line]];
            newlinesBefore = 0;
            continue;
        }

        // Forced Character.
        if ([line length] > 0 && [line characterAtIndex:0] == '@') {
            [self.elements addObject:[FNElement elementOfType:@"Character" text:line]];
            newlinesBefore = 0;
            isInsideDialogueBlock = YES;
            continue;
        }

        // Two spaces on an otherwise blank line keeps a dialogue block open.
        if (([line isMatchedByRegex:@"^\\s{2}$"]) && isInsideDialogueBlock) {
            newlinesBefore = 0;
            FNElement *previousElement = [self.elements lastObject];
            if (previousElement && [previousElement.elementType isEqualToString:@"Dialogue"]) {
                previousElement.elementText = [NSString stringWithFormat:@"%@\n%@", previousElement.elementText, line];
            }
            else {
                [self.elements addObject:[FNElement elementOfType:@"Dialogue" text:line]];
            }
            continue;
        }

        if (([line isMatchedByRegex:@"^\\s{2,}$"])) {
            [self.elements addObject:[FNElement elementOfType:@"Action" text:line]];
            newlinesBefore = 0;
            continue;
        }

        // Blank line. A line of nothing but whitespace counts as blank -- the
        // two-space dialogue-continuation forms were already handled above.
        if ([[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0) {
            if ([consumedByBoneyard containsIndex:index]) {
                continue;   // swallowed by a boneyard; not a paragraph break
            }
            isInsideDialogueBlock = NO;
            newlinesBefore++;
            continue;
        }

        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        // Page Breaks -- three or more '=' signs.
        if ([line isMatchedByRegex:@"^\\s*={3,}\\s*$"]) {
            [self.elements addObject:[FNElement elementOfType:@"Page Break" text:line]];
            newlinesBefore = 1;
            isInsideDialogueBlock = NO;
            continue;
        }

        // Synopsis -- a single '=' at the start of the line.
        if ([trimmed length] > 0 && [trimmed characterAtIndex:0] == '=') {
            NSRange markupRange = [line rangeOfRegex:@"^\\s*={1}"];
            NSString *text = [line stringByReplacingCharactersInRange:markupRange withString:@""];
            [self.elements addObject:[FNElement elementOfType:@"Synopsis" text:text]];
            newlinesBefore = 1;
            continue;
        }

        // Note -- [[ ... ]] occupying the whole line, possibly folded from several.
        if ([line isMatchedByRegex:@"^\\s*\\[{2}.*\\]{2}\\s*$"]) {
            NSString *text = [line stringByReplacingOccurrencesOfRegex:@"^\\s*\\[{2}" withString:@""];
            text = [text stringByReplacingOccurrencesOfRegex:@"\\]{2}\\s*$" withString:@""];
            text = [text stringByReplacingOccurrencesOfString:kNewlineToken withString:@"\n"];
            [self.elements addObject:[FNElement elementOfType:@"Comment"
                                                        text:[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]]];
            newlinesBefore = 1;
            continue;
        }

        // Section heading -- one or more '#', the count being the depth.
        if ([trimmed length] > 0 && [trimmed characterAtIndex:0] == '#') {
            NSRange markupRange = [line rangeOfRegex:@"^\\s*#+"];
            NSUInteger depth = [line rangeOfRegex:@"#+"].length;
            NSString *text = [line substringFromIndex:(markupRange.location + markupRange.length)];

            FNElement *element = [FNElement elementOfType:@"Section Heading"
                                                     text:[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
            element.sectionDepth = depth;
            [self.elements addObject:element];
            newlinesBefore = 1;
            isInsideDialogueBlock = NO;
            continue;
        }

        /*
         Forced scene heading -- a single leading '.' (but not ".."). A forced
         element always begins a block, so this must not fire part-way through
         a dialogue block: a spoken line may legitimately open with a period.
         */
        if (!isInsideDialogueBlock && [line length] > 1 &&
            [line characterAtIndex:0] == '.' && [line characterAtIndex:1] != '.') {
            newlinesBefore = 0;
            NSString *sceneNumber = nil;
            NSString *text = nil;
            if ([line isMatchedByRegex:@"#([^\\n#]*?)#\\s*$"]) {
                sceneNumber = [line stringByMatching:@"#([^\\n#]*?)#\\s*$" capture:1];
                text = [line stringByReplacingOccurrencesOfRegex:@"#([^\\n#]*?)#\\s*$" withString:@""];
                text = [[text substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
            else {
                text = [[line substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }

            FNElement *element = [FNElement elementOfType:@"Scene Heading" text:text];
            if (sceneNumber) {
                element.sceneNumber = sceneNumber;
            }
            [self.elements addObject:element];
            continue;
        }

        // Scene Headings.
        if (newlinesBefore > 0 && [trimmed isMatchedByRegex:kSceneHeadingPattern
                                                    options:RKLCaseless
                                                    inRange:NSMakeRange(0, trimmed.length)
                                                      error:nil]) {
            newlinesBefore = 0;
            NSString *sceneNumber = nil;
            NSString *text = nil;
            if ([line isMatchedByRegex:@"#([^\\n#]*?)#\\s*$"]) {
                sceneNumber = [line stringByMatching:@"#([^\\n#]*?)#\\s*$" capture:1];
                text = [line stringByReplacingOccurrencesOfRegex:@"\\s*#([^\\n#]*?)#\\s*$" withString:@""];
            }
            else {
                text = line;
            }

            FNElement *element = [FNElement elementOfType:@"Scene Heading" text:text];
            if (sceneNumber) {
                element.sceneNumber = sceneNumber;
            }
            [self.elements addObject:element];
            continue;
        }

        // Forced transitions and centered text -- likewise block-openers only.
        if (!isInsideDialogueBlock && [trimmed length] > 0 && [trimmed characterAtIndex:0] == '>') {
            // Centered text is bracketed. Trailing whitespace must not defeat it.
            if ([trimmed length] > 1 && [trimmed characterAtIndex:([trimmed length] - 1)] == '<') {
                NSString *text = [[trimmed substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                text = [[text substringToIndex:(text.length - 1)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

                FNElement *element = [FNElement elementOfType:@"Action" text:text];
                element.isCentered = YES;
                [self.elements addObject:element];
                newlinesBefore = 0;
                continue;
            }
            else {
                NSString *text = [[trimmed substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                [self.elements addObject:[FNElement elementOfType:@"Transition" text:text]];
                newlinesBefore = 0;
                continue;
            }
        }

        /*
         Dialogue and Parentheticals come BEFORE the transition test. A spoken
         line ending in "TO:" is dialogue, not a transition -- the old order
         turned "...what he was up TO:" into a Transition element.
         */
        if (isInsideDialogueBlock) {
            if (newlinesBefore == 0 && [line isMatchedByRegex:@"^\\s*\\("]) {
                [self.elements addObject:[FNElement elementOfType:@"Parenthetical" text:line]];
                continue;
            }
            FNElement *previousElement = [self.elements lastObject];
            if (previousElement && [previousElement.elementType isEqualToString:@"Dialogue"]) {
                previousElement.elementText = [NSString stringWithFormat:@"%@\n%@", previousElement.elementText, line];
            }
            else {
                [self.elements addObject:[FNElement elementOfType:@"Dialogue" text:line]];
            }
            continue;
        }

        /*
         Transitions. Must be preceded by a blank line and followed by one.
         Only LEADING whitespace is stripped before matching: trailing spaces
         after the colon are the spec's way of saying "treat this as Action".
         */
        NSString *leadingTrimmed = [line stringByReplacingOccurrencesOfRegex:@"^\\s*" withString:@""];
        if (newlinesBefore > 0 && [leadingTrimmed isMatchedByRegex:kTransitionPattern]) {
            NSUInteger nextIndex = index + 1;
            BOOL blankAfter = (nextIndex >= [lines count]) ||
                              ([[lines[nextIndex] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0);
            if (blankAfter) {
                [self.elements addObject:[FNElement elementOfType:@"Transition" text:line]];
                newlinesBefore = 0;
                continue;
            }
        }

        NSSet *transitions = [NSSet setWithArray:@[@"FADE OUT.", @"CUT TO BLACK.", @"FADE TO BLACK."]];
        if (newlinesBefore > 0 && [transitions containsObject:leadingTrimmed]) {
            [self.elements addObject:[FNElement elementOfType:@"Transition" text:line]];
            newlinesBefore = 0;
            continue;
        }

        // Character cue.
        if (newlinesBefore > 0 && [line isMatchedByRegex:kCharacterPattern]) {
            NSUInteger nextIndex = index + 1;
            if (nextIndex < [lines count]) {
                NSString *nextLine = lines[nextIndex];
                if (![nextLine isEqualToString:@""]) {
                    newlinesBefore = 0;
                    FNElement *element = [FNElement elementOfType:@"Character" text:line];

                    if ([line isMatchedByRegex:@"\\^\\s*$"]) {
                        element.isDualDialogue = YES;
                        element.elementText = [element.elementText stringByReplacingOccurrencesOfRegex:@"\\s*\\^\\s*$" withString:@""];
                        /*
                         Mark the character of the block immediately above. The
                         old loop walked back through the whole document and
                         could flag a character separated by pages of action.
                         */
                        NSSet *dialogueBlockTypes = [NSSet setWithObjects:@"Character", @"Dialogue", @"Parenthetical", nil];
                        for (NSInteger back = [self.elements count] - 1; back >= 0; back--) {
                            FNElement *previousElement = (self.elements)[back];
                            if ([previousElement.elementType isEqualToString:@"Character"]) {
                                previousElement.isDualDialogue = YES;
                                break;
                            }
                            if (![dialogueBlockTypes containsObject:previousElement.elementType]) {
                                break;  // left the dialogue block without finding a cue
                            }
                        }
                    }

                    [self.elements addObject:element];
                    isInsideDialogueBlock = YES;
                    continue;
                }
            }
        }

        // Continuation of the previous element, when not separated by a blank line.
        if (newlinesBefore == 0 && [self.elements count] > 0) {
            // Skip back over any Boneyard elements lifted out of this block, so
            // text either side of an inline comment joins up as one element.
            NSInteger mergeIndex = (NSInteger)[self.elements count] - 1;
            while (mergeIndex >= 0 &&
                   [[(self.elements)[mergeIndex] elementType] isEqualToString:@"Boneyard"]) {
                mergeIndex--;
            }
            FNElement *previousElement = (mergeIndex >= 0) ? (self.elements)[mergeIndex] : nil;
            if (!previousElement) {
                [self.elements addObject:[FNElement elementOfType:@"Action" text:line]];
                newlinesBefore = 0;
                continue;
            }

            /*
             Single-line elements never absorb the following line. Previously a
             Section Heading or Page Break swallowed whatever came next.
             */
            if (![singleLineTypes containsObject:previousElement.elementType]) {
                // A Scene Heading must be surrounded by blank lines.
                if ([previousElement.elementType isEqualToString:@"Scene Heading"]) {
                    previousElement.elementType = @"Action";
                }
                previousElement.elementText = [NSString stringWithFormat:@"%@\n%@", previousElement.elementText, line];
                newlinesBefore = 0;
                continue;
            }
        }

        [self.elements addObject:[FNElement elementOfType:@"Action" text:line]];
        newlinesBefore = 0;
    }
}

@end
