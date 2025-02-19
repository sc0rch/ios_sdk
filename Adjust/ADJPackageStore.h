#import <Foundation/Foundation.h>
#import "ADJActivityPackage.h"

@interface ADJPackageStore : NSObject

+ (instancetype)sharedInstance;

- (void)addPackage:(ADJActivityPackage *)package;

- (void)removePackageAtIndex:(NSUInteger)index;

- (NSArray<ADJActivityPackage *> *)loadPackages;

- (void)clearAllPackages;

- (NSUInteger)count;

- (ADJActivityPackage *)packageAtIndex:(NSUInteger)index;

- (BOOL)updatePackage:(ADJActivityPackage *)package atIndex:(NSUInteger)index;

- (void)updatePackages:(void (^)(ADJActivityPackage *package))updateBlock;

@end
