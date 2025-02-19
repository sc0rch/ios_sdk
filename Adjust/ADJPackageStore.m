#import "ADJPackageStore.h"
#import <sqlite3.h>
#import "ADJLogger.h"
#import "ADJAdjustFactory.h"

@interface ADJPackageStore()

@property (nonatomic) sqlite3 *database;
@property (nonatomic, strong) NSString *databasePath;
@property (nonatomic, weak) id<ADJLogger> logger;
@property (nonatomic, strong) dispatch_queue_t dbQueue;

@end

@implementation ADJPackageStore

+ (instancetype)sharedInstance {
    static ADJPackageStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.dbQueue = dispatch_queue_create("com.adjust.packagestore", DISPATCH_QUEUE_SERIAL);
        self.databasePath = [self getFilePathInAppSupportDir:@"adjustPackages.db"];
        self.logger = ADJAdjustFactory.logger;

        dispatch_sync(self.dbQueue, ^{
            [self createDatabaseInternal];
            [self migrateFromPlistInternal];
        });
    }
    return self;
}

- (void)createDatabaseInternal {
    if (sqlite3_open([self.databasePath UTF8String], &_database) == SQLITE_OK) {
        const char *createTableSQL = "CREATE TABLE IF NOT EXISTS packages ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "package_data BLOB,"
        "created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP"
        ");";

        char *errMsg;
        if (sqlite3_exec(_database, createTableSQL, NULL, NULL, &errMsg) != SQLITE_OK) {
            [self.logger error:@"Failed to create table: %s", errMsg];
            sqlite3_free(errMsg);
        }
    } else {
        [self.logger error:@"Failed to open database at path: %@", self.databasePath];
    }
}

- (void)migrateFromPlistInternal {
    NSString *plistPath = [self getFilePathInAppSupportDir:@"AdjustIoPackageQueue"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        return;
    }

    NSData *plistData = [NSData dataWithContentsOfFile:plistPath];
    NSArray *oldPackages = [NSKeyedUnarchiver unarchiveObjectWithData:plistData];
    if (![oldPackages isKindOfClass:[NSArray class]]) {
        return;
    }

    if (sqlite3_exec(self->_database, "BEGIN TRANSACTION;", NULL, NULL, NULL) != SQLITE_OK) {
        [self.logger error:@"Failed to begin transaction for migration"];
        return;
    }

    BOOL migrationSuccessful = YES;
    @try {
        for (ADJActivityPackage *pkg in oldPackages) {
            if (![self insertPackageInternal:pkg]) {
                migrationSuccessful = NO;
                break;
            }
        }
        if (migrationSuccessful) {
            if (sqlite3_exec(self->_database, "COMMIT;", NULL, NULL, NULL) == SQLITE_OK) {
                [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
            } else {
                sqlite3_exec(self->_database, "ROLLBACK;", NULL, NULL, NULL);
            }
        } else {
            sqlite3_exec(self->_database, "ROLLBACK;", NULL, NULL, NULL);
        }
    } @catch (NSException *ex) {
        sqlite3_exec(self->_database, "ROLLBACK;", NULL, NULL, NULL);
    }
}

- (BOOL)insertPackageInternal:(ADJActivityPackage *)package {
    if (!package) {
        [self.logger error:@"insertPackageInternal called with nil package"];
        return NO;
    }

    NSData *packageData = nil;

    if (@available(iOS 11.0, tvOS 11.0, *)) {
        NSError *error = nil;
        packageData = [NSKeyedArchiver archivedDataWithRootObject:package
                                            requiringSecureCoding:NO
                                                            error:&error];
        if (error) {
            [self.logger error:@"Failed to archive package: %@", error];
            return NO;
        }
    } else {
        @try {
            packageData = [NSKeyedArchiver archivedDataWithRootObject:package];
        } @catch (NSException *exception) {
            [self.logger error:@"Failed to archive package: %@", exception];
            return NO;
        }
    }

    if (!packageData) {
        [self.logger error:@"Failed to create package data"];
        return NO;
    }

    const char *sql = "INSERT INTO packages (package_data) VALUES (?);";
    sqlite3_stmt *statement = NULL;

    if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {

        sqlite3_bind_blob(statement, 1, [packageData bytes], (int)[packageData length], SQLITE_TRANSIENT);

        if (sqlite3_step(statement) != SQLITE_DONE) {
            [self.logger error:@"Failed to insert package: %s", sqlite3_errmsg(self->_database)];
            sqlite3_finalize(statement);
            return NO;
        }

        sqlite3_finalize(statement);
        return YES;
    } else {
        [self.logger error:@"Failed to prepare statement: %s", sqlite3_errmsg(self->_database)];
        if (statement) {
            sqlite3_finalize(statement);
        }
        return NO;
    }
}

// Helper method to get file path in Application Support directory
- (NSString *)getFilePathInAppSupportDir:(NSString *)fileName {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *appSupportDir = [paths objectAtIndex:0];

    NSString *adjustDir = [appSupportDir stringByAppendingPathComponent:@"Adjust"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:adjustDir]) {
        return nil;
    }

    return [adjustDir stringByAppendingPathComponent:fileName];
}

- (NSUInteger)count {
    __block NSUInteger count = 0;
    dispatch_sync(self.dbQueue, ^{
        const char *sql = "SELECT COUNT(*) FROM packages;";
        sqlite3_stmt *statement;

        if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {
            if (sqlite3_step(statement) == SQLITE_ROW) {
                count = sqlite3_column_int(statement, 0);
            }
        }
        sqlite3_finalize(statement);
    });
    return count;
}

- (ADJActivityPackage *)packageAtIndex:(NSUInteger)index {
    __block ADJActivityPackage *package = nil;
    dispatch_sync(self.dbQueue, ^{
        const char *sql = "SELECT package_data FROM packages ORDER BY created_at ASC LIMIT 1 OFFSET ?;";
        sqlite3_stmt *statement;

        if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {
            sqlite3_bind_int(statement, 1, (int)index);

            if (sqlite3_step(statement) == SQLITE_ROW) {
                const void *data = sqlite3_column_blob(statement, 0);
                int dataSize = sqlite3_column_bytes(statement, 0);

                if (data && dataSize > 0) {
                    NSData *packageData = [NSData dataWithBytes:data length:dataSize];

                    @try {
                        package = [NSKeyedUnarchiver unarchiveObjectWithData:packageData];
                        if (![package isKindOfClass:[ADJActivityPackage class]]) {
                            package = nil;
                            [self.logger error:@"Unarchived object is not ADJActivityPackage"];
                        }
                    } @catch (NSException *exception) {
                        [self.logger error:@"Failed to unarchive package: %@", exception];
                    }
                }
            }
        }
        sqlite3_finalize(statement);
    });
    return package;
}

- (BOOL)updatePackageInternal:(ADJActivityPackage *)package atIndex:(NSUInteger)index {
    if (!package) {
        [self.logger error:@"Cannot update nil package"];
        return NO;
    }

    NSData *packageData = nil;

    if (@available(iOS 11.0, tvOS 11.0, *)) {
        NSError *error = nil;
        packageData = [NSKeyedArchiver archivedDataWithRootObject:package
                                            requiringSecureCoding:NO
                                                            error:&error];
        if (error) {
            [self.logger error:@"Failed to archive package: %@", error];
            return NO;
        }
    } else {
        @try {
            packageData = [NSKeyedArchiver archivedDataWithRootObject:package];
        } @catch (NSException *exception) {
            [self.logger error:@"Failed to archive package: %@", exception];
            return NO;
        }
    }

    if (!packageData) {
        [self.logger error:@"Failed to create package data"];
        return NO;
    }

    const char *sql = "UPDATE packages SET package_data = ? WHERE id IN "
    "(SELECT id FROM packages ORDER BY created_at ASC LIMIT 1 OFFSET ?);";
    sqlite3_stmt *statement;

    if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_blob(statement, 1, [packageData bytes], (int)[packageData length], SQLITE_TRANSIENT);
        sqlite3_bind_int(statement, 2, (int)index);

        BOOL success = (sqlite3_step(statement) == SQLITE_DONE);
        if (!success) {
            [self.logger error:@"Failed to update package: %s", sqlite3_errmsg(self->_database)];
        }
        sqlite3_finalize(statement);
        return success;
    }

    if (statement) {
        sqlite3_finalize(statement);
    }
    return NO;
}

- (BOOL)updatePackage:(ADJActivityPackage *)package atIndex:(NSUInteger)index {
    __block BOOL success = NO;
    dispatch_sync(self.dbQueue, ^{
        success = [self updatePackageInternal:package atIndex:index];
    });
    return success;
}

- (void)updatePackages:(void (^)(ADJActivityPackage *package))updateBlock {
    if (!updateBlock) return;

    dispatch_sync(self.dbQueue, ^{
        if (sqlite3_exec(self->_database, "BEGIN TRANSACTION", NULL, NULL, NULL) != SQLITE_OK) {
            [self.logger error:@"Failed to begin transaction"];
            return;
        }

        BOOL success = YES;
        NSArray *packages = [self loadPackagesInternal];

        for (NSUInteger i = 0; i < packages.count; i++) {
            ADJActivityPackage *package = packages[i];
            updateBlock(package);
            if (![self updatePackageInternal:package atIndex:i]) {
                success = NO;
                break;
            }
        }

        if (success) {
            if (sqlite3_exec(self->_database, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
                [self.logger error:@"Failed to commit transaction"];
                sqlite3_exec(self->_database, "ROLLBACK", NULL, NULL, NULL);
            }
        } else {
            sqlite3_exec(self->_database, "ROLLBACK", NULL, NULL, NULL);
        }
    });
}

- (void)addPackage:(ADJActivityPackage *)package {
    if (!package) {
        [self.logger error:@"Cannot add nil package"];
        return;
    }

    dispatch_sync(self.dbQueue, ^{
        NSData *packageData = nil;

        if (@available(iOS 11.0, tvOS 11.0, *)) {
            NSError *error = nil;
            packageData = [NSKeyedArchiver archivedDataWithRootObject:package
                                                requiringSecureCoding:NO
                                                                error:&error];
            if (error) {
                [self.logger error:@"Failed to archive package: %@", error];
                return;
            }
        } else {
            @try {
                packageData = [NSKeyedArchiver archivedDataWithRootObject:package];
            } @catch (NSException *exception) {
                [self.logger error:@"Failed to archive package: %@", exception];
                return;
            }
        }

        if (!packageData) {
            [self.logger error:@"Failed to create package data"];
            return;
        }

        const char *sql = "INSERT INTO packages (package_data) VALUES (?);";
        sqlite3_stmt *statement;

        if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {
            sqlite3_bind_blob(statement, 1, [packageData bytes], (int)[packageData length], SQLITE_TRANSIENT);

            if (sqlite3_step(statement) != SQLITE_DONE) {
                [self.logger error:@"Failed to insert package: %s", sqlite3_errmsg(self->_database)];
            }
        }
        sqlite3_finalize(statement);
    });
}

- (void)removePackageAtIndex:(NSUInteger)index {
    dispatch_sync(self.dbQueue, ^{
        const char *sql = "DELETE FROM packages WHERE id IN "
        "(SELECT id FROM packages ORDER BY created_at ASC LIMIT 1 OFFSET ?);";
        sqlite3_stmt *statement;

        if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {
            sqlite3_bind_int(statement, 1, (int)index);

            if (sqlite3_step(statement) != SQLITE_DONE) {
                [self.logger error:@"Failed to remove package: %s", sqlite3_errmsg(self->_database)];
            }
        }
        sqlite3_finalize(statement);
    });
}

- (NSArray<ADJActivityPackage *> *)loadPackages {
    __block NSArray *packages = nil;
    dispatch_sync(self.dbQueue, ^{
        packages = [self loadPackagesInternal];
    });
    return packages;
}

- (NSArray<ADJActivityPackage *> *)loadPackagesInternal {
    NSMutableArray<ADJActivityPackage *> *packages = [NSMutableArray array];

    const char *sql = "SELECT package_data FROM packages ORDER BY created_at ASC;";
    sqlite3_stmt *statement;

    if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {
        while (sqlite3_step(statement) == SQLITE_ROW) {
            @autoreleasepool {
                const void *data = sqlite3_column_blob(statement, 0);
                int dataSize = sqlite3_column_bytes(statement, 0);

                if (data && dataSize > 0) {
                    NSData *packageData = [NSData dataWithBytes:data length:dataSize];

                    @try {
                        ADJActivityPackage *package = [NSKeyedUnarchiver unarchiveObjectWithData:packageData];
                        if (package && [package isKindOfClass:[ADJActivityPackage class]]) {
                            [packages addObject:package];
                        }
                    } @catch (NSException *exception) {
                        [self.logger error:@"Failed to unarchive package: %@", exception];
                    }
                }
            }
        }
    }
    sqlite3_finalize(statement);

    return packages;
}

- (void)clearAllPackages {
    dispatch_sync(self.dbQueue, ^{
        const char *sql = "DELETE FROM packages;";
        char *errMsg;

        if (sqlite3_exec(self->_database, sql, NULL, NULL, &errMsg) != SQLITE_OK) {
            [self.logger error:@"Failed to clear packages: %s", errMsg];
            sqlite3_free(errMsg);
        }
    });
}

- (void)closeDatabase {
    dispatch_sync(self.dbQueue, ^{
        if (self->_database) {
            sqlite3_close(self->_database);
            self->_database = NULL;
        }
    });
}

- (void)dealloc {
    [self closeDatabase];
}

@end
