//
//  fountain2pdf
//
//  Renders a Fountain screenplay to a print-ready PDF using the page geometry
//  measured from Final Draft output. See FNPDFMetrics.h.
//

#import <Foundation/Foundation.h>
#import "FNPDFRenderer.h"
#import "FNScript.h"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr,
                "fountain2pdf -- render a Fountain screenplay to PDF\n\n"
                "usage: fountain2pdf <input.fountain> [output.pdf] [options]\n\n"
                "options:\n"
                "  --no-title-page      skip the title page\n"
                "  --no-scene-numbers   omit scene numbers from the gutters\n");
            return 2;
        }

        NSString *inPath = [@(argv[1]) stringByExpandingTildeInPath];
        NSString *outPath = nil;
        BOOL noTitle = NO, noSceneNumbers = NO;

        for (int i = 2; i < argc; i++) {
            NSString *arg = @(argv[i]);
            if ([arg isEqualToString:@"--no-title-page"]) noTitle = YES;
            else if ([arg isEqualToString:@"--no-scene-numbers"]) noSceneNumbers = YES;
            else if (![arg hasPrefix:@"--"] && !outPath) outPath = [arg stringByExpandingTildeInPath];
            else {
                fprintf(stderr, "fountain2pdf: unrecognised option %s\n", argv[i]);
                return 2;
            }
        }
        if (!outPath) {
            outPath = [[inPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"pdf"];
        }

        NSError *error = nil;
        NSString *source = [NSString stringWithContentsOfFile:inPath encoding:NSUTF8StringEncoding error:&error];
        if (!source) {
            fprintf(stderr, "fountain2pdf: could not read %s: %s\n",
                    argv[1], error.localizedDescription.UTF8String);
            return 1;
        }

        FNScript *script = [[FNScript alloc] initWithString:source];
        FNPDFRenderer *renderer = [[FNPDFRenderer alloc] initWithScript:script];
        if (noTitle) renderer.includesTitlePage = NO;
        if (noSceneNumbers) renderer.includesSceneNumbers = NO;

        if (![renderer writeToFile:outPath error:&error]) {
            fprintf(stderr, "fountain2pdf: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        fprintf(stderr, "fountain2pdf: %lu elements -> %s (%lu pages%s)\n",
                (unsigned long)script.elements.count, outPath.UTF8String,
                (unsigned long)renderer.pageCount,
                renderer.includesTitlePage ? " + title page" : "");
    }
    return 0;
}
