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
  NSString *plistPath = [self getFilePathInAppSupportDir:@"AdjustIoPackageQueue"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
    return;
  }

  // Прочитать массив oldPackages (NSKeyedUnarchiver) можно и вне dbQueue,
  // но саму транзакцию и вставки нужно поместить в dispatch_sync на dbQueue.
  NSData *plistData = [NSData dataWithContentsOfFile:plistPath];
  NSArray *oldPackages = [NSKeyedUnarchiver unarchiveObjectWithData:plistData];
  if (![oldPackages isKindOfClass:[NSArray class]]) {
    return;
  }

  dispatch_sync(self.dbQueue, ^{
    // Запускаем транзакцию *внутри* dbQueue
    if (sqlite3_exec(self->_database, "BEGIN TRANSACTION;", NULL, NULL, NULL) != SQLITE_OK) {
      [self.logger error:@"Failed to begin transaction for migration"];
      return;
    }

    BOOL migrationSuccessful = YES;
    @try {
      for (ADJActivityPackage *pkg in oldPackages) {
        // Здесь можно вызвать *внутренний* метод вставки без dispatch_async,
        // или же сделать тело вставки прямо тут, чтобы гарантировать, что
        // все INSERT идут синхронно в рамках одной транзакции.
        if (![self insertPackageSync:pkg]) {
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
  });
}

- (BOOL)insertPackageSync:(ADJActivityPackage *)package {
  if (!package) {
    [self.logger error:@"insertPackageSync called with nil package"];
    return NO;
  }

  NSData *packageData = nil;

  // Архивируем package
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

  // Подготовим запрос
  if (sqlite3_prepare_v2(self->_database, sql, -1, &statement, NULL) == SQLITE_OK) {
    // Привязываем blob
    sqlite3_bind_blob(statement, 1, [packageData bytes], (int)[packageData length], SQLITE_TRANSIENT);

    // Выполняем запрос
    if (sqlite3_step(statement) != SQLITE_DONE) {
      [self.logger error:@"Failed to insert package: %s", sqlite3_errmsg(self->_database)];
      sqlite3_finalize(statement);
      return NO;
    }
    // Всё успешно
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
  dispatch_async(self.dbQueue, ^{
    const char *sql = "DELETE FROM packages WHERE id IN (SELECT id FROM packages LIMIT 1 OFFSET ?);";
    sqlite3_stmt *statement;

    if (sqlite3_prepare_v2(_database, sql, -1, &statement, NULL) == SQLITE_OK) {
      sqlite3_bind_int(statement, 1, (int)index);

      if (sqlite3_step(statement) != SQLITE_DONE) {
        [self.logger error:@"Failed to remove package"];
      }
    } else {
      [self.logger error:@"Failed to prepare statement: %s", sqlite3_errmsg(_database)];
    }
    sqlite3_finalize(statement);
  });
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
  dispatch_async(self.dbQueue, ^{
    const char *sql = "DELETE FROM packages;";
    char *errMsg;

    if (sqlite3_exec(_database, sql, NULL, NULL, &errMsg) != SQLITE_OK) {
      [self.logger error:@"Failed to clear packages: %s", errMsg];
      sqlite3_free(errMsg);
    }
  });
}

- (void)dealloc {
    sqlite3_close(_database);
}

@end 
