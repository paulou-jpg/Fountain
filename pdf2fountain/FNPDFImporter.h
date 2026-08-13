//
//  FNPDFImporter.h
//
//  Converts a screenplay PDF into Fountain.
//

#import <Foundation/Foundation.h>

@interface FNPDFImporter : NSObject

/// Converts the PDF at `path` to Fountain source. Returns nil and populates
/// `error` when the file cannot be opened or carries no text layer.
+ (NSString *)fountainFromPDFAtPath:(NSString *)path error:(NSError **)error;

@end
