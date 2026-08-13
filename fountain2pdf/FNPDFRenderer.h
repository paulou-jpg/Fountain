//
//  FNPDFRenderer.h
//
//  Renders an FNScript to a print-ready screenplay PDF in standard format.
//

#import <Foundation/Foundation.h>

@class FNScript;

@interface FNPDFRenderer : NSObject

- (instancetype)initWithScript:(FNScript *)script;

/// Draw the title page. Defaults to YES when the script has one.
@property (nonatomic) BOOL includesTitlePage;

/// Print scene numbers in the gutters. Defaults to YES.
@property (nonatomic) BOOL includesSceneNumbers;

/// Append (CONT'D) when a character speaks again within the same scene.
/// Defaults to YES, matching Final Draft's automatic character continueds.
@property (nonatomic) BOOL automaticContinueds;

/// Number of body pages. Valid after -PDFData.
@property (nonatomic, readonly) NSUInteger pageCount;

- (NSData *)PDFData;
- (BOOL)writeToFile:(NSString *)path error:(NSError **)error;

@end
