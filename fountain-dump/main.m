//
//  fountain-dump
//
//  Inspects a Fountain file: what the parser made of it, what the writer gives
//  back, and whether anything about it looks wrong. Mostly useful for checking
//  the output of a conversion, where the failure modes are structural rather
//  than visible in the text.
//

#import <Foundation/Foundation.h>
#import "FNScript.h"
#import "FNElement.h"
#import "FNHTMLScript.h"
#import "FNScriptCheck.h"

static void P(NSString *s)
{
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    fwrite(d.bytes, 1, d.length, stdout);
}

// Control characters and newlines made visible, for -elements.
static NSString *Visible(NSString *s)
{
    if (!s) return @"(nil)";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    s = [s stringByReplacingOccurrencesOfString:@"\t" withString:@"\\t"];
    return s;
}

static NSString *ReadFile(NSString *path, NSError **error)
{
    if ([path isEqualToString:@"-"]) {
        NSData *data = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return [NSString stringWithContentsOfFile:[path stringByExpandingTildeInPath]
                                     encoding:NSUTF8StringEncoding error:error];
}

#pragma mark - main

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr,
                "fountain-dump -- inspect a Fountain file\n\n"
                "usage: fountain-dump <command> <file.fountain>\n"
                "       fountain-dump <command> -            (read stdin)\n\n"
                "commands:\n"
                "  check       parse it and report anything that looks wrong\n"
                "  stats       count the elements\n"
                "  elements    one line per element, with its type\n"
                "  roundtrip   write the parsed script back out\n"
                "  html        render to HTML\n\n"
                "check exits non-zero when it finds problems.\n");
            return 2;
        }

        NSString *command = @(argv[1]);
        NSError *error = nil;
        NSString *source = ReadFile(@(argv[2]), &error);
        if (!source) {
            fprintf(stderr, "fountain-dump: could not read %s: %s\n",
                    argv[2], error.localizedDescription.UTF8String ?: "not valid UTF-8");
            return 1;
        }

        FNScript *script = [[FNScript alloc] initWithString:source];

        if ([command isEqualToString:@"check"]) {
            FNScriptCheck *check = [FNScriptCheck checkOfSource:source];
            P([check report]);
            return check.problemCount ? 1 : 0;
        }
        if ([command isEqualToString:@"stats"]) {
            NSDictionary *counts = [FNScriptCheck checkOfSource:source].elementCounts;
            for (NSString *type in [[counts allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                P([NSString stringWithFormat:@"%-16s %ld\n", type.UTF8String, (long)[counts[type] integerValue]]);
            }
            return 0;
        }
        if ([command isEqualToString:@"elements"]) {
            for (NSDictionary *entry in script.titlePage) {
                for (NSString *key in entry) {
                    P([NSString stringWithFormat:@"%-16s |%@|\n", "Title Page",
                       [NSString stringWithFormat:@"%@: %@", key, [entry[key] componentsJoinedByString:@" / "]]]);
                }
            }
            for (FNElement *e in script.elements) {
                NSMutableString *flags = [NSMutableString string];
                if (e.isCentered) [flags appendString:@" +centered"];
                if (e.isDualDialogue) [flags appendString:@" +dual"];
                if (e.sceneNumber) [flags appendFormat:@" +number(%@)", e.sceneNumber];
                if (e.sectionDepth) [flags appendFormat:@" +depth(%u)", (unsigned)e.sectionDepth];
                P([NSString stringWithFormat:@"%-16s |%@|%@\n", e.elementType.UTF8String,
                   Visible(e.elementText), flags]);
            }
            return 0;
        }
        if ([command isEqualToString:@"roundtrip"]) {
            P([script stringFromDocument]);
            P(@"\n");
            return 0;
        }
        if ([command isEqualToString:@"html"]) {
            P([[[FNHTMLScript alloc] initWithScript:script] html]);
            P(@"\n");
            return 0;
        }

        fprintf(stderr, "fountain-dump: unknown command '%s'\n", argv[1]);
        return 2;
    }
}
