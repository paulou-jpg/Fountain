//
//  FNHTMLScript.m
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

#import "FNHTMLScript.h"
#import "FNScript.h"
#import "FNElement.h"
#import "RegexKitLite.h"
#import "FountainRegexes.h"
#import "FNPaginator.h"

@interface FNHTMLScript ()

@property (readonly, copy, nonatomic) NSString *cssText;
@property (copy, nonatomic) NSString *bodyText;

@end

@implementation FNHTMLScript

- (id)initWithScript:(FNScript *)aScript
{
    self = [super init];
    if (self) {
        _script = aScript;
        _font = [QUQFont fontWithName:@"Courier" size:13];
    }
    return self;
}

- (NSString *)html
{
    if (!self.bodyText) {
        self.bodyText = [self bodyForScript];
    }
    
    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<!DOCTYPE html>\n"];
    [html appendString:@"<html>\n"];
    [html appendString:@"<head>\n"];
    [html appendString:@"<style type='text/css'>\n"];
    [html appendString:self.cssText];
    [html appendString:@"</style>\n"];
    [html appendString:@"</head>\n"];
    [html appendString:@"<body>\n<article>\n<section>\n"];
    [html appendString:self.bodyText];
    [html appendString:@"</section>\n</article>\n</body>\n"];
    [html appendString:@"</html>"];        
    return html;
}

- (NSString *)htmlClassForType:(NSString *)elementType
{
    return [[elementType lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"-"];
}

// Screenplay text is not markup. "HORIZON SAVINGS & LOAN" has to survive the
// trip into an HTML document intact, so entities are escaped before any of our
// own tags go in.
+ (NSString *)escapeHTML:(NSString *)text
{
    if (!text) {
        return @"";
    }
    NSMutableString *escaped = [NSMutableString stringWithString:text];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

- (NSString *)cssText
{    
    NSError *error = nil;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"ScriptCSS.css" ofType:@""];
    NSString *css = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        NSLog(@"Couldn't load CSS");
        css = @"";
    }
    return css;
}

- (NSString *)bodyForScript
{
    NSMutableString *body = [NSMutableString string];
    
    // Add title page
    NSMutableDictionary *titlePage = [NSMutableDictionary dictionary];
    for (NSDictionary *dict in self.script.titlePage) {
        [titlePage addEntriesFromDictionary:dict];
    }
    
    if ([titlePage count] > 0) {
        [body appendString:@"<div id='script-title'>"];

        // Keys we lay out explicitly, in title-page order. Anything else the
        // author wrote is rendered afterwards rather than being discarded --
        // the spec places no limit on which keys a title page may carry.
        NSArray *knownKeys = @[@"title", @"credit", @"authors", @"source", @"draft date", @"contact"];

        // Title
        if (titlePage[@"title"]) {
            NSArray *obj = titlePage[@"title"];
            NSMutableString *values = [NSMutableString string];
            for (NSString *val in obj) {
                [values appendFormat:@"%@<br>", val];
            }
            [body appendFormat:@"<p class='%@'>%@</p>", @"title", values];
        }
        else {
            [body appendFormat:@"<p class='%@'>%@</p>", @"title", @"Untitled"];
        }
        
        // Credit
        if (titlePage[@"credit"] || titlePage[@"authors"]) {
            if (titlePage[@"credit"]) {
                NSArray *obj = titlePage[@"credit"];
                NSMutableString *values = [NSMutableString string];
                for (NSString *val in obj) {
                    [values appendFormat:@"%@<br>", val];
                }
                [body appendFormat:@"<p class='%@'>%@</p>", @"credit", values];
            }
            else {
                [body appendFormat:@"<p class='%@'>%@</p>", @"credit", @"written by"];
            }
            
            // Authors
            if (titlePage[@"authors"]) {
                NSArray *obj = titlePage[@"authors"];
                NSMutableString *values = [NSMutableString string];
                for (NSString *val in obj) {
                    [values appendFormat:@"%@<br>", val];
                }
                [body appendFormat:@"<p class='%@'>%@</p>", @"authors", values];
            }
            else {
                [body appendFormat:@"<p class='%@'>%@</p>", @"authors", @"Anonymous"];
            }
        }
        
        // Source
        if (titlePage[@"source"]) {
            NSArray *obj = titlePage[@"source"];
            NSMutableString *values = [NSMutableString string];
            for (NSString *val in obj) {
                [values appendFormat:@"%@<br>", val];
            }
            [body appendFormat:@"<p class='%@'>%@</p>", @"source", values];
        }
        
        // Draft date
        if (titlePage[@"draft date"]) {
            NSArray *obj = titlePage[@"draft date"];
            NSMutableString *values = [NSMutableString string];
            for (NSString *val in obj) {
                [values appendFormat:@"%@<br>", val];
            }
            [body appendFormat:@"<p class='%@'>%@</p>", @"draft date", values];
        }
        
        // Contact
        if (titlePage[@"contact"]) {
            NSArray *obj = titlePage[@"contact"];
            NSMutableString *values = [NSMutableString string];
            for (NSString *val in obj) {
                [values appendFormat:@"%@<br>", val];
            }
            [body appendFormat:@"<p class='%@'>%@</p>", @"contact", values];
        }

        // Any remaining keys -- "Info:", "Notes:", "Revision:" and friends.
        for (NSString *key in [[titlePage allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            if ([knownKeys containsObject:key]) {
                continue;
            }
            NSMutableString *values = [NSMutableString string];
            for (NSString *val in titlePage[key]) {
                [values appendFormat:@"%@<br>", [FNHTMLScript escapeHTML:val]];
            }
            [body appendFormat:@"<p class='%@'>%@</p>", [self htmlClassForType:key], values];
        }

        [body appendString:@"</div>"];
    }
    
    NSInteger dualDialogueCharacterCount = 0;
    NSSet *dialogueTypes = [NSSet setWithObjects:@"Character", @"Dialogue", @"Parenthetical", nil];
    NSSet *ignoringTypes = [NSSet setWithObjects:@"Boneyard", @"Comment", @"Synopsis", @"Section Heading", nil];
    
    FNPaginator *paginator = [[FNPaginator alloc] initWithScript:self.script];
    NSUInteger maxPages = [paginator numberOfPages];
    
    for (NSInteger pageIndex = 0; pageIndex < maxPages; pageIndex++) {
        NSArray *elementsOnPage = [paginator pageAtIndex:pageIndex];
        
        // Print what page we're on -- used for page jumper
        [body appendFormat:@"<p class='page-break'>%d.</p>\n", (int)pageIndex+1];
    
        for (FNElement *element in elementsOnPage) {
            if ([ignoringTypes containsObject:element.elementType]) {
                continue;
            }
            
            if ([element.elementType isEqualToString:@"Page Break"]) {
                [body appendString:@"</section>\n<section>\n"];
                continue;
            }
            
            if ([element.elementType isEqualToString:@"Character"] && element.isDualDialogue) {
                dualDialogueCharacterCount++;
                if (dualDialogueCharacterCount == 1) {
                    [body appendString:@"<div class='dual-dialogue'>\n"];
                    [body appendString:@"<div class='dual-dialogue-left'>\n"];
                }
                else if (dualDialogueCharacterCount == 2) {
                    [body appendString:@"</div>\n<div class='dual-dialogue-right'>\n"];
                }
            }
            
            if (dualDialogueCharacterCount >= 2 && ![dialogueTypes containsObject:element.elementType]) {
                dualDialogueCharacterCount = 0;
                [body appendString:@"</div>\n</div>\n"];
            }
            
            // Escape first, so that markup we add below is the only markup present.
            NSMutableString *text = [NSMutableString string];
            NSString *escapedText = [FNHTMLScript escapeHTML:element.elementText];
            if ([element.elementType isEqualToString:@"Scene Heading"] && element.sceneNumber) {
                NSString *escapedNumber = [FNHTMLScript escapeHTML:element.sceneNumber];
                [text appendFormat:@"<span class='scene-number-left'>%@</span>", escapedNumber];
                [text appendString:escapedText];
                [text appendFormat:@"<span class='scene-number-right'>%@</span>", escapedNumber];
            }
            else {
                [text appendString:escapedText];
            }
            
            if ([element.elementType isEqualToString:@"Character"] && element.isDualDialogue) {
                // Remove any carets
                [text replaceOccurrencesOfString:@"^" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, text.length)];
            }
            
            if ([element.elementType isEqualToString:@"Character"]) {
                [text replaceOccurrencesOfRegex:@"^@" withString:@""];
            }
            
            if ([element.elementType isEqualToString:@"Scene Heading"]) {
                [text replaceOccurrencesOfRegex:@"^\\." withString:@""];
            }
            
            if ([element.elementType isEqualToString:@"Lyrics"]) {
                [text replaceOccurrencesOfRegex:@"^~" withString:@""];
            }
            
            if ([element.elementType isEqualToString:@"Action"]) {
                [text replaceOccurrencesOfRegex:@"^\\!" withString:@""];
            }
            
            // Tags have to close in the order they opened.
            [text replaceOccurrencesOfRegex:BOLD_ITALIC_UNDERLINE_PATTERN withString:@"<strong><em><u>$2</u></em></strong>"];
            [text replaceOccurrencesOfRegex:BOLD_ITALIC_PATTERN withString:@"<strong><em>$2</em></strong>"];
            [text replaceOccurrencesOfRegex:BOLD_UNDERLINE_PATTERN withString:@"<strong><u>$2</u></strong>"];
            [text replaceOccurrencesOfRegex:ITALIC_UNDERLINE_PATTERN withString:@"<em><u>$2</u></em>"];
            [text replaceOccurrencesOfRegex:BOLD_PATTERN withString:@"<strong>$2</strong>"];
            [text replaceOccurrencesOfRegex:ITALIC_PATTERN withString:@"<em>$2</em>"];
            [text replaceOccurrencesOfRegex:UNDERLINE_PATTERN withString:@"<u>$2</u>"];

            // Notes are omitted from formatted output, including ones that run
            // across line breaks -- hence (?s).
            [text replaceOccurrencesOfRegex:@"(?s)\\[{2}.*?\\]{2}" withString:@""];
            
            if (![text isEqualToString:@""]) {
                NSMutableString *additionalClasses = [NSMutableString string];
                if (element.isCentered) {
                    [additionalClasses appendString:@" center"];
                }
                [body appendFormat:@"<p class='%@%@'>%@</p>\n", [self htmlClassForType:element.elementType], additionalClasses, text];
            }            
        }
    }

    return body;
}

@end
