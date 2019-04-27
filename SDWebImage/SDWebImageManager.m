/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageManager.h"
#import "NSImage+WebCache.h"
#import <objc/message.h>

//信号量的形式进行加锁
#define LOCK(lock) dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#define UNLOCK(lock) dispatch_semaphore_signal(lock);

@interface SDWebImageCombinedOperation : NSObject <SDWebImageOperation>

@property (assign, nonatomic, getter = isCancelled) BOOL cancelled;
@property (strong, nonatomic, nullable) SDWebImageDownloadToken *downloadToken;
@property (strong, nonatomic, nullable) NSOperation *cacheOperation;
@property (weak, nonatomic, nullable) SDWebImageManager *manager;

@end

@interface SDWebImageManager ()

@property (strong, nonatomic, readwrite, nonnull) SDImageCache *imageCache;
@property (strong, nonatomic, readwrite, nonnull) SDWebImageDownloader *imageDownloader;
@property (strong, nonatomic, nonnull) NSMutableSet<NSURL *> *failedURLs;
@property (strong, nonatomic, nonnull) dispatch_semaphore_t failedURLsLock; // a lock to keep the access to `failedURLs` thread-safe
@property (strong, nonatomic, nonnull) NSMutableSet<SDWebImageCombinedOperation *> *runningOperations;
@property (strong, nonatomic, nonnull) dispatch_semaphore_t runningOperationsLock; // a lock to keep the access to `runningOperations` thread-safe

@end

@implementation SDWebImageManager

+ (nonnull instancetype)sharedManager {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (nonnull instancetype)init {
    SDImageCache *cache = [SDImageCache sharedImageCache];
    SDWebImageDownloader *downloader = [SDWebImageDownloader sharedDownloader];
    return [self initWithCache:cache downloader:downloader];
}

- (nonnull instancetype)initWithCache:(nonnull SDImageCache *)cache downloader:(nonnull SDWebImageDownloader *)downloader {
    if ((self = [super init])) {
        _imageCache = cache;
        _imageDownloader = downloader;
        _failedURLs = [NSMutableSet new];
        _failedURLsLock = dispatch_semaphore_create(1);
        _runningOperations = [NSMutableSet new];
        _runningOperationsLock = dispatch_semaphore_create(1);
    }
    return self;
}

- (nullable NSString *)cacheKeyForURL:(nullable NSURL *)url {
    if (!url) {
        return @"";
    }

    //判断是否存在 cacheKeyFilter 如果有则使用缓存过滤规则获取key 没有则或者url的absoluteString
    if (self.cacheKeyFilter) {
        return self.cacheKeyFilter(url);
    } else {
        return url.absoluteString;
    }
}

- (nullable UIImage *)scaledImageForKey:(nullable NSString *)key image:(nullable UIImage *)image {
    return SDScaledImageForKey(key, image);
}

- (void)cachedImageExistsForURL:(nullable NSURL *)url
                     completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock {
    NSString *key = [self cacheKeyForURL:url];
    
    BOOL isInMemoryCache = ([self.imageCache imageFromMemoryCacheForKey:key] != nil);
    
    if (isInMemoryCache) {
        // making sure we call the completion block on the main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionBlock) {
                completionBlock(YES);
            }
        });
        return;
    }
    
    [self.imageCache diskImageExistsWithKey:key completion:^(BOOL isInDiskCache) {
        // the completion block of checkDiskCacheForImageWithKey:completion: is always called on the main queue, no need to further dispatch
        if (completionBlock) {
            completionBlock(isInDiskCache);
        }
    }];
}

- (void)diskImageExistsForURL:(nullable NSURL *)url
                   completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock {
    NSString *key = [self cacheKeyForURL:url];
    
    [self.imageCache diskImageExistsWithKey:key completion:^(BOOL isInDiskCache) {
        // the completion block of checkDiskCacheForImageWithKey:completion: is always called on the main queue, no need to further dispatch
        if (completionBlock) {
            completionBlock(isInDiskCache);
        }
    }];
}

/*
 首先会查看要加载的图片链接是否失败过，再根据设置的选项决定要不要继续加载。
 然后根据图片链接查找是否有该图片的缓存，再根据设置的选项决定要不要网络下载。
 接着根据下载的图片是否是动图，再根据设置的选项决定怎么转换动图。
 最后根据设置的选项进行缓存，并进行回调。
 */
- (id <SDWebImageOperation>)loadImageWithURL:(nullable NSURL *)url
                                     options:(SDWebImageOptions)options
                                    progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                   completed:(nullable SDInternalCompletionBlock)completedBlock {
    // Invoking this method without a completedBlock is pointless
    // 完成回调代码块是必传的
    NSAssert(completedBlock != nil, @"If you mean to prefetch the image, use -[SDWebImagePrefetcher prefetchURLs] instead");

    // Very common mistake is to send the URL using NSString object instead of NSURL. For some strange reason, Xcode won't
    // throw any warning for this type mismatch. Here we failsafe this error by allowing URLs to be passed as NSString.
    // 假如URL 是NSString 类型 则将url转化成NSURL类型
    // 虽然参数要求传NSURL对象但是传NSStriing对象不会有警告，所以做一下处理
    if ([url isKindOfClass:NSString.class]) {
        url = [NSURL URLWithString:(NSString *)url];
    }

    // 加入转化失败了 ，则将url设置为nil
    // Prevents app crashing on argument type error like sending NSNull instead of NSURL
    if (![url isKindOfClass:NSURL.class]) {
        url = nil;
    }

    // 生成一个图片加载操作的封装对象
    SDWebImageCombinedOperation *operation = [SDWebImageCombinedOperation new];
    operation.manager = self;

    // 请求加载图片的地址连接是否在加载失败的地址链接集合中，也就是说这次请求加载的图片，以前是否加载失败过
    BOOL isFailedUrl = NO;
    if (url) {
        LOCK(self.failedURLsLock);
        isFailedUrl = [self.failedURLs containsObject:url];
        UNLOCK(self.failedURLsLock);
    }

    // 如果链接地址不正确，或者之前加载失败过但是也没设置失败可重试，就直接回调错误并返回
    // 表示禁用黑名单 !(options & SDWebImageRetryFailed) 表示没有禁用黑名单
    if (url.absoluteString.length == 0 || (!(options & SDWebImageRetryFailed) && isFailedUrl)) {
        [self callCompletionBlockForOperation:operation completion:completedBlock error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil] url:url];
        return operation;
    }

    // 将当前操作对象添加到集合中保存
    LOCK(self.runningOperationsLock);
    [self.runningOperations addObject:operation];
    UNLOCK(self.runningOperationsLock);
    
    // 生成地址链接对应的Key
    NSString *key = [self cacheKeyForURL:url];
    
    // 初始化缓存策略 ，并根据参数进行设置
    SDImageCacheOptions cacheOptions = 0;
     // 如果设置了强制内存查询
    if (options & SDWebImageQueryDataWhenInMemory) cacheOptions |= SDImageCacheQueryDataWhenInMemory;
    // 如果设置了强制硬盘查询
    if (options & SDWebImageQueryDiskSync) cacheOptions |= SDImageCacheQueryDiskSync;
    // 默认情况下，图像根据其原始大小进行解码。在iOS系统中，这个标志会将图像缩小到与设备有限内存兼容的大小
    if (options & SDWebImageScaleDownLargeImages) cacheOptions |= SDImageCacheScaleDownLargeImages;
    
    // 初始化一个weakOperation 变量
    __weak SDWebImageCombinedOperation *weakOperation = operation;
    // 从内存缓存或者硬盘缓存获取图片 （有可能成功 或者失败）
    operation.cacheOperation = [self.imageCache queryCacheOperationForKey:key options:cacheOptions done:^(UIImage *cachedImage, NSData *cachedData, SDImageCacheType cacheType) {
        //返回从内存缓存或者硬盘缓存获取的数据。 解码过的到的图片 ，二进制的图片数据 ，以及缓存类型
        __strong __typeof(weakOperation) strongOperation = weakOperation;
        //如果下载线程已经结束了 则将其移出
        if (!strongOperation || strongOperation.isCancelled) {
            [self safelyRemoveOperationFromRunning:strongOperation];
            return;
        }
        
        // Check whether we should download image from network
        // 查看是否应该从网络下载该图片，想要从网络下载图片必须同时满足以下条件：
        // 没有设置只从缓存加载的选项
        // 没找到缓存图，或者设置了需要刷新缓存图
        // 代理对象没有实现这个代理方法，或者代理对象实现了这个代理方法并且代理方法返回了YES，意思是在缓存中找不到图片时要从网络上下载

        BOOL shouldDownload = (!(options & SDWebImageFromCacheOnly))
            && (!cachedImage || options & SDWebImageRefreshCached)
            && (![self.delegate respondsToSelector:@selector(imageManager:shouldDownloadImageForURL:)] || [self.delegate imageManager:self shouldDownloadImageForURL:url]);
        // 如果需要下载图片
        if (shouldDownload) {
            // 如果有图片缓存并且设置了刷新图片缓存，就先进行完成回调
            if (cachedImage && options & SDWebImageRefreshCached) {
                // If image was found in the cache but SDWebImageRefreshCached is provided, notify about the cached image
                // AND try to re-download it in order to let a chance to NSURLCache to refresh it from server.
                [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:cachedImage data:cachedData error:nil cacheType:cacheType finished:YES url:url];
            }

            // download if no image or requested to refresh anyway, and download allowed by delegate
            // 初始化 并根据参数设置 SDWebImageDownloaderOptions
            SDWebImageDownloaderOptions downloaderOptions = 0;
            // 低优先级
            if (options & SDWebImageLowPriority) downloaderOptions |= SDWebImageDownloaderLowPriority;
            // 渐进显示
            if (options & SDWebImageProgressiveDownload) downloaderOptions |= SDWebImageDownloaderProgressiveDownload;
            // 刷新缓存
            if (options & SDWebImageRefreshCached) downloaderOptions |= SDWebImageDownloaderUseNSURLCache;
            // 后台下载
            if (options & SDWebImageContinueInBackground) downloaderOptions |= SDWebImageDownloaderContinueInBackground;
            // 处理Cookies
            if (options & SDWebImageHandleCookies) downloaderOptions |= SDWebImageDownloaderHandleCookies;
            // 允许不可信的SSL证书
            if (options & SDWebImageAllowInvalidSSLCertificates) downloaderOptions |= SDWebImageDownloaderAllowInvalidSSLCertificates;
            // 高优先级
            if (options & SDWebImageHighPriority) downloaderOptions |= SDWebImageDownloaderHighPriority;
            // 缩小尺寸
            if (options & SDWebImageScaleDownLargeImages) downloaderOptions |= SDWebImageDownloaderScaleDownLargeImages;
            
            // 如果有缓存图，并且选择了刷新缓存的选项
            if (cachedImage && options & SDWebImageRefreshCached) {
                // force progressive off if image already cached but forced refreshing
                // 关闭渐进显示
                downloaderOptions &= ~SDWebImageDownloaderProgressiveDownload;
                // ignore image read from NSURLCache if image if cached but force refreshing
                // 忽视从NSURLCache中获取缓存
                downloaderOptions |= SDWebImageDownloaderIgnoreCachedResponse;
            }
            
            // `SDWebImageCombinedOperation` -> `SDWebImageDownloadToken` -> `downloadOperationCancelToken`, which is a `SDCallbacksDictionary` and retain the completed block below, so we need weak-strong again to avoid retain cycle
            // 开启下载任务并获取下载任务的令牌
            __weak typeof(strongOperation) weakSubOperation = strongOperation;
            strongOperation.downloadToken = [self.imageDownloader downloadImageWithURL:url options:downloaderOptions progress:progressBlock completed:^(UIImage *downloadedImage, NSData *downloadedData, NSError *error, BOOL finished) {
                
                __strong typeof(weakSubOperation) strongSubOperation = weakSubOperation;
                //判断线程是否结束 ,结束则什么都不做
                if (!strongSubOperation || strongSubOperation.isCancelled) {
                    // Do nothing if the operation was cancelled
                    // See #699 for more details
                    // if we would call the completedBlock, there could be a race condition between this block and another completedBlock for the same object, so if this one is called second, we will overwrite the new data
                } else if (error) {
                     // 如果出错，就进行回调
                    [self callCompletionBlockForOperation:strongSubOperation completion:completedBlock error:error url:url];
                    // 是否应该阻止下载已经失败的图片地址链接
                    BOOL shouldBlockFailedURL;
                    // Check whether we should block failed url
                    if ([self.delegate respondsToSelector:@selector(imageManager:shouldBlockFailedURL:withError:)]) {
                        // 如果实现了代理就按照代理返回的数据
                        shouldBlockFailedURL = [self.delegate imageManager:self shouldBlockFailedURL:url withError:error];
                    } else {
                        // 如果没有实现代理，想要阻止下载失败的链接就得满足以下条件：
                        // 不是没联网、
                        // 不是被取消、
                        // 不是连接超时、
                        // 不是关闭了国际漫游、
                        // 不是不允许蜂窝数据连接、
                        // 不是没有找到host、
                        // 不是无法连接host、
                        // 不是连接丢失

                        shouldBlockFailedURL = (   error.code != NSURLErrorNotConnectedToInternet
                                                && error.code != NSURLErrorCancelled
                                                && error.code != NSURLErrorTimedOut
                                                && error.code != NSURLErrorInternationalRoamingOff
                                                && error.code != NSURLErrorDataNotAllowed
                                                && error.code != NSURLErrorCannotFindHost
                                                && error.code != NSURLErrorCannotConnectToHost
                                                && error.code != NSURLErrorNetworkConnectionLost);
                    }
                    
                    // 如果要组织失败连接再次下载，就把连接添加到黑名单中保存
                    if (shouldBlockFailedURL) {
                        LOCK(self.failedURLsLock);
                        [self.failedURLs addObject:url];
                        UNLOCK(self.failedURLsLock);
                    }
                }
                else {
                    // 如果下载成功
                    
                    // 如果设置了尝试下载失败的链接选项，就把连接从黑名单中移除
                    if ((options & SDWebImageRetryFailed)) {
                        LOCK(self.failedURLsLock);
                        [self.failedURLs removeObject:url];
                        UNLOCK(self.failedURLsLock);
                    }
                    
                    // 是否要缓存到硬盘：如果没设置只缓存到内存的选项就需要缓存到硬盘
                    BOOL cacheOnDisk = !(options & SDWebImageCacheMemoryOnly);
                    
                    // We've done the scale process in SDWebImageDownloader with the shared manager, this is used for custom manager and avoid extra scale.
                    // 在单例管理对象SDWebImageDownloader中已经实现了图片的缩放，这里是用于自定义管理对象以避免额外的缩放
                    if (self != [SDWebImageManager sharedManager] && self.cacheKeyFilter && downloadedImage) {
                        downloadedImage = [self scaledImageForKey:key image:downloadedImage];
                    }

                    if (options & SDWebImageRefreshCached && cachedImage && !downloadedImage) {
                        // 如果设置了刷新缓存选项，并且有缓存图，并且没有下载图，就什么也不需要做
                        // Image refresh hit the NSURLCache cache, do not call the completion block
                    } else if (downloadedImage && (!downloadedImage.images || (options & SDWebImageTransformAnimatedImage)) && [self.delegate respondsToSelector:@selector(imageManager:transformDownloadedImage:withURL:)]) {
                        
                        // 如果有下载图
                        // 并且下载的不是动图，如果是动图但是设置了动图转换选项
                        // 并且代理对象实现了转换动图的代理方法
                        
                        
                        // 全局并发队列异步执行
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                            @autoreleasepool {
                                // 调用代理方法获取转换后的图片
                                UIImage *transformedImage = [self.delegate imageManager:self transformDownloadedImage:downloadedImage withURL:url];
                                // 如果获取到了转换后的图片并且下载完成
                                if (transformedImage && finished) {
                                    // 判断转换后的图片是否真的被转换了
                                    BOOL imageWasTransformed = ![transformedImage isEqual:downloadedImage];
                                    NSData *cacheData;
                                    // pass nil if the image was transformed, so we can recalculate the data from the image
                                    if (self.cacheSerializer) {
                                        // 如果设置了图片编码代码块，就调用代码块对下载的图片进行编码。
                                        cacheData = self.cacheSerializer(transformedImage, (imageWasTransformed ? nil : downloadedData), url);
                                    } else {
                                        // 否则就检查图片是否被转换，如果被转换过，就不获取其二进制数据了，如果没转换过就用原始二进制数据
                                        cacheData = (imageWasTransformed ? nil : downloadedData);
                                    }
                                    // 缓存图片
                                    [self.imageCache storeImage:transformedImage imageData:cacheData forKey:key toDisk:cacheOnDisk completion:nil];
                                }
                                // 进行回调
                                [self callCompletionBlockForOperation:strongSubOperation completion:completedBlock image:transformedImage data:downloadedData error:nil cacheType:SDImageCacheTypeNone finished:finished url:url];
                            }
                        });
                    } else {
                        // 如果有下载图并且下载完成
                        if (downloadedImage && finished) {
                            if (self.cacheSerializer) {
                                // 如果设置了图片编码代码块，就在全局并发队列中异步调用代码块对下载的图片进行编码，然后缓存图片
                                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                                    @autoreleasepool {
                                        NSData *cacheData = self.cacheSerializer(downloadedImage, downloadedData, url);
                                        [self.imageCache storeImage:downloadedImage imageData:cacheData forKey:key toDisk:cacheOnDisk completion:nil];
                                    }
                                });
                            } else {
                                // 否者就直接缓存图片
                                [self.imageCache storeImage:downloadedImage imageData:downloadedData forKey:key toDisk:cacheOnDisk completion:nil];
                            }
                        }
                        // 进行回调
                        [self callCompletionBlockForOperation:strongSubOperation completion:completedBlock image:downloadedImage data:downloadedData error:nil cacheType:SDImageCacheTypeNone finished:finished url:url];
                    }
                }

                // 如果下载完成就从操作对象集合中移除
                if (finished) {
                    [self safelyRemoveOperationFromRunning:strongSubOperation];
                }
            }];
        } else if (cachedImage) {
            // 如果不需要下载并且获取到了缓存图就进行回调然后从操作对象集合中移除
            [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:cachedImage data:cachedData error:nil cacheType:cacheType finished:YES url:url];
            [self safelyRemoveOperationFromRunning:strongOperation];
        } else {
            // Image not in cache and download disallowed by delegate
            // 如果不需要下载 并且也没有缓存图就进行回调然后从操作对象集合中移除
            [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:nil data:nil error:nil cacheType:SDImageCacheTypeNone finished:YES url:url];
            [self safelyRemoveOperationFromRunning:strongOperation];
        }
    }];

    return operation;
}

- (void)saveImageToCache:(nullable UIImage *)image forURL:(nullable NSURL *)url {
    if (image && url) {
        NSString *key = [self cacheKeyForURL:url];
        [self.imageCache storeImage:image forKey:key toDisk:YES completion:nil];
    }
}

- (void)cancelAll {
    LOCK(self.runningOperationsLock);
    NSSet<SDWebImageCombinedOperation *> *copiedOperations = [self.runningOperations copy];
    UNLOCK(self.runningOperationsLock);
    [copiedOperations makeObjectsPerformSelector:@selector(cancel)]; // This will call `safelyRemoveOperationFromRunning:` and remove from the array
}

- (BOOL)isRunning {
    BOOL isRunning = NO;
    LOCK(self.runningOperationsLock);
    isRunning = (self.runningOperations.count > 0);
    UNLOCK(self.runningOperationsLock);
    return isRunning;
}

- (void)safelyRemoveOperationFromRunning:(nullable SDWebImageCombinedOperation*)operation {
    if (!operation) {
        return;
    }
    LOCK(self.runningOperationsLock);
    [self.runningOperations removeObject:operation];
    UNLOCK(self.runningOperationsLock);
}

- (void)callCompletionBlockForOperation:(nullable SDWebImageCombinedOperation*)operation
                             completion:(nullable SDInternalCompletionBlock)completionBlock
                                  error:(nullable NSError *)error
                                    url:(nullable NSURL *)url {
    [self callCompletionBlockForOperation:operation completion:completionBlock image:nil data:nil error:error cacheType:SDImageCacheTypeNone finished:YES url:url];
}

- (void)callCompletionBlockForOperation:(nullable SDWebImageCombinedOperation*)operation
                             completion:(nullable SDInternalCompletionBlock)completionBlock
                                  image:(nullable UIImage *)image
                                   data:(nullable NSData *)data
                                  error:(nullable NSError *)error
                              cacheType:(SDImageCacheType)cacheType
                               finished:(BOOL)finished
                                    url:(nullable NSURL *)url {
    dispatch_main_async_safe(^{
        if (operation && !operation.isCancelled && completionBlock) {
            completionBlock(image, data, error, cacheType, finished, url);
        }
    });
}

@end


@implementation SDWebImageCombinedOperation

- (void)cancel {
    @synchronized(self) {
        self.cancelled = YES;
        if (self.cacheOperation) {
            [self.cacheOperation cancel];
            self.cacheOperation = nil;
        }
        if (self.downloadToken) {
            [self.manager.imageDownloader cancel:self.downloadToken];
        }
        [self.manager safelyRemoveOperationFromRunning:self];
    }
}

@end
