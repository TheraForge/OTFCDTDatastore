//
//  TDPusherTests.m
//  Tests
//
//  Created by Adam Cox on 1/15/14.
//  Copyright (c) 2014 Cloudant. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import <Foundation/Foundation.h>
#import "CollectionUtils.h"
#import "TDPusher.h"
#import "TDInternal.h"
#import "CloudantTests.h"
#import "CDTEncryptionKeyNilProvider.h"

extern int findCommonAncestor(TD_Revision* rev, NSArray* possibleRevIDs);

@interface TDPusher (PendingSequenceTests)
- (void)addPending:(TD_Revision*)rev;
- (void)removePending:(TD_Revision*)rev;
@end

@interface TDPusherPendingSequenceTestDouble : TDPusher
- (void)preparePendingSequencesWithLastSequence:(SequenceNumber)lastSequence;
@end

@implementation TDPusherPendingSequenceTestDouble

- (void)preparePendingSequencesWithLastSequence:(SequenceNumber)lastSequence
{
    _pendingSequences = [NSMutableIndexSet indexSet];
    _maxPendingSequence = lastSequence;
    _lastSequence = [@(lastSequence) copy];
}

@end

@interface TDPusherTests : CloudantTests


@end

@implementation TDPusherTests

- (TD_Revision*)revisionWithDocID:(NSString*)docID revID:(NSString*)revID sequence:(SequenceNumber)sequence
{
    TD_Revision* rev = [[TD_Revision alloc] initWithDocID:docID revID:revID deleted:NO];
    rev.sequence = sequence;
    return rev;
}

- (TD_Revision*)revisionWithHistoryIDs:(NSArray*)ids start:(NSNumber*)start deleted:(BOOL)deleted
{
    NSMutableDictionary* properties =
        [@{@"_id": @"doc", @"_rev": [NSString stringWithFormat:@"%@-%@", start, ids.firstObject],
           @"_revisions": @{@"ids": ids, @"start": start}, @"current": @NO} mutableCopy];
    if (deleted) {
        properties[@"_deleted"] = @YES;
    }
    return [TD_Revision revisionWithProperties:properties];
}

- (TD_Database*)temporaryDatabaseNamed:(NSString*)name
{
    NSString* databasePath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.touchdb",
                                                                  name,
                                                                  [NSUUID UUID].UUIDString]];
    TD_Database* database =
        [TD_Database createEmptyDBAtPath:databasePath
               withEncryptionKeyProvider:[CDTEncryptionKeyNilProvider provider]];
    XCTAssertNotNil(database);
    return database;
}


- (void)testFindCommonAncestor
{
    NSDictionary* revDict = $dict({@"ids", @[@"second", @"first"]}, {@"start", @2});
    TD_Revision* rev = [TD_Revision revisionWithProperties: $dict({@"_revisions", revDict})];
    XCTAssertEqual(findCommonAncestor(rev, @[]), 0, @"Did not find zero common ancestors in empty rev dictionary in %s", __PRETTY_FUNCTION__);
    XCTAssertEqual(findCommonAncestor(rev, @[@"3-noway", @"1-nope"]), 0, @"Did not find zero common ancestors in incorrect rev dictionary in %s", __PRETTY_FUNCTION__);
    XCTAssertEqual(findCommonAncestor(rev, @[@"3-noway", @"1-first"]), 1, @"Did not find common ancestor 1-first in rev dictionary in %s", __PRETTY_FUNCTION__);
    XCTAssertEqual(findCommonAncestor(rev, @[@"3-noway", @"2-second", @"1-first"]), 2, @"Did not find common ancestor 2-second in rev dictionary in %s", __PRETTY_FUNCTION__);

//    STFail(@"test failing");
}

- (void)testFindCommonAncestorReturnsZeroForNilAndEmptyPossibleAncestors
{
    TD_Revision* rev = [self revisionWithHistoryIDs:@[@"current", @"parent"] start:@2 deleted:NO];

    XCTAssertEqual(findCommonAncestor(rev, nil), 0);
    XCTAssertEqual(findCommonAncestor(rev, @[]), 0);
}

- (void)testFindCommonAncestorMatchesFirstHistoryEntryAndDeeperAncestor
{
    TD_Revision* rev =
        [self revisionWithHistoryIDs:@[@"current", @"parent", @"grandparent", @"root"]
                               start:@4
                             deleted:NO];

    XCTAssertEqual(findCommonAncestor(rev, @[@"4-current", @"2-grandparent"]), 4);
    XCTAssertEqual(findCommonAncestor(rev, @[@"2-grandparent", @"1-root"]), 2);
}

- (void)testFindCommonAncestorReturnsZeroWhenNoAncestorMatches
{
    TD_Revision* rev =
        [self revisionWithHistoryIDs:@[@"current", @"parent", @"grandparent"] start:@3 deleted:NO];

    XCTAssertEqual(findCommonAncestor(rev, @[@"3-other", @"2-nope", @"1-missing"]), 0);
}

- (void)testFindCommonAncestorIgnoresDeletedAndCurrentProperties
{
    TD_Revision* activeRev =
        [self revisionWithHistoryIDs:@[@"current", @"parent", @"root"] start:@3 deleted:NO];
    TD_Revision* deletedRev =
        [self revisionWithHistoryIDs:@[@"current", @"parent", @"root"] start:@3 deleted:YES];

    XCTAssertFalse(activeRev.deleted);
    XCTAssertTrue(deletedRev.deleted);
    XCTAssertEqual(findCommonAncestor(activeRev, @[@"2-parent"]), 2);
    XCTAssertEqual(findCommonAncestor(deletedRev, @[@"2-parent"]), 2);
}

- (void)testAddAndRemovePendingAdvanceCheckpointAcrossGaps
{
    TD_Database* database = [self temporaryDatabaseNamed:@"TDPusherPending"];
    TDPusherPendingSequenceTestDouble* pusher =
        [[TDPusherPendingSequenceTestDouble alloc] initWithDB:database
                                                       remote:[NSURL URLWithString:@"https://example.com/db"]
                                                         push:YES
                                                   continuous:NO
                                                 interceptors:@[]];
    [pusher preparePendingSequencesWithLastSequence:1];

    TD_Revision* rev2 = [self revisionWithDocID:@"doc2" revID:@"1-a" sequence:2];
    TD_Revision* rev4 = [self revisionWithDocID:@"doc4" revID:@"1-b" sequence:4];
    TD_Revision* rev5 = [self revisionWithDocID:@"doc5" revID:@"1-c" sequence:5];
    [pusher addPending:rev2];
    [pusher addPending:rev4];
    [pusher addPending:rev5];

    [pusher removePending:rev4];
    XCTAssertEqualObjects(pusher.lastSequence, @1);

    [pusher removePending:rev2];
    XCTAssertEqualObjects(pusher.lastSequence, @4);

    [pusher removePending:rev5];
    XCTAssertEqualObjects(pusher.lastSequence, @5);

    [NSObject cancelPreviousPerformRequestsWithTarget:pusher];
    [database close];
    [TD_Database deleteClosedDatabaseAtPath:database.path error:nil];
}

@end
