#import "ADJPackageStore.h"
#import <sqlite3.h>
#import "ADJLogger.h"
#import "ADJAdjustFactory.h"
#import <UIKit/UIKit.h>

@interface ADJPackageStore()

@property (nonatomic) sqlite3 *database;
@property (nonatomic, strong) NSString *databasePath;
@property (nonatomic, weak) id<ADJLogger> logger;
@property (nonatomic, strong) dispatch_queue_t dbQueue;
@property (nonatomic, strong) NSMutableArray<ADJActivityPackage *> *packageCache;
@property (nonatomic) NSUInteger cacheLimit;
@property (nonatomic) BOOL isDirty;

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
        self.packageCache = [NSMutableArray array];
        self.cacheLimit = 100; // Cache up to 100 packages before writing to disk
        self.isDirty = NO;

        dispatch_sync(self.dbQueue, ^{
            [self createDatabaseInternal];
            [self migrateFromPlistInternal];
        });
        
        // Schedule periodic cache flushing
        [self schedulePeriodicCacheFlush];
    }
    return self;
}

- (void)createDatabaseInternal {
    if (sqlite3_open([self.databasePath UTF8String], &_database) == SQLITE_OK) {
        // Set SQLite optimizations to reduce disk writes
        const char *pragmas[] = {
            "PRAGMA synchronous = NORMAL;",          // Reduce fsync calls (FULL is default, NORMAL is safer than OFF)
            "PRAGMA journal_mode = WAL;",            // Write-Ahead Logging is more efficient than rollback
            "PRAGMA auto_vacuum = INCREMENTAL;",     // More efficient vacuum
            "PRAGMA temp_store = MEMORY;",           // Store temp tables in memory
            "PRAGMA mmap_size = 30000000;",          // Memory map up to 30MB (reduce I/O)
            NULL
        };
        
        // Apply SQLite optimizations
        for (int i = 0; pragmas[i] != NULL; i++) {
            char *errMsg = NULL;
            if (sqlite3_exec(_database, pragmas[i], NULL, NULL, &errMsg) != SQLITE_OK) {
                [self.logger error:@"Failed to set PRAGMA: %s", errMsg];
                sqlite3_free(errMsg);
            }
        }
        
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
        count = self.packageCache.count;
        
        // If we have items in DB, add them to the count
        const char *sql = "SELECT COUNT(*) FROM packages;";
        sqlite3_stmt *statement;

        if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {
            if (sqlite3_step(statement) == SQLITE_ROW) {
                count += sqlite3_column_int(statement, 0);
            }
        }
        sqlite3_finalize(statement);
    });
    return count;
}

- (ADJActivityPackage *)packageAtIndex:(NSUInteger)index {
    __block ADJActivityPackage *package = nil;
    dispatch_sync(self.dbQueue, ^{
        // Check if the index is in the cache
        if (index < self.packageCache.count) {
            package = self.packageCache[index];
            return;
        }
        
        // If not in cache, load from database with adjusted index
        NSUInteger dbIndex = index - self.packageCache.count;
        
        const char *sql = "SELECT package_data FROM packages ORDER BY created_at ASC LIMIT 1 OFFSET ?;";
        sqlite3_stmt *statement;

        if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {
            sqlite3_bind_int(statement, 1, (int)dbIndex);

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
        // Add to in-memory cache first
        [self.packageCache addObject:package];
        self.isDirty = YES;
        
        // If we reached the cache limit, flush to disk
        if (self.packageCache.count >= self.cacheLimit) {
            [self flushCacheInternal];
        }
    });
}

- (void)flushCacheInternal {
    if (self.packageCache.count == 0 || !self.isDirty) {
        return;
    }
    
    // Create a copy of the cache and clear it
    NSArray *packagesToWrite = [self.packageCache copy];
    [self.packageCache removeAllObjects];
    self.isDirty = NO;
    
    // Batch add them to the database
    [self batchAddPackages:packagesToWrite];
}

- (void)flushCache {
    dispatch_sync(self.dbQueue, ^{
        [self flushCacheInternal];
    });
}

- (void)batchAddPackages:(NSArray<ADJActivityPackage *> *)packages {
    if (packages.count == 0) {
        return;
    }
    
    // Begin transaction for batch processing
    if (sqlite3_exec(self->_database, "BEGIN TRANSACTION", NULL, NULL, NULL) != SQLITE_OK) {
        [self.logger error:@"Failed to begin transaction for batch insert"];
        return;
    }
    
    BOOL success = YES;
    sqlite3_stmt *statement = NULL;
    const char *sql = "INSERT INTO packages (package_data) VALUES (?);";
    
    if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) != SQLITE_OK) {
        [self.logger error:@"Failed to prepare statement: %s", sqlite3_errmsg(self->_database)];
        sqlite3_exec(self->_database, "ROLLBACK", NULL, NULL, NULL);
        return;
    }
    
    for (ADJActivityPackage *package in packages) {
        NSData *packageData = nil;
        
        if (@available(iOS 11.0, tvOS 11.0, *)) {
            NSError *error = nil;
            packageData = [NSKeyedArchiver archivedDataWithRootObject:package
                                                requiringSecureCoding:NO
                                                                error:&error];
            if (error) {
                [self.logger error:@"Failed to archive package: %@", error];
                success = NO;
                break;
            }
        } else {
            @try {
                packageData = [NSKeyedArchiver archivedDataWithRootObject:package];
            } @catch (NSException *exception) {
                [self.logger error:@"Failed to archive package: %@", exception];
                success = NO;
                break;
            }
        }
        
        if (!packageData) {
            [self.logger error:@"Failed to create package data"];
            success = NO;
            break;
        }
        
        sqlite3_clear_bindings(statement);
        sqlite3_reset(statement);
        sqlite3_bind_blob(statement, 1, [packageData bytes], (int)[packageData length], SQLITE_TRANSIENT);
        
        if (sqlite3_step(statement) != SQLITE_DONE) {
            [self.logger error:@"Failed to insert package: %s", sqlite3_errmsg(self->_database)];
            success = NO;
            break;
        }
    }
    
    sqlite3_finalize(statement);
    
    if (success) {
        if (sqlite3_exec(self->_database, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
            [self.logger error:@"Failed to commit transaction"];
            sqlite3_exec(self->_database, "ROLLBACK", NULL, NULL, NULL);
        }
    } else {
        sqlite3_exec(self->_database, "ROLLBACK", NULL, NULL, NULL);
    }
}

- (void)removePackageAtIndex:(NSUInteger)index {
    dispatch_sync(self.dbQueue, ^{
        // Check if the index is in the cache
        if (index < self.packageCache.count) {
            [self.packageCache removeObjectAtIndex:index];
            return;
        }
        
        // If not in cache, remove from database with adjusted index
        NSUInteger dbIndex = index - self.packageCache.count;
        
        const char *sql = "DELETE FROM packages WHERE id IN "
        "(SELECT id FROM packages ORDER BY created_at ASC LIMIT 1 OFFSET ?);";
        sqlite3_stmt *statement;

        if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {
            sqlite3_bind_int(statement, 1, (int)dbIndex);

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
        // Combine cache with database packages
        NSMutableArray *allPackages = [NSMutableArray arrayWithArray:self.packageCache];
        [allPackages addObjectsFromArray:[self loadPackagesInternal]];
        packages = [allPackages copy];
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
        // Clear the cache
        [self.packageCache removeAllObjects];
        self.isDirty = NO;
        
        // Clear the database
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
        // Flush any remaining cached packages before closing
        [self flushCacheInternal];
        
        if (self->_database) {
            sqlite3_close(self->_database);
            self->_database = NULL;
        }
    });
}

- (void)dealloc {
    [self closeDatabase];
    self.packageCache = nil;
}

- (void)schedulePeriodicCacheFlush {
    // Flush cache every 30 seconds or when app is going to background
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    
    // Register for app background notification
    [notificationCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                    object:nil
                                     queue:nil
                                usingBlock:^(NSNotification * _Nonnull note) {
                                    [self flushCache];
                                }];
    
    // Set up a timer to periodically flush
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:30.0
                                         target:self
                                       selector:@selector(flushCache)
                                       userInfo:nil
                                        repeats:YES];
    });
}

@end
