//
//  FNScriptCheck.h
//
//  Looks over a Fountain file for the marks of a bad conversion. The failure
//  modes worth catching are structural rather than visible in the text: page
//  furniture left in the body, spacing carried over from a PDF's line breaks,
//  and cues that were read as something else.
//

#import <Foundation/Foundation.h>

/// A cue count and a dialogue count this far apart mean cues were misread:
/// every cue should have a speech under it.
extern const double kFNCueBalanceThreshold;

@interface FNScriptCheck : NSObject

/// Parses `source` and examines the result.
+ (instancetype)checkOfSource:(NSString *)source;

@property (readonly, nonatomic) NSDictionary<NSString *, NSNumber *> *elementCounts;

// Cues against speech.
@property (readonly, nonatomic) NSUInteger characterCount;
@property (readonly, nonatomic) NSUInteger dialogueCount;
/// The smaller count over the larger, or 1 when the script has no dialogue.
@property (readonly, nonatomic) double cueBalance;
@property (readonly, nonatomic) BOOL cueBalanceSuspicious;

// Marks of a bad import. Each is a count of offending lines or elements.
@property (readonly, nonatomic) NSUInteger pageNumberLines;
@property (readonly, nonatomic) NSUInteger doubledSpaceLines;
@property (readonly, nonatomic) NSUInteger continuationMarkers;
@property (readonly, nonatomic) NSUInteger trailingWhitespaceLines;
@property (readonly, nonatomic) NSUInteger whitespaceOnlyElements;

// Round trip: parsing and writing back should reproduce the file.
@property (readonly, nonatomic) NSUInteger sourceLineCount;
@property (readonly, nonatomic) NSUInteger writtenLineCount;
@property (readonly, nonatomic) NSUInteger differingLines;
/// Up to five "in ... / out ..." pairs, for reporting.
@property (readonly, nonatomic) NSArray<NSString *> *sampleDifferences;

/// How many of the checks above found something. Zero means nothing suspicious.
@property (readonly, nonatomic) NSUInteger problemCount;

/// The human-readable form printed by `fountain-dump check`.
- (NSString *)report;

@end
