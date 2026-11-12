#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface XCTContainerBridge : NSObject
+ (NSString * _Nullable)appGroup;
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)discover:(BOOL)allowFullScan error:(NSError **)error;
+ (NSData * _Nullable)iconPNGForBundleID:(NSString *)bundleID;
+ (void)recordIconSource:(NSString *)bundleID message:(NSString *)message;
+ (void)recordDiscoveryExclusion:(NSString *)bundleID reason:(NSString *)reason;
+ (NSString *)diagnostics;
+ (NSString *)probeIconCaches;
+ (NSDictionary<NSString *, NSString *> *)iconDiagnostics:(NSString *)bundleID;
+ (BOOL)createConfigurationZIP:(NSString *)directory output:(NSString *)output error:(NSError **)error;
+ (BOOL)extractConfigurationZIP:(NSString *)zip output:(NSString *)output error:(NSError **)error;
+ (NSString * _Nullable)directoryReadError:(NSString *)path;
+ (BOOL)prepareRead:(NSString *)path;
@end
NS_ASSUME_NONNULL_END
