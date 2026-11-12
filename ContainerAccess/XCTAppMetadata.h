#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
NSDictionary * _Nullable XCTReadBundleInfo(NSString *path);
NSDictionary<NSString *, NSString *> *XCTApplicationListingFacts(NSString *bundleID);
NSData * _Nullable XCTReadApplicationIcon(NSString *bundleID);
void XCTRecordIconSource(NSString *bundleID, NSString *message);
NSDictionary<NSString *, NSString *> *XCTIconDiagnostics(NSString *bundleID);
NS_ASSUME_NONNULL_END
