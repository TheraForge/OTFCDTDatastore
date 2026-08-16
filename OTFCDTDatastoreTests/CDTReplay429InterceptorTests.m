//
//  CDTReplay429InterceptorTests.m
//  Tests
//

#import <XCTest/XCTest.h>

#import "CDTHTTPInterceptorContext.h"
#import "CDTReplay429Interceptor.h"

@interface CDTReplay429InterceptorTests : XCTestCase
@end

@implementation CDTReplay429InterceptorTests

- (void)testFactoryCreatesInterceptor
{
    XCTAssertNotNil([CDTReplay429Interceptor interceptor]);
}

- (void)testNon429ResponseDoesNotRetry
{
    CDTReplay429Interceptor *interceptor =
        [[CDTReplay429Interceptor alloc] initWithSleep:0 maxRetries:1];
    CDTHTTPInterceptorContext *context = [self contextWithStatusCode:200];

    CDTHTTPInterceptorContext *result = [interceptor interceptResponseInContext:context];

    XCTAssertEqual(result, context);
    XCTAssertFalse(result.shouldRetry);
    XCTAssertEqual(result.state.count, (NSUInteger)0);
}

- (void)test429ResponseRetriesUntilMaximumRetryCount
{
    CDTReplay429Interceptor *interceptor =
        [[CDTReplay429Interceptor alloc] initWithSleep:0 maxRetries:1];
    CDTHTTPInterceptorContext *context = [self contextWithStatusCode:429];

    CDTHTTPInterceptorContext *firstResult = [interceptor interceptResponseInContext:context];
    XCTAssertTrue(firstResult.shouldRetry);
    XCTAssertEqual(firstResult.state.count, (NSUInteger)2);

    firstResult.shouldRetry = NO;
    CDTHTTPInterceptorContext *secondResult = [interceptor interceptResponseInContext:firstResult];
    XCTAssertFalse(secondResult.shouldRetry);
    XCTAssertEqual(secondResult.state.count, (NSUInteger)2);
}

- (CDTHTTPInterceptorContext *)contextWithStatusCode:(NSInteger)statusCode
{
    NSURL *url = [NSURL URLWithString:@"https://example.com/db"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    CDTHTTPInterceptorContext *context =
        [[CDTHTTPInterceptorContext alloc] initWithRequest:request];
    context.response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                   statusCode:statusCode
                                                  HTTPVersion:@"HTTP/1.1"
                                                 headerFields:nil];
    return context;
}

@end
