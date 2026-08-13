//
//  pdf2fountain -- command line front end for FNPDFImporter.
//

#import <Foundation/Foundation.h>
#import "FNPDFImporter.h"
#import "FNScript.h"
#import "FNElement.h"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr,
                "pdf2fountain -- convert a screenplay PDF to Fountain\n\n"
                "usage: pdf2fountain <input.pdf> [output.fountain]\n"
                "       pdf2fountain <input.pdf> -            (write to stdout)\n");
            return 2;
        }

        NSError *error = nil;
        NSString *fountain = [FNPDFImporter fountainFromPDFAtPath:@(argv[1]) error:&error];
        if (!fountain) {
            fprintf(stderr, "pdf2fountain: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        NSData *data = [fountain dataUsingEncoding:NSUTF8StringEncoding];
        NSString *outPath = (argc > 2) ? @(argv[2]) : nil;
        if (!outPath || [outPath isEqualToString:@"-"]) {
            fwrite(data.bytes, 1, data.length, stdout);
            return 0;
        }

        if (![data writeToFile:[outPath stringByExpandingTildeInPath] options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "pdf2fountain: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        FNScript *script = [[FNScript alloc] initWithString:fountain];
        NSCountedSet *counts = [NSCountedSet set];
        for (FNElement *e in script.elements) [counts addObject:e.elementType];
        fprintf(stderr, "pdf2fountain: -> %s\n", outPath.UTF8String);
        for (NSString *type in [[counts allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
            fprintf(stderr, "   %-16s %lu\n", type.UTF8String, (unsigned long)[counts countForObject:type]);
        }
    }
    return 0;
}
