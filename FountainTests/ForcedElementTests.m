//
//  ForcedElementTests.m
//  Fountain
//
//  Created by Nima Yousefi on 3/14/14.
//  Copyright (c) 2014 Nima Yousefi. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "BaseElementTests.h"
#import "FNElement.h"

@interface ForcedElementTests : BaseElementTests

@end

@implementation ForcedElementTests

- (void)setUp
{
    [super setUp];
    [self loadTestFile:@"ForcedElements"];
}

- (void)testForcedAction
{
    NSUInteger index = 0;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Action", @"%@", [self errorForIndex:index]);
}

- (void)testForcedCharacterCue
{
    NSUInteger index = 1;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Character", @"%@", [self errorForIndex:index]);
}

- (void)testLyrics
{
    NSUInteger index = 4;
	XCTAssertEqualObjects([self elementTypeAtIndex:index], @"Lyrics", @"%@", [self errorForIndex:index]);
}

@end
