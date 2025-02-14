#import <Foundation/Foundation.h>
#import "ADJActivityPackage.h"

@interface ADJPackageStore : NSObject

+ (instancetype)sharedInstance;

- (void)addPackage:(ADJActivityPackage *)package;
- (void)removePackage:(ADJActivityPackage *)package;
- (void)removePackageAtIndex:(NSUInteger)index;
- (NSArray<ADJActivityPackage *> *)loadPackages;
- (void)clearAllPackages;
- (void)updatePackages:(NSArray<ADJActivityPackage *> *)packages;

@end 