//
//  TD_DatabaseLocalDocsTests.m
//  Tests
//

#import <XCTest/XCTest.h>

#import "CDTEncryptionKeyNilProvider.h"
#import "TD_Database+LocalDocs.h"
#import "TD_Revision.h"

@interface TD_DatabaseLocalDocsTests : XCTestCase

@property (nonatomic, strong) TD_Database *database;
@property (nonatomic, copy) NSString *temporaryDirectory;

@end

@implementation TD_DatabaseLocalDocsTests

- (void)setUp
{
    [super setUp];

    NSString *templatePath =
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"td_local_docs_tests.XXXXXX"];
    const char *templateCString = [templatePath fileSystemRepresentation];
    char *directoryCString = (char *)malloc(strlen(templateCString) + 1);
    strcpy(directoryCString, templateCString);

    char *result = mkdtemp(directoryCString);
    XCTAssertNotEqual(result, NULL);

    self.temporaryDirectory = [[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:directoryCString
                                    length:strlen(directoryCString)];
    free(directoryCString);

    NSString *databasePath =
        [self.temporaryDirectory stringByAppendingPathComponent:@"localdocs.touchdb"];
    self.database = [[TD_Database alloc] initWithPath:databasePath];
    XCTAssertTrue([self.database
        openWithEncryptionKeyProvider:[CDTEncryptionKeyNilProvider provider]]);
}

- (void)tearDown
{
    [self.database close];
    self.database = nil;

    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:self.temporaryDirectory error:&error];
    XCTAssertNil(error);
    self.temporaryDirectory = nil;

    [super tearDown];
}

- (void)testCreateReadUpdateAndDeleteLocalDocument
{
    TDStatus status = 0;
    TD_Revision *created = [self.database
        putLocalRevision:[self localRevisionWithID:@"_local/checkpoint"
                                        properties:@{ @"lastSequence" : @1 }]
          prevRevisionID:nil
                  status:&status];

    XCTAssertEqual(status, kTDStatusCreated);
    XCTAssertEqualObjects(created.revID, @"1-local");

    TD_Revision *read =
        [self.database getLocalDocumentWithID:@"_local/checkpoint" revisionID:nil];
    XCTAssertEqualObjects(read.docID, @"_local/checkpoint");
    XCTAssertEqualObjects(read.revID, @"1-local");
    XCTAssertEqualObjects(read.properties[@"lastSequence"], @1);

    TD_Revision *updated = [self.database
        putLocalRevision:[self localRevisionWithID:@"_local/checkpoint"
                                        properties:@{ @"lastSequence" : @2 }]
          prevRevisionID:created.revID
                  status:&status];

    XCTAssertEqual(status, kTDStatusCreated);
    XCTAssertEqualObjects(updated.revID, @"2-local");
    XCTAssertEqualObjects(
        [self.database getLocalDocumentWithID:@"_local/checkpoint" revisionID:updated.revID]
            .properties[@"lastSequence"],
        @2);

    TDStatus deleteStatus =
        [self.database deleteLocalDocumentWithID:@"_local/checkpoint" revisionID:updated.revID];
    XCTAssertEqual(deleteStatus, kTDStatusOK);
    XCTAssertNil([self.database getLocalDocumentWithID:@"_local/checkpoint" revisionID:nil]);
}

- (void)testLocalDocumentWriteConflicts
{
    TDStatus status = 0;
    TD_Revision *created = [self.database
        putLocalRevision:[self localRevisionWithID:@"_local/conflict"
                                        properties:@{ @"value" : @"original" }]
          prevRevisionID:nil
                  status:&status];

    XCTAssertEqual(status, kTDStatusCreated);

    TD_Revision *duplicateCreate = [self.database
        putLocalRevision:[self localRevisionWithID:@"_local/conflict"
                                        properties:@{ @"value" : @"duplicate" }]
          prevRevisionID:nil
                  status:&status];

    XCTAssertNil(duplicateCreate);
    XCTAssertEqual(status, kTDStatusConflict);

    TD_Revision *badGeneration = [self.database
        putLocalRevision:[self localRevisionWithID:@"_local/conflict"
                                        properties:@{ @"value" : @"bad" }]
          prevRevisionID:@"not-a-local-rev"
                  status:&status];

    XCTAssertNil(badGeneration);
    XCTAssertEqual(status, kTDStatusBadID);

    TD_Revision *updated = [self.database
        putLocalRevision:[self localRevisionWithID:@"_local/conflict"
                                        properties:@{ @"value" : @"updated" }]
          prevRevisionID:created.revID
                  status:&status];

    XCTAssertNotNil(updated);

    TD_Revision *staleUpdate = [self.database
        putLocalRevision:[self localRevisionWithID:@"_local/conflict"
                                        properties:@{ @"value" : @"stale" }]
          prevRevisionID:created.revID
                  status:&status];

    XCTAssertNil(staleUpdate);
    XCTAssertEqual(status, kTDStatusConflict);
}

- (void)testLocalDocumentDeleteStatuses
{
    TDStatus status = 0;
    TD_Revision *created = [self.database
        putLocalRevision:[self localRevisionWithID:@"_local/delete"
                                        properties:@{ @"value" : @"saved" }]
          prevRevisionID:nil
                  status:&status];

    XCTAssertEqual(status, kTDStatusCreated);
    XCTAssertEqual([self.database deleteLocalDocumentWithID:@"_local/delete" revisionID:nil],
                   kTDStatusConflict);
    XCTAssertEqual(
        [self.database deleteLocalDocumentWithID:@"_local/missing" revisionID:@"1-local"],
        kTDStatusNotFound);
    XCTAssertEqual([self.database deleteLocalDocumentWithID:nil revisionID:@"1-local"],
                   kTDStatusBadID);
    XCTAssertEqual(
        [self.database deleteLocalDocumentWithID:@"_local/delete" revisionID:created.revID],
        kTDStatusOK);
    XCTAssertEqual(
        [self.database deleteLocalDocumentWithID:@"_local/delete" revisionID:created.revID],
        kTDStatusNotFound);
}

- (void)testRejectsNonLocalDocumentIDs
{
    TDStatus status = 0;
    TD_Revision *revision = [self.database
        putLocalRevision:[self localRevisionWithID:@"not-local"
                                        properties:@{ @"value" : @"ignored" }]
          prevRevisionID:nil
                  status:&status];

    XCTAssertNil(revision);
    XCTAssertEqual(status, kTDStatusBadID);
}

- (void)testReadRequiresMatchingRevisionID
{
    TDStatus status = 0;
    TD_Revision *created = [self.database
        putLocalRevision:[self localRevisionWithID:@"_local/read"
                                        properties:@{ @"value" : @"saved" }]
          prevRevisionID:nil
                  status:&status];

    XCTAssertEqual(status, kTDStatusCreated);
    XCTAssertNotNil([self.database getLocalDocumentWithID:@"_local/read"
                                               revisionID:created.revID]);
    XCTAssertNil([self.database getLocalDocumentWithID:@"_local/read" revisionID:@"2-local"]);
}

- (TD_Revision *)localRevisionWithID:(NSString *)docID properties:(NSDictionary *)properties
{
    NSMutableDictionary *revisionProperties = [properties mutableCopy];
    revisionProperties[@"_id"] = docID;
    return [[TD_Revision alloc] initWithProperties:revisionProperties];
}

@end
