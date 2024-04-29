//
//  MRDatabaseContentChecker.m
//
//  Created by Michael Rhodes on 11/05/2014.
//  Copyright (c) 2014 Mike Rhodes. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "MRDatabaseContentChecker.h"

NSString* const MRDatabaseContentCheckerErrorDomain =
@"MRDatabaseContentCheckerErrorDomain";
NSString* const MRDatabaseContentCheckerErrorsArray =
@"MRDatabaseContentCheckerErrorsArray";

/**
 A simple class to check the content of your database tables.
 */
@implementation MRDatabaseContentChecker

/**
 Format the error messages produced by other methods in this
 class.
 */
- (NSString*)formattedErrors:(NSError*)error
{
    NSArray *errors = error.userInfo[MRDatabaseContentCheckerErrorsArray];
    return [errors componentsJoinedByString:@"; "];
}

/**
 Check that the contents of `table` match the specification in
 `expectedRows`. The first array in `expectedRows` MUST be the
 column names you want to check.
 
 Rows are assumed to be in the order presented in the array, and the table
 is assumed to contain the same number of rows as in the array.
 
 Note this means you can check just a subset of the data in a
 given table by including a subset of the columns.
 
 For more information on what you can have as values to check, see
 the documentation for checkDatabase:query:hasRows:error:, as this
 method calls into that one after constructing a query to get all
 the rows on the table.
 */
- (BOOL)checkDatabase:(FMDatabase*)db
                table:(NSString*)table
              hasRows:(NSArray*)expectedRows
                error:(NSError* __autoreleasing *)error
{
    NSArray *columns = expectedRows[0];
    
    NSString *sql = [NSString stringWithFormat:@"select %@ from %@",
               [columns componentsJoinedByString:@", "],
               table];
    
    return [self checkDatabase:db
                         query:sql
                       hasRows:expectedRows
                         error:error];
}

/**
 Check that the contents of `table` match the specification in
 `expectedRows`. The first array in `expectedRows` MUST be the
 column names you want to check.

 Rows from the database are ordered using the coloumn 
 `orderBy` with the rows given to be in the order presented
 by the database after ordering.

 Note this means you can check just a subset of the data in a
 given table by including a subset of the columns.

 For more information on what you can have as values to check, see
 the documentation for checkDatabase:query:hasRows:error:, as this
 method calls into that one after constructing a query to get all
 the rows on the table.
 */
- (BOOL)checkDatabase:(FMDatabase*)db
                table:(NSString*)table
              hasRows:(NSArray*)expectedRows
              orderBy:(NSArray*) orderby
                error:(NSError* __autoreleasing *)error
{
    NSArray *columns = expectedRows[0];
    NSString *sql = [NSString stringWithFormat:@"select %@ from %@ order by %@",
               [columns componentsJoinedByString:@", "],
               table,
               [orderby componentsJoinedByString:@", "]];

    return [self checkDatabase:db
                         query:sql
                       hasRows:expectedRows
                         error:error];
}

/**
 Check that the result of `query` matches the specification in
 `expectedRows`. The first array in `expectedRows` MUST be the
 column names you want to check from the result set. For example:

 ```
 NSArray *expectedRows = @[
 @[@"docId",      @"revId",  @"sequenceNumber"],  // columns
 @[@"document-1", @"1-rev",  @(1)],               // expected values
 @[@"document-2", @"34-rev", @(2)]
 ];
 ```

 Expected values can be: NSString, NSNumber, NSData or NSRegularExpression.

 In the case of regular expressions, checking is based on the existence
 of one or more matches using numberOfMatchesInString:options:error:.

 Rows are assumed to be present in the result set in the order presented
 in the array, and the result set is assumed to have the same number of
 results as the array. This means that you may want to use order by or
 limit clauses in your query.

 Note this means you can check just a subset of the data in a
 given query by including a subset of the columns.
 */
- (BOOL)checkDatabase:(FMDatabase*)db
                query:(NSString*)sql
              hasRows:(NSArray*)expectedRows
                error:(NSError* __autoreleasing *)error
{
    NSArray *columns = expectedRows[0];
    NSRange range = NSMakeRange(1, [expectedRows count] - 1);
    NSArray *values = [expectedRows subarrayWithRange:range];

    FMResultSet *result = [db executeQuery:sql];

    BOOL success = YES;
    NSMutableArray *errors = [[NSMutableArray alloc] init];

    for (int i = 0; i < values.count; i++) {
        NSArray *expectedRow = values[i];

        if (![result next]) {
            success = NO;
            NSString *msg = @"Reached end of result set before array";
            [errors addObject:msg];
            break;
        }
        
        for (int col = 0; col < columns.count; col++) {
            NSString *columnName = columns[col];
            NSObject *expectedValue = expectedRow[col];

            BOOL correct;
            Class expectedClass = [expectedValue class];
            NSObject *actualValue;

            if ([expectedClass isSubclassOfClass:[NSString class]]) {
                actualValue = [result stringForColumn:columnName];
                correct = [expectedValue isEqual:actualValue];

            } else if ([expectedClass isSubclassOfClass:[NSNumber class]]) {
                long long v = [result longLongIntForColumn:columnName];
                actualValue = [NSNumber numberWithLongLong:v];
                correct = [expectedValue isEqual:actualValue];

            } else if ([expectedClass isSubclassOfClass:[NSData class]]) {
                actualValue = [result dataForColumn:columnName];
                correct = [expectedValue isEqual:actualValue];

            } else if ([expectedClass isSubclassOfClass:[NSRegularExpression class]]) {
                actualValue = [result stringForColumn:columnName];
                NSString *actualString = (NSString*)actualValue;
                NSRange range = NSMakeRange(0, actualString.length);
                NSRegularExpression *expectedRegex = (NSRegularExpression*)expectedValue;
                NSUInteger found = [expectedRegex numberOfMatchesInString:actualString
                                                                  options:0
                                                                    range:range];
                correct = (found > 0);

            } else if (expectedValue == [NSNull null]) {
                actualValue = [result objectForColumnName:columnName];
                correct = actualValue == [NSNull null];

            } else {
                // Unknown class type!
                correct = NO;
            }

            if (!correct) {
                success = NO;

                NSString *msg = [NSString stringWithFormat:
                                 @"Row %i, field %@, expected %@, actual %@",
                                 i,
                                 columnName,
                                 expectedValue,
                                 actualValue];
                [errors addObject:msg];
            }
        }
    }

    if ([result next]) {  // we should be at the end of the results
        success = NO;

        NSString *msg = @"End of array not end of result set";
        [errors addObject:msg];
    }

    [result close];

    if (errors.count > 0 && error) {
        NSString *description = NSLocalizedString(
                                                  @"Problem updating attachments table.",
                                                  nil);
        NSDictionary *userInfo = @{
                                   NSLocalizedDescriptionKey: description,
                                   MRDatabaseContentCheckerErrorsArray: [errors copy]
                                   };
        *error = [NSError errorWithDomain:MRDatabaseContentCheckerErrorDomain
                                     code:MRDatabaseContentCheckerErrorValidation
                                 userInfo:userInfo];
    }

    return success;
}

@end
