//
//  FNScriptCheck.m
//

#import "FNScriptCheck.h"
#import "FNScript.h"
#import "FNElement.h"

const double kFNCueBalanceThreshold = 0.8;

@interface FNScriptCheck ()
@property (strong, nonatomic) FNScript *script;
@property (copy, nonatomic) NSString *source;
@end

@implementation FNScriptCheck

+ (instancetype)checkOfSource:(NSString *)source
{
    FNScriptCheck *check = [[FNScriptCheck alloc] init];
    check.source = source ?: @"";
    check.script = [[FNScript alloc] initWithString:check.source];
    [check examine];
    return check;
}

#pragma mark - Helpers

static NSArray<NSString *> *NonBlankLines(NSString *text)
{
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line stringByTrimmingCharactersInSet:
             [NSCharacterSet whitespaceCharacterSet]].length) [out addObject:line];
    }
    return out;
}

static NSUInteger CountMatching(NSArray<NSString *> *lines, NSString *pattern)
{
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSUInteger n = 0;
    for (NSString *line in lines) {
        if ([re numberOfMatchesInString:line options:0 range:NSMakeRange(0, line.length)]) n++;
    }
    return n;
}

static NSString *Trimmed(NSString *s)
{
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

#pragma mark - Examination

- (void)examine
{
    NSArray<NSString *> *lines = NonBlankLines(self.source);

    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    NSUInteger whitespaceOnly = 0;
    for (FNElement *e in self.script.elements) {
        counts[e.elementType] = @([counts[e.elementType] integerValue] + 1);
        if (e.elementText.length &&
            ![e.elementText stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]].length) whitespaceOnly++;
    }
    _elementCounts = counts;
    _whitespaceOnlyElements = whitespaceOnly;

    _characterCount = (NSUInteger)[counts[@"Character"] integerValue];
    _dialogueCount = (NSUInteger)[counts[@"Dialogue"] integerValue];
    if (_characterCount == 0 && _dialogueCount == 0) {
        _cueBalance = 1.0;                      // nothing spoken; nothing to judge
    } else {
        NSUInteger low = MIN(_characterCount, _dialogueCount);
        NSUInteger high = MAX(_characterCount, _dialogueCount);
        _cueBalance = (double)low / (double)high;
    }
    _cueBalanceSuspicious = (_cueBalance < kFNCueBalanceThreshold);

    _pageNumberLines = CountMatching(lines, @"^\\s*[0-9]{1,4}\\.\\s*$");
    _doubledSpaceLines = CountMatching(lines, @"\\S  +\\S");
    _continuationMarkers = CountMatching(lines, @"\\((CONTINUED|MORE)\\)");
    _trailingWhitespaceLines = CountMatching(lines, @"[ \\t]+$");

    // Round trip.
    NSArray<NSString *> *before = lines;
    NSArray<NSString *> *after = NonBlankLines([self.script stringFromDocument]);
    _sourceLineCount = before.count;
    _writtenLineCount = after.count;

    NSMutableArray *samples = [NSMutableArray array];
    NSUInteger differing = 0;
    for (NSUInteger i = 0; i < MIN(before.count, after.count); i++) {
        if ([Trimmed(before[i]) isEqualToString:Trimmed(after[i])]) continue;
        differing++;
        if (samples.count < 5) {
            [samples addObject:[NSString stringWithFormat:@"in  %@\nout %@",
                                Trimmed(before[i]), Trimmed(after[i])]];
        }
    }
    _differingLines = differing;
    _sampleDifferences = samples;

    NSUInteger problems = 0;
    if (_cueBalanceSuspicious) problems++;
    if (_pageNumberLines) problems++;
    if (_doubledSpaceLines) problems++;
    if (_continuationMarkers) problems++;
    if (_trailingWhitespaceLines) problems++;
    if (_whitespaceOnlyElements) problems++;
    if (_differingLines || _sourceLineCount != _writtenLineCount) problems++;
    _problemCount = problems;
}

#pragma mark - Report

- (NSString *)report
{
    NSMutableString *out = [NSMutableString string];

    [out appendString:@"elements\n"];
    for (NSString *type in [[self.elementCounts allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [out appendFormat:@"  %-16s %ld\n", type.UTF8String, (long)[self.elementCounts[type] integerValue]];
    }

    if (self.characterCount || self.dialogueCount) {
        [out appendFormat:@"\ncues %lu, dialogue %lu   %s\n",
         (unsigned long)self.characterCount, (unsigned long)self.dialogueCount,
         self.cueBalanceSuspicious ? "<- suspicious: these should be close" : "ok"];
    }

    [out appendString:@"\nsigns of a bad conversion\n"];
    struct { const char *label; NSUInteger value; } tells[] = {
        { "page numbers left in body",     self.pageNumberLines },
        { "doubled spaces inside a line",  self.doubledSpaceLines },
        { "(CONTINUED) / (MORE) markers",  self.continuationMarkers },
        { "trailing whitespace",           self.trailingWhitespaceLines },
        { "whitespace-only elements",      self.whitespaceOnlyElements },
    };
    for (int i = 0; i < 5; i++) {
        [out appendFormat:@"  %-32s %lu%s\n", tells[i].label,
         (unsigned long)tells[i].value, tells[i].value ? "   <-" : ""];
    }

    [out appendString:@"\nround trip through the writer\n"];
    [out appendFormat:@"  lines %lu -> %lu\n",
     (unsigned long)self.sourceLineCount, (unsigned long)self.writtenLineCount];
    BOOL roundTripDiffers = (self.differingLines || self.sourceLineCount != self.writtenLineCount);
    [out appendFormat:@"  differing lines                  %lu%s\n",
     (unsigned long)self.differingLines, roundTripDiffers ? "   <-" : ""];
    for (NSString *sample in self.sampleDifferences) {
        [out appendFormat:@"      %@\n", [sample stringByReplacingOccurrencesOfString:@"\n"
                                                                           withString:@"\n      "]];
    }

    [out appendFormat:@"\n%s\n", self.problemCount ? "problems found" : "nothing suspicious"];
    return out;
}

@end
