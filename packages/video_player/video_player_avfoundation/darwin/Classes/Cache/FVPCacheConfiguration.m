// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FVPCacheConfiguration.h"
#import "FVPCacheManager.h"

static NSString *kFileNameKey = @"kFileNameKey";
static NSString *kCacheFragmentsKey = @"kCacheFragmentsKey";
static NSString *kDownloadInfoKey = @"kDownloadInfoKey";
static NSString *kContentInfoKey = @"kContentInfoKey";
static NSString *kURLKey = @"kURLKey";
static int kSavePendingSeconds = 2;

@interface FVPCacheConfiguration () <NSSecureCoding>

@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, copy) NSString *fileName;
@property(nonatomic, copy) NSArray<NSValue *> *internalCacheFragments;
@property(nonatomic, copy) NSArray *downloadInfo;  //(NSArray of bytes and time)

@end

@implementation FVPCacheConfiguration

// Returns configuration or error.
+ (instancetype)configurationWithFilePath:(NSString *)filePath error:(NSError **)error {
  // FilePath for the cache configuration filepath.
  filePath = [filePath stringByAppendingPathExtension:@"cache_configuration"];

  // Get the cache confguration.
  NSData *data = [NSData dataWithContentsOfFile:filePath];
  NSSet *allowedClasses = [NSSet setWithObjects:[FVPCacheConfiguration class],
                         [NSString class],
                         [NSURL class],
                         [NSArray class],
                         [NSValue class],
                         [NSNumber class],
                         [FVPContentInfo class],
                         nil];
  FVPCacheConfiguration *configuration =
      [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses
          fromData:data error:error];
  if (*error) {
      NSLog(@"Error unarchiving cache configuration: %@", *error);
  }
  // If there is no cache confguration, create a new one.
  if (!configuration) {
    configuration = [[FVPCacheConfiguration alloc] init];
    configuration.fileName = [filePath lastPathComponent];
  }
  configuration.filePath = filePath;

  // Return the configuration that has been created or retrieved.
  return configuration;
}

+ (NSString *)configurationFilePathForFilePath:(NSString *)filePath {
  return [filePath stringByAppendingPathExtension:@"fvp_cont_cfg"];
}

- (NSArray<NSValue *> *)internalCacheFragments {
  if (!_internalCacheFragments) {
    _internalCacheFragments = [NSArray array];
  }
  return _internalCacheFragments;
}

// Returns or creates downloadInfo.
- (NSArray *)downloadInfo {
  if (!_downloadInfo) {
    _downloadInfo = [NSArray array];
  }
  return _downloadInfo;
}

- (NSArray<NSValue *> *)cacheFragments {
  return [_internalCacheFragments copy];
}

#pragma mark - NSCoding

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [aCoder encodeObject:self.fileName forKey:kFileNameKey];
  [aCoder encodeObject:self.internalCacheFragments forKey:kCacheFragmentsKey];
  [aCoder encodeObject:self.downloadInfo forKey:kDownloadInfoKey];
  [aCoder encodeObject:self.contentInfo forKey:kContentInfoKey];
  [aCoder encodeObject:self.url forKey:kURLKey];
}

- (nullable instancetype)initWithCoder:(NSCoder *)aDecoder {
  self = [super init];
  if (self) {
    _fileName = [aDecoder decodeObjectForKey:kFileNameKey];
    _internalCacheFragments = [[aDecoder decodeObjectForKey:kCacheFragmentsKey] mutableCopy];
    if (!_internalCacheFragments) {
      _internalCacheFragments = [NSArray array];
    }
    _downloadInfo = [aDecoder decodeObjectForKey:kDownloadInfoKey];
    _contentInfo = [aDecoder decodeObjectForKey:kContentInfoKey];
    _url = [aDecoder decodeObjectForKey:kURLKey];
    _pendingSaveCount = 0;
  }
  return self;
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

#pragma mark - NSCopying

- (id)copyWithZone:(nullable NSZone *)zone {
  FVPCacheConfiguration *configuration = [[FVPCacheConfiguration allocWithZone:zone] init];
  configuration.fileName = self.fileName;
  configuration.filePath = self.filePath;
  configuration.internalCacheFragments = self.internalCacheFragments;
  configuration.downloadInfo = self.downloadInfo;
  configuration.url = self.url;
  configuration.contentInfo = self.contentInfo;
  configuration.pendingSaveCount = 0;

  return configuration;
}

#pragma mark - Update

// Save the cache configuration, but cancel "in progress" save.
- (void)save {
  if (self.pendingSaveCount > 0) {
    // If saving is in progress, return without initiating another save operation
    self.pendingSaveCount++;
    return;
  }
  self.pendingSaveCount = 1;
  [self archiveData];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSavePendingSeconds * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
        if (self) {
            BOOL run = self.pendingSaveCount > 1;
            self.pendingSaveCount = 0;
            if (run) {
                [self archiveData];
            }
        }
    });
}

// Save action, or print error.
- (void)archiveData {
  @synchronized(self.internalCacheFragments) {
    NSError *error;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:self
                                         requiringSecureCoding:NO
                                                         error:&error];

    if (error) {
      NSLog(@"ERROR 1 %@", error);
    }
    [data writeToFile:self.filePath options:NSDataWritingAtomic error:&error];
    if (error) {
      NSLog(@"ERROR 2 %@", error);
    }
  }
}

- (void)addCacheFragment:(NSRange)fragment {
  if (fragment.location == NSNotFound || fragment.length == 0) {
    return;
  }

  @synchronized(self.internalCacheFragments) {
    NSMutableArray *internalCacheFragments = [self.internalCacheFragments mutableCopy];

    NSValue *fragmentValue = [NSValue valueWithRange:fragment];
    NSInteger count = self.internalCacheFragments.count;
    if (count == 0) {
      [internalCacheFragments addObject:fragmentValue];
    } else {
      NSMutableIndexSet *indexSet = [NSMutableIndexSet indexSet];
      [internalCacheFragments
          enumerateObjectsUsingBlock:^(NSValue *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
            NSRange range = obj.rangeValue;
            if ((fragment.location + fragment.length) <= range.location) {
              if (indexSet.count == 0) {
                [indexSet addIndex:idx];
              }
              *stop = YES;
            } else if (fragment.location <= (range.location + range.length) &&
                       (fragment.location + fragment.length) > range.location) {
              [indexSet addIndex:idx];
            } else if (fragment.location >= range.location + range.length) {
              if (idx == count - 1) {  // Append to last index
                [indexSet addIndex:idx];
              }
            }
          }];

      if (indexSet.count > 1) {
        NSRange firstRange = self.internalCacheFragments[indexSet.firstIndex].rangeValue;
        NSRange lastRange = self.internalCacheFragments[indexSet.lastIndex].rangeValue;
        NSInteger location = MIN(firstRange.location, fragment.location);
        NSInteger endOffset =
            MAX(lastRange.location + lastRange.length, fragment.location + fragment.length);
        NSRange combineRange = NSMakeRange(location, endOffset - location);
        [internalCacheFragments removeObjectsAtIndexes:indexSet];
        [internalCacheFragments insertObject:[NSValue valueWithRange:combineRange]
                                     atIndex:indexSet.firstIndex];
      } else if (indexSet.count == 1) {
        NSRange firstRange = self.internalCacheFragments[indexSet.firstIndex].rangeValue;

        NSRange expandFirstRange = NSMakeRange(firstRange.location, firstRange.length + 1);
        NSRange expandFragmentRange = NSMakeRange(fragment.location, fragment.length + 1);
        NSRange intersectionRange = NSIntersectionRange(expandFirstRange, expandFragmentRange);
        if (intersectionRange.length > 0) {  // Should combine
          NSInteger location = MIN(firstRange.location, fragment.location);
          NSInteger endOffset =
              MAX(firstRange.location + firstRange.length, fragment.location + fragment.length);
          NSRange combineRange = NSMakeRange(location, endOffset - location);
          [internalCacheFragments removeObjectAtIndex:indexSet.firstIndex];
          [internalCacheFragments insertObject:[NSValue valueWithRange:combineRange]
                                       atIndex:indexSet.firstIndex];
        } else {
          if (firstRange.location > fragment.location) {
            [internalCacheFragments insertObject:fragmentValue atIndex:[indexSet lastIndex]];
          } else {
            [internalCacheFragments insertObject:fragmentValue atIndex:[indexSet lastIndex] + 1];
          }
        }
      }
    }

    self.internalCacheFragments = [internalCacheFragments copy];
  }
}

// Store downloadInfo.
- (void)addDownloadedBytes:(long long)bytes spent:(NSTimeInterval)time {
  @synchronized(self.downloadInfo) {
    self.downloadInfo = [self.downloadInfo arrayByAddingObject:@[ @(bytes), @(time) ]];
  }
}

@end
