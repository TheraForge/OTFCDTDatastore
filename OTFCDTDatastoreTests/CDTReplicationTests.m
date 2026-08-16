//
//  CDTReplicationTests.m
//  Tests
//
//  Created by Adam Cox on 4/14/14.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import <XCTest/XCTest.h>
#import "CDTPullReplication.h"
#import "CDTPushReplication.h"
#import "CloudantSyncTests.h"
#import "CDTDatastoreManager.h"
#import "CDTDatastore.h"
#import "CDTReplicatorFactory.h"
#import "CDTReplicator.h"
#import "CDTDocumentRevision.h"
#import "TD_Body.h"
#import "TD_Revision.h"
#import "TDPuller.h"
#import "TDPusher.h"
#import "CDTSessionCookieInterceptor.h"
#import "CDTIAMSessionCookieInterceptor.h"
#import "CDTReplay429Interceptor.h"
#import "CDTURLSession.h"
#import "TD_Database.h"
#import "TD_Database+Insertion.h"
#import "TD_Database+Replication.h"
#import "TDChangeTracker.h"
#import "TDInternal.h"
#import "TDJSON.h"
#import "TDStatus.h"
#import <OHHTTPStubs/OHHTTPStubs.h>
#import <OHHTTPStubs/OHHTTPStubsResponse+JSON.h>
#import <OCMock/OCMock.h>
#import <netinet/in.h>


@interface TDReplicator ()
@property (nonatomic, strong) NSArray* interceptors;
@end

@interface CDTReplicator()
- (TDReplicator *)buildTDReplicatorFromConfiguration:(NSError *__autoreleasing *)error;
@end

@interface CDTSessionCookieInterceptor()
@property (nonnull, strong, nonatomic) NSData *sessionRequestBody;
@end
#pragma mark Utility - ContextCaptureInterceptor

@interface ContextCaptureInterceptor : NSObject <CDTHTTPInterceptor>

@property CDTHTTPInterceptorContext *lastContext;

@end

@implementation ContextCaptureInterceptor

- (CDTHTTPInterceptorContext *)interceptResponseInContext:(CDTHTTPInterceptorContext *)context
{
    _lastContext = context;
    return context;
}

@end

#pragma mark Utility - ChangesFeedRequestCheckInterceptor

@interface ChangesFeedRequestCheckInterceptor : NSObject <CDTHTTPInterceptor>

@property (nonatomic) BOOL changesFeedRequestMade;

@end

@implementation ChangesFeedRequestCheckInterceptor

- (instancetype)init
{
    self = [super init];
    if (self) {
        _changesFeedRequestMade = NO;
    }
    return self;
}

- (CDTHTTPInterceptorContext *)interceptRequestInContext:(CDTHTTPInterceptorContext *)context
{
    // determines if the interceptor was run before request
    NSURL *url = context.request.URL;

    if ([[url path] containsString:@"/_changes"]) {
        self.changesFeedRequestMade = YES;
    }

    return context;
}

@end

#pragma mark Utility - ChangeTrackerRecordingClient

@interface ChangeTrackerRecordingClient : NSObject <TDChangeTrackerClient>

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *changes;
@property (nonatomic) BOOL stopped;

@end

@implementation ChangeTrackerRecordingClient

- (instancetype)init
{
    self = [super init];
    if (self) {
        _changes = [NSMutableArray array];
    }
    return self;
}

- (void)changeTrackerReceivedChange:(NSDictionary *)change
{
    [self.changes addObject:change];
}

- (void)changeTrackerStopped:(TDChangeTracker *)tracker
{
    self.stopped = YES;
}

@end

#pragma mark Utility - SimpleHttpServer

@interface SimpleHttpServer : NSObject

@property int listenSocketFd;
@property bool stopped;
@property NSString *header;
@property int port;

@end

@implementation SimpleHttpServer

- (id)initWithHeader:(NSString*)header
                port:(int)port
{
    if (self = [super init]) {
        self.header = header;
        self.port = port;
    }
    return self;
}

// Start a simple HTTP server on localhost that responds to any message with a fixed header.
- (void)startWithError:(NSError**)error {
    int success;
    self.listenSocketFd = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
    int yes = 1;
    setsockopt(self.listenSocketFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    self.stopped = false;
    const int buf_size = 1024;
    
    struct sockaddr_in serv_addr;
    memset(&serv_addr, '0', sizeof(serv_addr));
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_port = htons(self.port);
    serv_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    
    success = bind(self.listenSocketFd, (struct sockaddr*)&serv_addr, sizeof(serv_addr));
    if (success == -1) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                     code:errno
                                 userInfo:@{@"reason":@"bind() failed"}];
        return;
    }
    success = listen(self.listenSocketFd, 10);
    if (success == -1) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                     code:errno
                                 userInfo:@{@"reason":@"listen() failed"}];
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        while (!self.stopped)
        {
            int connfd = accept(self.listenSocketFd, (struct sockaddr*)NULL, NULL);
            if (connfd > 0) {
                char buffer[buf_size];
                bzero(buffer, buf_size);
                
                // Receive a message.
                recv(connfd, buffer, buf_size, 0);
                
                // We don't care what the message was (or if we read it all), just send back the header.
                const char* header = [self.header cString];
                write(connfd, header, strlen(header));
                close(connfd);
            } else {
                self.stopped = true;
            }
        }
    });
}

- (void)stop {
    self.stopped = true;
    close(self.listenSocketFd);
}

@end

#pragma mark Tests

@interface CDTReplicationTests : CloudantSyncTests

@end

@implementation CDTReplicationTests

- (TDReplicator *)tdReplicatorForReplication:(CDTAbstractReplication *)replication
                                       error:(NSError **)error
{
    CDTReplicatorFactory *factory =
        [[CDTReplicatorFactory alloc] initWithDatastoreManager:self.factory];
    CDTReplicator *replicator = [factory oneWay:replication error:error];
    if (!replicator) {
        return nil;
    }
    return [replicator buildTDReplicatorFromConfiguration:error];
}

- (NSDictionary<NSString *, NSString *> *)queryItemsForChangeTracker:(TDChangeTracker *)tracker
{
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:tracker.changesFeedURL resolvingAgainstBaseURL:NO];
    NSMutableDictionary<NSString *, NSString *> *items = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        items[item.name] = item.value ?: @"";
    }
    return items;
}

- (TDChangeTracker *)changeTrackerWithMode:(TDChangeTrackerMode)mode
                              lastSequence:(id)lastSequence
                                    client:(id<TDChangeTrackerClient>)client
{
    CDTURLSession *session =
        [[CDTURLSession alloc] initWithCallbackThread:[NSThread currentThread]
                                  requestInterceptors:@[]
                                sessionConfigDelegate:nil];
    return [[TDChangeTracker alloc] initWithDatabaseURL:[NSURL URLWithString:@"https://example.com/db"]
                                                   mode:mode
                                              conflicts:NO
                                           lastSequence:lastSequence
                                                 client:client
                                                session:session];
}

- (TD_Revision *)insertRevisionWithDocID:(NSString *)docID
                            previousRevID:(NSString *)previousRevID
                                  deleted:(BOOL)deleted
                               inDatabase:(TD_Database *)database
{
    TD_Revision *rev = [[TD_Revision alloc] initWithDocID:docID revID:nil deleted:deleted];
    if (!deleted) {
        rev.body = [[TD_Body alloc] initWithProperties:@{@"doc": docID}];
    }

    TDStatus status = 0;
    TD_Revision *inserted = [database putRevision:rev
                                   prevRevisionID:previousRevID
                                    allowConflict:YES
                                           status:&status];
    XCTAssertFalse(TDStatusIsError(status), @"Unexpected insert status: %ld", (long)status);
    XCTAssertNotNil(inserted);
    return inserted;
}

- (NSArray<NSString *> *)docRevIDsFromRevisionList:(TD_RevisionList *)revisions
{
    NSMutableArray<NSString *> *docRevIDs = [NSMutableArray array];
    for (TD_Revision *rev in revisions) {
        [docRevIDs addObject:[NSString stringWithFormat:@"%@/%@", rev.docID, rev.revID]];
    }
    return docRevIDs;
}

- (void)testValidateOptionalHeadersAcceptsNilAndUserAgent
{
    NSError *error = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    XCTAssertTrue([CDTAbstractReplication validateOptionalHeaders:nil error:&error]);
#pragma clang diagnostic pop
    XCTAssertNil(error);

    XCTAssertTrue([CDTAbstractReplication
        validateOptionalHeaders:@{@"User-Agent": @"CloudantSyncTests"}
                          error:&error]);
    XCTAssertNil(error);
}

- (void)testValidateOptionalHeadersRejectsNonStringKeysAndValues
{
    NSError *error = nil;
    XCTAssertFalse([CDTAbstractReplication validateOptionalHeaders:@{@42: @"value"} error:&error]);
    XCTAssertEqualObjects(error.domain, CDTReplicationErrorDomain);
    XCTAssertEqual(error.code, CDTReplicationErrorBadOptionalHttpHeaderType);

    error = nil;
    XCTAssertFalse(
        [CDTAbstractReplication validateOptionalHeaders:@{@"X-Test": @42} error:&error]);
    XCTAssertEqualObjects(error.domain, CDTReplicationErrorDomain);
    XCTAssertEqual(error.code, CDTReplicationErrorBadOptionalHttpHeaderType);
}

- (void)testClearInterceptorsRemovesConfiguredAndURLCredentialInterceptors
{
    NSURL *remoteUrl = [NSURL URLWithString:@"http://user:pass@example.com/db"];
    CDTDatastore *datastore = [self.factory datastoreNamed:@"clear_interceptors" error:nil];
    CDTPullReplication *pull =
        [CDTPullReplication replicationWithSource:remoteUrl target:datastore];
    [pull addInterceptor:[[ContextCaptureInterceptor alloc] init]];

    XCTAssertEqual(pull.httpInterceptors.count, 2u);

    [pull clearInterceptors];

    XCTAssertEqual(pull.httpInterceptors.count, 0u);
}

- (void)testCopyPreservesHeadersCredentialsAndInterceptors
{
    NSURL *remoteUrl = [NSURL URLWithString:@"https://example.com/db"];
    CDTDatastore *datastore = [self.factory datastoreNamed:@"copy_abstract" error:nil];
    CDTPullReplication *pull = [CDTPullReplication replicationWithSource:remoteUrl
                                                                  target:datastore
                                                                username:@"username"
                                                                password:@"password"];
    ContextCaptureInterceptor *interceptor = [[ContextCaptureInterceptor alloc] init];
    pull.optionalHeaders = @{@"X-Test": @"value"};
    [pull addInterceptor:interceptor];

    CDTPullReplication *copy = [pull copy];

    XCTAssertNotEqual(copy, pull);
    XCTAssertEqualObjects(copy.optionalHeaders, pull.optionalHeaders);
    XCTAssertEqualObjects(copy.username, @"username");
    XCTAssertEqualObjects(copy.password, @"password");
    XCTAssertEqual(copy.httpInterceptors.count, 1u);
    XCTAssertEqual(copy.httpInterceptors.firstObject, interceptor);
}

- (void)testValidateRemoteDatastoreURLReportsNilSourceAndTarget
{
    CDTPullReplication *pull = [[CDTPullReplication alloc] init];
    CDTPushReplication *push = [[CDTPushReplication alloc] init];

    NSError *error = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    XCTAssertFalse([pull validateRemoteDatastoreURL:nil error:&error]);
#pragma clang diagnostic pop
    XCTAssertEqualObjects(error.domain, CDTReplicationErrorDomain);
    XCTAssertEqual(error.code, CDTReplicationErrorUndefinedSource);

    error = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    XCTAssertFalse([push validateRemoteDatastoreURL:nil error:&error]);
#pragma clang diagnostic pop
    XCTAssertEqualObjects(error.domain, CDTReplicationErrorDomain);
    XCTAssertEqual(error.code, CDTReplicationErrorUndefinedTarget);
}

- (void)testValidateRemoteDatastoreURLRejectsInvalidSchemeAndIncompleteCredentials
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"invalid_remote_validation" error:nil];
    CDTPullReplication *pull =
        [CDTPullReplication replicationWithSource:[NSURL URLWithString:@"https://example.com/db"]
                                           target:datastore];

    NSError *error = nil;
    XCTAssertFalse([pull validateRemoteDatastoreURL:[NSURL URLWithString:@"ftp://example.com/db"]
                                             error:&error]);
    XCTAssertEqual(error.code, CDTReplicationErrorInvalidScheme);

    error = nil;
    XCTAssertFalse(
        [pull validateRemoteDatastoreURL:[NSURL URLWithString:@"https://user@example.com/db"]
                                   error:&error]);
    XCTAssertEqual(error.code, CDTReplicationErrorIncompleteCredentials);

    error = nil;
    XCTAssertFalse(
        [pull validateRemoteDatastoreURL:[NSURL URLWithString:@"https://:pass@example.com/db"]
                                   error:&error]);
    XCTAssertEqual(error.code, CDTReplicationErrorIncompleteCredentials);
}

- (void)testPushAndPullReplicationAssignSourceAndTarget
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"source_target" error:nil];
    NSURL *remoteUrl = [NSURL URLWithString:@"https://example.com/db"];

    CDTPushReplication *push = [CDTPushReplication replicationWithSource:datastore
                                                                  target:remoteUrl];
    XCTAssertEqual(push.source, datastore);
    XCTAssertEqualObjects(push.target, remoteUrl);

    CDTPullReplication *pull = [CDTPullReplication replicationWithSource:remoteUrl
                                                                  target:datastore];
    XCTAssertEqualObjects(pull.source, remoteUrl);
    XCTAssertEqual(pull.target, datastore);
}

- (void)testIAMAPIKeyInitializersSanitizeURLAndAddIAMInterceptor
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"iam_replication" error:nil];
    NSURL *remoteUrl = [NSURL URLWithString:@"https://user:pass@example.com/db"];

    CDTPushReplication *push = [CDTPushReplication replicationWithSource:datastore
                                                                  target:remoteUrl
                                                               IAMAPIKey:@"api key/with spaces"];
    XCTAssertEqualObjects(push.target.absoluteString, @"https://example.com/db");
    XCTAssertEqual(push.httpInterceptors.count, 1u);
    XCTAssertEqualObjects([push.httpInterceptors.firstObject class],
                          [CDTIAMSessionCookieInterceptor class]);

    CDTPullReplication *pull = [CDTPullReplication replicationWithSource:remoteUrl
                                                                  target:datastore
                                                               IAMAPIKey:@"api key/with spaces"];
    XCTAssertEqualObjects(pull.source.absoluteString, @"https://example.com/db");
    XCTAssertEqual(pull.httpInterceptors.count, 1u);
    XCTAssertEqualObjects([pull.httpInterceptors.firstObject class],
                          [CDTIAMSessionCookieInterceptor class]);
}

- (void)testPushReplicationCopyPreservesFilterAndConfiguration
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"push_copy" error:nil];
    NSURL *remoteUrl = [NSURL URLWithString:@"https://example.com/db"];
    CDTPushReplication *push = [CDTPushReplication replicationWithSource:datastore
                                                                  target:remoteUrl];
    push.filterParams = @{@"allow": @YES};
    push.filter = ^BOOL(CDTDocumentRevision *revision, NSDictionary *params) {
        return [revision.docId isEqualToString:@"allowed"] && [params[@"allow"] boolValue];
    };

    CDTPushReplication *copy = [push copy];
    CDTDocumentRevision *revision =
        [[CDTDocumentRevision alloc] initWithDocId:@"allowed"
                                        revisionId:@"1-a"
                                              body:@{}
                                           deleted:NO
                                       attachments:@{}
                                          sequence:1];

    XCTAssertEqual(copy.source, datastore);
    XCTAssertEqualObjects(copy.target, remoteUrl);
    XCTAssertEqualObjects(copy.filterParams, push.filterParams);
    XCTAssertTrue(copy.filter(revision, copy.filterParams));
}

- (void)testPullReplicationCopyPreservesFilterAndConfiguration
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"pull_copy" error:nil];
    NSURL *remoteUrl = [NSURL URLWithString:@"https://example.com/db"];
    CDTPullReplication *pull = [CDTPullReplication replicationWithSource:remoteUrl
                                                                  target:datastore];
    pull.filter = @"design/by_type";
    pull.filterParams = @{@"type": @"task"};

    CDTPullReplication *copy = [pull copy];

    XCTAssertEqualObjects(copy.source, remoteUrl);
    XCTAssertEqual(copy.target, datastore);
    XCTAssertEqualObjects(copy.filter, pull.filter);
    XCTAssertEqualObjects(copy.filterParams, pull.filterParams);
}

- (void)testFactoryCreatesPushAndPullWrappersWithExpectedUnderlyingConfiguration
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"factory_config" error:nil];
    NSURL *remoteUrl = [NSURL URLWithString:@"https://example.com/db"];
    NSDictionary *headers = @{@"X-Test": @"value"};

    CDTPullReplication *pull = [CDTPullReplication replicationWithSource:remoteUrl
                                                                  target:datastore];
    pull.optionalHeaders = headers;
    pull.filter = @"design/filter";
    pull.filterParams = @{@"type": @"active"};
    ContextCaptureInterceptor *pullInterceptor = [[ContextCaptureInterceptor alloc] init];
    [pull addInterceptor:pullInterceptor];

    NSError *error = nil;
    TDReplicator *tdPull = [self tdReplicatorForReplication:pull error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(tdPull);
    XCTAssertFalse(tdPull.isPush);
    XCTAssertEqual(tdPull.db, datastore.database);
    XCTAssertEqualObjects(tdPull.remote, remoteUrl);
    XCTAssertEqualObjects(tdPull.requestHeaders, headers);
    XCTAssertEqualObjects(tdPull.filterName, @"design/filter");
    XCTAssertEqualObjects(tdPull.filterParameters, pull.filterParams);
    XCTAssertEqualObjects(tdPull.interceptors, @[ pullInterceptor ]);

    CDTPushReplication *push = [CDTPushReplication replicationWithSource:datastore
                                                                  target:remoteUrl];
    push.optionalHeaders = headers;
    push.filterParams = @{@"local": @"yes"};
    ContextCaptureInterceptor *pushInterceptor = [[ContextCaptureInterceptor alloc] init];
    [push addInterceptor:pushInterceptor];

    error = nil;
    TDReplicator *tdPush = [self tdReplicatorForReplication:push error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(tdPush);
    XCTAssertTrue(tdPush.isPush);
    XCTAssertEqual(tdPush.db, datastore.database);
    XCTAssertEqualObjects(tdPush.remote, remoteUrl);
    XCTAssertEqualObjects(tdPush.requestHeaders, headers);
    XCTAssertNil(tdPush.filterName);
    XCTAssertEqualObjects(tdPush.filterParameters, push.filterParams);
    XCTAssertEqualObjects(tdPush.interceptors, @[ pushInterceptor ]);
    XCTAssertFalse(((TDPusher *)tdPush).createTarget);
}

- (void)testFactoryRejectsInvalidOptionalHeaderConfigurationWithoutStartingReplication
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"factory_invalid_headers" error:nil];
    CDTPullReplication *pull =
        [CDTPullReplication replicationWithSource:[NSURL URLWithString:@"https://example.com/db"]
                                           target:datastore];
    pull.optionalHeaders = (NSDictionary *)@{@"X-Test": @42};

    NSError *error = nil;
    CDTReplicatorFactory *factory =
        [[CDTReplicatorFactory alloc] initWithDatastoreManager:self.factory];
    CDTReplicator *replicator = [factory oneWay:pull error:&error];

    XCTAssertNil(replicator);
    XCTAssertEqualObjects(error.domain, CDTReplicationErrorDomain);
    XCTAssertEqual(error.code, CDTReplicationErrorBadOptionalHttpHeaderType);
}

- (void)testCheckpointSaveAndLoadPreservesOldAndNewSequenceFormats
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"checkpoint_storage" error:nil];
    TD_Database *database = datastore.database;

    NSError *error = nil;
    NSDictionary *oldCheckpoint = @{@"_id": @"_local/old-checkpoint", @"seq": @7};
    XCTAssertTrue([database saveCheckpointDocument:oldCheckpoint error:&error]);
    XCTAssertNil(error);
    NSDictionary *loadedOld = [database checkpointDocumentWithID:@"old-checkpoint"];
    XCTAssertEqualObjects(loadedOld[@"seq"], @7);
    XCTAssertNil(loadedOld[@"source_last_seq"]);

    NSDictionary *newCheckpoint = @{
        @"_id": @"_local/new-checkpoint",
        @"source_last_seq": @42,
        @"history": @[ @{@"session_id": @"session-a", @"recorded_seq": @42} ],
        @"session_id": @"session-a",
        @"replication_id_version": @3
    };
    XCTAssertTrue([database saveCheckpointDocument:newCheckpoint error:&error]);
    XCTAssertNil(error);
    NSDictionary *loadedNew = [database checkpointDocumentWithID:@"new-checkpoint"];
    XCTAssertEqualObjects(loadedNew[@"source_last_seq"], @42);
    XCTAssertEqualObjects(loadedNew[@"history"], newCheckpoint[@"history"]);
}

- (void)testJoinQuotedStringsEscapesQuotesAndHandlesEmptyInput
{
    XCTAssertEqualObjects([TD_Database joinQuotedStrings:@[]], @"");
    XCTAssertEqualObjects([TD_Database joinQuotedStrings:@[@"alpha"]], @"'alpha'");
    NSArray *stringsToQuote = @[@"a'b", @"c"];
    NSString *quotedStrings = [TD_Database joinQuotedStrings:stringsToQuote];
    XCTAssertEqualObjects(quotedStrings, @"'a''b','c'");
}

- (void)testFindMissingRevisionsHandlesEmptyInput
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"missing_empty" error:nil];
    TD_RevisionList *revisions = [[TD_RevisionList alloc] init];

    XCTAssertTrue([datastore.database findMissingRevisions:revisions]);
    XCTAssertEqual(revisions.count, 0u);
}

- (void)testFindMissingRevisionsLeavesOnlyMissingRevisions
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"missing_revisions" error:nil];
    TD_Database *database = datastore.database;
    TD_Revision *existing =
        [self insertRevisionWithDocID:@"existing" previousRevID:nil deleted:NO inDatabase:database];
    TD_Revision *deletedParent =
        [self insertRevisionWithDocID:@"deleted" previousRevID:nil deleted:NO inDatabase:database];
    TD_Revision *deleted = [self insertRevisionWithDocID:@"deleted"
                                           previousRevID:deletedParent.revID
                                                 deleted:YES
                                              inDatabase:database];
    TD_Revision *missing =
        [[TD_Revision alloc] initWithDocID:@"missing" revID:@"1-missing" deleted:NO];
    TD_RevisionList *revisions =
        [[TD_RevisionList alloc] initWithArray:@[ existing, deleted, missing ]];

    XCTAssertTrue([database findMissingRevisions:revisions]);

    XCTAssertEqualObjects([self docRevIDsFromRevisionList:revisions],
                          @[ @"missing/1-missing" ]);
}

- (void)testFindMissingRevisionsHandlesDuplicateMissingRevisions
{
    CDTDatastore *datastore = [self.factory datastoreNamed:@"missing_duplicates" error:nil];
    TD_Revision *missing =
        [[TD_Revision alloc] initWithDocID:@"missing" revID:@"1-missing" deleted:NO];
    TD_RevisionList *revisions =
        [[TD_RevisionList alloc] initWithArray:@[ missing, missing ]];

    XCTAssertTrue([datastore.database findMissingRevisions:revisions]);

    XCTAssertEqualObjects([self docRevIDsFromRevisionList:revisions],
                          (@[ @"missing/1-missing", @"missing/1-missing" ]));
}

- (void)testChangeTrackerBuildsChangesFeedPathForEachMode
{
    ChangeTrackerRecordingClient *client = [[ChangeTrackerRecordingClient alloc] init];
    NSDictionary *expectedFeeds = @{
        @(kOneShot): @"normal",
        @(kLongPoll): @"longpoll",
        @(kContinuous): @"continuous"
    };

    for (NSNumber *modeNumber in expectedFeeds) {
        TDChangeTracker *tracker = [self changeTrackerWithMode:(TDChangeTrackerMode)modeNumber.integerValue
                                                  lastSequence:nil
                                                        client:client];
        NSDictionary *query = [self queryItemsForChangeTracker:tracker];
        XCTAssertEqualObjects(query[@"feed"], expectedFeeds[modeNumber]);
        XCTAssertEqualObjects(query[@"heartbeat"], @"300000");
    }
}

- (void)testChangeTrackerEscapesSinceFilterParametersAndDocIDs
{
    ChangeTrackerRecordingClient *client = [[ChangeTrackerRecordingClient alloc] init];
    NSArray *lastSequence = @[ @"10", @"node/a b" ];
    TDChangeTracker *tracker = [self changeTrackerWithMode:kLongPoll
                                              lastSequence:lastSequence
                                                    client:client];
    tracker.limit = 25;
    tracker.filterName = @"design/filter name";
    tracker.filterParameters = @{@"space key": @"a value&b", @"number": @7};

    NSDictionary *query = [self queryItemsForChangeTracker:tracker];
    XCTAssertEqualObjects(query[@"since"],
                          [TDJSON stringWithJSONObject:lastSequence options:0 error:nil]);
    XCTAssertEqualObjects(query[@"limit"], @"25");
    XCTAssertEqualObjects(query[@"filter"], @"design/filter name");
    XCTAssertEqualObjects(query[@"space key"], @"a value&b");
    XCTAssertEqualObjects(query[@"number"], @"7");

    TDChangeTracker *docIDsTracker = [self changeTrackerWithMode:kOneShot
                                                    lastSequence:nil
                                                          client:client];
    docIDsTracker.docIDs = @[ @"doc/a", @"space doc" ];
    NSDictionary *docIDsQuery = [self queryItemsForChangeTracker:docIDsTracker];
    NSData *docIDsData = [docIDsQuery[@"doc_ids"] dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *docIDs = [TDJSON JSONObjectWithData:docIDsData options:0 error:nil];
    XCTAssertEqualObjects(docIDsQuery[@"filter"], @"_doc_ids");
    XCTAssertEqualObjects(docIDs, docIDsTracker.docIDs);
}

- (void)testChangeTrackerReceivedPollResponseHandlesEmptyAndMalformedResults
{
    ChangeTrackerRecordingClient *client = [[ChangeTrackerRecordingClient alloc] init];
    TDChangeTracker *tracker = [self changeTrackerWithMode:kOneShot
                                              lastSequence:nil
                                                    client:client];
    NSString *errorMessage = nil;
    NSData *emptyResults = [@"{\"results\":[]}" dataUsingEncoding:NSUTF8StringEncoding];

    XCTAssertEqual([tracker receivedPollResponse:emptyResults errorMessage:&errorMessage], 0);
    XCTAssertNil(errorMessage);
    XCTAssertNil(tracker.lastSequenceID);
    XCTAssertEqual(client.changes.count, 0u);

    errorMessage = nil;
    XCTAssertEqual([tracker receivedPollResponse:nil errorMessage:&errorMessage], -1);
    XCTAssertEqualObjects(errorMessage, @"No body in response");

    errorMessage = nil;
    NSData *malformedJSON = [@"{\"results\":[" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqual([tracker receivedPollResponse:malformedJSON errorMessage:&errorMessage], -1);
    XCTAssertTrue([errorMessage containsString:@"JSON parse error"]);

    errorMessage = nil;
    NSData *missingResults = [@"{\"results\":{}}" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqual([tracker receivedPollResponse:missingResults errorMessage:&errorMessage], -1);
    XCTAssertEqualObjects(errorMessage, @"No 'changes' array in response");

    errorMessage = nil;
    NSData *invalidChange = [@"{\"results\":[\"bad\"]}" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqual([tracker receivedPollResponse:invalidChange errorMessage:&errorMessage], -1);
    XCTAssertTrue([errorMessage containsString:@"Invalid change object"]);
}

- (void)testChangeTrackerReceivedPollResponseUpdatesLastSequence
{
    ChangeTrackerRecordingClient *client = [[ChangeTrackerRecordingClient alloc] init];
    TDChangeTracker *tracker = [self changeTrackerWithMode:kOneShot
                                              lastSequence:nil
                                                    client:client];
    NSString *bodyString =
        @"{\"results\":[{\"seq\":1,\"id\":\"doc1\",\"changes\":[{\"rev\":\"1-a\"}]},"
        @"{\"seq\":\"2-b\",\"id\":\"doc2\",\"changes\":[{\"rev\":\"1-b\"}]}]}";
    NSData *body = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
    NSString *errorMessage = nil;

    XCTAssertEqual([tracker receivedPollResponse:body errorMessage:&errorMessage], 2);
    XCTAssertNil(errorMessage);
    XCTAssertEqualObjects(tracker.lastSequenceID, @"2-b");
    XCTAssertEqual(client.changes.count, 2u);
    XCTAssertEqualObjects(client.changes.lastObject[@"id"], @"doc2");
}

- (void)testChangeTrackerSetUpstreamErrorRecordsError
{
    ChangeTrackerRecordingClient *client = [[ChangeTrackerRecordingClient alloc] init];
    TDChangeTracker *tracker = [self changeTrackerWithMode:kOneShot
                                              lastSequence:nil
                                                    client:client];

    [tracker setUpstreamError:@"boom"];

    XCTAssertEqualObjects(tracker.error.domain, @"TDChangeTracker");
    XCTAssertEqual(tracker.error.code, kTDStatusUpstreamError);
}

- (void) testURLCredsIgnoredIfParametersPresentPull
{
    CDTReplicatorFactory * factory = [[CDTReplicatorFactory alloc] initWithDatastoreManager:self.factory];
    NSError *error;
    //Doesn't need to be real, we aren't going to actually make a replication.
    NSURL * remoteUrl = [[NSURL alloc] initWithString:@"http://user:pass@example.com"];
    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:&error];
    CDTPullReplication *pull =
            [CDTPullReplication replicationWithSource:remoteUrl target:tmp username:@"username" password:@"password"];


    CDTReplicator * replicator = [factory oneWay:pull error:nil];
    TDReplicator * tdReplicator = [replicator buildTDReplicatorFromConfiguration:nil];
            // check the underlying source to make sure it doesn't contain the userinfo
    // and check that the interceptors list contains the cookie interceptor.
    XCTAssertEqualObjects(@"http://example.com", pull.source.absoluteString);
    XCTAssertEqual(tdReplicator.interceptors.count, 1);
    XCTAssertEqualObjects([tdReplicator.interceptors[0] class], [CDTSessionCookieInterceptor class]);

    NSData* expectedPayload = [[NSString stringWithFormat:@"name=%@&password=%@", @"username", @"password"]
            dataUsingEncoding:NSUTF8StringEncoding];
    CDTSessionCookieInterceptor* cookieInterceptor = (CDTSessionCookieInterceptor*)tdReplicator.interceptors[0];
            XCTAssertEqualObjects(expectedPayload, [cookieInterceptor sessionRequestBody]);
}

- (void) testURLCredsIgnoredIfParametersPresentPush {
    CDTReplicatorFactory * factory = [[CDTReplicatorFactory alloc] initWithDatastoreManager:self.factory];
    NSError *error;
    //Doesn't need to be real, we aren't going to actually make a replication.
    NSURL * remoteUrl = [[NSURL alloc] initWithString:@"http://user:pass@example.com"];
    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:&error];
    CDTPushReplication *push = [CDTPushReplication replicationWithSource:tmp target:remoteUrl username:@"username" password:@"password"];

    CDTReplicator * replicator = [factory oneWay:push error:nil];
    TDReplicator * tdReplicator = [replicator buildTDReplicatorFromConfiguration:nil];


    // check the underlying source to make sure it doesn't contain the userinfo
    // and check that the interceptors list contains the cookie interceptor.
    XCTAssertEqualObjects(@"http://example.com", push.target.absoluteString);
    XCTAssertEqual(tdReplicator.interceptors.count, 1);
    XCTAssertEqualObjects([tdReplicator.interceptors[0] class], [CDTSessionCookieInterceptor class]);

    NSData* expectedPayload = [[NSString stringWithFormat:@"name=%@&password=%@", @"username", @"password"]
            dataUsingEncoding:NSUTF8StringEncoding];
    CDTSessionCookieInterceptor* cookieInterceptor = (CDTSessionCookieInterceptor*) tdReplicator.interceptors[0];
    XCTAssertEqualObjects(expectedPayload, [cookieInterceptor sessionRequestBody]);
}

- (void)testURLCredsReplacedWithCookieInterceptorPull
{
    NSError *error;
    //Doesn't need to be real, we aren't going to actually make a replication.
    NSURL * remoteUrl = [[NSURL alloc] initWithString:@"http://user:pass@example.com"];
    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:&error];
    CDTPullReplication *pull =
    [CDTPullReplication replicationWithSource:remoteUrl target:tmp];

    // check the underlying source to make sure it doesn't contain the userinfo
    // and check that the interceptors list contains the cookie interceptor.
    XCTAssertEqualObjects(@"http://example.com", pull.source.absoluteString);
    XCTAssertEqual(pull.httpInterceptors.count, 1);
    XCTAssertEqualObjects([pull.httpInterceptors[0] class], [CDTSessionCookieInterceptor class]);
}

- (void)testURLCredsReplacedWithCookieInterceptorPush
{
    NSError *error;
    //Doesn't need to be real, we aren't going to actually make a replication.
    NSURL * remoteUrl = [[NSURL alloc] initWithString:@"http://user:pass@example.com"];
    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:&error];
    CDTPushReplication *push = [CDTPushReplication replicationWithSource:tmp target:remoteUrl];

    // check the underlying source to make sure it doesn't contain the userinfo
    // and check that the interceptors list contains the cookie interceptor.
    XCTAssertEqualObjects(@"http://example.com", push.target.absoluteString);
    XCTAssertEqual(push.httpInterceptors.count, 1);
    XCTAssertEqualObjects([push.httpInterceptors[0] class], [CDTSessionCookieInterceptor class]);
}

- (void)testCredentialsAddedViaPushInit
{
    NSError *error;
    // Doesn't need to be real, we aren't going to actually make a replication.
    NSURL *remoteUrl = [[NSURL alloc] initWithString:@"http://example.com"];
    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:&error];
    CDTPushReplication *push = [CDTPushReplication replicationWithSource:tmp
                                                                  target:remoteUrl
                                                                username:@"user"
                                                                password:@"password"];

    // check the underlying source to make sure it doesn't contain the userinfo
    // and check that the interceptors list contains the cookie interceptor.
    XCTAssertEqualObjects(@"http://example.com", push.target.absoluteString);
    XCTAssertEqual(push.httpInterceptors.count, 0);

    // The interceptor will be added when creating the TDReplicator
    error = nil;

    CDTReplicatorFactory *factory = [[CDTReplicatorFactory alloc] initWithDatastoreManager:self.factory];
    CDTReplicator *replicator = [factory oneWay:push error:&error];
    XCTAssertNil(error);
    error = nil;
    TDReplicator *tdReplicator = [replicator buildTDReplicatorFromConfiguration:&error];
    XCTAssertNil(error);
    NSArray<id<CDTHTTPInterceptor>> *interceptors = tdReplicator.interceptors;

    XCTAssertNotNil(interceptors);
    XCTAssertEqual(1, interceptors.count);
    XCTAssertEqual([interceptors[0] class], [CDTSessionCookieInterceptor class]);
}

- (void)testCredentialsAddedViaPullInit
{
    NSError *error;
    // Doesn't need to be real, we aren't going to actually make a replication.
    NSURL *remoteUrl = [[NSURL alloc] initWithString:@"http://example.com"];
    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:&error];
    CDTPullReplication *pull = [CDTPullReplication replicationWithSource:remoteUrl
                                                                  target:tmp
                                                                username:@"user"
                                                                password:@"password"];

    // check the underlying source to make sure it doesn't contain the userinfo
    // and check that the interceptors list contains the cookie interceptor.
    XCTAssertEqualObjects(@"http://example.com", pull.source.absoluteString);
    XCTAssertEqual(pull.httpInterceptors.count, 0);

    // The interceptor will be added when creating the TDReplicator
    error = nil;

    CDTReplicatorFactory *factory = [[CDTReplicatorFactory alloc] initWithDatastoreManager:self.factory];
    CDTReplicator *replicator = [factory oneWay:pull error:&error];
    XCTAssertNil(error);
    error = nil;
    TDReplicator *tdReplicator = [replicator buildTDReplicatorFromConfiguration:&error];
    XCTAssertNil(error);
    NSArray<id<CDTHTTPInterceptor>> *interceptors = tdReplicator.interceptors;

    XCTAssertNotNil(interceptors);
    XCTAssertEqual(1, interceptors.count);
    XCTAssertEqual([interceptors[0] class], [CDTSessionCookieInterceptor class]);
}

// this test can only run on macOS and not iOS because it needs to start a server
#if TARGET_OS_MAC && !TARGET_OS_IPHONE
- (void)test429Retry
{
    NSError *error = nil;
    SimpleHttpServer *server;
    // simple remote to send 429
    int port = 9999 + (arc4random() & 0x3FF); // add 10 bits of randomness
    // find a free port
    for (int i=0; i<100; i++, port++) {
        server = [[SimpleHttpServer alloc] initWithHeader:@"HTTP/1.0 429 Too Many Requests\r\n\r\n"
                                                                       port:port];
        [server startWithError:&error];
        if (error == nil) {
            break;
        }
    }
    XCTAssertNil(error, @"Start errored with %@", error);
        
    if (error) {
        // early exit
        return;
    }
    NSString *remoteUrl = [NSString stringWithFormat:@"http://127.0.0.1:%d", port];
    
    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:&error];
    CDTPullReplication *pull =
    [CDTPullReplication replicationWithSource:[NSURL URLWithString:remoteUrl] target:tmp];
    // add 429 backoff interceptor
    [pull addInterceptor:[CDTReplay429Interceptor interceptor]];
    // add utility interceptor to capture final sleep valuew
    ContextCaptureInterceptor *cci = [[ContextCaptureInterceptor alloc] init];
    [pull addInterceptor:cci];
    CDTReplicatorFactory *replicatorFactory =
    [[CDTReplicatorFactory alloc] initWithDatastoreManager:self.factory];
    
    CDTReplicator *replicator = [replicatorFactory oneWay:pull error:&error];
    
    dispatch_group_t taskGroup = dispatch_group_create();
    [replicator startWithTaskGroup:taskGroup error:&error];
    
    dispatch_group_wait(taskGroup, DISPATCH_TIME_FOREVER);

    // after 3 retries the sleep time should equal 2s:
    // 250ms * (2^3)
    double lastSleepValue = [(NSNumber*)[cci.lastContext stateForKey:@"com.cloudant.CDTRequestLimitInterceptor.sleep"] doubleValue];
    XCTAssertEqual(2.0, lastSleepValue);
    
    [server stop];
}
#endif

// this test can only run on macOS and not iOS because it needs to start a server
#if TARGET_OS_MAC && !TARGET_OS_IPHONE
- (void)testFiltersWithChangesFeed
{
    NSError *error = nil;
    SimpleHttpServer *server;
    // We need a real remote here, so the reachability test before the replication starts
    // passes, it doesn't need a couch server, since the NSURLProtocol will 404 any request.
    // We can't use OHHTTPStubs to stub the server as that doesn't work with background
    // requests, so we just start a simple local server that returns 404 to anything it receives
    // and use that for our remote.
    int port = 9999 + (arc4random() & 0x3FF); // add 10 bits of randomness
    // find a free port
    for (int i=0; i<100; i++, port++) {
        server = [[SimpleHttpServer alloc] initWithHeader:@"HTTP/1.0 404 Not Found\r\n\r\n"
                                                                   port:port];
        [server startWithError:&error];
        if (error == nil) {
            break;
        }
    }
    XCTAssertNil(error, @"Start errored with %@", error);

    if (error) {
        // early exit
        return;
    }
    NSString *remoteUrl = [NSString stringWithFormat:@"http://127.0.0.1:%d", port];

    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:&error];
    CDTPullReplication *pull =
        [CDTPullReplication replicationWithSource:[NSURL URLWithString:remoteUrl] target:tmp];
    ChangesFeedRequestCheckInterceptor *interceptor =
        [[ChangesFeedRequestCheckInterceptor alloc] init];
    [pull addInterceptor:interceptor];
    CDTReplicatorFactory *replicatorFactory =
        [[CDTReplicatorFactory alloc] initWithDatastoreManager:self.factory];

    CDTReplicator *replicator = [replicatorFactory oneWay:pull error:&error];

    dispatch_group_t taskGroup = dispatch_group_create();
    [replicator startWithTaskGroup:taskGroup error:&error];

    dispatch_group_wait(taskGroup, DISPATCH_TIME_FOREVER);

    XCTAssertTrue(interceptor.changesFeedRequestMade);

    [server stop];
}
#endif

-(void)testReplicatorIsNilForNilDatastoreManager {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    XCTAssertNil([[CDTReplicatorFactory alloc] initWithDatastoreManager:nil], @"Replication factory should be nil");
#pragma clang diagnostic pop
}

-(CDTAbstractReplication *)buildReplicationObject:(Class)aClass remoteUrl:(NSURL *)url
{
    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:nil];
    
    //this feels wrong...
    if (aClass == [CDTPushReplication class]) {
        
        return [CDTPushReplication replicationWithSource:tmp target:url];
    
    } else if (aClass == [CDTPullReplication class]) {
    
        return [CDTPullReplication replicationWithSource:url target:tmp];
    
    } else {
        
        return nil;
    }
}

-(void)urlTestExpectTrue:(Class)prClass
                     url:(NSURL*)url
{
    CDTAbstractReplication *pr = [self buildReplicationObject:prClass remoteUrl:url];
    NSError *error = nil;
    XCTAssertTrue([pr validateRemoteDatastoreURL:url error:&error], @"\nerror: %@ \nurl: %@", error, url);
}

-(void)urlTestExpectFalse:(Class)prClass
                      url:(NSURL*)url
            withErrorCode:(NSInteger)code
{
    NSError *error = nil;
    CDTAbstractReplication *pr = [self buildReplicationObject:prClass remoteUrl:url];
    
    XCTAssertFalse([pr validateRemoteDatastoreURL:url error:&error], @"\nerror: %@ \nurl: %@", error, url);
    XCTAssertTrue(error.code == code, @"\nerror: %@  \nurl: %@", error, url);
}

-(void)runUrlTestFor:(Class)prClass
{

    //expect to pass
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"https://myaccount.cloudant.com/foo"]];
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"https://adam:pass@myaccount.cloudant.com/foo"]];
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"http://adam:pass@myaccount.cloudant.com/foo"]];
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"http://adam:pass@myaccount.cloudant.com:5000/foo"]];
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"http://myaccount.cloudant.com:5000/foo"]];
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"https://myaccount.cloudant.com:5000/foo"]];
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"https://myaccount.cloudant.com/foo%2Fbar%2Fbam"]];
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"https://myaccount.cloudant.com:5000/foo%2Fbar%2Fbam"]];
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"https://adam:pass@myaccount.cloudant.com:5000/foo%2Fbar%2Fbam"]];
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"http://adam:pass@myaccount.cloudant.com:5000/foo%2Fbar%2Fbam"]];
    
    //even though this path shouldn't exist in normal situations, we can't restrict the URL because
    //it could be a CNAME record or other type of redirect.
    [self urlTestExpectTrue:prClass
                        url:[NSURL URLWithString:@"https://someurl.com/foo/bar/bam"]];
    
    //build a URL with NSURLComponents
    NSURLComponents *urlc = [[NSURLComponents alloc] init];
    urlc.scheme = @"https";
    urlc.host = @"myaccount.cloudant.com";
    urlc.percentEncodedPath = @"/foo%2Fbar%2Fbam";
    [self urlTestExpectTrue:prClass  url:[urlc URL]];
    
    urlc.user = @"adam";
    [self urlTestExpectFalse:prClass
                         url:[urlc URL]
               withErrorCode:CDTReplicationErrorIncompleteCredentials];
    
    urlc.user = nil;
    urlc.password = @"password";
    [self urlTestExpectFalse:prClass
                         url:[urlc URL]
               withErrorCode:CDTReplicationErrorIncompleteCredentials];
    
    urlc.user = @"adam";
    [self urlTestExpectTrue:prClass url:[urlc URL]];
    
    //expect to fail
    [self urlTestExpectFalse:prClass
                         url:[NSURL URLWithString:@"ftp://myaccount.cloudant.com/foo"]
               withErrorCode:CDTReplicationErrorInvalidScheme];
    
    [self urlTestExpectFalse:prClass
                         url:[NSURL URLWithString:@"ftp://myaccount.cloudant.com/foo/bar"]
               withErrorCode:CDTReplicationErrorInvalidScheme];
    
    [self urlTestExpectFalse:prClass
                         url:[NSURL URLWithString:@"https://adam@myaccount.cloudant.com/foo"]
               withErrorCode:CDTReplicationErrorIncompleteCredentials];
    
    [self urlTestExpectFalse:prClass
                         url:[NSURL URLWithString:@"https://:password@myaccount.cloudant.com/foo"]
               withErrorCode:CDTReplicationErrorIncompleteCredentials];
    
}

-(void) testStateAfterStoppingBeforeStarting
{
    NSString *remoteUrl = @"https://adam:cox@myaccount.cloudant.com/mydb";
    NSError *error;
    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:&error];
    CDTPushReplication *push = [CDTPushReplication replicationWithSource:tmp
                                                                  target:[NSURL URLWithString:remoteUrl]];
 
    
    CDTReplicatorFactory *replicatorFactory = [[CDTReplicatorFactory alloc]
                                               initWithDatastoreManager:self.factory];
    
    error = nil;
    CDTReplicator *replicator =  [replicatorFactory oneWay:push error:&error];
    XCTAssertNotNil(replicator, @"%@", push);
    XCTAssertNil(error, @"%@", error);
    
    XCTAssertEqual(replicator.state, CDTReplicatorStatePending, @"Unexpected state: %@",
                   [CDTReplicator stringForReplicatorState:replicator.state ]);
    
    [replicator stop];
    
    XCTAssertEqual(replicator.state, CDTReplicatorStateStopped, @"Unexpected state: %@",
                   [CDTReplicator stringForReplicatorState:replicator.state ]);
    
}

-(CDTPullReplication*)createPullReplicationWithHeaders:(NSDictionary *)optionalHeaders
{
    NSString *remoteUrl = @"https://adam:cox@myaccount.cloudant.com/mydb";
    
    CDTDatastore *tmp = [self.factory datastoreNamed:@"test_database" error:nil];
    CDTPullReplication *pull = [CDTPullReplication replicationWithSource:[NSURL URLWithString:remoteUrl]
                                                                  target:tmp];
    
    pull.optionalHeaders = optionalHeaders;

    return pull;
}

-(void)testForProhibitedOptionalReplicationHeaders
{
    CDTPullReplication *pull;
    NSError *error;
    NSDictionary *optionalHeaders;
    
    optionalHeaders = @{@"User-Agent": @"My Agent"};
    pull = [self createPullReplicationWithHeaders:optionalHeaders];
    error = nil;
    
    NSArray *prohibitedUpperArray = @[@"Authorization", @"WWW-Authenticate", @"Host",
                                  @"Connection", @"Content-Type", @"Accept",
                                  @"Content-Length"];
    
    NSMutableArray *prohibitedLowerArray = [[NSMutableArray alloc] init];
    
    for (NSString *header in prohibitedUpperArray) {
        [prohibitedLowerArray addObject:[header lowercaseString]];
    }
    
    for (NSString* prohibitedHeader in prohibitedUpperArray) {
        optionalHeaders = @{prohibitedHeader: @"some value"};
        pull = [self createPullReplicationWithHeaders:optionalHeaders];
        CDTReplicatorFactory *replicatorFactory =
        [[CDTReplicatorFactory alloc] initWithDatastoreManager:self.factory];
        CDTReplicator *rep = [replicatorFactory oneWay:pull error:&error];
        
        XCTAssertNil(rep, @"Error was not set");
        XCTAssertNotNil(error, @"Error was not set");
        XCTAssertEqual(error.code, CDTReplicationErrorProhibitedOptionalHttpHeader,
                       @"Wrote error code: %ld", (long)error.code);
    }
    //make sure the lower case versions fail too
    for (NSString* prohibitedHeader in prohibitedLowerArray) {
        optionalHeaders = @{prohibitedHeader: @"some value"};
        pull = [self createPullReplicationWithHeaders:optionalHeaders];
        CDTReplicatorFactory *replicatorFactory =
        [[CDTReplicatorFactory alloc] initWithDatastoreManager:self.factory];
        CDTReplicator *rep = [replicatorFactory oneWay:pull error:&error];
        
        XCTAssertNil(rep, @"Error was not set");
        XCTAssertNotNil(error, @"Error was not set");
        XCTAssertEqual(error.code, CDTReplicationErrorProhibitedOptionalHttpHeader,
                       @"Wrote error code: %ld", (long)error.code);
    }
}

@end
