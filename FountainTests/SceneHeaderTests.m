//
//  FTNSceneHeaderTests.m
//  Fountain
//
//  Copyright (c) 2013 Nima Yousefi & John August
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

#import "SceneHeaderTests.h"
#import "FNElement.h"

@implementation SceneHeaderTests

- (void)setUp
{
	[super setUp];
	[self loadTestFile:@"SceneHeaders"];
}

#pragma mark - Tests

- (void)testInt
{	
	NSUInteger index = 0;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
}

- (void)testExt
{
	NSUInteger index = 1;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
}

- (void)testSpaceSeparators
{
	NSUInteger index = 2;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
	
	index = 3;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
}

- (void)testIntExt
{
	NSUInteger index = 4;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
}

- (void)testAbbreviatedIntExt
{
	NSUInteger index = 6;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
	
	index = 7;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);

	index = 8;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
}

- (void)testESTHeader
{
	NSUInteger index = 11;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
	
	index = 12;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
}

- (void)testSceneHeaderWithDate
{
	NSUInteger index = 13;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
}

- (void)testForcedSceneHeader
{
	NSUInteger index = 14;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Scene Heading", @"%@", [self errorForIndex:index]);
}

- (void)testNotAForcedSceneHeader
{
	NSUInteger index = 15;
	XCTAssertFalse([[self elementTypeAtIndex:index] isEqualToString:@"Scene Heading"], @"%@", [self errorForIndex:index]);
}

- (void)testRequiresBlankLinesBeforeAndAfter
{
	NSUInteger index = 16;
	XCTAssertFalse([[self elementTypeAtIndex:index] isEqualToString:@"Scene Heading"], @"%@", [self errorForIndex:index]);
}

- (void)testNeedsSeparatorAfterPrefix
{
	NSUInteger index = 17;
	XCTAssertFalse([[self elementTypeAtIndex:index] isEqualToString:@"Scene Heading"], @"%@", [self errorForIndex:index]);
}

- (void)testNoCaps
{
	NSUInteger index = 18;
	XCTAssertTrue([[self elementTypeAtIndex:index] isEqualToString:@"Scene Heading"], @"%@", [self errorForIndex:index]);
}

@end
