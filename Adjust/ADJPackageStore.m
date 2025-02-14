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
        NSString *documentsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
        self.databasePath = [documentsPath stringByAppendingPathComponent:@"adjustPackages.db"];
        self.logger = ADJAdjustFactory.logger;
        [self createDatabase];
        [self migrateFromPlistIfNeeded];
    }
    return self;
}

- (void)createDatabase {
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
    }
}

- (void)migrateFromPlistIfNeeded {
    // Get path to old file in Application Support directory
    NSString *plistPath = [self getFilePathInAppSupportDir:@"AdjustIoPackageQueue"];
    
    // Check if old file exists
    if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        return;
    }
    
    @try {
        // Read data from old file
        NSData *plistData = [NSData dataWithContentsOfFile:plistPath];
        if (!plistData) {
            [self.logger debug:@"No data found in old package queue file"];
            return;
        }
        
        NSArray *oldPackages = [NSKeyedUnarchiver unarchiveObjectWithData:plistData];
        if (!oldPackages || ![oldPackages isKindOfClass:[NSArray class]]) {
            [self.logger error:@"Failed to unarchive old package queue"];
            return;
        }
        
        // Start transaction for migration
        const char *beginTransaction = "BEGIN TRANSACTION;";
        if (sqlite3_exec(_database, beginTransaction, NULL, NULL, NULL) != SQLITE_OK) {
            [self.logger error:@"Failed to begin transaction for migration"];
            return;
        }
        
        // Migrate each package
        BOOL migrationSuccessful = YES;
        for (ADJActivityPackage *package in oldPackages) {
            if (![package isKindOfClass:[ADJActivityPackage class]]) {
                continue;
            }
            
            @try {
                [self addPackage:package];
            } @catch (NSException *exception) {
                [self.logger error:@"Failed to migrate package: %@", exception];
                migrationSuccessful = NO;
                break;
            }
        }
        
        if (migrationSuccessful) {
            // Complete transaction
            const char *commitTransaction = "COMMIT;";
            if (sqlite3_exec(_database, commitTransaction, NULL, NULL, NULL) == SQLITE_OK) {
                // Delete old file only after successful migration
                NSError *error = nil;
                if ([[NSFileManager defaultManager] removeItemAtPath:plistPath error:&error]) {
                    [self.logger debug:@"Successfully migrated %lu packages from plist to SQLite", 
                                     (unsigned long)oldPackages.count];
                } else {
                    [self.logger error:@"Failed to remove old package queue file: %@", error];
                }
            } else {
                [self.logger error:@"Failed to commit migration transaction"];
                const char *rollbackTransaction = "ROLLBACK;";
                sqlite3_exec(_database, rollbackTransaction, NULL, NULL, NULL);
            }
        } else {
            // Rollback transaction in case of error
            const char *rollbackTransaction = "ROLLBACK;";
            sqlite3_exec(_database, rollbackTransaction, NULL, NULL, NULL);
            [self.logger error:@"Migration failed, rolling back changes"];
        }
    } @catch (NSException *exception) {
        [self.logger error:@"Exception during migration: %@", exception];
        const char *rollbackTransaction = "ROLLBACK;";
        sqlite3_exec(_database, rollbackTransaction, NULL, NULL, NULL);
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

- (void)addPackage:(ADJActivityPackage *)package {
    dispatch_async(self.dbQueue, ^{
        if (!package) {
            [self.logger error:@"Cannot add nil package"];
            return;
        }
        
        @try {
            NSError *error = nil;
            NSData *packageData = nil;
            
            if (@available(iOS 11.0, tvOS 11.0, *)) {
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
            
            if (sqlite3_prepare_v2(_database, sql, -1, &statement, NULL) == SQLITE_OK) {
                sqlite3_bind_blob(statement, 1, [packageData bytes], (int)[packageData length], SQLITE_TRANSIENT);
                
                if (sqlite3_step(statement) != SQLITE_DONE) {
                    [self.logger error:@"Failed to insert package: %s", sqlite3_errmsg(_database)];
                }
            } else {
                [self.logger error:@"Failed to prepare statement: %s", sqlite3_errmsg(_database)];
            }
            sqlite3_finalize(statement);
        } @catch (NSException *exception) {
            [self.logger error:@"Exception while adding package: %@", exception];
        }
    });
}

- (void)removePackageAtIndex:(NSUInteger)index {
    const char *sql = "DELETE FROM packages WHERE id IN (SELECT id FROM packages LIMIT 1 OFFSET ?);";
    sqlite3_stmt *statement;
    
    if (sqlite3_prepare_v2(_database, sql, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int(statement, 1, (int)index);
        
        if (sqlite3_step(statement) != SQLITE_DONE) {
            [self.logger error:@"Failed to remove package"];
        }
    }
    sqlite3_finalize(statement);
}

- (NSArray<ADJActivityPackage *> *)loadPackages {
    __block NSArray *result = nil;
    dispatch_sync(self.dbQueue, ^{
        NSMutableArray<ADJActivityPackage *> *packages = [NSMutableArray array];
        
        const char *sql = "SELECT package_data FROM packages ORDER BY created_at ASC;";
        sqlite3_stmt *statement;
        
        if (sqlite3_prepare_v2(_database, sql, -1, &statement, NULL) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                @autoreleasepool {
                    @try {
                        const void *data = sqlite3_column_blob(statement, 0);
                        int dataSize = sqlite3_column_bytes(statement, 0);
                        
                        if (data && dataSize > 0) {
                            NSData *packageData = [NSData dataWithBytes:data length:dataSize];
                            
                            if (@available(iOS 11.0, tvOS 11.0, *)) {
                                NSError *error = nil;
                                ADJActivityPackage *package = [NSKeyedUnarchiver unarchivedObjectOfClass:[ADJActivityPackage class]
                                                                                              fromData:packageData
                                                                                                error:&error];
                                if (error) {
                                    [self.logger error:@"Failed to unarchive package: %@", error];
                                    continue;
                                }
                                if (package) {
                                    [packages addObject:package];
                                }
                            } else {
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
                    } @catch (NSException *exception) {
                        [self.logger error:@"Exception while loading package: %@", exception];
                    }
                }
            }
        }
        sqlite3_finalize(statement);
        
        result = packages;
    });
    return result;
}

- (void)clearAllPackages {
    const char *sql = "DELETE FROM packages;";
    char *errMsg;
    
    if (sqlite3_exec(_database, sql, NULL, NULL, &errMsg) != SQLITE_OK) {
        [self.logger error:@"Failed to clear packages: %s", errMsg];
        sqlite3_free(errMsg);
    }
}

- (void)dealloc {
    sqlite3_close(_database);
}

@end 